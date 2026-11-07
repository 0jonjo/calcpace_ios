import CoreLocation
import UIKit
import UserNotifications

extension Notification.Name {
    /// The run, its GPS or its problem changed: the screen draws again.
    static let recorderChanged = Notification.Name("app.calcpace.recorder.changed")
}

/// The run recorder: Core Location at full accuracy while a run is on, every
/// event in the run's log as it happens (`RecorderFiles`), and the run handed
/// to the `Outbox` on Save. The Android app's RecorderService.kt, in the
/// iPhone's terms:
///
/// - Location "while using the app" is enough: updates started with the app
///   in front go on with the screen locked or the app in the background,
///   because the app declares the location background mode and holds a
///   `CLBackgroundActivitySession` while recording. iOS shows the blue
///   location pill, which brings the app back.
/// - iOS may still end the app in the background. The log on disk keeps the
///   run up to the last fix; the next launch opens the recording screen on it
///   (`Mode.orphan`), to be resumed or saved, as on Android. A local
///   notification set a few minutes ahead and pushed back while the run is
///   alive goes off only when nothing is pushing it any more: "Recording
///   stopped", the iPhone's version of Android's notice.
/// - GPS stays on through a pause, so the app is not suspended in a pocket
///   and Resume finds a warm fix; paused fixes are not logged.
///
/// Main thread only. CLLocationManager calls its delegate on the thread that
/// made it, which is the main one.
@MainActor
final class Recorder: NSObject {
    static let shared = Recorder()

    enum Mode: Equatable {
        /// No run: Start.
        case ready
        case running
        case paused
        /// The log has a run no one is recording: iOS ended the app mid-run.
        case orphan
        /// The log has a stopped run the outbox doesn't: its save failed.
        case unsaved
    }

    enum Problem: Equatable {
        /// The log can't be written: recording paused, what was written is safe.
        case diskFull
        /// Location was taken away mid-run: recording paused.
        case noLocation
    }

    /// No fix for this long while running: the screen says the GPS is gone.
    static let noGpsWarning: Int64 = 20_000
    /// Below either, a run is too short to save (D11 of the spec).
    static let minSaveMeters = 100.0
    static let minSaveMillis: Int64 = 60_000
    /// How far ahead "Recording stopped" is set, and how often it is pushed back.
    static let watchdogDelay: TimeInterval = 180
    static let watchdogEvery: TimeInterval = 30
    static let watchdogId = "recorder.stopped"
    /// The purpose key of NSLocationTemporaryUsageDescriptionDictionary.
    static let fullAccuracyPurpose = "RunRecording"

    let files: RecorderFiles
    private let manager = CLLocationManager()

    /// The run this process records, nil when none.
    private(set) var live: Track?
    private(set) var problem: Problem?
    /// The last run saved since launch: the screen follows its upload.
    private(set) var finished: Outbox.Entry?
    /// Whether location services are on for the whole phone (read off the main thread).
    private(set) var servicesEnabled = true

    private var logged: Track?
    private var loggedRead = false
    private var backgroundSession: CLBackgroundActivitySession?
    private var timer: Timer?
    private var watchdogAt: Date?

    init(files: RecorderFiles = RecorderFiles()) {
        self.files = files
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        refreshServices()
    }

    // MARK: What the screen reads

    var mode: Mode {
        if let live { return live.isRunning ? .running : .paused }
        guard let logged = loggedTrack() else { return .ready }
        return logged.isStopped ? .unsaved : .orphan
    }

    /// The run on screen: the live one, or the one left in the log.
    var track: Track? { live ?? loggedTrack() }

    var authorization: CLAuthorizationStatus { manager.authorizationStatus }
    var canLocate: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }
    var isPrecise: Bool { manager.accuracyAuthorization == .fullAccuracy }

    /// A run in the log or on: the app opens on the recording screen.
    var hasRun: Bool { mode != .ready }

    /// The time the run in the log ends: its last event, not now.
    func lastEventAt(_ track: Track?) -> Int64 {
        [track?.lastFixAt, track?.pausedAt, track?.runningSince, track?.startedAt].compactMap { $0 }.max() ?? Self.now()
    }

    /// Since the last fix, or since the run started or resumed when none came since.
    func silentFor(_ track: Track, now: Int64) -> Int64 {
        guard let since = [track.lastFixAt, track.runningSince].compactMap({ $0 }).max() else { return 0 }
        return max(now - since, 0)
    }

    // MARK: What the screen does

    func requestLocation() {
        manager.requestWhenInUseAuthorization()
    }

    /// Precise location turned off: ask for it for this session.
    func requestFullAccuracy() {
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: Self.fullAccuracyPurpose)
    }

    /// Start a new run, or go on with the one the log holds (iOS ended the
    /// app mid-run): its dead minutes stay on the clock, the runner was
    /// running through them. A stopped run whose save failed is saved first.
    func start() {
        guard live == nil, canLocate else { return }
        problem = nil
        if let logged = loggedTrack(), logged.isStopped {
            guard save(logged) else { changed(); return }
            forgetLog()
        }
        if let logged = loggedTrack(), !logged.isStopped {
            live = logged
            forgetLog()
            if logged.isPaused { record(.resume(time: Self.now())) }
        } else {
            let now = Self.now()
            live = Track()
            forgetLog()
            record(.start(time: now, recordingId: RecorderFiles.newRecordingId(), utcOffsetSeconds: RecorderFiles.offset(at: now)))
        }
        // Fixed from here: the unit a run counts in never changes under it.
        RecorderPrefs.unit = RecorderPrefs.unit
        finished = nil
        updateLocation()
        startTimer()
        if live?.isRunning == true { pushWatchdog(force: true) }
        changed()
    }

    func pause() {
        guard let live, live.isRunning else { return }
        record(.pause(time: Self.now()))
        cancelWatchdog()
        changed()
    }

    func resume() {
        guard let live, live.isPaused, canLocate else { return }
        problem = nil
        record(.resume(time: Self.now()))
        if live.isRunning { pushWatchdog(force: true) }
        changed()
    }

    /// Save: the live run ends now; one from the log where the log ends, as
    /// the confirmation said. Then it goes to the outbox and up.
    func finish() {
        if let live {
            record(.stop(time: Self.now()))
            // Saved or not, no longer live: a failed save leaves the stopped
            // run in the log (Mode.unsaved), to be saved again.
            self.live = nil
            _ = save(live)
        } else if let logged = loggedTrack() {
            if !logged.isStopped {
                let end = lastEventAt(logged)
                try? files.append(.stop(time: end))
                logged.add(.stop(time: end))
            }
            _ = save(logged)
        }
        forgetLog()
        stopRecording()
        changed()
    }

    /// Throws the run away, live or in the log: nothing kept.
    func discard() {
        live = nil
        problem = nil
        files.discard()
        forgetLog()
        stopRecording()
        changed()
    }

    /// The saved run's page opened: the screen forgets it.
    func forgetFinished() {
        finished = nil
        changed()
    }

    // MARK: Private

    static func now() -> Int64 { millis(Date()) }

    static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    private func loggedTrack() -> Track? {
        if !loggedRead {
            loggedRead = true
            let track = Track(files.readCurrent())
            logged = track.startedAt == nil ? nil : track
        }
        return logged
    }

    private func forgetLog() {
        loggedRead = false
        logged = nil
    }

    /// In the log first, then on screen. A log that can't be written pauses
    /// the run: what is on disk is safe, and nothing new is counted that the
    /// file wouldn't have.
    private func record(_ event: RunEvent) {
        guard let live else { return }
        do {
            try files.append(event)
            live.add(event)
        } catch {
            problem = .diskFull
            live.add(event)
            if live.isRunning { live.add(.pause(time: Self.now())) }
            cancelWatchdog()
        }
    }

    // True when the run is in the outbox; then it goes up.
    private func save(_ track: Track) -> Bool {
        do {
            finished = try files.finish(track, now: Self.now())
            RecorderUploads.shared.send()
            return true
        } catch {
            return false
        }
    }

    private func stopRecording() {
        timer?.invalidate()
        timer = nil
        cancelWatchdog()
        updateLocation()
    }

    /// GPS on while a run is on (in the background too), off otherwise: the
    /// location is read only between Start and Finish, as the permission
    /// text says.
    private func updateLocation() {
        let recording = live != nil
        manager.allowsBackgroundLocationUpdates = recording
        manager.showsBackgroundLocationIndicator = recording
        if recording {
            if backgroundSession == nil { backgroundSession = CLBackgroundActivitySession() }
        } else {
            backgroundSession?.invalidate()
            backgroundSession = nil
        }
        if canLocate && recording {
            manager.startUpdatingLocation()
        } else {
            manager.stopUpdatingLocation()
        }
    }

    // Once a second while a run is on: the clock on screen, "no GPS for 40 s",
    // and the watchdog pushed back. Core Location keeps the app running in the
    // background, so this keeps ticking there too.
    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let recorder = Recorder.shared
                if recorder.live?.isRunning == true { recorder.pushWatchdog(force: false) }
                recorder.changed()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func pushWatchdog(force: Bool) {
        if !force, let at = watchdogAt, Date().timeIntervalSince(at) < Self.watchdogEvery { return }
        watchdogAt = Date()
        let content = UNMutableNotificationContent()
        content.title = RecorderStrings.text("recorder_notif_stopped_title")
        content.body = RecorderStrings.text("recorder_notif_stopped_body")
        content.sound = .default
        content.userInfo = [RecorderNotices.openKey: true]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Self.watchdogDelay, repeats: false)
        // Same id: each one replaces the last, so only the latest can go off.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.watchdogId, content: content, trigger: trigger))
    }

    private func cancelWatchdog() {
        watchdogAt = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.watchdogId])
    }

    // Location services for the whole phone: Apple asks not to read this on
    // the main thread.
    private func refreshServices() {
        Task.detached(priority: .utility) { [weak self] in
            let enabled = CLLocationManager.locationServicesEnabled()
            await MainActor.run {
                guard let self, self.servicesEnabled != enabled else { return }
                self.servicesEnabled = enabled
                self.changed()
            }
        }
    }

    private func changed() {
        NotificationCenter.default.post(name: .recorderChanged, object: self)
    }

    private func locationLost() {
        guard let live else { return }
        problem = .noLocation
        if live.isRunning { record(.pause(time: Self.now())) }
        cancelWatchdog()
    }
}

extension Recorder: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated { received(locations) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            refreshServices()
            if live != nil && !canLocate { locationLost() }
            updateLocation()
            changed()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            if (error as? CLError)?.code == .denied, live != nil { locationLost() }
            changed()
        }
    }

    private func received(_ locations: [CLLocation]) {
        guard let live else { return }
        for location in locations {
            // One iOS couldn't place, or one from before this stretch began
            // (the position it kept from earlier, handed over first). A batch
            // iOS held back and delivers late is kept: its times are its own.
            let time = Self.millis(location.timestamp)
            guard location.horizontalAccuracy >= 0, live.isRunning,
                  let since = live.runningSince, time >= since - 1000
            else { continue }
            record(.fix(RunFix(
                time: time,
                lat: location.coordinate.latitude,
                lon: location.coordinate.longitude,
                altitude: location.verticalAccuracy > 0 ? location.altitude : nil,
                accuracy: location.horizontalAccuracy
            )))
        }
    }
}

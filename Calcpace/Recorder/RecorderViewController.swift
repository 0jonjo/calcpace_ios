import CoreLocation
import UIKit
import UserNotifications

/// The recording screen, over the site from its Record button, the app
/// icon's quick action or at launch with a run on: what the phone still has
/// to allow, Start / Pause / Resume / Finish, time, distance and pace, and,
/// once the run is saved, where its upload stands. A run that goes up while
/// this is in front opens its edit page in the app. The Android app's
/// RecorderActivity.kt, in UIKit.
///
/// Finish needs a pause first and a confirmation with the run's numbers: a
/// pocket can pause a run, never end it. A run iOS cut short comes back here
/// from its log, to be resumed or saved. Closing the screen never stops a
/// run: it goes on in the background, and the Record button brings it back.
///
/// Light only, like the site: black on white reads best in the sun.
@MainActor
final class RecorderViewController: UIViewController {
    private enum Tone { case ok, warn, info }

    private static let green = UIColor(red: 0x10 / 255, green: 0xB9 / 255, blue: 0x81 / 255, alpha: 1)
    private static let greenText = UIColor(red: 0x04 / 255, green: 0x78 / 255, blue: 0x57 / 255, alpha: 1)
    private static let ink = UIColor(red: 0x11 / 255, green: 0x18 / 255, blue: 0x27 / 255, alpha: 1)
    private static let muted = UIColor(red: 0x4B / 255, green: 0x55 / 255, blue: 0x63 / 255, alpha: 1)
    private static let line = UIColor(red: 0xE5 / 255, green: 0xE7 / 255, blue: 0xEB / 255, alpha: 1)
    private static let okBackground = UIColor(red: 0xEC / 255, green: 0xFD / 255, blue: 0xF5 / 255, alpha: 1)
    private static let okLine = UIColor(red: 0xA7 / 255, green: 0xF3 / 255, blue: 0xD0 / 255, alpha: 1)
    private static let warnBackground = UIColor(red: 0xFF / 255, green: 0xFB / 255, blue: 0xEB / 255, alpha: 1)
    private static let warnLine = UIColor(red: 0xFC / 255, green: 0xD3 / 255, blue: 0x4D / 255, alpha: 1)
    private static let infoBackground = UIColor(red: 0xF9 / 255, green: 0xFA / 255, blue: 0xFB / 255, alpha: 1)

    private let recorder = Recorder.shared
    private let uploads = RecorderUploads.shared

    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let status = UILabel()
    private let units = UISegmentedControl(items: [RunFormat.Unit.km.label, RunFormat.Unit.mi.label])
    private let clock = UILabel()
    private let distance = UILabel()
    private let paceNow = UILabel()
    private let paceAverage = UILabel()
    private let noticeCard = UIView()
    private let noticeTitle = UILabel()
    private let noticeBody = UILabel()
    private let noticeButtons = [UIButton(type: .system), UIButton(type: .system)]
    private var noticeActions: [() -> Void] = []
    private let locationCard = RecorderPermissionCard()
    private let preciseCard = RecorderPermissionCard()
    private let notificationsCard = RecorderPermissionCard()
    private let hint = UILabel()
    private let primary = UIButton(type: .system)
    private let finishButton = UIButton(type: .system)

    private var timer: Timer?
    /// The tap on Start waits for the location sheet's answer.
    private var startWhenAllowed = false
    private var notificationStatus: UNAuthorizationStatus = .authorized

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .light
        view.backgroundColor = .white
        build()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(changed), name: .recorderChanged, object: nil)
        center.addObserver(self, selector: #selector(changed), name: .recorderUploadsChanged, object: nil)
        center.addObserver(self, selector: #selector(cameBack), name: UIApplication.didBecomeActiveNotification, object: nil)
        uploads.onArrival = { [weak self] arrival in self?.arrived(arrival) ?? false }
        uploads.kick()
        readNotificationStatus()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        render()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        NotificationCenter.default.removeObserver(self)
        uploads.onArrival = nil
        timer?.invalidate()
        timer = nil
    }

    @objc private func changed() {
        if startWhenAllowed, recorder.canLocate {
            startWhenAllowed = false
            beforeRecording { [weak self] in self?.recorder.start() }
        } else if startWhenAllowed, recorder.authorization != .notDetermined {
            startWhenAllowed = false
        }
        render()
    }

    @objc private func cameBack() {
        readNotificationStatus()
        render()
    }

    // MARK: What is on screen

    private func render() {
        let now = Recorder.now()
        let unit = RecorderPrefs.unit
        let mode = recorder.mode
        let track: Track?
        switch mode {
        case .running, .paused, .orphan, .unsaved: track = recorder.track
        case .ready: track = nil
        }
        // A run read from the log ends where the log does, not now.
        let until = mode == .orphan ? recorder.lastEventAt(track) : track?.stoppedAt ?? now
        let saved = mode == .ready ? recorder.finished : nil

        clock.text = RunFormat.clock(track?.movingMillis(until) ?? saved?.movingMillis ?? 0)
        distance.text = RunFormat.distance(track?.distanceMeters ?? saved?.distanceMeters ?? 0, unit: unit, locale: RecorderLanguage.locale)
        paceNow.text = RunFormat.pace(mode == .running ? track?.currentPace(now) : nil, unit: unit)
        let average = track?.averagePace(until) ?? saved.flatMap { entry in
            entry.distanceMeters < 50 ? nil : Double(entry.movingMillis) / 1000 / (entry.distanceMeters / 1000)
        }
        paceAverage.text = RunFormat.pace(average, unit: unit)

        units.isHidden = mode != .ready
        units.selectedSegmentIndex = unit == .km ? 0 : 1
        renderStatus(mode, track: track, now: now)
        renderButtons(mode)
        renderNotice(mode, track: track, now: now)
        renderPermissions(mode)
    }

    private func renderStatus(_ mode: Recorder.Mode, track: Track?, now: Int64) {
        switch mode {
        case .running:
            if let accuracy = track?.lastAccuracy, track?.lastFixAt != nil {
                status.text = RecorderStrings.format("recorder_gps_accuracy", Int(accuracy))
            } else {
                status.text = RecorderStrings.text("recorder_gps_searching")
            }
            status.textColor = Self.greenText
        case .paused:
            status.text = RecorderStrings.format("recorder_paused_for", RunFormat.clock(now - (track?.pausedAt ?? now)))
            status.textColor = Self.muted
        case .ready:
            status.text = RecorderStrings.text("recorder_ready")
            status.textColor = Self.muted
        case .orphan, .unsaved:
            status.text = nil
        }
        status.isHidden = status.text == nil
        switch mode {
        case .running: hint.text = RecorderStrings.text("recorder_pause_first")
        case .ready: hint.text = RecorderStrings.text("recorder_start_hint")
        default: hint.text = nil
        }
        hint.isHidden = hint.text == nil
    }

    private func renderButtons(_ mode: Recorder.Mode) {
        let (key, color): (String, UIColor) = switch mode {
        case .ready: ("recorder_start", Self.green)
        case .running: ("recorder_pause", Self.ink)
        case .paused: ("recorder_resume", Self.green)
        case .orphan: ("recorder_resume_run", Self.green)
        case .unsaved: ("recorder_finish_and_save", Self.green)
        }
        // Only when it changes: this runs every second, and a system button
        // given its title again mid-tap can lose the tap.
        let title = RecorderStrings.text(key)
        if primary.title(for: .normal) != title { primary.setTitle(title, for: .normal) }
        if primary.backgroundColor != color { primary.backgroundColor = color }
        let hideFinish = !(mode == .paused || mode == .orphan)
        if finishButton.isHidden != hideFinish { finishButton.isHidden = hideFinish }
        let finishTitle = RecorderStrings.text(mode == .orphan ? "recorder_finish_and_save" : "recorder_finish")
        if finishButton.title(for: .normal) != finishTitle { finishButton.setTitle(finishTitle, for: .normal) }
    }

    private func renderNotice(_ mode: Recorder.Mode, track: Track?, now: Int64) {
        if recorder.problem == .diskFull {
            return notice(.warn, nil, RecorderStrings.text("recorder_disk_full"))
        }
        if recorder.problem == .noLocation && !recorder.canLocate {
            return notice(.warn, nil, RecorderStrings.text("recorder_lost_location"),
                          (RecorderStrings.text("recorder_perm_location_settings"), Self.openSettings))
        }
        switch mode {
        case .orphan:
            guard let track else { return hideNotice() }
            let until = recorder.lastEventAt(track)
            notice(.warn, RecorderStrings.format("recorder_killed_title", time(until)),
                   RecorderStrings.format("recorder_killed_body", dist(track.distanceMeters), RunFormat.clock(track.movingMillis(until)))
                       + "\n\n" + RecorderStrings.text("recorder_killed_resume_hint"))
        case .unsaved:
            notice(.warn, nil, RecorderStrings.text("recorder_save_failed"))
        case .running:
            if let track, recorder.silentFor(track, now: now) >= Recorder.noGpsWarning {
                notice(.warn, nil, RecorderStrings.format("recorder_no_gps", Int(recorder.silentFor(track, now: now) / 1000)))
            } else {
                hideNotice()
            }
        case .ready:
            renderUpload()
        case .paused:
            hideNotice()
        }
    }

    /// Where the last run saved stands, or that the run is up.
    private func renderUpload() {
        let entries = recorder.files.outbox.entries()
        let justSaved = recorder.finished?.recordingId
        guard let entry = entries.first(where: { $0.recordingId == justSaved }) ?? entries.last else {
            if let arrival = uploads.lastArrival, arrival.recordingId == justSaved {
                notice(.ok, nil, RecorderStrings.format("recorder_uploaded", dist(arrival.distanceMeters)),
                       (RecorderStrings.text("recorder_open_run"), { [weak self] in self?.openInApp(arrival.editURL) }))
            } else if !uploads.online {
                notice(.info, nil, RecorderStrings.text("recorder_offline_ok"))
            } else {
                hideNotice()
            }
            return
        }
        let more = entries.count > 1 ? "\n\n" + RecorderStrings.count("recorder_queue_count", entries.count) : ""
        let runDistance = dist(entry.distanceMeters)
        let share: (String, () -> Void) = (RecorderStrings.text("recorder_share_gpx"), { [weak self] in self?.shareGpx(entry) })
        let tryNow: (String, () -> Void) = (RecorderStrings.text("recorder_retry_now"), { [weak self] in self?.uploads.send(retryParked: true) })
        let card = UploadPlan.card(entry.state, sending: uploads.sendingId == entry.recordingId, online: uploads.online,
                                   attempted: entry.lastAttemptAt != nil)
        switch card {
        case .sending:
            notice(.info, RecorderStrings.text("recorder_sending"), RecorderStrings.format("recorder_sending_hint", runDistance) + more)
        case .queued:
            notice(.info, RecorderStrings.text("recorder_queued_title"),
                   RecorderStrings.format("recorder_queued_body", runDistance, RunFormat.clock(entry.movingMillis)) + "\n"
                       + RecorderStrings.text("recorder_queued_close_hint") + more,
                   (RecorderStrings.text("recorder_close"), { [weak self] in self?.close() }))
        case .failed:
            notice(.warn, RecorderStrings.text("recorder_failed_title"),
                   RecorderStrings.format("recorder_failed_body", runDistance, time(entry.lastAttemptAt ?? 0)) + more, tryNow, share)
        case .signedOut:
            notice(.warn, RecorderStrings.text("recorder_failed_title"), RecorderStrings.format("recorder_signed_out_body", runDistance) + more,
                   (RecorderStrings.text("recorder_sign_in"), { [weak self] in self?.openInApp(nil) }), share)
        case .noProfile:
            notice(.warn, RecorderStrings.text("recorder_failed_title"), RecorderStrings.format("recorder_no_profile_body", runDistance) + more,
                   (RecorderStrings.text("recorder_open_calcpace"), { [weak self] in self?.openInApp(nil) }), share)
        case .refused:
            notice(.warn, RecorderStrings.text("recorder_refused_title"), RecorderStrings.format("recorder_refused_body", runDistance) + more,
                   share, (RecorderStrings.text("recorder_retry_now"), { [weak self] in self?.uploads.send(retryRefused: true) }))
        }
    }

    private func notice(_ tone: Tone, _ title: String?, _ body: String, _ actions: (String, () -> Void)...) {
        switch tone {
        case .ok:
            noticeCard.backgroundColor = Self.okBackground
            noticeCard.layer.borderColor = Self.okLine.cgColor
        case .warn:
            noticeCard.backgroundColor = Self.warnBackground
            noticeCard.layer.borderColor = Self.warnLine.cgColor
        case .info:
            noticeCard.backgroundColor = Self.infoBackground
            noticeCard.layer.borderColor = Self.line.cgColor
        }
        noticeTitle.text = title
        noticeTitle.isHidden = title == nil
        noticeBody.text = body
        noticeActions = actions.map(\.1)
        for (index, button) in noticeButtons.enumerated() {
            button.isHidden = index >= actions.count
            if index < actions.count, button.title(for: .normal) != actions[index].0 { button.setTitle(actions[index].0, for: .normal) }
        }
        noticeCard.isHidden = false
    }

    private func hideNotice() {
        noticeCard.isHidden = true
        noticeActions = []
    }

    private func renderPermissions(_ mode: Recorder.Mode) {
        let missingLocation = !recorder.canLocate
        let refused = recorder.authorization == .denied || recorder.authorization == .restricted
        // Nothing to allow while running; paused or cut short, only what stops a resume.
        let asking = mode == .ready || mode == .paused || mode == .orphan
        if !recorder.servicesEnabled && asking {
            locationCard.show(title: RecorderStrings.text("recorder_perm_location"),
                              body: RecorderStrings.text("recorder_location_off"),
                              button: RecorderStrings.text("recorder_perm_location_settings")) { Self.openSettings() }
        } else if missingLocation && asking {
            locationCard.show(title: RecorderStrings.text("recorder_perm_location"),
                              body: RecorderStrings.text("recorder_perm_location_hint"),
                              button: RecorderStrings.text(refused ? "recorder_perm_location_settings" : "recorder_perm_location_btn")) { [weak self] in
                if refused { Self.openSettings() } else { self?.recorder.requestLocation() }
            }
        } else {
            locationCard.isHidden = true
        }
        if recorder.canLocate && !recorder.isPrecise && mode != .unsaved {
            preciseCard.show(title: RecorderStrings.text("recorder_perm_location"),
                             body: RecorderStrings.text("recorder_precise_off"),
                             button: RecorderStrings.text("recorder_perm_notif_btn")) { [weak self] in self?.recorder.requestFullAccuracy() }
        } else {
            preciseCard.isHidden = true
        }
        if mode == .ready && (notificationStatus == .notDetermined || notificationStatus == .denied) {
            notificationsCard.show(title: RecorderStrings.text("recorder_perm_notif"),
                                   body: RecorderStrings.text("recorder_perm_notif_hint"),
                                   button: RecorderStrings.text("recorder_perm_notif_btn")) { [weak self] in self?.askForNotifications() }
        } else {
            notificationsCard.isHidden = true
        }
    }

    // MARK: What the buttons do

    @objc private func onPrimary() {
        switch recorder.mode {
        case .ready, .orphan: beforeRecording { [weak self] in self?.recorder.start() }
        case .running: recorder.pause()
        case .paused: beforeRecording { [weak self] in self?.recorder.resume() }
        case .unsaved: recorder.finish()
        }
        render()
    }

    @objc private func onFinish() {
        guard let track = recorder.track else { return }
        confirmFinish(track)
    }

    @objc private func onUnit() {
        RecorderPrefs.unit = units.selectedSegmentIndex == 1 ? .mi : .km
        render()
    }

    @objc private func onNoticeButton(_ sender: UIButton) {
        guard let index = noticeButtons.firstIndex(of: sender), index < noticeActions.count else { return }
        noticeActions[index]()
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    /// Location (required), asked for when it was never asked; once per
    /// install, notifications. Then `then`.
    private func beforeRecording(_ then: @escaping () -> Void) {
        switch recorder.authorization {
        case .notDetermined:
            startWhenAllowed = true
            recorder.requestLocation()
            return
        case .denied, .restricted:
            Self.openSettings()
            return
        default:
            break
        }
        guard !RecorderPrefs.askedNotifications, notificationStatus == .notDetermined else { return then() }
        RecorderPrefs.askedNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in
                self.readNotificationStatus()
                then()
            }
        }
    }

    private func askForNotifications() {
        if notificationStatus == .denied {
            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
            return
        }
        RecorderPrefs.askedNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in self.readNotificationStatus() }
        }
    }

    /// Pause first, then this: the run's numbers and Save. A run too short to
    /// save offers only Discard or Keep running; nothing is ever discarded
    /// without a second "Delete".
    private func confirmFinish(_ track: Track) {
        let until = recorder.mode == .orphan ? recorder.lastEventAt(track) : Recorder.now()
        let runDistance = dist(track.distanceMeters)
        let time = RunFormat.clock(track.movingMillis(until))
        let alert: UIAlertController
        if track.distanceMeters < Recorder.minSaveMeters || track.movingMillis(until) < Recorder.minSaveMillis {
            alert = UIAlertController(title: RecorderStrings.text("recorder_too_short_title"),
                                      message: RecorderStrings.format("recorder_too_short_body", runDistance, time), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: RecorderStrings.text("recorder_keep_going"), style: .cancel) { [weak self] _ in self?.keepGoing() })
            alert.addAction(UIAlertAction(title: RecorderStrings.text("recorder_discard"), style: .destructive) { [weak self] _ in
                self?.confirmDiscard(runDistance)
            })
        } else {
            let pace = RunFormat.pace(track.averagePace(until), unit: RecorderPrefs.unit)
            alert = UIAlertController(title: RecorderStrings.text("recorder_finish_title"),
                                      message: RecorderStrings.format("recorder_finish_body", runDistance, time, pace), preferredStyle: .alert)
            let save = UIAlertAction(title: RecorderStrings.text("recorder_save"), style: .default) { [weak self] _ in
                self?.recorder.finish()
                self?.render()
            }
            alert.addAction(save)
            alert.addAction(UIAlertAction(title: RecorderStrings.text("recorder_keep_going"), style: .cancel) { [weak self] _ in self?.keepGoing() })
            alert.addAction(UIAlertAction(title: RecorderStrings.text("recorder_discard"), style: .destructive) { [weak self] _ in
                self?.confirmDiscard(runDistance)
            })
            alert.preferredAction = save
        }
        present(alert, animated: true)
    }

    private func keepGoing() {
        if recorder.mode == .orphan {
            beforeRecording { [weak self] in self?.recorder.start() }
        } else {
            beforeRecording { [weak self] in self?.recorder.resume() }
        }
    }

    private func confirmDiscard(_ runDistance: String) {
        let alert = UIAlertController(title: nil, message: RecorderStrings.format("recorder_discard_confirm", runDistance), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: RecorderStrings.text("recorder_back"), style: .cancel))
        alert.addAction(UIAlertAction(title: RecorderStrings.text("recorder_discard_delete"), style: .destructive) { [weak self] _ in
            self?.recorder.discard()
        })
        present(alert, animated: true)
    }

    /// The run that just went up: its edit page, if this screen is still on
    /// the saved run and in front. Recording another one already, or with
    /// the app away, the notification says it instead.
    private func arrived(_ arrival: RecorderUploads.Arrival) -> Bool {
        guard recorder.mode == .ready, arrival.recordingId == recorder.finished?.recordingId,
              viewIfLoaded?.window != nil, UIApplication.shared.applicationState == .active
        else { return false }
        recorder.forgetFinished()
        openInApp(arrival.editURL)
        return true
    }

    /// Back to the site, on `url` when there is one (the run's edit page).
    private func openInApp(_ url: URL?) {
        // From what presented this screen: whatever is over it (the
        // confirmation still on its way out) goes too.
        let base = presentingViewController ?? self
        base.dismiss(animated: true) {
            if let url { PushInbox.shared.open(url) }
            RecorderUploads.shared.kick()
        }
    }

    private func shareGpx(_ entry: Outbox.Entry) {
        guard let data = try? Data(contentsOf: recorder.files.outbox.gpx(entry.recordingId)),
              let file = try? ShareFiles.write(data, named: entry.filename, in: "shared_runs")
        else { return }
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = view
        present(sheet, animated: true)
    }

    private func readNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                self.notificationStatus = status
                self.render()
            }
        }
    }

    private static func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    // MARK: Small things

    private func dist(_ meters: Double) -> String {
        RunFormat.distance(meters, unit: RecorderPrefs.unit, locale: RecorderLanguage.locale)
    }

    private func time(_ epochMillis: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = RecorderLanguage.locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: Gpx.date(epochMillis))
    }

    // MARK: Layout

    private func build() {
        titleLabel.text = RecorderStrings.text("recorder_title")
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = Self.ink
        titleLabel.accessibilityTraits = .header

        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = Self.ink
        closeButton.accessibilityLabel = RecorderStrings.text("recorder_close")
        closeButton.accessibilityIdentifier = "recorder.close"
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)

        let header = UIView()
        [titleLabel, closeButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview($0)
        }
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 52),
            closeButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 8)
        ])

        status.font = .systemFont(ofSize: 15, weight: .semibold)
        status.numberOfLines = 0
        status.textAlignment = .center
        status.accessibilityIdentifier = "recorder.status"

        units.addTarget(self, action: #selector(onUnit), for: .valueChanged)
        units.accessibilityIdentifier = "recorder.unit"

        clock.font = .monospacedDigitSystemFont(ofSize: 76, weight: .bold)
        clock.adjustsFontSizeToFitWidth = true
        clock.minimumScaleFactor = 0.5
        clock.textAlignment = .center
        clock.textColor = Self.ink
        clock.accessibilityIdentifier = "recorder.clock"

        distance.accessibilityIdentifier = "recorder.distance"
        paceNow.accessibilityIdentifier = "recorder.pace_now"
        paceAverage.accessibilityIdentifier = "recorder.pace_avg"
        let numbers = UIStackView(arrangedSubviews: [
            metric(RecorderStrings.text("recorder_distance"), distance, size: 34),
            metric(RecorderStrings.text("recorder_pace_now"), paceNow, size: 34)
        ])
        numbers.axis = .horizontal
        numbers.distribution = .fillEqually
        numbers.spacing = 12

        buildNotice()

        let content = UIStackView(arrangedSubviews: [
            status, units, metric(RecorderStrings.text("recorder_time"), clock, size: nil), numbers,
            metric(RecorderStrings.text("recorder_pace_avg"), paceAverage, size: 26),
            noticeCard, locationCard, preciseCard, notificationsCard
        ])
        content.axis = .vertical
        content.spacing = 18
        content.isLayoutMarginsRelativeArrangement = true
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 20, bottom: 24, trailing: 20)

        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)

        hint.font = .systemFont(ofSize: 14)
        hint.textColor = Self.muted
        hint.numberOfLines = 0
        hint.textAlignment = .center
        hint.accessibilityIdentifier = "recorder.hint"

        primary.titleLabel?.font = .systemFont(ofSize: 24, weight: .bold)
        primary.setTitleColor(.white, for: .normal)
        primary.layer.cornerRadius = 22
        primary.accessibilityIdentifier = "recorder.primary"
        primary.addTarget(self, action: #selector(onPrimary), for: .touchUpInside)

        finishButton.titleLabel?.font = .systemFont(ofSize: 20, weight: .semibold)
        finishButton.setTitleColor(Self.ink, for: .normal)
        finishButton.layer.cornerRadius = 20
        finishButton.layer.borderWidth = 2
        finishButton.layer.borderColor = Self.ink.cgColor
        finishButton.accessibilityIdentifier = "recorder.finish"
        finishButton.addTarget(self, action: #selector(onFinish), for: .touchUpInside)

        let bottom = UIStackView(arrangedSubviews: [hint, primary, finishButton])
        bottom.axis = .vertical
        bottom.spacing = 12
        bottom.isLayoutMarginsRelativeArrangement = true
        bottom.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)

        let divider = UIView()
        divider.backgroundColor = Self.line

        [header, scroll, divider, bottom].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: guide.topAnchor),
            header.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: divider.topAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            bottom.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            primary.heightAnchor.constraint(equalToConstant: 80),
            finishButton.heightAnchor.constraint(equalToConstant: 64),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
    }

    private func metric(_ caption: String, _ value: UILabel, size: CGFloat?) -> UIView {
        let label = UILabel()
        label.text = caption
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = Self.muted
        if let size {
            value.font = .monospacedDigitSystemFont(ofSize: size, weight: .bold)
            value.textColor = Self.ink
            value.adjustsFontSizeToFitWidth = true
            value.minimumScaleFactor = 0.5
        }
        label.textAlignment = size == nil ? .center : .natural
        let stack = UIStackView(arrangedSubviews: [label, value])
        stack.axis = .vertical
        stack.spacing = 2
        stack.alignment = size == nil ? .fill : .leading
        return stack
    }

    private func buildNotice() {
        noticeCard.layer.cornerRadius = 16
        noticeCard.layer.borderWidth = 1
        noticeCard.isHidden = true
        noticeTitle.font = .systemFont(ofSize: 16, weight: .bold)
        noticeTitle.textColor = Self.ink
        noticeTitle.numberOfLines = 0
        noticeTitle.accessibilityIdentifier = "recorder.notice.title"
        noticeBody.font = .systemFont(ofSize: 15)
        noticeBody.textColor = Self.ink
        noticeBody.numberOfLines = 0
        noticeBody.accessibilityIdentifier = "recorder.notice.body"
        for (index, button) in noticeButtons.enumerated() {
            button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
            button.titleLabel?.numberOfLines = 0
            button.setTitleColor(Self.greenText, for: .normal)
            button.contentHorizontalAlignment = .leading
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.accessibilityIdentifier = "recorder.notice.action\(index)"
            button.addTarget(self, action: #selector(onNoticeButton(_:)), for: .touchUpInside)
        }
        let stack = UIStackView(arrangedSubviews: [noticeTitle, noticeBody] + noticeButtons)
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        noticeCard.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: noticeCard.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: noticeCard.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: noticeCard.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: noticeCard.trailingAnchor, constant: -16)
        ])
    }
}

/// One thing the phone still has to allow, with the button that does it.
final class RecorderPermissionCard: UIView {
    private let title = UILabel()
    private let body = UILabel()
    private let button = UIButton(type: .system)
    private var action: (() -> Void)?

    init() {
        super.init(frame: .zero)
        isHidden = true
        backgroundColor = UIColor(red: 0xF9 / 255, green: 0xFA / 255, blue: 0xFB / 255, alpha: 1)
        layer.cornerRadius = 16
        layer.borderWidth = 1
        layer.borderColor = UIColor(red: 0xE5 / 255, green: 0xE7 / 255, blue: 0xEB / 255, alpha: 1).cgColor
        title.font = .systemFont(ofSize: 16, weight: .bold)
        title.numberOfLines = 0
        body.font = .systemFont(ofSize: 15)
        body.textColor = UIColor(red: 0x4B / 255, green: 0x55 / 255, blue: 0x63 / 255, alpha: 1)
        body.numberOfLines = 0
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        button.setTitleColor(UIColor(red: 0x04 / 255, green: 0x78 / 255, blue: 0x57 / 255, alpha: 1), for: .normal)
        button.contentHorizontalAlignment = .leading
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [title, body, button])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(title: String, body: String, button label: String, action: @escaping () -> Void) {
        self.title.text = title
        self.body.text = body
        if button.title(for: .normal) != label { button.setTitle(label, for: .normal) }
        self.action = action
        isHidden = false
    }

    @objc private func tapped() { action?() }
}

import Foundation
import HealthKit
import UIKit

/// Sends what Apple Health holds to the site, for the account whose token
/// the page handed over (AppleHealthComponent "link"):
///
/// - right after the link (the last 30 days), each time the app comes to the
///   front, and whenever HealthKit wakes the app for a new workout or route
///   (`HKObserverQuery` + background delivery, at most hourly, often later);
/// - what changed since the anchor of the last sync the server answered,
///   deletions included, so a workout is sent again until it was taken;
/// - the workouts read before their distance or route was saved, read again
///   by id until they have it (PendingWorkouts);
/// - a 401 means the link died on the server (signed out, password changed,
///   disconnected): the app forgets it, as on "forget".
///
/// One sync at a time, in the order asked.
actor HealthSync {
    static let shared = HealthSync()

    enum Outcome: Equatable {
        case unlinked
        case unavailable
        case failedToRead
        case sent(SyncPlan.After)
    }

    private let reader: HealthReader
    private let links: HealthLinkStore
    private var uploader: HealthUploader
    private var current: Task<Outcome, Never>?
    private var observers: [HKObserverQuery] = []

    /// A new workout, and a route its app saved after it (PendingWorkouts).
    private static let observedTypes: [HKSampleType] = [HealthReader.workoutType, HealthReader.routeType]

    init(reader: HealthReader = HealthReader(), links: HealthLinkStore = .shared, uploader: HealthUploader = HealthUploader()) {
        self.reader = reader
        self.links = links
        self.uploader = uploader
    }

    /// At launch (AppDelegate), so HealthKit has an observer to wake. Asks
    /// for background delivery again too: HealthKit stops it for an app that
    /// failed to answer a few wake-ups, and the call is idempotent.
    func resume() async {
        guard links.token != nil else { return }
        observe()
        await enableBackgroundDelivery()
    }

    /// The page's "link", after a granted "enable".
    @discardableResult
    func link(token: String) async -> Bool {
        guard links.link(token: token) else { return false }
        observe()
        await enableBackgroundDelivery()
        Task { await run() }
        return true
    }

    /// The page's "forget", or a 401. HealthKit's permissions stay: only the
    /// athlete changes them, in Settings.
    func forget() async {
        links.clear()
        for observer in observers {
            reader.store.stop(observer)
        }
        observers = []
        try? await reader.store.disableAllBackgroundDelivery()
    }

    @discardableResult
    func run() async -> Outcome {
        let previous = current
        let task = Task { () -> Outcome in
            _ = await previous?.value
            return await syncOnce()
        }
        current = task
        return await task.value
    }

    #if DEBUG
    /// The UI tests' fake server (HealthHarness).
    func use(uploader: HealthUploader) {
        self.uploader = uploader
    }
    #endif

    // MARK: Private

    private func syncOnce() async -> Outcome {
        guard HealthReader.isAvailable else { return .unavailable }
        guard let token = links.token else { return .unlinked }

        let anchor = links.anchor
        let changes: HealthChanges
        do {
            changes = try await reader.changes(since: anchor, startingAfter: SyncPlan.initialStart(now: Date()))
        } catch {
            // The phone is locked (Apple Health is encrypted then), or no
            // permission was ever answered: next time.
            return .failedToRead
        }

        let now = Int(Date().timeIntervalSince1970)
        var pending = PendingWorkouts.remove(PendingWorkouts.expire(links.pending, now: now), changes.deleted)
        let changed = Set(changes.workouts.map { WorkoutMapper.id($0.uuid) })
        let waiting = pending.filter { !changed.contains($0.key) }
        var rechecked: [HKWorkout] = []
        // Gone from Apple Health meanwhile: no longer waited for. A read that
        // fails leaves them waiting.
        if let found = try? await reader.workouts(ids: Set(waiting.keys.compactMap(UUID.init(uuidString:)))) {
            rechecked = found
            let still = Set(found.map { WorkoutMapper.id($0.uuid) })
            pending = PendingWorkouts.remove(pending, waiting.keys.filter { !still.contains($0) })
        }

        var sessions: [WireSession] = []
        for workout in changes.workouts + rechecked {
            let id = WorkoutMapper.id(workout.uuid)
            let isChanged = changed.contains(id)
            let reason = waiting[id]?.reason
            // Waiting only for its route, which is still not there: the rest
            // is not read again.
            if !isChanged, reason == .route, await reader.route(of: workout) == nil { continue }
            let next = PendingWorkouts.next(WorkoutMapper.judge(await reader.facts(workout)), waiting: pending[id]?.reason, changed: isChanged)
            if let session = next.send { sessions.append(session) }
            if let wait = next.wait {
                pending = PendingWorkouts.mark(pending, id, wait, now: now)
            } else {
                pending = PendingWorkouts.remove(pending, [id])
            }
        }

        var afters: [SyncPlan.After] = []
        for upload in HealthPayload.batches(sessions: sessions, deleted: changes.deleted, initial: anchor == nil) {
            // Forgotten meanwhile (the page, a 401): nothing more leaves the phone.
            guard links.token == token else { return .unlinked }
            let after = SyncPlan.after(await uploader.send(upload, token: token))
            afters.append(after)
            if after != .advance { break }
        }

        let overall = SyncPlan.overall(afters)
        switch overall {
        case .advance: links.save(anchor: changes.anchor, pending: pending, for: token)
        case .unlink: if links.token == token { await forget() }
        case .retry: break
        }
        return .sent(overall)
    }

    private func enableBackgroundDelivery() async {
        for type in Self.observedTypes {
            // Without it, still synced each time the app comes to the front.
            try? await reader.store.enableBackgroundDelivery(for: type, frequency: .hourly)
        }
    }

    private func observe() {
        guard observers.isEmpty else { return }
        // HealthKit waits for completion() before it counts the wake-up as
        // handled, and stops waking an app that misses it a few times; it
        // also fires once as soon as the query starts. A background task
        // keeps the app up for the sync, and its expiry still answers.
        for type in Self.observedTypes {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                guard error == nil, let self else {
                    completion()
                    return
                }
                Task { @MainActor in
                    let wake = BackgroundWake(completion)
                    await self.run()
                    wake.finish()
                }
            }
            observers.append(query)
            reader.store.execute(query)
        }
    }
}

/// One wake-up by HealthKit: a background task keeps the app up for the
/// sync, and HealthKit's completion handler is called once, at the sync's
/// end or when the background time runs out, whichever comes first.
@MainActor
private final class BackgroundWake {
    private var completion: (() -> Void)?
    private var task = UIBackgroundTaskIdentifier.invalid

    init(_ completion: @escaping () -> Void) {
        self.completion = completion
        task = UIApplication.shared.beginBackgroundTask(withName: "apple-health-sync") { [weak self] in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    func finish() {
        completion?()
        completion = nil
        if task != .invalid {
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
    }
}

import Foundation
import HealthKit

/// Sends what Apple Health holds to the site, for the account whose token
/// the page handed over (AppleHealthComponent "link"):
///
/// - right after the link (the last 30 days), each time the app comes to the
///   front, and whenever HealthKit wakes the app for a new workout
///   (`HKObserverQuery` + background delivery, at most hourly, often later);
/// - what changed since the anchor of the last sync the server answered,
///   deletions included, so a workout is sent again until it was taken;
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
    private var observer: HKObserverQuery?

    init(reader: HealthReader = HealthReader(), links: HealthLinkStore = .shared, uploader: HealthUploader = HealthUploader()) {
        self.reader = reader
        self.links = links
        self.uploader = uploader
    }

    /// At launch (AppDelegate), so HealthKit has an observer to wake.
    func resume() {
        guard links.token != nil else { return }
        observe()
    }

    /// The page's "link", after a granted "enable".
    @discardableResult
    func link(token: String) async -> Bool {
        guard links.link(token: token) else { return false }
        observe()
        do {
            try await reader.store.enableBackgroundDelivery(for: HealthReader.workoutType, frequency: .hourly)
        } catch {
            // Still synced each time the app comes to the front.
        }
        Task { await run() }
        return true
    }

    /// The page's "forget", or a 401. HealthKit's permissions stay: only the
    /// athlete changes them, in Settings.
    func forget() async {
        links.clear()
        if let observer {
            reader.store.stop(observer)
            self.observer = nil
        }
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

        var sessions: [WireSession] = []
        for workout in changes.workouts {
            if let session = WorkoutMapper.wire(await reader.facts(workout)) {
                sessions.append(session)
            }
        }

        var afters: [SyncPlan.After] = []
        for upload in HealthPayload.batches(sessions: sessions, deleted: changes.deleted, initial: anchor == nil) {
            let after = SyncPlan.after(await uploader.send(upload, token: token))
            afters.append(after)
            if after != .advance { break }
        }

        let overall = SyncPlan.overall(afters)
        switch overall {
        case .advance: links.save(anchor: changes.anchor, for: token)
        case .unlink: if links.token == token { await forget() }
        case .retry: break
        }
        return .sent(overall)
    }

    private func observe() {
        guard observer == nil else { return }
        // HealthKit waits for completion() before it counts the wake-up as
        // handled; it also fires once as soon as the query starts.
        let query = HKObserverQuery(sampleType: HealthReader.workoutType, predicate: nil) { [weak self] _, completion, error in
            guard error == nil, let self else {
                completion()
                return
            }
            Task {
                await self.run()
                completion()
            }
        }
        observer = query
        reader.store.execute(query)
    }
}

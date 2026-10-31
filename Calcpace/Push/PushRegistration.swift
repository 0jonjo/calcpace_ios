import UIKit

/// The APNs device token, for the push bridge component. iOS hands it over
/// through the AppDelegate, some time after
/// `registerForRemoteNotifications()`, or says it couldn't; this collects
/// whoever is waiting in between (a "connect" and an "enable" can overlap)
/// and answers them all at once, with the token or with nil.
///
/// It never hangs: without an answer from iOS in `defaultTimeout` (no
/// network, a simulator, a build without the push entitlement) everybody
/// gets nil and the page goes on without a token. The token is asked for
/// afresh each time, as Apple recommends: it can change, and iOS answers
/// quickly once it has one.
///
/// Main thread only.
@MainActor
final class PushRegistration {
    static let shared = PushRegistration()

    nonisolated static let defaultTimeout: TimeInterval = 10

    private let register: @MainActor () -> Void
    private let timeout: TimeInterval
    private var waiting: [@MainActor (String?) -> Void] = []
    private var attempt = 0

    init(timeout: TimeInterval = PushRegistration.defaultTimeout,
         register: @escaping @MainActor () -> Void = { UIApplication.shared.registerForRemoteNotifications() }) {
        self.timeout = timeout
        self.register = register
    }

    /// Calls back with the token, or nil if iOS didn't give one in time.
    func token(_ callback: @escaping @MainActor (String?) -> Void) {
        waiting.append(callback)
        guard waiting.count == 1 else { return }

        attempt += 1
        let current = attempt
        register()
        Task { [weak self, timeout] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, self.attempt == current else { return }
            self.resolve(nil)
        }
    }

    /// From `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    func didRegister(_ deviceToken: Data) {
        resolve(PushToken.hex(deviceToken))
    }

    /// From `application(_:didFailToRegisterForRemoteNotificationsWithError:)`.
    func didFail() {
        resolve(nil)
    }

    // A late answer, or one iOS sends on its own, finds nobody waiting and
    // goes nowhere: the home page asks again on its next visit.
    private func resolve(_ token: String?) {
        let callbacks = waiting
        waiting = []
        attempt += 1
        callbacks.forEach { $0(token) }
    }
}

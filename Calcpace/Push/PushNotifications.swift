import UserNotifications

/// The app's side of a "your run is in" notification iOS has drawn from the
/// server's APNs payload (`PushPayload`):
///
/// - With the app open, iOS would keep it quiet; it shows as a banner (and
///   in the list, with its sound) all the same, since the athlete is waiting
///   for the run, maybe on another screen of the app.
/// - A tap opens the run's page in the app (`PushInbox`). Anything the
///   payload doesn't hold up to just brings the app to the front.
///
/// Set as the notification center's delegate before the app finishes
/// launching: a tap that launched the app is only delivered to a delegate
/// that is already there.
final class PushNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let notice = PushPayload.parse(response.notification.request.content.userInfo, rootURL: rootURL)
        else { return }

        let url = notice.url
        Task { @MainActor in PushInbox.shared.open(url) }
    }
}

/// Where a tapped notification's page waits for the Navigator. On a cold
/// start, the tap that launched the app can come before the scene has made
/// its Navigator and started it on the home page; the page is held until
/// SceneDelegate says it is ready, and then opens on top of the home, so
/// Back leads there. The same after the scene was let go with the process
/// still up: SceneDelegate disconnects, and the next scene's ready takes
/// it. A route that answers false (its scene is gone) keeps the page
/// waiting too. Only the last tap is kept.
///
/// Main thread only.
@MainActor
final class PushInbox {
    static let shared = PushInbox()

    private var pending: URL?
    private var route: (@MainActor (URL) -> Bool)?

    func open(_ url: URL) {
        pending = url
        deliver()
    }

    /// From SceneDelegate, once `navigator.start()` has run: opens what is
    /// waiting, and every tap after. `route` answers whether it opened it.
    func ready(_ route: @escaping @MainActor (URL) -> Bool) {
        self.route = route
        deliver()
    }

    /// From SceneDelegate, when its scene goes: taps wait again.
    func disconnect() {
        route = nil
    }

    private func deliver() {
        guard let url = pending, let route else { return }
        if route(url) { pending = nil }
    }
}

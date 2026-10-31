import HotwireNative
import UIKit
import UserNotifications

/// The site's "push" bridge component (bridge/push_controller.js on the home
/// page: the "your run is in" card), as in the Android app
/// (PushComponent.kt). Both events are answered with `{ status, token? }`:
/// the phone's `PushStatus` and, once the athlete has allowed notifications,
/// the APNs device token (`PushToken`), which the page registers against its
/// session:
///
/// - "connect" `{}`: where things stand. Never prompts.
/// - "enable" `{}`: the athlete tapped "turn on". Shows the system prompt
///   (only the first time: iOS never asks twice), then answers like
///   "connect".
///
/// With "granted" the app asks iOS for the token and answers once it comes,
/// or without one if it doesn't (`PushRegistration`). Only while the WebView
/// shows the home page (`PushPages`); messages sent from any other page get
/// no answer, and neither does a page left before the answer was ready.
final class PushComponent: BridgeComponent {
    override class var name: String { "push" }

    override func onReceive(message: Message) {
        guard onHomePage else { return }

        switch message.event {
        case "connect":
            answer(message)
        case "enable":
            enable(message)
        default:
            break
        }
    }

    // MARK: Private

    private struct Reply: Encodable {
        let status: String
        var token: String? = nil
    }

    private var onHomePage: Bool {
        PushPages.isHome(delegate?.webView?.url, rootURL: AppDelegate.rootURL)
    }

    private func enable(_ message: Message) {
        Task {
            // Allowed, refused or failed: the status read afterwards says
            // which, so the outcome itself is not needed.
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            answer(message)
        }
    }

    private func answer(_ message: Message) {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            let status = PushStatus.of(settings.authorizationStatus)
            guard status == PushStatus.granted else {
                return send(message, Reply(status: status))
            }
            PushRegistration.shared.token { [weak self] token in
                self?.send(message, Reply(status: status, token: token))
            }
        }
    }

    // The page may have moved on while the prompt was up or the token was
    // on its way: an answer only goes back to the home page.
    private func send(_ message: Message, _ data: Reply) {
        guard onHomePage else { return }
        reply(with: message.replacing(data: data))
    }
}

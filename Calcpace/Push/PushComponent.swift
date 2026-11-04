import HotwireNative
import UIKit
import UserNotifications

/// The site's "push" bridge component (bridge/push_controller.js: the home
/// page's "your run is in" card, and Settings' "Notifications" row and page),
/// as in the Android app (PushComponent.kt, which still answers on the home
/// page only until its next build). "connect" and "enable" are
/// answered with `{ status, token? }`:
/// the phone's `PushStatus` and, once the athlete has allowed notifications,
/// the APNs device token (`PushToken`), which the page registers against its
/// session:
///
/// - "connect" `{}`: where things stand. Never prompts.
/// - "enable" `{}`: the athlete tapped "turn on". Shows the system prompt
///   (only the first time: iOS never asks twice), then answers like
///   "connect".
/// - "openSettings" `{}`: the athlete refused notifications and tapped
///   "open phone settings". Opens this app's notification settings; no answer: the page
///   asks again ("connect") when it is back on screen.
///
/// With "granted" the app asks iOS for the token and answers once it comes,
/// or without one if it doesn't (`PushRegistration`). Only while the WebView
/// shows one of the pages `PushPages` allows; messages sent from any other
/// page get no answer, and neither does a page left before the answer was
/// ready.
final class PushComponent: BridgeComponent {
    override class var name: String { "push" }

    override func onReceive(message: Message) {
        guard onAllowedPage else { return }

        switch message.event {
        case "connect":
            answer(message)
        case "enable":
            enable(message)
        case "openSettings":
            openSettings()
        default:
            break
        }
    }

    // MARK: Private

    private struct Reply: Encodable {
        let status: String
        var token: String? = nil
    }

    private var onAllowedPage: Bool {
        PushPages.allows(delegate?.webView?.url, rootURL: AppDelegate.rootURL)
    }

    // This app's notification settings (iOS 16+; some iOS versions land on
    // the app's settings page instead, one tap away). BridgeComponent is
    // @MainActor, so this already runs on the main thread.
    private func openSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
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
    // on its way: an answer only goes back to a page that may have it.
    private func send(_ message: Message, _ data: Reply) {
        guard onAllowedPage else { return }
        reply(with: message.replacing(data: data))
    }
}

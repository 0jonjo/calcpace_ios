import HotwireNative
import UIKit

/// The site's "apple-health" bridge component
/// (bridge/apple_health_controller.js in calcpace_web: the home page's card
/// and Settings › Apple Health). Contract in calcpace_docs
/// plans/calcpace_ios_i2_plan.md; the Android app's "health"
/// (HealthComponent.kt), without steps, background or writing:
///
/// - "connect" `{}` → `{ status, linked }`: "available" when the phone has
///   Apple Health; whether this app holds a link token.
/// - "enable" `{}` → `{ status, granted, grant? }`, once the HealthKit sheet
///   was answered. `granted` says the sheet was answered, not what was
///   allowed: HealthKit never tells. Only then comes `grant`, a one-time
///   value for "link" (`LinkGate`).
/// - "link" `{ token, grant }` → `{ linked }`: the token the page got from
///   POST /health_connect/link, with the grant of its "enable"; the app keeps
///   it and syncs (`HealthSync`).
/// - "forget" `{}` → `{}`: the server has no iOS link for this session; the
///   app drops its token and stops syncing.
///
/// Only while the WebView shows the home page or Settings › Apple Health
/// (`HealthPages`); messages sent from any other page get no answer.
final class AppleHealthComponent: BridgeComponent {
    override class var name: String { "apple-health" }

    private let gate = LinkGate()

    override func onReceive(message: Message) {
        guard onHealthPage else { return }

        switch message.event {
        case "connect":
            answer(message, State(status: status, linked: HealthLinkStore.shared.token != nil))
        case "enable":
            enable(message)
        case "link":
            link(message)
        case "forget":
            Task {
                await HealthSync.shared.forget()
                answer(message, Empty())
            }
        default:
            break
        }
    }

    // MARK: Private

    private struct State: Encodable {
        let status: String
        let linked: Bool
    }

    private struct Enabled: Encodable {
        let status: String
        let granted: Bool
        var grant: String? = nil
    }

    private struct Linked: Encodable {
        let linked: Bool
    }

    private struct Empty: Encodable {}

    private var status: String {
        HealthReader.isAvailable ? "available" : "unavailable"
    }

    private var onHealthPage: Bool {
        HealthPages.isAllowed(delegate?.webView?.url, rootURL: AppDelegate.rootURL)
    }

    private func enable(_ message: Message) {
        guard HealthReader.isAvailable else {
            return answer(message, Enabled(status: status, granted: false))
        }
        Task {
            let granted: Bool
            do {
                try await HealthReader().requestAuthorization()
                granted = true
            } catch {
                granted = false
            }
            // The page may have moved on while the sheet was up: a grant only
            // goes back to the page that asked.
            guard onHealthPage else { return }
            answer(message, Enabled(status: status, granted: granted, grant: granted ? gate.open() : nil))
        }
    }

    private func link(_ message: Message) {
        let request = HealthPayload.linkRequest(message.jsonData)
        // Spent either way, right or wrong.
        let allowed = gate.consume(request?.grant)
        guard allowed, let token = request?.token, HealthPayload.isLinkToken(token) else {
            return answer(message, Linked(linked: false))
        }
        Task {
            let linked = await HealthSync.shared.link(token: token)
            answer(message, Linked(linked: linked))
        }
    }

    private func answer<T: Encodable>(_ message: Message, _ data: T) {
        reply(with: message.replacing(data: data))
    }
}

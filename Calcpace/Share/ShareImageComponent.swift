import HotwireNative
import UIKit
import WebKit

/// The site's "share-image" bridge component
/// (bridge/share_image_controller.js in a run's share dialog), as in the
/// Android app (ShareImageComponent.kt). The page hands over the card it
/// already has, so the app never fetches anything with the session's cookies:
///
/// - "share" `{ filename, data }` (data = the PNG in base64, `SharePayload`)
///   → `{ ok: true }` once the share sheet is up, or
///   `{ ok: false, error: "invalid" }` when the payload doesn't hold up, or
///   `{ ok: false, error: "failed" }` when writing the file or showing the
///   sheet didn't work, or the screen was no longer on view to show it (the
///   athlete taps again).
///
/// Only while the WebView shows a run's page (`SharePages`); messages sent
/// from any other page get no answer. `SharePublicImageComponent` is the same
/// on the calculator's page, under a name of its own. One share at a time: a "share" that
/// arrives while another is being prepared (a double tap) is ignored and never
/// answered; the first one's answer stands for both. The page gives up on an
/// unanswered message after a while and says the share failed.
///
/// Decoding and writing happen off the main thread. If the page went away in
/// the meantime, nothing is shown and nothing is answered.
class ShareImageComponent: BridgeComponent {
    override class var name: String { "share-image" }

    private var preparing = false

    private var viewController: UIViewController? {
        delegate?.destination as? UIViewController
    }

    override func onReceive(message: Message) {
        guard message.event == "share", !preparing, onAllowedPage else { return }

        preparing = true
        let jsonData = message.jsonData
        Task {
            let prepared = await Task.detached(priority: .userInitiated) { ShareImageComponent.prepare(jsonData) }.value
            preparing = false
            show(prepared, answering: message)
        }
    }

    // MARK: Private

    private enum Prepared {
        case ready(URL)
        case invalid
        case failed
    }

    private struct Reply: Encodable {
        let ok: Bool
        var error: String? = nil
    }

    /// The page this component answers on.
    class func allows(_ location: URL?) -> Bool {
        SharePages.isRunPage(location, rootURL: AppDelegate.rootURL)
    }

    private var onAllowedPage: Bool {
        Self.allows(delegate?.webView?.url)
    }

    private nonisolated static func prepare(_ jsonData: String) -> Prepared {
        guard let image = SharePayload.parse(jsonData) else { return .invalid }
        guard let file = try? ShareFiles.write(image.bytes, named: image.filename, in: ShareFiles.images) else { return .failed }
        return .ready(file)
    }

    private func show(_ prepared: Prepared, answering message: Message) {
        // Gone, or the WebView moved on to another page: drop it quietly.
        guard let viewController, onAllowedPage else { return }

        switch prepared {
        case .invalid:
            answer(message, Reply(ok: false, error: "invalid"))
        case .failed:
            answer(message, Reply(ok: false, error: "failed"))
        case .ready(let file):
            answer(message, present(file, from: viewController) ? Reply(ok: true) : Reply(ok: false, error: "failed"))
        }
    }

    // Not on screen (the app went to the background, another screen is on
    // top, something else is presented): showing the sheet would fail or
    // land over whatever the athlete went to, so that counts as failed.
    private func present(_ file: URL, from viewController: UIViewController) -> Bool {
        guard viewController.viewIfLoaded?.window != nil,
              viewController.presentedViewController == nil,
              UIApplication.shared.applicationState == .active
        else { return false }

        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = viewController.view
        viewController.present(sheet, animated: true)
        return true
    }

    private func answer(_ message: Message, _ reply: Reply) {
        self.reply(with: message.replacing(data: reply))
    }
}

/// The site's "share-public-image" bridge component
/// (bridge/share_public_image_controller.js): the age grade's picture on the
/// calculator's page, through the same message and sheet as "share-image". A
/// name of its own so that an app from before it (1.1.0), which accepts
/// "share-image" on a run's page only, is never asked from the calculator.
final class SharePublicImageComponent: ShareImageComponent {
    override class var name: String { "share-public-image" }

    override class func allows(_ location: URL?) -> Bool {
        SharePages.isCalculatorPage(location, rootURL: AppDelegate.rootURL)
    }
}

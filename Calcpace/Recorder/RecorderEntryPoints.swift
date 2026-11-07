import HotwireNative
import UIKit

/// The "recorder" bridge component. It handles no message: registering it is
/// what puts "recorder" in the WebView's user agent ("bridge-components: […
/// recorder]"), and that is how the site knows this build can record and
/// draws its Record button (RecorderEntryHelper and the calcpace-recorder
/// class on the site). A build without it keeps the site's "+". The Android
/// app's RecorderComponent.kt.
final class RecorderComponent: BridgeComponent {
    override class var name: String { "recorder" }

    override func onReceive(message: Message) {}
}

/// The site's Record button (`RecorderEntry`): opens the recording screen
/// over the page, and cancels the visit, so the page under it stays where it
/// was. The link's language becomes the screen's, and its unit (the
/// profile's) the one runs count in, unless a run is on: a run never changes
/// unit under it. As the CSV export, every way a link is followed reaches the
/// router first, so /record never loads in the WebView; the server's answer
/// there is only for builds without this.
final class RecordRouteDecisionHandler: RouteDecisionHandler {
    let name = "recorder"

    func matches(proposal: VisitProposal, configuration: Navigator.Configuration) -> Bool {
        RecorderEntry.visit(proposal.url, rootURL: AppDelegate.rootURL) != nil
    }

    func handle(proposal: VisitProposal, configuration: Navigator.Configuration, navigator: Navigating) -> Router.Decision {
        guard let visit = RecorderEntry.visit(proposal.url, rootURL: AppDelegate.rootURL) else { return .cancel }
        // The router calls in on the main thread.
        MainActor.assumeIsolated {
            let presenter = navigator.activeNavigationController
            if let locale = visit.locale { RecorderPrefs.siteLocale = locale }
            if let unit = visit.unit, Recorder.shared.mode == .ready { RecorderPrefs.unit = unit }
            RecorderScreen.present(over: presenter)
        }
        return .cancel
    }
}

/// Opens the recording screen: from the Record button, the app icon's quick
/// action, the "recording stopped" notification, and at launch when a run
/// is still on or was cut short. Asks that come before the scene is up wait
/// for it (`ready`), as `PushInbox` does for pages.
@MainActor
enum RecorderScreen {
    /// The app icon's "Record a run" (UIApplicationShortcutItems).
    nonisolated static let shortcutType = "app.calcpace.ios.record"

    private static var pending = false
    private static var root: (() -> UIViewController?)?

    /// From SceneDelegate, once its window is up: what to present over.
    static func ready(_ root: @escaping () -> UIViewController?) {
        self.root = root
        // On the next turn: the window has just been made key, and a
        // presentation during the scene's connection can be dropped.
        DispatchQueue.main.async {
            if pending || Recorder.shared.hasRun { open() }
        }
    }

    static func disconnect() {
        root = nil
    }

    /// Present it over whatever is on top, or once the scene is ready.
    static func open() {
        guard let base = root?() else {
            pending = true
            return
        }
        pending = false
        present(over: base)
    }

    static func present(over base: UIViewController) {
        var top = base
        while let presented = top.presentedViewController { top = presented }
        if top is RecorderViewController { return }
        let screen = RecorderViewController()
        screen.modalPresentationStyle = .fullScreen
        top.present(screen, animated: true)
    }
}

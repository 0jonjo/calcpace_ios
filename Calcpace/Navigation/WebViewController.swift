import HotwireNative
import UIKit

/// Every screen of the site. The front page and the tab bar's destinations
/// are roots: the path configuration opens them with replace_root and marks
/// them tab_root (calcpace_web's TabRoots), and there the site's header is the
/// only one, so the navigation bar hides. Every other screen is pushed and
/// keeps the bar, for Back and the page's title; the site drops its own header
/// there (data-tab-root on <body>), so the two never stack.
///
/// The bar hides only on a tab root that is also the bottom of its stack. If
/// one were ever pushed, it would show the bar rather than a screen with no
/// way back.
final class WebViewController: HotwireWebViewController {
    // The page starts below the bar instead of scrolling under it: on iOS 26
    // a bar over the page took its colours from it and settled dark, with a
    // white title, over the site's white pages. Where the bar is hidden the
    // page still reaches the top, and the site clears the status bar.
    override func viewDidLoad() {
        super.viewDidLoad()
        edgesForExtendedLayout = []
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(hidesNavigationBar, animated: animated)
    }

    // An animated setViewControllers (a replace_root) calls viewWillAppear
    // before the stack holds this screen, so it looked pushed there. Tab roots
    // replace without animation; this catches whatever still gets it wrong.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let navigationController, navigationController.isNavigationBarHidden != hidesNavigationBar else { return }
        navigationController.setNavigationBarHidden(hidesNavigationBar, animated: true)
    }

    // Every visit that renders, where the page landed, redirects followed:
    // how a sign-in's redeem went (AppAuth).
    override func visitableDidRender() {
        super.visitableDidRender()
        navigationItem.title = ScreenTitle.short(visitableView.webView?.title)
        AppAuth.shared.visitCompleted(currentVisitableURL)
    }

    private var hidesNavigationBar: Bool {
        guard navigationController?.viewControllers.first === self else { return false }
        return Hotwire.config.pathConfiguration.properties(for: initialVisitableURL).tabRoot
    }
}

extension PathProperties {
    /// A screen of the tab bar, opened as a root ("tab_root" in the path
    /// configuration).
    var tabRoot: Bool {
        self["tab_root"] as? Bool ?? false
    }
}

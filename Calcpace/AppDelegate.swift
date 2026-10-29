import HotwireNative
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    static let rootURL = URL(string: "https://calcpace.app")!

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Before any Navigator exists: each one builds its WebViews, and
        // their user agent, when it is created.
        Hotwire.config.applicationUserAgentPrefix = AppUserAgent.prefix()
        Hotwire.config.backButtonDisplayMode = .minimal
        Hotwire.config.showDoneButtonOnModals = true
        Hotwire.config.defaultViewController = { url in WebViewController(url: url) }

        // Native pieces the site can drive: "share-image" hands a run's share
        // card to the share sheet. The user agent lists them, so the site only
        // talks to components this build has.
        Hotwire.registerBridgeComponents([ShareImageComponent.self])

        // Order matters: the first handler that matches decides. The runs
        // list's CSV export must be caught before in-app navigation claims
        // every calcpace.app URL. The other three are Hotwire's defaults.
        Hotwire.registerRouteDecisionHandlers([
            CsvExportRouteDecisionHandler(),
            AppNavigationRouteDecisionHandler(),
            SafariViewControllerRouteDecisionHandler(),
            SystemNavigationRouteDecisionHandler()
        ])

        // The bundled copy works offline and on first launch; the site's copy
        // (calcpace_web's ConfigurationsController#ios_v1), once fetched, wins
        // and lets routing change without a store release.
        Hotwire.loadPathConfiguration(from: [
            .file(Bundle.main.url(forResource: "path-configuration", withExtension: "json")!),
            .server(Self.rootURL.appendingPathComponent("configurations/ios_v1.json"))
        ])

        // A solid white bar, like the site's header, rather than a
        // see-through one at the top of the page that blurs or darkens with
        // what scrolls under it.
        let bar = UINavigationBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = .white
        bar.titleTextAttributes = [.foregroundColor: UIColor.black]
        UINavigationBar.appearance().standardAppearance = bar
        UINavigationBar.appearance().scrollEdgeAppearance = bar
        UINavigationBar.appearance().compactAppearance = bar
#if DEBUG
        Hotwire.config.debugLoggingEnabled = true
#endif
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}

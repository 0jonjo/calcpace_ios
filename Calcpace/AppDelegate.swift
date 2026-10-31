import HotwireNative
import UIKit
import UserNotifications

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    static let rootURL = URL(string: "https://calcpace.app")!

    // The notification center holds its delegate weakly.
    private let notifications = PushNotifications(rootURL: AppDelegate.rootURL)

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Before any Navigator exists: each one builds its WebViews, and
        // their user agent, when it is created.
        Hotwire.config.applicationUserAgentPrefix = AppUserAgent.prefix()
        Hotwire.config.backButtonDisplayMode = .minimal
        Hotwire.config.showDoneButtonOnModals = true
        Hotwire.config.defaultViewController = { url in WebViewController(url: url) }

        // Native pieces the site can drive: "share-image" hands a run's share
        // card to the share sheet, "apple-health" links Apple Health, "push"
        // turns on the "your run is in" notification. The user agent lists
        // them, so the site only talks to components this build has.
        Hotwire.registerBridgeComponents([ShareImageComponent.self, AppleHealthComponent.self, PushComponent.self])

        // Before launch finishes, or a tap on a notification that launched
        // the app is never delivered.
        UNUserNotificationCenter.current().delegate = notifications
#if DEBUG
        // The UI tests' push run (PushTests) has no home card to tap, signed
        // out: the app asks at launch instead.
        if ProcessInfo.processInfo.arguments.contains("-askForNotifications") {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
#endif

        // HealthKit wakes the app for new workouts only if an observer is
        // set up here, at launch.
        HealthLinkStore.shared.forgetPreviousInstall()
        Task {
#if DEBUG
            // The UI tests' Apple Health run links and syncs on its own.
            if HealthHarness.isOn { return }
#endif
            await HealthSync.shared.resume()
        }

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

    // The APNs device token, or why there is none, for whoever asked
    // (PushRegistration: the push component's "connect" and "enable").
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushRegistration.shared.didRegister(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushRegistration.shared.didFail()
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}

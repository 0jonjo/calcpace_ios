import HotwireNative
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    // Made after AppDelegate has configured Hotwire (the user agent), since
    // the Navigator builds its WebViews when it is created.
    private lazy var navigator = Navigator(
        configuration: .init(name: "main", startLocation: AppDelegate.rootURL)
    )

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        window = UIWindow(windowScene: windowScene)
#if DEBUG
        // The UI tests' Apple Health run: no site, a fake server.
        if HealthHarness.isOn {
            window?.rootViewController = HealthHarnessViewController()
            window?.makeKeyAndVisible()
            return
        }
#endif
        // The site has no dark mode: a phone in dark mode would otherwise get
        // black bars and sheets around white pages.
        window?.overrideUserInterfaceStyle = .light
        window?.rootViewController = navigator.rootViewController
        window?.makeKeyAndVisible()

        navigator.start()

        // A tapped "your run is in" notification opens its run on top of the
        // home page. The tap that launched the app may have come before this
        // point, and waited for it (PushInbox).
        PushInbox.shared.ready { [weak self] url in
            guard let self else { return false }
            self.navigator.route(url)
            return true
        }

        // A link from outside that launched the app opens on top of the
        // home page too. URLs on the app's own scheme (connectionOptions'
        // urlContexts) are never read: see scene(_:openURLContexts:).
        if let location = connectionOptions.userActivities.lazy.compactMap({ Self.outsideLocation($0) }).first {
            navigator.route(location)
        }
    }

    // A link from outside with the app running: a calcpace.app page handed
    // over by iOS (a universal link, once the site's
    // apple-app-site-association names the app). Ordinary pages only
    // (IncomingLink).
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
#if DEBUG
        if HealthHarness.isOn { return }
#endif
        guard let location = Self.outsideLocation(userActivity) else { return }
        navigator.route(location)
    }

    // The app's own scheme, app.calcpace.ios, isn't registered: a sign-in
    // comes back through its web authentication session (AppAuthBrowser),
    // never this way. Should iOS ever deliver one anyway, from another app
    // or a link, it is dropped without a look: a ticket from outside is
    // someone else's.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {}

    // iOS may let the scene go while the process stays (HealthKit's
    // background delivery keeps it up): a tap from now on waits for the next
    // scene's Navigator instead of reaching this one.
    func sceneDidDisconnect(_ scene: UIScene) {
        PushInbox.shared.disconnect()
    }

    // Each time the app comes to the front: what Apple Health got since,
    // sooner than a background delivery would bring it.
    func sceneDidBecomeActive(_ scene: UIScene) {
#if DEBUG
        if HealthHarness.isOn { return }
#endif
        Task { await HealthSync.shared.run() }
    }

    private static func outsideLocation(_ activity: NSUserActivity) -> URL? {
        guard activity.activityType == NSUserActivityTypeBrowsingWeb, let url = activity.webpageURL else { return nil }
        return IncomingLink.location(forOutsideLink: url, rootURL: AppDelegate.rootURL)
    }
}

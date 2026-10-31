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
            self?.navigator.route(url)
        }
    }

    // Each time the app comes to the front: what Apple Health got since,
    // sooner than a background delivery would bring it.
    func sceneDidBecomeActive(_ scene: UIScene) {
#if DEBUG
        if HealthHarness.isOn { return }
#endif
        Task { await HealthSync.shared.run() }
    }
}

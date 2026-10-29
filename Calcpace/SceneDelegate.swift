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
        // The site has no dark mode: a phone in dark mode would otherwise get
        // black bars and sheets around white pages.
        window?.overrideUserInterfaceStyle = .light
        window?.rootViewController = navigator.rootViewController
        window?.makeKeyAndVisible()

        navigator.start()
    }
}

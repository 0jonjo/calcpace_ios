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
#if DEBUG
        Hotwire.config.debugLoggingEnabled = true
#endif
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}

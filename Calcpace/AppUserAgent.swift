import Foundation

/// The start of the WebView's user agent, in the Android app's format
/// ("Calcpace Android/2.0.0 (3);"). Hotwire Native adds "Hotwire Native iOS;
/// Turbo Native iOS; bridge-components: […]" after it. The site reads it in
/// the browser to tell the iOS app apart (the `ios-app` class on `<html>`),
/// and its session list names the app and the build that signed in.
///
/// A build installed from TestFlight adds "TestFlight;" after the build, as
/// its own token so "(build)" reads as before: until the App Store has the
/// app, the site sends iPhones to TestFlight's public link, and this is how
/// it tells those installs from the store's once both exist (calcpace_docs
/// plans/ios_saida_testflight_plan.md).
enum AppUserAgent {
    static func prefix(version: String?, build: String?, testFlight: Bool = false) -> String {
        let channel = testFlight ? " TestFlight;" : ""
        guard let version, !version.isEmpty else { return "Calcpace iOS;\(channel)" }
        guard let build, !build.isEmpty else { return "Calcpace iOS/\(version);\(channel)" }
        return "Calcpace iOS/\(version) (\(build));\(channel)"
    }

    static func prefix(bundle: Bundle = .main) -> String {
        prefix(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            testFlight: isTestFlight(receiptURL: bundle.appStoreReceiptURL)
        )
    }

    /// TestFlight installs carry a sandbox receipt; the App Store's is named
    /// "receipt". The long-standing check, read once at launch; a build run
    /// from Xcode or the simulator reads as TestFlight too, which only ever
    /// reaches the site from a developer's own device.
    static func isTestFlight(receiptURL: URL?) -> Bool {
        receiptURL?.lastPathComponent == "sandboxReceipt"
    }
}

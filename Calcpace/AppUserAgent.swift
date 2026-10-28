import Foundation

/// The start of the WebView's user agent, in the Android app's format
/// ("Calcpace Android/2.0.0 (3);"). Hotwire Native adds "Hotwire Native iOS;
/// Turbo Native iOS; bridge-components: […]" after it. The site reads it in
/// the browser to tell the iOS app apart (the `ios-app` class on `<html>`),
/// and its session list names the app and the build that signed in.
enum AppUserAgent {
    static func prefix(version: String?, build: String?) -> String {
        guard let version, !version.isEmpty else { return "Calcpace iOS;" }
        guard let build, !build.isEmpty else { return "Calcpace iOS/\(version);" }
        return "Calcpace iOS/\(version) (\(build));"
    }

    static func prefix(bundle: Bundle = .main) -> String {
        prefix(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }
}

import HotwireNative

/// The "apple-sign-in" bridge component only says the build has Sign in with
/// Apple (`AppleSignIn`); nothing on the site drives it, and it handles no
/// message.
///
/// Hotwire Native lists every registered component in the WebView's user
/// agent ("bridge-components: [… apple-sign-in]"), and the site's
/// hotwire_native_detection_tag turns that into the `apple-sign-in` class
/// on `<html>`. The site shows its Google, Strava and Apple buttons in the
/// iPhone app only with that class: App Store rule 4.8 lets Google and
/// Strava in only alongside Sign in with Apple, so a build without it gets
/// email sign-in alone.
final class AppleSignInComponent: BridgeComponent {
    override class var name: String { "apple-sign-in" }

    // BridgeComponent's own traps: a message, should a page ever send one,
    // is dropped.
    override func onReceive(message: Message) {}
}

# Calcpace iOS

The iOS app for [calcpace.app](https://calcpace.app), a running pace calculator and training log. Like the [Android app](https://play.google.com/store/apps/details?id=app.calcpace.twa), it is a [Hotwire Native](https://native.hotwired.dev) shell: the Rails site renders the screens, and native code handles what a web page can't do. On iOS that will be importing runs from Apple Health.

## No Mac in the loop

The project is built without a Mac:

- **XcodeGen.** The Xcode project is `project.yml`. CI generates `Calcpace.xcodeproj` on every run, and no `.xcodeproj` is committed.
- **GitHub Actions on `macos`.** Every pull request builds the app and runs the unit and UI tests on the simulator. The run uploads a video of the simulator and the test screenshots as an artifact.
- **TestFlight from tags.** Coming once the App Store Connect account exists. Signing will use an App Store Connect API key, with certificates kept in a separate private repository.

To work on it with a Mac:

```sh
brew install xcodegen
xcodegen generate
open Calcpace.xcodeproj
```

## How it fits together

- The app opens `https://calcpace.app`, and Hotwire Native drives the WebView.
- The user agent starts with `Calcpace iOS/<version> (<build>);`, in the Android app's format. That lets the site tell the two apps apart in the browser (the `ios-app` class on `<html>`) without varying the edge-cached pages.
- Routing follows a path configuration the site serves (`/configurations/ios_v1.json`), with a copy bundled for the first launch. The front page and the bottom tab bar's destinations open as roots, with the site's header and no navigation bar; every other screen is pushed under the native bar, with Back and the page's title, and the site hides its own header there.
- The `share-image` bridge component hands a run's share card to the iOS share sheet.
- The `push` bridge component turns on the "your run is in" notification from the home page and hands the page the APNs device token; a tap on the notification opens the run in the app.
- Sign-in is by email, Google, Strava or Sign in with Apple (`Calcpace/Auth`). Google and Strava open in a web authentication session, which hands a one-time ticket back on the `app.calcpace.ios` scheme; Sign in with Apple is Apple's own sheet, whose identity token the app trades with the site for the same ticket. The WebView then trades the ticket, with a PKCE verifier only the app holds, for a session. The `apple-sign-in` bridge component handles nothing: listed in the user agent, it tells the site this build has Sign in with Apple, and only then does the site show the three buttons, as App Store rule 4.8 requires. The App ID needs the Sign in with Apple capability before any signed build.

## License

[MIT](LICENSE)

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
- Sign-in is email only for now. Google and Strava sign-in come back with Sign in with Apple, as App Store rule 4.8 requires.

## License

[MIT](LICENSE)

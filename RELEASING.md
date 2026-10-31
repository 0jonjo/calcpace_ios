# Releasing

Builds reach TestFlight from GitHub Actions, without a Mac: a tag `v*` runs [`testflight.yml`](.github/workflows/testflight.yml), which runs `fastlane beta` ([`fastlane/Fastfile`](fastlane/Fastfile)). Signing uses an App Store Connect API key and [match](https://docs.fastlane.tools/actions/match/), with the certificate and profile encrypted in the private repository `0jonjo/calcpace_ios_certs`.

The whole day-of-account sequence (APNs key, Sign in with Apple key, email domain, universal links, testers) is the "No dia da conta" checklist in `calcpace_docs/plans/calcpace_ios_plan.md`. This file covers only this repository's part.

## Once, when the account exists

The app icon (A5) has to be in the project before the first upload: App Store Connect rejects a build without one, so `beta` stops in seconds when there is no `AppIcon.appiconset`.

1. **Agreements.** The Account Holder accepts the current Program License Agreement (developer.apple.com → Account, and App Store Connect → Business). Until then, and again whenever Apple publishes a new version, every API call fails with 403 `REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED`.
2. **App ID.** In Certificates, Identifiers & Profiles, register `app.calcpace.ios` with **HealthKit**, **Push Notifications** and **Sign in with Apple** turned on. Do it before step 7: the entitlements are in `project.yml`, and a profile made without a capability fails to sign.
3. **App record.** In App Store Connect, create the app "Calcpace" with that bundle id.
4. **API key.** The Account Holder first requests API access: App Store Connect → Users and Access → Integrations → App Store Connect API → Request Access. Then a key with the **Admin** role, for the `certs` run only (only Admin can create a distribution certificate). Keep the `.p8`; Apple lets you download it once.
5. **Certificates repository.** Create the private repository `0jonjo/calcpace_ios_certs` with a README on `main`. Make a fine-grained token with access to that repository only, Contents read and write.
6. **Secrets.** In this repository (`gh secret set NAME -R 0jonjo/calcpace_ios`):

   | Secret | Value |
   |---|---|
   | `APPLE_TEAM_ID` | The 10-character team id (Membership details) |
   | `ASC_KEY_ID` | The API key's id |
   | `ASC_ISSUER_ID` | The issuer id above the keys list |
   | `ASC_KEY_P8_BASE64` | `base64 -w0 AuthKey_XXXXXXXXXX.p8` |
   | `MATCH_GIT_URL` | `https://github.com/0jonjo/calcpace_ios_certs.git` |
   | `MATCH_GIT_BASIC_AUTHORIZATION` | `printf '0jonjo:<token>' \| base64 -w0` |
   | `MATCH_PASSWORD` | A new random password (`openssl rand -base64 32`), kept in the password manager: it decrypts the certificates |

7. **Certificate and profile.** Actions → TestFlight → Run workflow → lane `certs`. match creates the Apple Distribution certificate and the App Store profile and pushes them, encrypted, to `calcpace_ios_certs`; the lane then clones that repository and fails if they are not there. Confirm the match commit in `calcpace_ios_certs` (`certs/distribution/`, `profiles/appstore/`) before the first tag. Every other run only reads them.
8. **Lower the key.** Make a second key with the **App Manager** role, put its id and `.p8` in `ASC_KEY_ID` and `ASC_KEY_P8_BASE64` (the issuer id stays), and revoke the Admin key. `beta` needs no more than that.

**Once a year**, when the certificate expires (the profile expires with it), or after a capability changes: an Admin key in the secrets again, run `certs`, then back to App Manager. `renew_expired_certs` revokes the expired certificate and makes a new one and its profile.

## Each release

1. In a pull request: raise `MARKETING_VERSION` in `project.yml` when the version changes, and always after an App Store release (TestFlight rejects uploads for a version Apple has approved). Put the "What to Test" text in `fastlane/testflight_changelog.txt` (an empty file uploads without one).
2. After the merge, tag `main` with the same version:

   ```sh
   git tag v1.0.0 && git push origin v1.0.0
   ```

The lane refuses a tag that differs from `MARKETING_VERSION`. The build number is the last one on TestFlight plus one, so it never needs bumping by hand. The user agent then reads, for example, `Calcpace iOS/1.0.0 (3);`. The upload returns without waiting for Apple's processing; the build appears in TestFlight 10 to 30 minutes later. Internal testers get it from there. The first build for external testers goes through Beta App Review.

## Push in App Store builds

`aps-environment` is `$(APS_ENVIRONMENT)` in the entitlements: `development` for Debug (the simulator and Xcode runs), `production` for Release, which is what the lane archives. A TestFlight or App Store build therefore registers with APNs' production environment, the server's default (`APNS_ENVIRONMENT=sandbox` only for a Debug build on a device).

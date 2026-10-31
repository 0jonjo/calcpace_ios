# Releasing

Builds reach TestFlight from GitHub Actions, without a Mac: a tag `v*` runs [`testflight.yml`](.github/workflows/testflight.yml), which runs `fastlane beta` ([`fastlane/Fastfile`](fastlane/Fastfile)). Signing uses an App Store Connect API key and [match](https://docs.fastlane.tools/actions/match/), with the certificate and profile encrypted in the private repository `0jonjo/calcpace_ios_certs`.

The whole day-of-account sequence (APNs key, Sign in with Apple key, email domain, universal links, testers) is the "No dia da conta" checklist in `calcpace_docs/plans/calcpace_ios_plan.md`. This file covers only this repository's part.

## Once, when the account exists

1. **App ID.** In Certificates, Identifiers & Profiles, register `app.calcpace.ios` with **HealthKit**, **Push Notifications** and **Sign in with Apple** turned on. Do it before step 5: the entitlements are already in `project.yml`, and a profile made without a capability fails to sign.
2. **App record.** In App Store Connect, create the app "Calcpace" with that bundle id.
3. **API key.** App Store Connect → Users and Access → Integrations → App Store Connect API: a key with the **Admin** role (only Admin can create a distribution certificate). Keep the `.p8`; Apple lets you download it once.
4. **Certificates repository.** Create the private repository `0jonjo/calcpace_ios_certs` with a README on `main`. Make a fine-grained token with access to that repository only, Contents read and write.
5. **Secrets.** In this repository (`gh secret set NAME -R 0jonjo/calcpace_ios`):

   | Secret | Value |
   |---|---|
   | `APPLE_TEAM_ID` | The 10-character team id (Membership details) |
   | `ASC_KEY_ID` | The API key's id |
   | `ASC_ISSUER_ID` | The issuer id above the keys list |
   | `ASC_KEY_P8_BASE64` | `base64 -w0 AuthKey_XXXXXXXXXX.p8` |
   | `MATCH_GIT_URL` | `https://github.com/0jonjo/calcpace_ios_certs.git` |
   | `MATCH_GIT_BASIC_AUTHORIZATION` | `printf '0jonjo:<token>' \| base64 -w0` |
   | `MATCH_PASSWORD` | A new random password (`openssl rand -base64 32`), kept in the password manager: it decrypts the certificates |

6. **Certificate and profile.** Actions → TestFlight → Run workflow → lane `certs`. match creates the Apple Distribution certificate and the App Store profile and pushes them, encrypted, to `calcpace_ios_certs`. Every other run only reads them. Run it again only when the certificate expires (a year) or a capability changes.

## Each release

1. In a pull request: `MARKETING_VERSION` in `project.yml` if the version changes, and the "What to Test" text in `fastlane/testflight_changelog.txt` (an empty file uploads without one).
2. After the merge, tag `main` with the same version:

   ```sh
   git tag v1.0.0 && git push origin v1.0.0
   ```

The lane refuses a tag that differs from `MARKETING_VERSION`. The build number is the last one on TestFlight plus one, so it never needs bumping by hand. The user agent then reads, for example, `Calcpace iOS/1.0.0 (3);`. The upload returns without waiting for Apple's processing; the build appears in TestFlight 10 to 30 minutes later. Internal testers get it from there. The first build for external testers goes through Beta App Review.

## Push in App Store builds

`aps-environment` is `$(APS_ENVIRONMENT)` in the entitlements: `development` for Debug (the simulator and Xcode runs), `production` for Release, which is what the lane archives. A TestFlight or App Store build therefore registers with APNs' production environment, the server's default (`APNS_ENVIRONMENT=sandbox` only for a Debug build on a device).

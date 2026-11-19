# RevokeGPT for React Native

Bot protection for React Native apps on iOS and Android. One call returns a RevokeGPT token. The package is a TurboModule over the native RevokeGPT SDKs, which do the work: proof of work, App Attest (iOS) or Play Integrity (Android), and the hosted challenge sheet when your site's rules ask for one. Your server verifies the token with siteverify.

- **React Native 0.88.1 or later, New Architecture only.** There is no legacy-bridge module: on the old architecture every call fails with a clear error naming the New Architecture.
- iOS 15.1+ (React Native's minimum) and Android 7.0 (API 24)+.
- **Same version as the native SDKs:** package 0.1.1 wraps `revokegpt-ios` and `revokegpt-android` 0.1.1.

```ts
import { RevokeGPT, RevokeGPTError } from '@revokegpt/react-native';

await RevokeGPT.configure({ siteKey: 'rgpk_...' });
try {
  const token = await RevokeGPT.execute({ action: 'login' });
  // Send `token` to your server with the request.
} catch (e) {
  if (e instanceof RevokeGPTError) {
    // e.code: 'challenge-required', 'cancelled', 'rate-limited', ... (see Errors)
  }
}
```

## Install

> **Not published yet.** Until the first release, neither `@revokegpt/react-native` (npm) nor `com.revokegpt:revokegpt-android` (Maven Central) exists, so install from source as below. The registry steps under "After the first release" apply once both are published.

### From source (until the first release)

From a checkout of the RevokeGPT repository, with Node 22.13+, pnpm 12, JDK 17 and the Android SDK:

1. **Build the package tarball:**
   ```sh
   cd sdks/react-native
   pnpm install --frozen-lockfile
   pnpm run pack:prepare                                    # vendors the iOS SDK sources, builds lib/ and plugin/build
   node ../../tools/mobile-vendor/src/cli.ts check --root ../..
   npm pack                                                 # writes revokegpt-react-native-0.1.1.tgz
   ```
2. **Publish the Android SDK to a local Maven repository:**
   ```sh
   cd ../android
   ./gradlew :revokegpt:publishReleasePublicationToLocalExamplesRepository   # sdks/android/build/local-maven
   ```
3. **In your app**, install the tarball, `npm install /path/to/revokegpt-react-native-0.1.1.tgz` (or `pnpm add`).
4. **Resolve `com.revokegpt` from that local repository**, in `android/build.gradle`:
   ```groovy
   allprojects {
       repositories {
           exclusiveContent {
               forRepository { maven { url = uri("/path/to/recaptcha/sdks/android/build/local-maven") } }
               filter { includeGroup("com.revokegpt") }
           }
       }
   }
   ```
5. **Install the pods and rebuild:** `cd ios && pod install`, then rebuild the app. The package is native code, so a JavaScript reload is not enough.

### After the first release

```sh
npm install @revokegpt/react-native   # or pnpm add / yarn add
cd ios && pod install
```

Android then resolves `com.revokegpt:revokegpt-android` from Maven Central, which `mavenCentral()` in your build already covers. No extra repository is needed.

### Both paths

- **iOS:** add the App Attest capability to your app target. Its entitlement `com.apple.developer.devicecheck.appattest-environment` is `production` for App Store and TestFlight builds, and `development` while you develop.
- **Android:** for Play Integrity, link Play Integrity to your Google Cloud project in the Play Console and pass `cloudProjectNumber`.

### Expo

Use a development build (`npx expo prebuild`, or EAS Build). **Expo Go is not supported:** it cannot load native modules that are not part of Expo Go.

```json
{
  "expo": {
    "plugins": [["@revokegpt/react-native", { "appAttestEnvironment": "production" }]]
  }
}
```

The config plugin adds the App Attest entitlement (`appAttestEnvironment`: `production`, the default, or `development`). It changes nothing on Android. Until the first release, install the tarball as above. After `expo prebuild`, add the local repository to `android/build.gradle` with the `allprojects` block from step 4 (`prebuild --clean` rewrites that file, so add it again after each clean prebuild).

**What has been checked with Expo** (a scratch app, not part of this repository):

- **Setup:** `expo` 58.0.23, which targets React Native 0.88.1, with this package installed from the packed tarball.
- **Passed:**
  - `expo prebuild` writes the entitlements file with the configured `appattest-environment`;
  - `pod install` from the tarball succeeds, which confirms the vendored iOS sources are in it;
  - the iOS simulator build succeeds.
- **Not done:** the Expo app was not run, and its Android build was not made.

**Register the app** (bundle id and package name) on your site in the RevokeGPT dashboard, on either path.

## Use it

`configure` takes these settings. Each is checked in JavaScript before any native call, and a malformed one fails with `invalid-argument`:

| Setting | Notes |
|---|---|
| `siteKey` | Required: your site's public key, `rgpk_` and 20 letters and digits. |
| `endpoint`, `widgetOrigin` | `https:` URLs. Plain `http:` to a loopback host works in debug builds only. |
| `timeoutMs` | The total deadline of one call, 1000 to 60000 ms (default 10000). |
| `locale`, `theme` | The hosted challenge page's language (`en`, `pt-BR`, ...) and theme (`light`, `dark`, `auto`). |
| `cloudProjectNumber` | Android: your Google Cloud project number, as a decimal string, for Play Integrity. iOS ignores it. |
| `keyScope` | iOS: an opaque id of the signed-in account (1 to 1024 bytes of UTF-8), for one App Attest key per account on the device. Only a keyed hash of it is stored; use an opaque value, not an email. Android ignores it. |
| `debugLogging` | Logs event names, never values, natively. Off by default. |

`configure` returns a promise. It rejects with `invalid-argument`, or with `busy` while a call is running. A later call replaces the configuration.

- `execute({ action?, cdata? })` returns a token:
  - `action` is 1 to 100 of `A-Z a-z 0-9 / _`;
  - `cdata` is 0 to 255 of `A-Z a-z 0-9 _ -`.
- When the site's rules ask for a puzzle, the hosted page is shown over your app in a native sheet, and the call returns when the person finishes or closes it.
- `challengeAccount(requestToken, { languageCode? })` runs account verification (protocol section 17) for the request token your server got from RevokeGPT.

**Verify the token on your server** with siteverify and your secret key. Never verify it in the app.

**Cancellation:** a call is cancelled, with `cancelled`, when the person closes the sheet, and when the React instance goes away (a reload, or the app tearing down React Native).

## Errors

A `RevokeGPTError` has only these fields:

- `code`: one of the codes below;
- `status` and `requestId`: when the server sent them (`requestId` only when it is well-formed);
- `retryAfterSeconds`: on 429 and 503.

Its message is `RevokeGPT error: <code>`. No native or server text, token or site key ever reaches JavaScript. There is one exception: when the TurboModule is missing from the build (the old architecture, or no native rebuild after installing), every call fails with a `RevokeGPTError` whose code is `internal` and whose message says so (its class, `RevokeGPTModuleMissingError`, is exported).

| Code | Meaning |
|---|---|
| `invalid-argument` | A setting or argument is malformed. |
| `not-configured` | `execute` before `configure`. |
| `network-error` | No connection, a TLS failure or a refused connection. |
| `timeout` | The call's deadline passed. |
| `http-error` | A non-200 answer without a known error, or a redirect (never followed). |
| `invalid-response` | The server's answer was not valid, or named another app. |
| `challenge-required` | A challenge is needed and could not be shown (no screen to show it on). |
| `challenge-unsupported` | The device cannot show the challenge safely. |
| `cancelled` | The person closed the challenge, or the call was cancelled. |
| `busy` | `configure` during a call, or a second sheet while one is up. |
| `internal` | An unexpected state. |
| API codes | Passed through unchanged, for example `rate-limited`, `invalid-site-key`, `app-not-allowed`, `plan-required` (protocol section 7). |

`ERROR_CODES`, `OWN_ERROR_CODES` and `API_ERROR_CODES` are exported.

## Privacy

The package adds nothing to what the native SDKs send and store; their READMEs (`sdks/ios`, `sdks/android`) list it in full. In short:

- **What is sent:** your site key, the app's bundle id or package name, the `action` and `cdata` you pass, the proof of work, and the App Attest or Play Integrity result.
- **Not collected:** advertising identifiers, `ANDROID_ID`, the device name, location, contacts or installed apps.
- **The `sdk` field:** it names this package (`revokegpt-react-native` and its version). The server treats it as untrusted telemetry.
- **Stored on the device:** on iOS, only the App Attest key id, in the Keychain. On Android, nothing.

The iOS privacy manifest (`PrivacyInfo.xcprivacy`) ships in the pod's `RevokeGPT_Privacy` resource bundle.

## How it is built

- **iOS:** the pod `RevokeGPTReactNative` compiles the TurboModule and the native iOS SDK's sources into one module, so it depends on no other RevokeGPT pod. The sources are vendored at pack time by `tools/mobile-vendor`, and checked file for file against `sdks/ios`.
- **Android:** the library depends on `com.revokegpt:revokegpt-android` at the same version (Maven Central after the first release; until then the local repository above).

## Example app

`example/` is a bare React Native 0.88.1 app with three screens: Execute, Verify on your server, and Account verification. It is its own pnpm root with its own lockfile. In the monorepo it resolves the Android SDK from a locally published Maven repository.

```sh
cd sdks/react-native && pnpm install && pnpm run vendor
cd example && pnpm install --frozen-lockfile
pnpm run android:sdk                    # publishes sdks/android to sdks/android/build/local-maven
(cd ios && pod install)
pnpm start                              # Metro, in another terminal
pnpm ios     # or: pnpm android
```

Its settings:

- **Release builds:** they need your keystore: `-Prg.signing.storeFile` (outside the repository) and `-Prg.signing.keyAlias`, with `RG_SIGNING_STORE_PASSWORD` and `RG_SIGNING_KEY_PASSWORD` in the environment, plus `-Prg.siteKey`. They are never signed with the debug keystore.
- **Your server:** pass the Gradle properties `rg.siteKey`, `rg.edgeUrl`, `rg.widgetOrigin`, `rg.cloudProjectNumber` and `rg.verifyUrl` (Android), or the build settings `RG_SITE_KEY`, `RG_EDGE_URL`, `RG_WIDGET_ORIGIN` and `RG_VERIFY_URL` (iOS).
- **The autorun (debug builds only):** `node scripts/autorun.mjs --platform ios|android execute|puzzle-cancel|mfa-cancel [--build] [--metro-port N]` runs a flow headlessly against a stub API (`scripts/stub-api.mjs`).
  - It runs its own Metro on port 8091 (`--metro-port` or `RG_METRO_PORT`), and refuses a port that another server, or another project's Metro, already holds.
  - The iOS debug app takes that port from the launch environment. On Android the port is built into the debug APK (`-PreactNativeDevServerPort`), so the script always runs an incremental `assembleDebug`. That APK then looks for Metro on that port. A later `pnpm android` rebuilds it for the default 8081.
  - The app logs `RG_RESULT <code>`, and `RG_TOKEN <token>` in debug builds.
  - The script checks the result, the token and the request's `sdk` field, and exits non-zero on any mismatch.
  - iOS needs `RG_SIMULATOR_UDID`. Android needs `ANDROID_SERIAL`, which must be an emulator.
- **The request token (debug launches):** the launch's `RG_REQUEST_TOKEN` (environment on iOS, Intent extra on Android) reaches JavaScript through the debug-only native module `RGExampleLaunch` (its constant `requestToken`, read once). It is not an initial property, for the reason below.

**Never pass a token or secret to JavaScript through initial props.** In debug builds React Native logs every initial property to the device log (`Running "<app>" with {"initialProps": ...}`), so a token there leaks to the console, `log stream` and logcat. Pass credentials over a channel React Native does not log, such as a native module, and keep initial props to public settings (the site key and the endpoints).

## Development

```sh
pnpm install
pnpm test && pnpm typecheck && pnpm lint
pnpm run pack:prepare && npm pack --dry-run   # vendors the iOS sources, then builds lib/ and plugin/build
```

`pack:prepare` must run before every pack: a package packed without it has no iOS sources, and its podspec refuses to install. After it, run `node ../../tools/mobile-vendor/src/cli.ts check --root ../..`. The package and the example are outside the monorepo's pnpm workspace (plan R8), each with the root's supply-chain settings.

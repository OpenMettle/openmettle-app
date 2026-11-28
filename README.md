# OpenMettle app

The Flutter client signs in and displays the capabilities visible to the current session. The server reports installation, authorization and readiness separately. A signed-in user can receive an empty list on a core-only installation. The client foundation is tracked in [V1-33](https://github.com/OpenMettle/openmettle-app/issues/1).

## Connect the web client

Serve the built app and the Rust API on the same HTTPS origin. Route the configured sign-in, callback, session check, logout and `/v1/*` paths to the API. Serve the app at the browser profile's landing path so a successful sign-in returns the user to Flutter. Enable the server's browser authentication profile first. See the [core browser routing profile](https://github.com/OpenMettle/openmettle-core/blob/6e82f3b6edcdb3f3270170195623115462316948/docs/adr/0020-browser-routing-profile.md).

Set the three public paths at build time to match that profile. This example uses synthetic paths.

```sh
flutter build web --no-pub \
  --dart-define=OPENMETTLE_LOGIN_PATH=/auth/login \
  --dart-define=OPENMETTLE_SESSION_PATH=/auth/session \
  --dart-define=OPENMETTLE_LOGOUT_PATH=/auth/logout
```

Sign-in submits a form to the API. The API handles the provider callback and sets the secure HttpOnly session cookie. The browser sends the cookie with same-origin requests. Keep credentials out of build settings and browser storage.

Serve the Flutter HTML page with `Referrer-Policy: same-origin`. With `no-referrer` on that page, a browser can send `Origin: null` on the sign-in form and core will reject it. The API supplies its own referrer policy on authentication responses. [Core sign-in page requirements](https://github.com/OpenMettle/openmettle-core/blob/6e82f3b6edcdb3f3270170195623115462316948/docs/adr/0017-browser-login-handoff.md#L213-L214)

If sign-in does not open, select **Check session** to recover. If the session has expired, sign in again. If the service is unavailable, retry after it recovers. If logout cannot be confirmed, retry sign-out before leaving a shared browser.

### Read a personal conversation in the web client

After signing in, select **Conversations**, choose a conversation by its ID, then choose a branch. The transcript shows that branch’s messages in chronological order. Select **Load older messages** to read further back. Message text is selectable. A partial response has a label when the server reports that generation reached the output token limit. Attachment labels show whether a revision is available or retained. A branch with unavailable history has its own status, distinct from an empty transcript.

Select **Back** or press Escape to return one level. If the branch changes while you are paging and the server rejects the cursor, select **Retry** to reload the transcript from its current head. Switching away from the tab clears the history view. Return to the tab and reopen **Conversations** after the session check.

Route the conversation list, branch list and branch messages under `/v1/conversations` to the API. Configure `cursor_keys` in the API authentication settings for pagination. The server uses the signed-in user’s personal scope and checks access on every read. [Core conversation and branch contract](https://github.com/OpenMettle/openmettle-core/blob/6e82f3b6edcdb3f3270170195623115462316948/docs/adr/0036-conversation-branches-presets-and-effective-model-config.md)

### Follow a run in the web client

After signing in, select **Open run**, enter the lowercase UUID of an existing run and select **View status**. Flutter loads its current state and listens for updates until the run ends. Select **Back** or press Escape to return to capabilities. If the API reports that the run is inaccessible or missing, the screen displays the same message in both cases. If the session expires, sign in again.

Configure `cursor_keys` in the API's version 2 authentication settings. Route both `GET /v1/runs/{run_id}` and `GET /v1/runs/{run_id}/events` to the API on the app's origin. Configure the proxy to forward event-stream bytes as they arrive. Flutter uses the last complete event's cursor to reconnect. Select **Retry** if automatic recovery stops. [Core run snapshot and replay contract](https://github.com/OpenMettle/openmettle-core/blob/6e82f3b6edcdb3f3270170195623115462316948/docs/adr/0034-ordered-events-and-replayable-sse.md)

## Connect an Android debug build

Configure the three public build settings to match the API's version-2 `native` profile. The issuer is the HTTPS origin serving the API. The client ID identifies this native registration. Use a dedicated HTTPS App Link on a DNS host with a literal path. The provider registers the API's upstream callback. Android handles the separate App Link after the API completes sign-in. [Core native profile](https://github.com/OpenMettle/openmettle-core/blob/6e82f3b6edcdb3f3270170195623115462316948/docs/adr/0029-native-sign-in-mounting-and-session-context.md)

Build a debug APK with the Android SDK and Flutter 3.50.0. Substitute your test registration for these synthetic values.

```sh
flutter build apk --debug --no-pub \
  --dart-define=OPENMETTLE_NATIVE_ISSUER=https://app.relying.test:18443 \
  --dart-define=OPENMETTLE_NATIVE_CLIENT_ID=synthetic.android \
  --dart-define=OPENMETTLE_NATIVE_REDIRECT_URI=https://return.relying.test/native/complete
```

On the App Link host, serve `/.well-known/assetlinks.json` over trusted HTTPS. Associate `delegate_permission/common.handle_all_urls` with package `org.openmettle.app.debug` and the SHA-256 fingerprint of the certificate that signed the installed APK. Limit that debug association to the test host. On Android 12 or later, run `adb shell pm get-app-links org.openmettle.app.debug` and check that the host is marked `verified`. [Android App Link verification](https://developer.android.com/training/app-links/verify-applinks)

Tap **Sign in**. Android opens the system browser for confirmation and provider sign-in. The verified link returns to Flutter, which exchanges the one-use code and its PKCE verifier for an OpenMettle session. Android Keystore protects the saved attempt and session. After restarting the app, Flutter checks the saved session before displaying capabilities. If sign-in expires, start a new attempt. If sign-out cannot be confirmed, select **Retry sign out** when the API is reachable. Release signing and association with a production domain require the owner's release identity.

## Connect an iOS build

Use iOS 17.4 or later. Register the iOS client in the deployment's native profile. Use the API origin as the issuer and a dedicated HTTPS host and path for the return to the app. The provider redirects to the API's upstream callback. The API redirects to the app's registered return URL after sign-in. [Core native registration](https://github.com/OpenMettle/openmettle-core/blob/6e82f3b6edcdb3f3270170195623115462316948/docs/adr/0023-native-sign-in.md)

Build the simulator app with Flutter 3.50.0 and Xcode on macOS. Supply all three public settings together. The shared Runner scheme derives the associated domain from the redirect host. These values illustrate a test registration.

```sh
flutter pub get --enforce-lockfile
flutter build ios --simulator --debug --no-pub \
  --dart-define=OPENMETTLE_NATIVE_ISSUER=https://app.relying.test:18443 \
  --dart-define=OPENMETTLE_NATIVE_CLIENT_ID=synthetic.ios \
  --dart-define=OPENMETTLE_NATIVE_REDIRECT_URI=https://return.relying.test/native/complete
```

For a signed device build, enable **Associated Domains** for the App ID and use a provisioning profile that includes the capability. Debug uses bundle ID `org.openmettle.app.debug`, profile uses `org.openmettle.app.profile`, and release uses `org.openmettle.app`. Keep development associations on a test host.

Apple's system authentication session requires the `webcredentials` association for the HTTPS callback host. Serve `/.well-known/apple-app-site-association` from that host over trusted HTTPS without redirects. Replace the example identifier with the exact `application-identifier` from the signed build, including its App ID prefix. Apple's associated-domains service must be able to fetch the file for a standard device deployment. [Apple HTTPS callback](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession/callback/https(host:path:)) · [Apple associated domains](https://developer.apple.com/documentation/xcode/supporting-associated-domains)

```json
{"webcredentials":{"apps":["EXAMPLE123.org.openmettle.app.debug"]}}
```

On the signed device, tap **Sign in**, confirm the system prompt, and complete provider sign-in. On return, check the capabilities screen and reopen the app to verify the saved session. The app stores the attempt and session in this device's Keychain. Unlock the device if storage is unavailable. If the app closes during browser sign-in, start a new attempt.

Sign out while connected and confirm that the app stays signed out after reopening. An interrupted logout offers **Retry sign out**. On a shared device, confirm sign-out before removing the app so the API revokes the session. A fresh installation discards credentials left in Keychain by an earlier installation.

## Development

Use Flutter **3.50.0** and its bundled Dart SDK. The version is recorded in `.flutter-version`. [Flutter SDK archive](https://docs.flutter.dev/install/archive)

```sh
python3 scripts/check_repository.py
flutter pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub
flutter test --no-pub
flutter test --no-pub --platform chrome test/api/fetch_transport_browser_test.dart \
  test/api/run_reads_test.dart test/api/history_reads_test.dart \
  test/conversation_history_test.dart test/session_screen_test.dart \
  test/runs/run_replay_test.dart test/runs/run_status_view_test.dart
flutter build web --no-pub
```

Client tests use synthetic responses and pinned core contract fixtures. CI also runs a browser sign-in journey against the core revision in the [fixture manifest](test/fixtures/core/MANIFEST). The Ubuntu runner serves the compiled Flutter application and the API on one HTTPS origin, starts stock Keycloak 26.8.2 with a disposable realm, and migrates a PostgreSQL 18.1 database. Chrome signs in as a pre-approved test user, returns to Flutter, checks the empty capabilities view across reload and opens a queued personal run. The driver cancels that run through core. Flutter must display **Cancelled** from the event stream after a single snapshot. Chrome opens two branches in the same conversation and checks that each transcript contains the common opening and its own follow-up. It then signs out and reloads again. The job uses per-run trust and synthetic identities.

The Android CI journey installs the debug APK on a disposable Android 13 (API 33) AOSP emulator. Android's StatementService fetches the association from the private test host. The journey checks Android's verification result, drives the installed Chromium browser through Keycloak, checks capabilities before and after restarting Flutter, and checks session revocation in PostgreSQL. The fixture serves the certificate association for the installed APK and installs its test CAs only on that emulator.

The macOS CI job runs the iOS host tests and opens the production Flutter screen on an iPhone simulator before and after relaunch. Qualify the iOS provider round trip, authenticated capabilities and logout with a provisioned device build and its associated return domain. Physical devices, production signing and site ingress remain owner qualification steps.

### Try run reconnect with a fixture

From the app repository, launch the standalone Flutter target in Chrome.

```sh
flutter run -d chrome --no-pub -t test/qualification/run_reconnect_app.dart
```

The fixture opens a queued run, delivers its running state, then drops the connection halfway through the cancellation event. The view shows **Reconnecting…**, resumes from the last complete event and displays **Cancelled**. A terminal run stops reconnecting. The fixture runs locally without an account or backend. The default app continues to open the session and capabilities screen.

If the server rejects a cursor, the replay controller discards the previous state and fetches a fresh snapshot. It makes up to three automatic retries without new event progress. Select **Retry** to start a fresh check if recovery stops. Returning from the background checks the snapshot again before showing run data. [Core run snapshot and replay contract](https://github.com/OpenMettle/openmettle-core/blob/6e82f3b6edcdb3f3270170195623115462316948/docs/adr/0034-ordered-events-and-replayable-sse.md)

## Boundaries

The server owns permissions, approvals, quotas and run state. Chat composition, branch navigation and recovery are tracked in [V1-34](https://github.com/OpenMettle/openmettle-app/issues/2). See the [accepted architecture](https://github.com/OpenMettle/openmettle-core/blob/main/ARCHITECTURE-v1.md), [repository boundaries](REPOSITORIES.md), [provenance](UPSTREAM.md) and [delivery tracker](https://github.com/OpenMettle/openmettle-core/issues/1).

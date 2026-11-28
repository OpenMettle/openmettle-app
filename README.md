# OpenMettle app

The Flutter web client checks the browser session and displays the capabilities visible to that session. The server reports installation, authorization and readiness separately. A signed-in user can receive an empty list on a core-only installation. This is the first web increment of [V1-33](https://github.com/OpenMettle/openmettle-app/issues/1).

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

## Development

Use Flutter **3.50.0** and its bundled Dart SDK. The version is recorded in `.flutter-version`. [Flutter SDK archive](https://docs.flutter.dev/install/archive)

```sh
python3 scripts/check_repository.py
flutter pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub
flutter test --no-pub
flutter test --no-pub --platform chrome test/api/fetch_transport_browser_test.dart
flutter build web --no-pub
```

Client tests use synthetic responses and pinned core contract fixtures. CI also runs a browser sign-in journey against the core revision in the [fixture manifest](test/fixtures/core/MANIFEST). The Ubuntu runner serves the compiled Flutter application and the API on one HTTPS origin, starts stock Keycloak 26.8.2 with a disposable realm, and migrates a PostgreSQL 18.1 database. Chrome signs in as a pre-approved test user, returns to Flutter, checks the empty capabilities view across reload, signs out and reloads again. The job uses per-run trust and synthetic identities.

The browser check covers the web session on the CI runner. Invitation-code entry, native sign-in and site ingress qualification are separate work. Choose application identifiers and signing settings before generating the native platform shells.

## Boundaries

The server owns permissions, approvals, quotas and run state. Chat and replayable run events are tracked in [V1-34](https://github.com/OpenMettle/openmettle-app/issues/2). See the [accepted architecture](https://github.com/OpenMettle/openmettle-core/blob/main/ARCHITECTURE-v1.md), [repository boundaries](REPOSITORIES.md), [provenance](UPSTREAM.md) and [delivery tracker](https://github.com/OpenMettle/openmettle-core/issues/1).

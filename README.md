# OpenMettle app

Flutter web/mobile presentation layer for the [accepted architecture](https://github.com/OpenMettle/openmettle-core/blob/main/ARCHITECTURE-v1.md). **Bootstrap only:** the entry point displays the product name. There is no login, API client, conversation UI or client persistence yet. Flutter implementation remains step 2, tracked by V1-33 through V1-35.

## Development

Install Flutter **3.50.0** from the [official SDK archive](https://docs.flutter.dev/install/archive); the pin is recorded in `.flutter-version`. Use the Dart SDK bundled with Flutter.

```sh
python3 scripts/check_repository.py
flutter pub get
dart format --output=none --set-exit-if-changed lib
flutter analyze
flutter build web
flutter run -d chrome
```

Commit the generated `pubspec.lock` once dependency resolution has been verified with the pinned SDK; no guessed package checksums are supplied by this bootstrap. CI checks formatting, analysis and the web build. Add behavioral tests with the first real client behavior.

Web entry files are present. Generate Android/iOS platform shells with the pinned Flutter CLI during V1-33 after choosing the application identifier and signing approach; do not hand-author signing configuration or commit private keys. iOS qualification requires macOS/Xcode. This bootstrap does not claim mobile builds are qualified.

## Boundaries

Consume the core versioned APIs and replayable events. Permissions, approvals, quotas and run state remain server-authoritative. Backend delivery must not depend on this client. Keep production credentials out of compile-time configuration and browser storage. See [repository boundaries](REPOSITORIES.md), [provenance](UPSTREAM.md), and the [delivery tracker](https://github.com/orgs/OpenMettle/projects/1/views/1?filterQuery=%5BV1-00%5D&pane=issue&itemId=307308630).

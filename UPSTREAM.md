# Provenance

Repository hygiene, editor/attribute defaults and the MIT licence originate from OpenMettle/repository-template at commit `eb327e329929a054fde30c75c2cfd7e862057040` (MIT). The bootstrap adapts its guidance and CI.

The new Rust/Flutter scaffolding and repository documentation were authored for OpenMettle. No Open WebUI implementation, model weights, curated fork sources or runtime images are imported here. MIT covers original repository material and the retained starter; linked third-party materials keep their own terms.

Before adding dependencies or distributing images, complete the version-specific provenance and notices inventory in V1-42. A repository licence does not clear all later runtime dependencies.

The web session increment uses Flutter and its bundled `flutter_test` package at 3.50.0 (`ab2912035e160d9cad6306df307576da6128ebdb`, BSD-3-Clause). The latter is a development dependency. The lockfile records resolved packages and registry checksums. [Flutter source and licence](https://github.com/flutter/flutter/tree/ab2912035e160d9cad6306df307576da6128ebdb)

The web screen uses Flutter's maintained Material component library, `material_ui` 1.11.1 (BSD-3-Clause), for buttons, focus handling and accessible text layout. Its additional runtime dependencies include `cupertino_ui` 1.1.7, `intl` 0.20.3 and the SDK's `flutter_localizations` (BSD-3-Clause). [Material UI](https://pub.dev/packages/material_ui/versions/1.11.1) · [Cupertino UI](https://pub.dev/packages/cupertino_ui/versions/1.1.7) · [intl](https://pub.dev/packages/intl/versions/0.20.3)

The capabilities tests reuse synthetic fixtures from OpenMettle core at `6e82f3b6edcdb3f3270170195623115462316948` (MIT, OpenMettle contributors). [Core contract fixtures](https://github.com/OpenMettle/openmettle-core/tree/6e82f3b6edcdb3f3270170195623115462316948/contracts/fixtures)

Browser qualification builds the API and migrator and reuses the Keycloak realm and Chrome test helpers from that core revision. CI uses the same digest-pinned PostgreSQL 18.1 (PostgreSQL License) and Keycloak 26.8.2 (Apache-2.0) images as core. NGINX serves the compiled app and terminates test TLS on the disposable runner. These tools are CI dependencies. [Core qualification workflow](https://github.com/OpenMettle/openmettle-core/blob/6e82f3b6edcdb3f3270170195623115462316948/.github/workflows/keycloak-qualification.yml)

The Android host derives from the Kotlin Android app template in the same Flutter SDK (BSD-3-Clause). It uses Android platform intents, Android Keystore and Java cryptography. The build uses Gradle 9.5.0, Android Gradle Plugin 9.3.1 and Kotlin Gradle Plugin 2.4.20 (Apache-2.0). JVM tests use JUnit 4.13.2 (EPL-1.0). [Flutter Android tooling](https://github.com/flutter/flutter/tree/ab2912035e160d9cad6306df307576da6128ebdb/packages/flutter_tools) · [Gradle](https://github.com/gradle/gradle) · [Android Gradle Plugin](https://android.googlesource.com/platform/tools/base/) · [Kotlin](https://github.com/JetBrains/kotlin) · [JUnit](https://github.com/junit-team/junit4/tree/r4.13.2)

Android qualification uses Google’s Android 13 (API 33) Google APIs x86_64 emulator image from SDK Manager under the Android SDK License Agreement and the image's Chrome browser. The hosted Ubuntu runner supplies the Android SDK tools. The test driver uses Ubuntu 24.04's `python3-websocket` 1.7.0 package to operate Chrome DevTools over a local ADB forward (websocket-client, Apache-2.0). [Android system images](https://developer.android.com/studio/run/managing-avds) · [Ubuntu package](https://packages.ubuntu.com/noble/python3-websocket)

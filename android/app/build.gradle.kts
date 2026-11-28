import java.util.Base64

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Native sign-in reads the same --dart-define values as the Dart code. Flutter passes them to
// Gradle as comma-separated base64 entries of KEY=VALUE.
val dartDefines: Map<String, String> =
    (findProperty("dart-defines") as String?).orEmpty()
        .split(',')
        .filter { it.isNotEmpty() }
        .map { String(Base64.getDecoder().decode(it), Charsets.UTF_8) }
        .filter { '=' in it }
        .associate { it.substringBefore('=') to it.substringAfter('=') }

// These rules match NativeAuthConfig.parse in the app. Keep the two in step.
val dnsLabel = "[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
val dnsHost = "$dnsLabel(?:\\.$dnsLabel)*\\.[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?"
val issuerPattern = Regex("https://($dnsHost)(?::([1-9][0-9]{0,4}))?")
val redirectPattern = Regex("https://($dnsHost)((?:/[A-Za-z0-9._~-]+)+)")

data class NativeSignIn(val issuer: String, val redirect: String, val host: String, val path: String)

val nativeSignIn: NativeSignIn? = run {
    val issuer = dartDefines["OPENMETTLE_NATIVE_ISSUER"].orEmpty()
    val redirect = dartDefines["OPENMETTLE_NATIVE_REDIRECT_URI"].orEmpty()
    if (issuer.isEmpty() && redirect.isEmpty()) return@run null
    val refused = GradleException(
        "OPENMETTLE_NATIVE_ISSUER must be a canonical HTTPS origin and " +
            "OPENMETTLE_NATIVE_REDIRECT_URI an HTTPS app link with a plain path; set both or neither",
    )
    val issuerMatch = issuerPattern.matchEntire(issuer) ?: throw refused
    val port = issuerMatch.groups[2]?.value?.toInt()
    if (issuer.length > 2048 || issuerMatch.groups[1]!!.value.length > 253) throw refused
    if (port != null && (port > 65535 || port == 443)) throw refused
    val redirectMatch = redirectPattern.matchEntire(redirect) ?: throw refused
    val host = redirectMatch.groups[1]!!.value
    val path = redirectMatch.groups[2]!!.value
    if (redirect.length > 2048 || host.length > 253) throw refused
    if (path.split('/').any { it == "." || it == ".." }) throw refused
    NativeSignIn(issuer, redirect, host, path)
}

android {
    namespace = "org.openmettle.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        buildConfig = true
    }

    defaultConfig {
        applicationId = "org.openmettle.app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Unconfigured builds register a reserved .invalid host that no site can verify, and
        // the app refuses every sign-in operation.
        manifestPlaceholders["openmettleAppLinkHost"] = nativeSignIn?.host ?: "unconfigured.invalid"
        manifestPlaceholders["openmettleAppLinkPath"] = nativeSignIn?.path ?: "/unconfigured"
        buildConfigField("String", "OPENMETTLE_NATIVE_ISSUER", "\"${nativeSignIn?.issuer.orEmpty()}\"")
        buildConfigField(
            "String",
            "OPENMETTLE_NATIVE_REDIRECT_URI",
            "\"${nativeSignIn?.redirect.orEmpty()}\"",
        )
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
        }
        // Flutter creates profile from debug, including the debug signing key. Keep it off the
        // release identity.
        getByName("profile") {
            applicationIdSuffix = ".profile"
        }
        release {
            // No signing configuration is tracked here. Sign release builds with the owner's
            // release key outside this repository; never with the debug key.
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}

flutter {
    source = "../.."
}

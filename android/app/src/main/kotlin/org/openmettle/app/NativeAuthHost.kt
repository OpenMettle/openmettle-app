package org.openmettle.app

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.system.Os
import android.system.OsConstants
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.KeyStore
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

/** Process-wide native sign-in state shared by the two activities. */
internal object NativeAuthHost {
    val config: NativeAuthConfig? =
        NativeAuthConfig.parse(
            BuildConfig.OPENMETTLE_NATIVE_ISSUER,
            BuildConfig.OPENMETTLE_NATIVE_REDIRECT_URI,
        )

    private val links = PendingLink({ SystemClock.elapsedRealtime() })

    /** Main thread only. Set while a Flutter engine has the channel open. */
    var linkListener: (() -> Unit)? = null

    /** One thread serialises every Keystore and file operation. */
    val io: ExecutorService = Executors.newSingleThreadExecutor()

    @Volatile private var store: SecretStore? = null

    /** Main thread only. [raw] must already have passed [NativeAuthConfig.isCallback]. */
    fun offerLink(raw: String) {
        links.offer(raw)
        linkListener?.invoke()
    }

    fun takeLink(): String? = links.take()

    fun store(context: Context): SecretStore =
        store ?: synchronized(this) {
            store ?: SecretStore(
                File(context.applicationContext.noBackupFilesDir, "openmettle_native_auth"),
                KeystoreKeys,
                ::syncDirectory,
            ).also { store = it }
        }

    private fun syncDirectory(directory: File) {
        val fd = Os.open(directory.path, OsConstants.O_RDONLY, 0)
        try {
            Os.fsync(fd)
        } finally {
            Os.close(fd)
        }
    }
}

/** A non-exportable AES-256-GCM key in AndroidKeyStore, usable without user authentication. */
private object KeystoreKeys : SecretStore.KeyProvider {
    private const val PROVIDER = "AndroidKeyStore"
    private const val ALIAS = "org.openmettle.app.native_auth.v1"

    override fun existing(): SecretKey? =
        KeyStore.getInstance(PROVIDER).run {
            load(null)
            getKey(ALIAS, null) as SecretKey?
        }

    override fun getOrCreate(): SecretKey =
        existing() ?: KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER).run {
            init(
                KeyGenParameterSpec.Builder(
                    ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setKeySize(256)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setRandomizedEncryptionRequired(true)
                    .build(),
            )
            generateKey()
        }
}

/**
 * The `org.openmettle.app/native_auth` channel. Errors carry fixed codes and messages and no
 * details, so no secret, URL or exception text reaches Dart or the log.
 */
internal class NativeAuthChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, NAME)
    private val main = Handler(Looper.getMainLooper())

    init {
        channel.setMethodCallHandler(this)
        NativeAuthHost.linkListener = { channel.invokeMethod("linkAvailable", null) }
    }

    fun close() {
        channel.setMethodCallHandler(null)
        NativeAuthHost.linkListener = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "newAttempt" ->
                if (call.arguments == null) result.success(Pkce.newAttempt()) else refuse(result)
            "readSecret" -> {
                val key = arguments(call, setOf("key"))?.get("key") as? String
                if (key == null || key !in SecretStore.NAMES) return refuse(result)
                storage(result) { it.read(key) }
            }
            "writeSecret" -> {
                val args = arguments(call, setOf("key", "value"))
                val key = args?.get("key") as? String
                val value = args?.get("value")
                if (key == null || key !in SecretStore.NAMES || (value != null && value !is String)) {
                    return refuse(result)
                }
                storage(result) {
                    it.write(key, value as String?)
                    null
                }
            }
            "launchBrowser" -> launchBrowser(arguments(call, setOf("url"))?.get("url"), result)
            "takeLink" ->
                if (call.arguments == null) result.success(NativeAuthHost.takeLink()) else refuse(result)
            else -> result.notImplemented()
        }
    }

    private fun launchBrowser(url: Any?, result: MethodChannel.Result) {
        val config = NativeAuthHost.config ?: return result.error(NOT_CONFIGURED, NOT_CONFIGURED_TEXT, null)
        if (url !is String || !config.isAuthorizeRequest(url)) return refuse(result)
        val browser = browserPackage(activity.packageManager, activity.packageName)
            ?: return result.error(NO_BROWSER, NO_BROWSER_TEXT, null)
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            .addCategory(Intent.CATEGORY_BROWSABLE)
            .setPackage(browser)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            activity.startActivity(intent)
        } catch (_: ActivityNotFoundException) {
            return result.error(NO_BROWSER, NO_BROWSER_TEXT, null)
        } catch (_: SecurityException) {
            return result.error(NO_BROWSER, NO_BROWSER_TEXT, null)
        }
        result.success(null)
    }

    private fun storage(result: MethodChannel.Result, operation: (SecretStore) -> String?) {
        val store = NativeAuthHost.store(activity)
        NativeAuthHost.io.execute {
            val outcome = try {
                Result.success(operation(store))
            } catch (e: Exception) {
                Result.failure(e)
            }
            main.post {
                outcome.fold(
                    onSuccess = { result.success(it) },
                    onFailure = { result.error(STORAGE, STORAGE_TEXT, null) },
                )
            }
        }
    }

    private fun refuse(result: MethodChannel.Result) = result.error(INVALID, INVALID_TEXT, null)

    companion object {
        const val NAME = "org.openmettle.app/native_auth"
        private const val INVALID = "invalid_argument"
        private const val INVALID_TEXT = "native sign-in request refused"
        private const val NOT_CONFIGURED = "not_configured"
        private const val NOT_CONFIGURED_TEXT = "native sign-in is not configured"
        private const val NO_BROWSER = "browser_unavailable"
        private const val NO_BROWSER_TEXT = "no web browser is available"
        private const val STORAGE = "storage_unavailable"
        private const val STORAGE_TEXT = "secure storage is unavailable"

        /** The argument map when its keys are a subset of [allowed], otherwise null. */
        private fun arguments(call: MethodCall, allowed: Set<String>): Map<*, *>? {
            val args = call.arguments as? Map<*, *> ?: return null
            return if (args.keys.all { it is String && it in allowed }) args else null
        }

        /**
         * A full web browser: an activity that views any http and https URL rather than links
         * for particular hosts. The default browser is preferred. This app is never chosen,
         * and an app that has verified the issuer's links cannot take the authorization page.
         */
        private fun browserPackage(pm: PackageManager, self: String): String? {
            val probe = Intent(Intent.ACTION_VIEW, Uri.parse("https://"))
                .addCategory(Intent.CATEGORY_BROWSABLE)
            val preferred = pm.resolveActivity(probe, PackageManager.MATCH_DEFAULT_ONLY)
                ?.activityInfo?.packageName
            val browsers = pm.queryIntentActivities(
                probe,
                PackageManager.MATCH_ALL or PackageManager.GET_RESOLVED_FILTER,
            ).mapNotNull { info ->
                val filter = info.filter ?: return@mapNotNull null
                val pkg = info.activityInfo?.packageName ?: return@mapNotNull null
                val full = pkg != self &&
                    filter.hasAction(Intent.ACTION_VIEW) &&
                    filter.hasCategory(Intent.CATEGORY_BROWSABLE) &&
                    filter.hasDataScheme("http") &&
                    filter.hasDataScheme("https") &&
                    filter.countDataAuthorities() == 0
                if (full) pkg else null
            }
            return browsers.firstOrNull { it == preferred } ?: browsers.firstOrNull()
        }
    }
}

package org.openmettle.app

import java.io.UnsupportedEncodingException
import java.net.URI
import java.net.URISyntaxException
import java.net.URLDecoder
import java.security.MessageDigest
import java.security.SecureRandom
import kotlin.io.encoding.Base64

/**
 * The native sign-in registration compiled into this build (core ADRs 0023 and 0029).
 *
 * Every check compares raw, undecoded URI components exactly. Nothing here logs or retains a
 * value it refuses.
 */
internal class NativeAuthConfig private constructor(
    private val issuerAuthority: String,
    private val redirectUri: String,
    private val redirectHost: String,
    private val redirectPath: String,
) {
    /** True for an HTTPS link to exactly the registered app-link host and path, with a query. */
    fun isCallback(raw: String): Boolean {
        if (raw.length > MAX_CALLBACK_LENGTH) return false
        val uri = parseUri(raw) ?: return false
        return uri.scheme == "https" &&
            uri.rawAuthority == redirectHost &&
            uri.rawPath == redirectPath &&
            uri.rawFragment == null &&
            !uri.rawQuery.isNullOrEmpty()
    }

    /**
     * True for the issuer's authorization URL carrying exactly the six ADR 0023 parameters, once
     * each, for this registration's app link.
     */
    fun isAuthorizeRequest(raw: String): Boolean {
        if (raw.length > MAX_AUTHORIZE_LENGTH) return false
        val uri = parseUri(raw) ?: return false
        if (uri.scheme != "https" ||
            uri.rawAuthority != issuerAuthority ||
            uri.rawPath != AUTHORIZE_PATH ||
            uri.rawFragment != null
        ) {
            return false
        }
        val query = uri.rawQuery ?: return false
        val params = HashMap<String, String>()
        for (pair in query.split('&')) {
            val separator = pair.indexOf('=')
            if (separator <= 0) return false
            val name = pair.substring(0, separator)
            if (name !in AUTHORIZE_PARAMETERS) return false
            val value = decodeQueryValue(pair.substring(separator + 1)) ?: return false
            if (params.put(name, value) != null) return false
        }
        return params.size == AUTHORIZE_PARAMETERS.size &&
            params["response_type"] == "code" &&
            params["code_challenge_method"] == "S256" &&
            params["redirect_uri"] == redirectUri &&
            CLIENT_ID.matches(params.getValue("client_id")) &&
            PROTOCOL_TOKEN.matches(params.getValue("code_challenge")) &&
            PROTOCOL_TOKEN.matches(params.getValue("state"))
    }

    companion object {
        const val AUTHORIZE_PATH = "/auth/native/authorize"
        private const val MAX_URL_LENGTH = 2048
        private const val MAX_CALLBACK_LENGTH = 8192
        private const val MAX_AUTHORIZE_LENGTH = 8192
        private val AUTHORIZE_PARAMETERS = setOf(
            "response_type",
            "client_id",
            "redirect_uri",
            "code_challenge_method",
            "code_challenge",
            "state",
        )
        private val CLIENT_ID = Regex("[A-Za-z0-9._-]{1,128}")
        private val PROTOCOL_TOKEN = Regex("[A-Za-z0-9_-]{43,128}")

        // These rules match android/app/build.gradle.kts. Keep the two in step.
        private const val DNS_LABEL = "[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
        private const val DNS_HOST =
            "$DNS_LABEL(?:\\.$DNS_LABEL)*\\.[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?"
        private val ISSUER = Regex("https://($DNS_HOST)(?::([1-9][0-9]{0,4}))?")
        private val REDIRECT = Regex("https://($DNS_HOST)((?:/[A-Za-z0-9._~-]+)+)")

        /**
         * Returns null when both values are empty (an unconfigured build) or either is not
         * acceptable. Callers treat both cases as "native sign-in unavailable".
         */
        fun parse(issuer: String, redirect: String): NativeAuthConfig? {
            if (issuer.length > MAX_URL_LENGTH || redirect.length > MAX_URL_LENGTH) return null
            val issuerMatch = ISSUER.matchEntire(issuer) ?: return null
            val issuerHost = issuerMatch.groups[1]!!.value
            val port = issuerMatch.groups[2]?.value?.toInt()
            if (issuerHost.length > 253 || (port != null && (port > 65535 || port == 443))) {
                return null
            }
            val redirectMatch = REDIRECT.matchEntire(redirect) ?: return null
            val redirectHost = redirectMatch.groups[1]!!.value
            val redirectPath = redirectMatch.groups[2]!!.value
            if (redirectHost.length > 253 ||
                redirectPath.split('/').any { it == "." || it == ".." }
            ) {
                return null
            }
            return NativeAuthConfig(
                issuer.removePrefix("https://"),
                redirect,
                redirectHost,
                redirectPath,
            )
        }

        private fun parseUri(raw: String): URI? =
            try {
                URI(raw)
            } catch (_: URISyntaxException) {
                null
            }

        private fun decodeQueryValue(raw: String): String? =
            try {
                URLDecoder.decode(raw, "UTF-8")
            } catch (_: IllegalArgumentException) {
                null
            } catch (_: UnsupportedEncodingException) {
                null
            }
    }
}

/** PKCE and state values for one sign-in attempt (RFC 7636, S256). */
internal object Pkce {
    private val random = SecureRandom()

    /** Independent 32-byte state and verifier, and the verifier's S256 challenge. */
    fun newAttempt(source: SecureRandom = random): Map<String, String> {
        val state = base64Url(ByteArray(32).also(source::nextBytes))
        val verifier = base64Url(ByteArray(32).also(source::nextBytes))
        return mapOf("state" to state, "verifier" to verifier, "challenge" to challenge(verifier))
    }

    fun challenge(verifier: String): String =
        base64Url(
            MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(Charsets.US_ASCII)),
        )

    private val encoder = Base64.UrlSafe.withPadding(Base64.PaddingOption.ABSENT)

    fun base64Url(bytes: ByteArray): String = encoder.encode(bytes)
}

/**
 * At most one received callback link, held in memory only. A newer link replaces an older one,
 * a link is returned once, and a link older than [maxAgeMillis] is discarded: the server's code
 * lasts at most 30 seconds (ADR 0023).
 */
internal class PendingLink(
    private val now: () -> Long,
    private val maxAgeMillis: Long = 60_000,
) {
    private var link: String? = null
    private var receivedAt = 0L

    @Synchronized
    fun offer(raw: String) {
        link = raw
        receivedAt = now()
    }

    @Synchronized
    fun take(): String? {
        val raw = link ?: return null
        link = null
        val age = now() - receivedAt
        return if (age in 0..maxAgeMillis) raw else null
    }
}

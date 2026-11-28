package org.openmettle.app

import java.security.SecureRandom
import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// Synthetic, reserved test names only.
private const val ISSUER = "https://app.example.test"
private const val REDIRECT = "https://links.example.test/native/complete"
private const val CHALLENGE = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
private const val STATE = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

class NativeAuthConfigTest {
    private val config = NativeAuthConfig.parse(ISSUER, REDIRECT)!!

    private fun authorize(
        base: String = "$ISSUER/auth/native/authorize",
        redirect: String = "https%3A%2F%2Flinks.example.test%2Fnative%2Fcomplete",
        extra: String = "",
    ) = "$base?response_type=code&client_id=openmettle-android&redirect_uri=$redirect" +
        "&code_challenge_method=S256&code_challenge=$CHALLENGE&state=$STATE$extra"

    @Test
    fun unconfiguredAndInvalidSettingsDisableSignIn() {
        assertNull(NativeAuthConfig.parse("", ""))
        val refused = listOf(
            ISSUER to "",
            "" to REDIRECT,
            "http://app.example.test" to REDIRECT,
            "https://app.example.test/" to REDIRECT,
            "https://APP.example.test" to REDIRECT,
            "https://app.example.test:443" to REDIRECT,
            "https://app.example.test:0" to REDIRECT,
            "https://app.example.test:65536" to REDIRECT,
            "https://user@app.example.test" to REDIRECT,
            "https://192.0.2.1" to REDIRECT,
            "https://localhost" to REDIRECT,
            ISSUER to "https://links.example.test",
            ISSUER to "https://links.example.test/",
            ISSUER to "https://links.example.test/native/",
            ISSUER to "https://links.example.test//native",
            ISSUER to "https://links.example.test/native/../x",
            ISSUER to "https://links.example.test/./x",
            ISSUER to "https://links.example.test:8443/native",
            ISSUER to "https://links.example.test/native?x=1",
            ISSUER to "https://links.example.test/native#x",
            ISSUER to "https://links.example.test/na%2Ftive",
            ISSUER to "http://links.example.test/native",
        )
        for ((issuer, redirect) in refused) {
            assertNull("$issuer $redirect", NativeAuthConfig.parse(issuer, redirect))
        }
        assertNotNull(NativeAuthConfig.parse("https://app.example.test:8443", REDIRECT))
    }

    @Test
    fun callbackMustMatchSchemeAuthorityAndPathExactly() {
        assertTrue(config.isCallback("$REDIRECT?code=abc&state=$STATE&iss=$ISSUER"))
        val refused = listOf(
            REDIRECT,
            "$REDIRECT?",
            "$REDIRECT?code=a#",
            "$REDIRECT?code=a#frag",
            "HTTPS://links.example.test/native/complete?code=a",
            "http://links.example.test/native/complete?code=a",
            "https://LINKS.example.test/native/complete?code=a",
            "https://links.example.test:443/native/complete?code=a",
            "https://user@links.example.test/native/complete?code=a",
            "https://links.example.test/native/complete/?code=a",
            "https://links.example.test/native/complete/x?code=a",
            "https://links.example.test/native/Complete?code=a",
            "https://links.example.test/native/%63omplete?code=a",
            "https://links.example.test.evil.test/native/complete?code=a",
            "https://app.example.test/native/complete?code=a",
            "https://links.example.test/native/complete?code=a b",
            "$REDIRECT?code=" + "a".repeat(8192),
        )
        for (raw in refused) assertFalse(raw, config.isCallback(raw))
    }

    @Test
    fun browserTargetMustBeTheIssuerAuthorizePageForThisRegistration() {
        assertTrue(config.isAuthorizeRequest(authorize()))
        val refused = listOf(
            authorize(base = "http://app.example.test/auth/native/authorize"),
            authorize(base = "https://evil.example.test/auth/native/authorize"),
            authorize(base = "https://app.example.test:8443/auth/native/authorize"),
            authorize(base = "https://user@app.example.test/auth/native/authorize"),
            authorize(base = "$ISSUER/auth/native/authorize/"),
            authorize(base = "$ISSUER/auth/native/token"),
            authorize(redirect = "https%3A%2F%2Fevil.example.test%2Fnative%2Fcomplete"),
            authorize(extra = "&state=$STATE"),
            authorize(extra = "&invitation_code=123"),
            authorize(extra = "#fragment"),
            authorize().replace("response_type=code", "response_type=token"),
            authorize().replace("S256", "plain"),
            authorize().replace("client_id=openmettle-android", "client_id="),
            authorize().replace("state=$STATE", "state=short"),
            authorize().replace("&state=$STATE", ""),
            authorize().replace("code_challenge=$CHALLENGE", "code_challenge=%ZZ"),
            "$ISSUER/auth/native/authorize",
            "javascript:alert(1)",
        )
        for (raw in refused) assertFalse(raw, config.isAuthorizeRequest(raw))
    }
}

class PkceTest {
    @Test
    fun challengeMatchesRfc7636AppendixB() {
        assertEquals(CHALLENGE, Pkce.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"))
    }

    @Test
    fun base64UrlIsCanonicalWithoutPadding() {
        val random = SecureRandom()
        val reference = Base64.getUrlEncoder().withoutPadding()
        for (size in 0..70) {
            val bytes = ByteArray(size).also(random::nextBytes)
            assertEquals(reference.encodeToString(bytes), Pkce.base64Url(bytes))
        }
    }

    @Test
    fun attemptsUseIndependentRandomStateAndVerifier() {
        val first = Pkce.newAttempt()
        val second = Pkce.newAttempt()
        assertEquals(setOf("state", "verifier", "challenge"), first.keys)
        for (value in first.values) assertTrue(Regex("[A-Za-z0-9_-]{43}").matches(value))
        assertNotEquals(first["state"], first["verifier"])
        assertNotEquals(first["verifier"], second["verifier"])
        assertNotEquals(first["state"], second["state"])
        assertEquals(Pkce.challenge(first["verifier"]!!), first["challenge"])
        assertEquals(32, Base64.getUrlDecoder().decode(first["verifier"]).size)
        assertEquals(32, Base64.getUrlDecoder().decode(first["state"]).size)
    }
}

class PendingLinkTest {
    private var now = 1_000L
    private val links = PendingLink({ now }, maxAgeMillis = 60_000)

    @Test
    fun linkIsReturnedOnceAndNewerReplacesOlder() {
        assertNull(links.take())
        links.offer("first")
        links.offer("second")
        assertEquals("second", links.take())
        assertNull(links.take())
    }

    @Test
    fun staleLinkIsDiscarded() {
        links.offer("old")
        now += 60_001
        assertNull(links.take())
        links.offer("fresh")
        now += 60_000
        assertEquals("fresh", links.take())
    }
}

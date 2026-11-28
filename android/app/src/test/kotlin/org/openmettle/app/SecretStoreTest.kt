package org.openmettle.app

import java.io.File
import java.nio.file.Files
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Exercises the record format and file handling with a software AES key in place of Keystore. */
class SecretStoreTest {
    private val root: File = Files.createTempDirectory("secret-store").toFile()
    private val directory = File(root, "openmettle_native_auth")
    private var syncs = 0

    private class SoftwareKeys : SecretStore.KeyProvider {
        var key: SecretKey? = null

        override fun existing() = key

        override fun getOrCreate() =
            key ?: KeyGenerator.getInstance("AES").apply { init(256) }.generateKey().also { key = it }
    }

    private val keys = SoftwareKeys()
    private val store = SecretStore(directory, keys) { syncs++ }

    @After
    fun cleanUp() {
        root.deleteRecursively()
    }

    @Test
    fun valuesRoundTripAndNullDeletes() {
        assertNull(store.read("session"))
        store.write("session", "bearer-é")
        store.write("attempt", "")
        assertEquals("bearer-é", store.read("session"))
        assertEquals("", store.read("attempt"))
        store.write("session", null)
        assertNull(store.read("session"))
        assertFalse(File(directory, "session.bin").exists())
        store.write("session", null)
        assertEquals(listOf("attempt.bin"), directory.list()!!.sorted())
        assertTrue(syncs >= 3)
    }

    @Test
    fun recordIsEncryptedWithAFreshNonce() {
        store.write("session", "synthetic-bearer")
        val first = File(directory, "session.bin").readBytes()
        store.write("session", "synthetic-bearer")
        val second = File(directory, "session.bin").readBytes()
        assertFalse(String(first, Charsets.ISO_8859_1).contains("synthetic-bearer"))
        assertEquals(1.toByte(), first[0])
        assertEquals(1 + 12 + "synthetic-bearer".length + 16, first.size)
        assertFalse(first.copyOfRange(1, 13).contentEquals(second.copyOfRange(1, 13)))
    }

    @Test
    fun onlyTheTwoNamesAreAccepted() {
        for (name in listOf("other", "", "../session", "session.bin")) {
            try {
                store.write(name, "x")
                fail(name)
            } catch (_: IllegalArgumentException) {
            }
            try {
                store.read(name)
                fail(name)
            } catch (_: IllegalArgumentException) {
            }
        }
        try {
            store.write("session", "x".repeat(SecretStore.MAX_VALUE_BYTES + 1))
            fail()
        } catch (_: IllegalArgumentException) {
        }
        assertFalse(File(directory, "session.bin").exists())
    }

    @Test
    fun associatedDataBindsTheRecordName() {
        store.write("attempt", "attempt-value")
        File(directory, "attempt.bin").copyTo(File(directory, "session.bin"))
        assertNull(store.read("session"))
        assertFalse(File(directory, "session.bin").exists())
        assertEquals("attempt-value", store.read("attempt"))
    }

    @Test
    fun tamperedTruncatedOrForeignRecordsAreDiscarded() {
        val file = File(directory, "session.bin")
        val cases = listOf<(ByteArray) -> ByteArray>(
            { it.copyOf().also { b -> b[b.size - 1] = (b[b.size - 1] + 1).toByte() } },
            { it.copyOf().also { b -> b[5] = (b[5] + 1).toByte() } },
            { it.copyOf().also { b -> b[0] = 2 } },
            { it.copyOf(20) },
            { ByteArray(0) },
        )
        for (mutate in cases) {
            store.write("session", "value")
            file.writeBytes(mutate(file.readBytes()))
            assertNull(store.read("session"))
            assertFalse(file.exists())
        }
    }

    @Test
    fun recordsBecomeAbsentWhenTheKeyIsLostOrReplaced() {
        store.write("session", "value")
        keys.key = null
        assertNull(store.read("session"))
        assertFalse(File(directory, "session.bin").exists())

        store.write("session", "value")
        keys.key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        assertNull(store.read("session"))
    }

    @Test
    fun failedWritesLeaveOneCompleteRecord() {
        store.write("session", "old")
        val failing = SecretStore(directory, keys) { throw java.io.IOException() }
        try {
            failing.write("session", "new")
            fail()
        } catch (_: java.io.IOException) {
        }
        // The rename happened before the directory sync failed; a crash at that point leaves
        // either the old or the new complete record, never a partial one.
        assertEquals("new", store.read("session"))
        assertFalse(File(directory, "session.tmp").exists())

        val brokenKeys = object : SecretStore.KeyProvider {
            override fun existing() = keys.key
            override fun getOrCreate(): SecretKey = throw java.security.ProviderException()
        }
        try {
            SecretStore(directory, brokenKeys) {}.write("session", "newer")
            fail()
        } catch (_: java.security.ProviderException) {
        }
        assertEquals("new", store.read("session"))
        assertArrayEquals(arrayOf("session.bin"), directory.list())
    }
}

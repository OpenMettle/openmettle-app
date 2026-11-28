package org.openmettle.app

import android.security.keystore.KeyPermanentlyInvalidatedException
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.security.GeneralSecurityException
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Encrypted storage for the two native sign-in records, `attempt` and `session`.
 *
 * Each record is one file `<name>.bin`: a format byte, the 12-byte GCM nonce and the
 * AES-256-GCM ciphertext with its 128-bit tag. The associated data binds the ciphertext to the
 * format and record name, so a record cannot be moved to the other name. Writes go to a
 * temporary file that is synced and renamed over the record, then the directory is synced.
 *
 * A record that cannot be authenticated, whose key is gone or permanently invalidated, or that
 * is malformed is deleted and reads as absent. Any other failure propagates and changes nothing.
 * Callers serialise access; this class is not thread-safe.
 */
internal class SecretStore(
    private val directory: File,
    private val keys: KeyProvider,
    private val syncDirectory: (File) -> Unit,
) {
    interface KeyProvider {
        /** The existing key, or null when none has been created. */
        fun existing(): SecretKey?

        fun getOrCreate(): SecretKey
    }

    fun read(name: String): String? {
        val file = recordFile(name)
        if (!file.exists()) return null
        if (file.length() > MAX_RECORD_BYTES) return discard(file)
        val record = file.readBytes()
        val key = keys.existing() ?: return discard(file)
        if (record.size < HEADER_SIZE + TAG_BYTES || record.size > MAX_RECORD_BYTES ||
            record[0] != FORMAT
        ) {
            return discard(file)
        }
        val plain = try {
            Cipher.getInstance(TRANSFORMATION).run {
                init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BYTES * 8, record, 1, NONCE_BYTES))
                updateAAD(associatedData(name))
                doFinal(record, HEADER_SIZE, record.size - HEADER_SIZE)
            }
        } catch (e: GeneralSecurityException) {
            if (e.isPermanent()) return discard(file) else throw e
        }
        return try {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(plain))
                .toString()
        } catch (_: CharacterCodingException) {
            discard(file)
        } finally {
            plain.fill(0)
        }
    }

    /** Stores [value] under [name], or deletes the record when [value] is null. */
    fun write(name: String, value: String?) {
        val file = recordFile(name)
        if (value == null) {
            if (file.exists() && !file.delete()) throw IOException()
            if (directory.isDirectory) syncDirectory(directory)
            return
        }
        val plain = value.toByteArray(Charsets.UTF_8)
        require(plain.size <= MAX_VALUE_BYTES)
        val record = try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, keys.getOrCreate())
            val nonce = cipher.iv
            if (nonce == null || nonce.size != NONCE_BYTES) throw GeneralSecurityException()
            cipher.updateAAD(associatedData(name))
            byteArrayOf(FORMAT) + nonce + cipher.doFinal(plain)
        } finally {
            plain.fill(0)
        }
        if (!directory.isDirectory && !directory.mkdirs()) throw IOException()
        val temporary = File(directory, "$name.tmp")
        try {
            FileOutputStream(temporary).use { out ->
                out.write(record)
                out.fd.sync()
            }
            if (!temporary.renameTo(file)) throw IOException()
        } finally {
            temporary.delete()
        }
        syncDirectory(directory)
    }

    private fun recordFile(name: String): File {
        require(name in NAMES)
        return File(directory, "$name.bin")
    }

    private fun discard(file: File): String? {
        if (!file.delete() && file.exists()) throw IOException()
        syncDirectory(directory)
        return null
    }

    private fun GeneralSecurityException.isPermanent(): Boolean =
        this is AEADBadTagException || this is KeyPermanentlyInvalidatedException

    companion object {
        val NAMES = setOf("attempt", "session")
        const val MAX_VALUE_BYTES = 64 * 1024
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val FORMAT: Byte = 1
        private const val NONCE_BYTES = 12
        private const val TAG_BYTES = 16
        private const val HEADER_SIZE = 1 + NONCE_BYTES
        private const val MAX_RECORD_BYTES = HEADER_SIZE + MAX_VALUE_BYTES + TAG_BYTES

        fun associatedData(name: String): ByteArray =
            "openmettle.app/native-secret/v1".toByteArray(Charsets.US_ASCII) +
                byteArrayOf(0, FORMAT) +
                name.toByteArray(Charsets.US_ASCII)
    }
}

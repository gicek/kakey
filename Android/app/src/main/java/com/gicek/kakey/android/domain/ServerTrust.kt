package com.gicek.kakey.android.domain

import java.security.MessageDigest

/**
 * The server certificate can't be validated with system trust (see docs/SECURITY.md). [fingerprint] is the SHA-256 of the
 * server leaf certificate's DER. Not an `IOException`, so it is never retried as a transient network failure.
 */
sealed class CloudCertificateException(val fingerprint: ByteArray) : Exception("server certificate not trusted") {
    /** No pinned certificate: the UI asks the user to check the fingerprint and decide whether to trust it. */
    class Untrusted(fingerprint: ByteArray) : CloudCertificateException(fingerprint)

    /**
     * The pinned certificate differs from the one the server presented: possibly a man-in-the-middle; the user must go back to
     * the connection page and re-check, with no one-tap trust.
     */
    class Changed(fingerprint: ByteArray) : CloudCertificateException(fingerprint)
}

/** Decision for a server certificate challenge (same rules as Apple's `ServerTrustDecision`). */
sealed interface ServerTrustDecision {
    /**
     * Leave it to the system: either the system accepts it (regardless of any pin, so switching the server to a proper
     * certificate just works), or there is no certificate (the system fails as usual).
     */
    data object SystemDefault : ServerTrustDecision

    /**
     * The system rejects it, but the leaf is exactly the certificate the user confirmed (hostname is not checked then: self-
     * signed certificates often have the wrong hostname or an IP).
     */
    data object AcceptPinned : ServerTrustDecision

    class Reject(val error: CloudCertificateException) : ServerTrustDecision

    companion object {
        fun decide(systemTrusted: Boolean, leafFingerprint: ByteArray?, pinned: ByteArray?): ServerTrustDecision = when {
            systemTrusted || leafFingerprint == null -> SystemDefault
            pinned == null -> Reject(CloudCertificateException.Untrusted(leafFingerprint))
            // MessageDigest.isEqual is a constant-time comparison
            MessageDigest.isEqual(leafFingerprint, pinned) -> AcceptPinned
            else -> Reject(CloudCertificateException.Changed(leafFingerprint))
        }

        fun sha256(der: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(der)

        /**
         * Display form of a fingerprint: uppercase hex with bytes separated by colons, as shown on NAS admin pages and in
         * browser certificate details.
         */
        fun formatted(fingerprint: ByteArray): String = fingerprint.joinToString(":") { "%02X".format(it) }
    }
}

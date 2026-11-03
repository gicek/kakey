package com.gicek.kakey.android

import com.gicek.kakey.android.core.CLOUD_ERROR_STRINGS
import com.gicek.kakey.android.core.UiText
import com.gicek.kakey.android.core.VaultException
import com.gicek.kakey.android.core.text
import com.gicek.kakey.android.domain.CloudSyncException
import com.gicek.kakey.core.CoreCloudException
import com.gicek.kakey.core.KakeyException
import com.gicek.kakey.core.coreCloudErrorL10nKey
import com.gicek.kakey.core.coreErrorL10nKey
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Every error key from the core has an Android string resource; this fails first when the core adds a variant or renames a key. */
class CoreErrorsTest {
    @Test
    fun everyCoreErrorMapsToAStringResource() {
        val variants = KakeyException::class.java.declaredClasses
            .filter { KakeyException::class.java.isAssignableFrom(it) }
            .map { it.getDeclaredConstructor().newInstance() as KakeyException }
        assertTrue("UniFFI should generate every error variant", variants.size >= 15)
        val keys = variants.map { error ->
            val key = coreErrorL10nKey(error)
            val text = VaultException(error).text
            assertTrue("$key has no resource mapping", text is UiText.Res)
            key
        }
        assertEquals("No extra keys in the table", keys.toSet(), VaultException.ERROR_STRINGS.keys)
        assertEquals(
            "Category name too long carries the max length argument",
            1,
            (VaultException(KakeyException.CategoryNameTooLong()).text as UiText.Res).args.size,
        )
    }

    @Test
    fun everyCloudErrorMapsToAStringResource() {
        val variants = CoreCloudException::class.java.declaredClasses.filter { CoreCloudException::class.java.isAssignableFrom(it) }
        val errors = listOf(
            CoreCloudException.ReauthRequired(),
            CoreCloudException.Forbidden(),
            CoreCloudException.NotFound(),
            CoreCloudException.Conflict(),
            CoreCloudException.QuotaExceeded(),
            CoreCloudException.RateLimited(30uL),
            CoreCloudException.Server(503u),
            CoreCloudException.InvalidResponse(),
            CoreCloudException.TooLarge(),
            CoreCloudException.InsecureRedirect(),
            CoreCloudException.InsecureAddress(),
            CoreCloudException.InvalidAddress(),
            CoreCloudException.InvalidPath(),
            CoreCloudException.InvalidConnection(),
            CoreCloudException.AuthorizationDenied(),
            CoreCloudException.AuthorizationFailed(),
            CoreCloudException.Internal(),
        )
        assertEquals("Test lists every variant", variants.size, errors.size)
        val keys = errors.map { error ->
            assertTrue("${coreCloudErrorL10nKey(error)} has no resource mapping", CloudSyncException(error).text is UiText.Res)
            coreCloudErrorL10nKey(error)
        }
        assertEquals("No extra keys in the table", keys.toSet(), CLOUD_ERROR_STRINGS.keys)
        assertEquals(
            "Server error carries the status code",
            listOf<Any>(503),
            (CloudSyncException(CoreCloudException.Server(503u)).text as UiText.Res).args,
        )
    }
}

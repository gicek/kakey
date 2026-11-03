package com.gicek.kakey.android

import com.gicek.kakey.android.domain.VaultRepository
import java.time.Instant
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The v2 vault samples written by the Mac app (`Core/golden/vault.json`) open on Android with the same master password:
 * accounts match field by field, samples without `categories` read as having no categories, and opening never writes back.
 */
class GoldenVaultTest {
    @Test
    fun opensVaultsWrittenByTheMacApp() {
        val vaults = JSONObject(repoRoot.resolve("Core/golden/vault.json").readText()).getJSONArray("vaults")
        for (index in 0 until vaults.length()) {
            val sample = vaults.getJSONObject(index)
            val name = sample.getString("name")
            val files = MemoryVaultFiles(sample.getString("file").encodeToByteArray())
            val repository = VaultRepository(files, { Instant.now() }, { "Favorites" })
            val unlocked = repository.unlock(sample.getString("password"))
            val expected = sample.getJSONArray("accounts")
            assertEquals(name, expected.length(), unlocked.contents.accounts.size)
            for (i in 0 until expected.length()) {
                val account = expected.getJSONObject(i)
                assertEquals(name, account.getString("id"), unlocked.contents.accounts[i].id)
                assertEquals(name, account.getString("secret"), unlocked.contents.accounts[i].secret)
                assertEquals(name, account.getString("username"), unlocked.contents.accounts[i].username)
            }
            assertTrue(name, unlocked.contents.categories.isEmpty())
            assertEquals("Opening does not modify the file", 0, files.writes)
        }
    }
}

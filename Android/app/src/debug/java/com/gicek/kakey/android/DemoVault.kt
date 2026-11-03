package com.gicek.kakey.android

import android.content.Intent
import com.gicek.kakey.android.core.Account
import com.gicek.kakey.android.core.AccountCategory
import com.gicek.kakey.android.core.VaultContents
import com.gicek.kakey.android.data.FileVaultFiles
import com.gicek.kakey.android.domain.BackupHistoryItem
import com.gicek.kakey.android.domain.BackupHistoryStore
import com.gicek.kakey.android.domain.InMemoryPreferencesStore
import com.gicek.kakey.android.domain.VaultKeyStore
import com.gicek.kakey.android.domain.VaultRepository
import com.gicek.kakey.core.CoreTotpAlgorithm
import java.io.File
import java.time.Duration
import java.time.Instant
import java.util.UUID
import javax.crypto.Cipher
import kotlinx.coroutines.launch

/**
 * Demo vault for screenshots and UI review. Compiled into Debug builds only; `src/release` has an empty implementation with
 * the same name. Counterpart of the iOS `DemoVault`.
 *
 * `adb shell am start -n com.gicek.kakey/com.gicek.kakey.android.MainActivity --ez kakey.demo true` switches to a separate
 * vault in the cache directory (leaving real data, the Keystore and settings untouched), writes sample accounts, and unlocks
 * automatically with a fixed password. Add `--ez kakey.demo.locked true` to stay on the lock screen,
 * `--ez kakey.demo.empty true` to stay on onboarding, `--es kakey.demo.screen <screen>` to open detail / add / settings /
 * categories / manual directly, and `--ei kakey.demo.count <N>` to pad the list to N accounts (for testing long-list
 * scrolling and drag reordering).
 */
@Suppress("MagicNumber") // Demo data: fixed creation date and category indices
object DemoVault {
    const val PASSWORD = "demo-password-2026"

    /** The screen to open right after launch (`kakey.demo.screen`); the UI calls [clearScreen] once it has read it. */
    var screen: String? = null
        private set

    fun clearScreen() {
        screen = null
    }

    private var installed = false

    /**
     * Switches to the demo vault if the launch extras ask for it. Returns true for a demo launch, in which case the Activity
     * skips `FLAG_SECURE` so screenshots work. The store is replaced at most once per process.
     */
    fun start(app: KakeyApplication, intent: Intent): Boolean {
        if (!intent.getBooleanExtra("kakey.demo", false)) return false
        screen = intent.getStringExtra("kakey.demo.screen")
        if (installed) return true
        installed = true
        val empty = intent.getBooleanExtra("kakey.demo.empty", false)
        val locked = intent.getBooleanExtra("kakey.demo.locked", false)
        val count = intent.getIntExtra("kakey.demo.count", 0)
        app.installStore(app.makeStore(prepare(app, empty, count), MemoryKeyStore(), InMemoryPreferencesStore(), MemoryHistory()))
        if (!empty && !locked) app.scope.launch { app.store.unlock(PASSWORD) }
        return true
    }

    private fun prepare(app: KakeyApplication, empty: Boolean, count: Int): VaultRepository {
        val directory = File(app.cacheDir, "kakey-demo")
        directory.deleteRecursively()
        val repository = VaultRepository(FileVaultFiles(directory), Instant::now) { app.getString(R.string.favorites) }
        if (!empty) repository.create(contents(app, count), PASSWORD)
        return repository
    }

    private fun contents(app: KakeyApplication, count: Int): VaultContents {
        val created = Instant.now().minus(Duration.ofDays(12))
        fun account(
            issuer: String,
            username: String,
            secret: String,
            algorithm: CoreTotpAlgorithm = CoreTotpAlgorithm.SHA1,
            digits: Int = 6,
            period: Int = 30,
        ) = Account(
            UUID.randomUUID().toString().uppercase(),
            issuer,
            username,
            secret,
            algorithm,
            digits,
            period,
            created,
            Account.PROVENANCE_MANUAL,
        )
        val accounts = listOf(
            account("GitHub", "alex@example.com", "JBSWY3DPEHPK3PXP"),
            account("Google", "alex.chen@gmail.com", "GEZDGNBVGY3TQOJQ"),
            account("Apple", "alex@icloud.com", "MZXW6YTBOI"),
            account("Cloudflare", "ops@kakey.app", "KRSXG5CTMVRXEZLU", CoreTotpAlgorithm.SHA256),
            account("Amazon Web Services", "root", "NBSWY3DPO5XXE3DE", digits = 8),
            account("Microsoft", "alex@outlook.com", "ORSXG5BAOJSWG33S"),
            account("Dropbox", "alex@example.com", "MFRGGZDFMZTWQ2LK"),
            account("Stripe", "billing@kakey.app", "GAYTEMZUGU3DOOBZ", period = 60),
        ).let { base ->
            base + (base.size until count).map { account("Service ${it + 1}", "user${it + 1}@example.com", "JBSWY3DPEHPK3PXP") }
        }
        fun category(name: Int, vararg indices: Int) =
            AccountCategory(UUID.randomUUID().toString().uppercase(), app.getString(name), indices.map { accounts[it].id })
        return VaultContents(
            accounts,
            listOf(
                category(R.string.favorites, 0, 1),
                category(R.string.work, 3, 4, 7, 0),
                category(R.string.personal, 2, 5, 6),
            ),
        )
    }

    /** In-memory key storage for the demo: the biometrics toggle works without touching the real Keystore. */
    class MemoryKeyStore : VaultKeyStore {
        private var key: ByteArray? = null
        override fun save(key: ByteArray) {
            this.key = key.copyOf()
        }
        override fun hasKey() = key != null
        override fun remove() {
            key = null
        }
        override suspend fun load(authenticate: suspend (Cipher) -> Cipher): ByteArray = key ?: error("no key")
    }

    class MemoryHistory : BackupHistoryStore {
        private var items = emptyList<BackupHistoryItem>()
        override suspend fun load() = items
        override suspend fun save(items: List<BackupHistoryItem>) {
            this.items = items
        }
        override suspend fun clear() {
            items = emptyList()
        }
    }
}

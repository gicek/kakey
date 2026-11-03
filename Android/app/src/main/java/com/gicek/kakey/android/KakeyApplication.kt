package com.gicek.kakey.android

import android.app.Application
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.SystemClock
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import com.gicek.kakey.android.core.Core
import com.gicek.kakey.android.core.UiText
import com.gicek.kakey.android.data.DataStorePreferencesStore
import com.gicek.kakey.android.data.FileBackupHistoryStore
import com.gicek.kakey.android.data.FileVaultFiles
import com.gicek.kakey.android.data.KeystoreVaultKeyStore
import com.gicek.kakey.android.data.SafSyncBackends
import com.gicek.kakey.android.domain.VaultRepository
import com.gicek.kakey.android.domain.VaultStore
import com.gicek.kakey.android.platform.Biometrics
import com.gicek.kakey.android.platform.DeviceInfo
import com.gicek.kakey.android.ui.components.nameRes
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

/**
 * Process-level dependency wiring (hand-written constructor injection). Vault state lives in the process rather than the
 * Activity, so unlock state and in-flight operations survive the UI being recreated for a language change or rotation.
 * Auto-lock re-checks elapsed time when the app returns to the foreground, and the vault locks immediately when the screen
 * turns off.
 */
class KakeyApplication : Application() {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    /** Serial background queue for vault file IO (see the VaultStore threading model). */
    private val vaultFiles = Dispatchers.IO.limitedParallelism(1)
    lateinit var store: VaultStore
        private set
    lateinit var syncBackends: SafSyncBackends
        private set

    override fun onCreate() {
        super.onCreate()
        syncBackends = SafSyncBackends(this, "Kakey/${BuildConfig.VERSION_NAME} (Android)")
        store = makeStore(
            VaultRepository(FileVaultFiles(this), java.time.Instant::now) { getString(R.string.favorites) },
            KeystoreVaultKeyStore(this, Dispatchers.IO),
            DataStorePreferencesStore(this, scope),
            FileBackupHistoryStore(this, Dispatchers.IO),
        )
        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) = store.onForeground()
        })
        // Lock immediately when the screen turns off (power button or timeout) without waiting for the idle timer,
        // matching the Mac's lock on sleep / screen lock
        registerReceiver(
            object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) = store.lock()
            },
            IntentFilter(Intent.ACTION_SCREEN_OFF),
            Context.RECEIVER_NOT_EXPORTED,
        )
    }

    /** Wires up a store; the Debug demo vault uses it to swap in a temp directory and in-memory fakes (`src/debug/.../DemoVault.kt`). */
    internal fun makeStore(
        repository: VaultRepository,
        keyStore: com.gicek.kakey.android.domain.VaultKeyStore,
        preferences: com.gicek.kakey.android.domain.PreferencesStore,
        history: com.gicek.kakey.android.domain.BackupHistoryStore,
    ) = VaultStore(
        repository = repository,
        keyStore = keyStore,
        preferencesStore = preferences,
        historyStore = history,
        syncBackends = syncBackends,
        scope = scope,
        io = Dispatchers.IO,
        files = vaultFiles,
        placeholders = { Core.placeholders(this) },
        deviceName = { DeviceInfo.name(this) },
        elapsedMillis = SystemClock::elapsedRealtime,
        biometricName = UiText.Res(Biometrics.kind(this).nameRes),
    )

    internal fun installStore(store: VaultStore) {
        this.store = store
    }
}

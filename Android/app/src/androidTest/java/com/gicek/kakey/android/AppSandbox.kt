package com.gicek.kakey.android

import androidx.test.core.app.ApplicationProvider
import com.gicek.kakey.android.domain.Phase
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout

/**
 * The app sandbox used by instrumented tests.
 *
 * Instrumented tests run inside the real app's process on a device and touch that app's own sandbox (`files/Kakey/`,
 * DataStore, and `com.gicek.kakey.vault-key` in the Keystore). This is the one explicit exception to the AGENTS.md rule
 * that tests never touch real storage, and it is allowed only for UI flow tests: before and after every test the sandbox
 * is wiped through the app's own reset path (`VaultStore.resetApplication`, the same code as Settings > Reset App), leaving
 * no vault, settings, backup history or biometric key behind. `pm clear` is not used because it also kills the test process.
 */
object AppSandbox {
    val app: KakeyApplication get() = ApplicationProvider.getApplicationContext()

    /** Waits for the launch load to finish, then wipes the sandbox so the next UI launch lands on onboarding. */
    fun reset() = runBlocking {
        withTimeout(30_000) { app.store.state.first { it.phase != Phase.LOADING } }
        app.store.resetApplication()
    }
}

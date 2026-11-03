package com.gicek.kakey.android.domain

import com.gicek.kakey.android.R
import com.gicek.kakey.android.core.Account
import com.gicek.kakey.android.core.UiText
import com.gicek.kakey.android.core.VaultContents
import com.gicek.kakey.android.core.VaultException
import com.gicek.kakey.android.core.toAccount
import com.gicek.kakey.android.core.toCategory
import com.gicek.kakey.android.core.toCore
import com.gicek.kakey.core.KakeyException
import com.gicek.kakey.core.coreCandidatesFromImport
import com.gicek.kakey.core.coreExportAccounts
import com.gicek.kakey.core.coreImportBackup
import com.gicek.kakey.core.coreInsertAccounts
import com.gicek.kakey.core.coreIsAcceptableMasterPassword
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

/**
 * Importing and exporting backup files, and resetting the app. Restoring from a backup location lives in
 * [SyncCoordinator.restore] because it uses the backup location and backup history.
 */
internal class BackupController(
    private val session: VaultSession,
    private val accounts: AccountEditor,
    private val unlock: UnlockController,
    private val sync: SyncCoordinator,
) {
    private val current get() = session.current

    /**
     * Imports a backup file (a Kakey encrypted export or an Authenticator backup). Categories in the file are merged by name; if
     * every account is a duplicate, shows "all accounts in the file already exist" (see docs/DESIGN.md). Throws [VaultException]
     * (`PasswordRequired` / `EmptyPassword`) when a password is needed; the UI asks for it and retries.
     */
    suspend fun importBackup(data: ByteArray, password: String): Int {
        val placeholders = session.placeholders()
        val candidates = withContext(session.io) {
            try {
                // Authenticator pins are first merged into the Favorites category, then converted to candidates
                // (the contract of core `candidates_from_import`)
                coreCandidatesFromImport(
                    session.repository.adoptingPinned(coreImportBackup(data, password, session.now(), placeholders)),
                )
            } catch (error: KakeyException) {
                throw VaultException(error)
            }
        }
        val count = accounts.insert(candidates, Account.PROVENANCE_IMPORTED)
        session.message(
            if (count >
                0
            ) {
                UiText.Plural(R.plurals.added_x_accounts, count)
            } else {
                UiText.Res(R.string.all_accounts_in_this_file_already)
            },
        )
        return count
    }

    /**
     * First-run restore from a Kakey export file (same as Apple): opens it with the export password, creates and unlocks a new
     * vault with [masterPassword], and does not enable a backup location. When "use as master password" is checked,
     * [masterPassword] is the export password. Nothing is created if the master password fails the rules.
     * Returns null on success, otherwise the error to show.
     */
    suspend fun restoreFromExport(data: ByteArray, password: String, masterPassword: String, enableBiometrics: Boolean): UiText? {
        val placeholders = session.placeholders()
        val contents = withContext(session.io) {
            try {
                val candidates =
                    coreCandidatesFromImport(
                        session.repository.adoptingPinned(coreImportBackup(data, password, session.now(), placeholders)),
                    )
                if (!coreIsAcceptableMasterPassword(masterPassword)) return@withContext null
                // The new vault has no accounts yet, so the insert result is the whole content; deduplication and category
                // merging match import
                val result =
                    coreInsertAccounts(emptyList(), emptyList(), candidates, Account.PROVENANCE_IMPORTED, session.now(), placeholders)
                VaultContents(result.accounts.map { it.toAccount() }, result.categories.map { it.toCategory() })
            } catch (error: KakeyException) {
                throw VaultException(error)
            }
        } ?: return UiText.Res(R.string.this_export_password_cant_be_used)
        return if (unlock.createVault(masterPassword, enableBiometrics, contents)) null else current.unlockError
    }

    /** Encrypted export (separate password, salt and nonce). */
    suspend fun exportBackup(password: String): ByteArray {
        val accounts = current.accounts.map { it.toCore() }
        val categories = current.categories.map { it.toCore() }
        return withContext(session.io) {
            try {
                coreExportAccounts(accounts, categories, password, session.now())
            } catch (error: KakeyException) {
                throw VaultException(error)
            }
        }
    }

    /**
     * Clears the local vault, biometric key, cloud storage credentials (revoking authorization best effort), settings and backup
     * history; remote backups are untouched.
     */
    suspend fun resetApplication() {
        withContext(NonCancellable) {
            unlock.lock()
            val location = current.preferences.syncLocation
            // Let saves already queued on files finish before deleting, so nothing gets written back afterwards
            withContext(session.files) { session.repository.deleteAll() }
            withContext(session.io) {
                location?.let { sync.releaseLocation(it, keepConnection = false) }
                session.keyStore.remove()
                session.preferencesStore.clear()
                session.historyStore.clear()
            }
            session.state.value = VaultState(phase = Phase.ONBOARDING)
        }
    }
}

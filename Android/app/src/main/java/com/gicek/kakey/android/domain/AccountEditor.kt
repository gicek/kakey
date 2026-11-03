package com.gicek.kakey.android.domain

import com.gicek.kakey.android.R
import com.gicek.kakey.android.core.Account
import com.gicek.kakey.android.core.AccountCategory
import com.gicek.kakey.android.core.Categories
import com.gicek.kakey.android.core.Core
import com.gicek.kakey.android.core.ParsedOtpAuth
import com.gicek.kakey.android.core.UiText
import com.gicek.kakey.android.core.VaultContents
import com.gicek.kakey.android.core.VaultException
import com.gicek.kakey.android.core.VaultSection
import com.gicek.kakey.android.core.toAccount
import com.gicek.kakey.android.core.toCategory
import com.gicek.kakey.android.core.toCore
import com.gicek.kakey.core.CoreAccountCandidate
import com.gicek.kakey.core.CoreTotpAlgorithm
import com.gicek.kakey.core.KakeyException
import com.gicek.kakey.core.coreInsertAccounts
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Adds, edits, deletes and reorders accounts and categories, and queues in-memory state to disk via [persist].
 * Importing backup files lives in [BackupController], which also goes through [insert] after parsing a file.
 */
@Suppress("TooManyFunctions") // One function per account / category use case; splitting further would leave only forwarders
internal class AccountEditor(private val session: VaultSession, private val sync: SyncCoordinator) {
    private val current get() = session.current

    // region Accounts

    /** The single insert path (core `dedup.rs`): skips invalid and duplicate entries, puts new accounts first. Returns the number added. */
    fun insert(candidates: List<CoreAccountCandidate>, addedBy: String, categoryId: String? = null): Int {
        if (current.phase != Phase.UNLOCKED || candidates.isEmpty()) return 0
        val result = try {
            coreInsertAccounts(
                current.accounts.map { it.toCore() },
                current.categories.map { it.toCore() },
                candidates,
                addedBy,
                session.now(),
                session.placeholders(),
            )
        } catch (error: KakeyException) {
            return 0
        }
        if (result.insertedIds.isEmpty()) return 0
        val added = result.accounts.take(result.insertedIds.size).map { it.toAccount() }
        val categories = Categories.adding(result.categories.map { it.toCategory() }, added.map { it.id }, categoryId)
        session.setContents(added + current.accounts, categories)
        persist()
        return added.size
    }

    /** Manual add; returns null on success, otherwise the error to show. Adding inside a category also adds the account to it. */
    @Suppress("LongParameterList") // The six parameters are the six otpauth fields
    fun addManual(issuer: String, username: String, secret: String, algorithm: CoreTotpAlgorithm, digits: Int, period: Int): UiText? {
        if (Core.standardizedSecret(secret) == null) return UiText.Res(R.string.invalid_secret_key)
        val candidate = CoreAccountCandidate(issuer, username, secret, algorithm, digits.toUInt(), period.toUInt(), emptyList(), null)
        return if (insert(listOf(candidate), Account.PROVENANCE_MANUAL, current.section.categoryId) > 0) {
            null
        } else {
            UiText.Res(R.string.account_already_exists)
        }
    }

    /**
     * Results from a scan, photo or paste (all started on the main screen; inside a category they also join it).
     * If every result is a duplicate, shows "account already exists".
     */
    fun addParsed(parsed: List<ParsedOtpAuth>): Int {
        val count = insert(parsed.filter { it.isValid }.map(Core::candidate), Account.PROVENANCE_IMPORTED, current.section.categoryId)
        session.message(if (count > 0) UiText.Plural(R.plurals.added_x_accounts, count) else UiText.Res(R.string.account_already_exists))
        return count
    }

    fun update(account: Account) {
        val accounts = current.accounts.map {
            if (it.id ==
                account.id
            ) {
                account.copy(issuer = account.issuer.trim(), username = account.username.trim())
            } else {
                it
            }
        }
        session.setContents(accounts, current.categories)
        persist()
    }

    fun delete(account: Account) {
        val categories = runCatching { Categories.removing(current.categories, listOf(account.id)) }.getOrDefault(current.categories)
        session.setContents(current.accounts.filterNot { it.id == account.id }, categories)
        persist()
    }

    /**
     * Drag-to-reorder preview: moves the account at [from] in the current section to [to], in memory only and affecting only
     * the current section (all accounts or one category). Called once per item passed while dragging; [commitOrder] saves once
     * on release.
     */
    fun move(from: Int, to: Int) {
        val state = current
        if (from == to) return
        when (val section = state.section) {
            VaultSection.All -> {
                val accounts = state.accounts.toMutableList().apply { add(to, removeAt(from)) }
                session.setContents(accounts, state.categories)
            }
            is VaultSection.Category -> {
                val ordered = state.sectionAccounts.map { it.id }.toMutableList().apply { add(to, removeAt(from)) }
                val categories = runCatching { Categories.setAccountOrder(state.categories, section.id, ordered) }.getOrNull() ?: return
                session.setContents(state.accounts, categories)
            }
        }
    }

    /** End of a drag: writes the order previewed by [move] / [moveCategory] to disk. */
    fun commitOrder() = persist()

    // endregion

    // region Categories

    /** Creates a category; throws [VaultException] for an invalid name. */
    fun createCategory(name: String): AccountCategory {
        val categories = Categories.create(current.categories, name)
        session.setContents(current.accounts, categories)
        persist()
        return categories.last()
    }

    fun renameCategory(id: String, name: String) {
        session.setContents(current.accounts, Categories.rename(current.categories, id, name))
        persist()
    }

    /** Deletes only the category itself; its accounts stay in "All". */
    fun deleteCategory(id: String) {
        session.setContents(current.accounts, Categories.delete(current.categories, id))
        persist()
    }

    /** Category drag-to-reorder preview (in memory only); [commitOrder] on release. */
    fun moveCategory(from: Int, to: Int) {
        val ordered = current.categories.map { it.id }.toMutableList().apply { add(to, removeAt(from)) }
        session.setContents(current.accounts, Categories.reorder(current.categories, ordered))
    }

    /** Toggles a checkmark in "Add to": removes the account if it is already in the category, otherwise appends it. */
    fun toggleAccount(accountId: String, categoryId: String) {
        val categories = runCatching {
            if (current.isAccount(accountId, categoryId)) {
                Categories.remove(current.categories, categoryId, accountId)
            } else {
                Categories.add(current.categories, categoryId, accountId)
            }
        }.getOrNull() ?: return
        session.setContents(current.accounts, categories)
        persist()
    }

    /**
     * Saves the "Add to" sheet: sets the account's category membership to [categoryIds] in one go (joining newly checked ones,
     * leaving unchecked ones) and writes to disk once; does nothing when nothing changed.
     */
    fun setAccountCategories(accountId: String, categoryIds: Set<String>) {
        var categories = current.categories
        var changed = false
        current.categories.forEach { category ->
            val wanted = category.id in categoryIds
            if (wanted == accountId in category.accountIds) return@forEach
            categories = runCatching {
                if (wanted) Categories.add(categories, category.id, accountId) else Categories.remove(categories, category.id, accountId)
            }.getOrNull() ?: return@forEach
            changed = true
        }
        if (!changed) return
        session.setContents(current.accounts, categories)
        persist()
    }

    // endregion

    /**
     * Rewrites with the current key while unlocked: takes a snapshot on the main thread (generation, key copy, contents), queues
     * a serial write on `files`, then queues a sync on success. If the file is replaced wholesale while queued (password change,
     * download) the snapshot is dropped; in-memory state is still current and the next save catches up.
     */
    private fun persist() {
        val snapshotGeneration = session.generation.get()
        val key = session.key?.copyOf() ?: return
        val contents = VaultContents(current.accounts, current.categories)
        // Launch directly onto files: enqueuing on the calling thread keeps call order with later password changes, resets and other
        // file operations
        session.scope.launch(session.files) {
            val failure = withContext(NonCancellable) {
                try {
                    if (session.generation.get() != snapshotGeneration) return@withContext null
                    session.repository.save(contents, key)
                    null
                } catch (error: VaultException) {
                    // The key failing to open the current file can only happen if the generation check above failed, so report a crypto
                    // failure rather than "wrong password"
                    if (error.error is KakeyException.InvalidPassword) UiText.Res(R.string.err_vault_crypto_failure) else error.text
                } catch (error: Exception) {
                    UiText.Res(R.string.err_vault_crypto_failure)
                } finally {
                    key.fill(0)
                }
            }
            if (failure == null) session.scope.launch { sync.scheduleSync() } else session.message(failure)
        }
    }
}

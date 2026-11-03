package com.gicek.kakey.android.core

import com.gicek.kakey.core.CoreAccount
import com.gicek.kakey.core.CoreCategory
import com.gicek.kakey.core.CoreParsedOtpAuth
import com.gicek.kakey.core.CoreTotpAlgorithm
import com.gicek.kakey.core.CoreVaultContents
import java.time.Instant

/**
 * Platform-side account and category models, just the Kotlin shape of core records; all rules (normalization, deduplication,
 * category membership, encryption) live in the Rust core. IDs are always the core's uppercase UUID strings to avoid conversions.
 */
data class Account(
    val id: String,
    val issuer: String,
    val username: String,
    val secret: String,
    val algorithm: CoreTotpAlgorithm,
    val digits: Int,
    val period: Int,
    val createdAt: Instant,
    val addedBy: String,
) {
    fun matchesSearch(query: String): Boolean = Core.matchesSearch(issuer, username, query)

    /** Logs and debug output never include the secret (docs/SECURITY.md). */
    override fun toString(): String = "Account(id=$id, issuer=$issuer, digits=$digits, period=$period)"

    companion object {
        const val PROVENANCE_MANUAL = "manual"
        const val PROVENANCE_IMPORTED = "import"
    }
}

data class AccountCategory(val id: String, val name: String, val accountIds: List<String>)

data class VaultContents(val accounts: List<Account>, val categories: List<AccountCategory>) {
    companion object {
        val EMPTY = VaultContents(emptyList(), emptyList())
    }
}

/** The section the list currently shows: all accounts, or one category. */
sealed interface VaultSection {
    data object All : VaultSection
    data class Category(val id: String) : VaultSection

    val categoryId: String? get() = (this as? Category)?.id
}

/** One result recognized from a scan, paste or photo; invalid ones carry a failure reason and are listed separately on the review page. */
data class ParsedOtpAuth(
    val issuer: String,
    val account: String,
    val secret: String,
    val algorithm: CoreTotpAlgorithm,
    val digits: Int,
    val period: Int,
    val failure: com.gicek.kakey.core.CoreParseFailure?,
) {
    val isValid: Boolean get() = failure == null

    override fun toString(): String = "ParsedOtpAuth(issuer=$issuer, valid=$isValid)"
}

fun CoreAccount.toAccount() = Account(
    id = id,
    issuer = issuer,
    username = username,
    secret = secret,
    algorithm = algorithm,
    digits = digits.toInt(),
    period = period.toInt(),
    createdAt = createdAt,
    addedBy = addedBy,
)

fun Account.toCore() = CoreAccount(
    id = id,
    issuer = issuer,
    username = username,
    secret = secret,
    algorithm = algorithm,
    digits = digits.toUInt(),
    period = period.toUInt(),
    createdAt = createdAt,
    addedBy = addedBy,
)

fun CoreCategory.toCategory() = AccountCategory(id = id, name = name, accountIds = accountIds)

fun AccountCategory.toCore() = CoreCategory(id = id, name = name, accountIds = accountIds)

fun CoreVaultContents.toContents() = VaultContents(
    accounts = accounts.map { it.toAccount() },
    categories = categories.map { it.toCategory() },
)

fun VaultContents.toCore() = CoreVaultContents(
    accounts = accounts.map { it.toCore() },
    categories = categories.map { it.toCore() },
    pinnedIds = emptyList(),
)

fun CoreParsedOtpAuth.toParsed() = ParsedOtpAuth(
    issuer = issuer,
    account = account,
    secret = secret,
    algorithm = algorithm,
    digits = digits.toInt(),
    period = period.toInt(),
    failure = failure,
)

/** Accounts in a category, in the category's own order (`accountIds` order is the in-category order). */
fun List<AccountCategory>.accountsIn(categoryId: String, accounts: List<Account>): List<Account> {
    val category = firstOrNull { it.id == categoryId } ?: return emptyList()
    val byId = accounts.associateBy { it.id }
    return category.accountIds.mapNotNull { byId[it] }
}

val CoreTotpAlgorithm.label: String
    get() = when (this) {
        CoreTotpAlgorithm.SHA1 -> "SHA1"
        CoreTotpAlgorithm.SHA256 -> "SHA256"
        CoreTotpAlgorithm.SHA512 -> "SHA512"
    }

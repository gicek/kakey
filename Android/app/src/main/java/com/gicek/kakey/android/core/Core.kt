package com.gicek.kakey.android.core

import android.content.Context
import com.gicek.kakey.android.R
import com.gicek.kakey.android.domain.CloudSyncException
import com.gicek.kakey.core.CoreAccountCandidate
import com.gicek.kakey.core.CoreCloudException
import com.gicek.kakey.core.CoreParseFailure
import com.gicek.kakey.core.CorePasswordStrength
import com.gicek.kakey.core.CorePlaceholders
import com.gicek.kakey.core.CoreScanResult
import com.gicek.kakey.core.KakeyException
import com.gicek.kakey.core.coreCategoriesRemovingAccounts
import com.gicek.kakey.core.coreCategoryAddAccount
import com.gicek.kakey.core.coreCategoryCreate
import com.gicek.kakey.core.coreCategoryDelete
import com.gicek.kakey.core.coreCategoryRemoveAccount
import com.gicek.kakey.core.coreCategoryRename
import com.gicek.kakey.core.coreCategoryReorder
import com.gicek.kakey.core.coreCategorySetAccountOrder
import com.gicek.kakey.core.coreCloudErrorL10nKey
import com.gicek.kakey.core.coreErrorL10nKey
import com.gicek.kakey.core.coreEvaluatePassword
import com.gicek.kakey.core.coreFilterPasswordInput
import com.gicek.kakey.core.coreIsAcceptableExportPassword
import com.gicek.kakey.core.coreIsAcceptableMasterPassword
import com.gicek.kakey.core.coreIsKakeyExport
import com.gicek.kakey.core.coreMatchesSearch
import com.gicek.kakey.core.coreMaxCategoryNameChars
import com.gicek.kakey.core.coreMinPasswordLength
import com.gicek.kakey.core.coreMonogram
import com.gicek.kakey.core.coreOtpauthUrl
import com.gicek.kakey.core.corePaletteIndex
import com.gicek.kakey.core.coreParseOtpauthLines
import com.gicek.kakey.core.coreParseScanResult
import com.gicek.kakey.core.coreStandardizedSecret
import com.gicek.kakey.core.coreTotpCode
import com.gicek.kakey.core.coreTotpFormatted
import com.gicek.kakey.core.coreTotpProgress
import com.gicek.kakey.core.coreTotpSecondsRemaining
import java.time.Instant

/**
 * Thin wrapper over the Rust core: type conversion and error mapping live here (the counterpart of Apple's `CoreBridge.swift`).
 * Platform code never reimplements core rules.
 */
@Suppress("TooManyFunctions") // Core facade: one function per core call
object Core {
    fun code(account: Account, at: Instant = Instant.now()): String =
        coreTotpCode(account.secret, account.algorithm, account.digits.toUInt(), account.period.toUInt(), at)

    /** Groups digits as 3+3 / 4+4 for display (core `totp_formatted`). */
    fun formatted(code: String): String = coreTotpFormatted(code)

    fun secondsRemaining(account: Account, at: Instant = Instant.now()): Int = coreTotpSecondsRemaining(account.period.toUInt(), at).toInt()

    fun progress(account: Account, at: Instant = Instant.now()): Float = coreTotpProgress(account.period.toUInt(), at).toFloat()

    fun matchesSearch(issuer: String, username: String, query: String): Boolean = coreMatchesSearch(issuer, username, query)

    fun monogram(issuer: String): String = coreMonogram(issuer)

    fun paletteIndex(issuer: String): Int = corePaletteIndex(issuer).toInt()

    fun standardizedSecret(secret: String): String? = coreStandardizedSecret(secret)

    fun parseLines(text: String, placeholders: CorePlaceholders): List<ParsedOtpAuth> =
        coreParseOtpauthLines(text, placeholders).map { it.toParsed() }

    /** Scan result, including batch info for Google migration codes (`batchId` / `batchKey` / `batchSize`). */
    fun parseScan(payload: String, placeholders: CorePlaceholders): CoreScanResult = coreParseScanResult(payload, placeholders)

    /** The `otpauth://` text for a single-account QR code (same URI builder as import). */
    fun otpauthUrl(account: Account, placeholders: CorePlaceholders): String = coreOtpauthUrl(account.toCore(), placeholders)

    fun evaluatePassword(password: String): CorePasswordStrength = coreEvaluatePassword(password)

    /** New master and export passwords: 8 to 128 characters, allowed characters only, strength at least "fair" (weak is rejected). */
    fun isAcceptableMasterPassword(password: String): Boolean = coreIsAcceptableMasterPassword(password)

    fun isKakeyExport(data: ByteArray): Boolean = coreIsKakeyExport(data)

    /** Matches the 8 in the "at least 8 characters" UI text. */
    val minPasswordLength: Int get() = coreMinPasswordLength().toInt()

    /** Input filter for new master and export passwords: keeps only digits, ASCII letters and ASCII symbols (no spaces). */
    fun filterPasswordInput(input: String): String = coreFilterPasswordInput(input)

    fun isAcceptableExportPassword(password: String): Boolean = coreIsAcceptableExportPassword(password)

    /** Placeholder names used by parsing and deduplication ("Unknown service", "No account"), in the current language. */
    fun placeholders(context: Context) =
        CorePlaceholders(context.getString(R.string.unknown_service), context.getString(R.string.no_account))

    val maxCategoryNameChars: Int get() = coreMaxCategoryNameChars().toInt()

    fun candidate(parsed: ParsedOtpAuth) = CoreAccountCandidate(
        issuer = parsed.issuer,
        username = parsed.account,
        secret = parsed.secret,
        algorithm = parsed.algorithm,
        digits = parsed.digits.toUInt(),
        period = parsed.period.toUInt(),
        categoryNames = emptyList(),
        createdAt = null,
    )
}

/** Category operations (core `category.rs`); invalid names throw [VaultException]. */
object Categories {
    fun create(categories: List<AccountCategory>, name: String) = mapped { coreCategoryCreate(categories.map { it.toCore() }, name) }

    fun rename(categories: List<AccountCategory>, id: String, name: String) =
        mapped { coreCategoryRename(categories.map { it.toCore() }, id, name) }

    fun delete(categories: List<AccountCategory>, id: String) = mapped { coreCategoryDelete(categories.map { it.toCore() }, id) }

    fun reorder(categories: List<AccountCategory>, orderedIds: List<String>) =
        mapped { coreCategoryReorder(categories.map { it.toCore() }, orderedIds) }

    fun add(categories: List<AccountCategory>, categoryId: String, accountId: String) =
        mapped { coreCategoryAddAccount(categories.map { it.toCore() }, categoryId, accountId) }

    fun remove(categories: List<AccountCategory>, categoryId: String, accountId: String) =
        mapped { coreCategoryRemoveAccount(categories.map { it.toCore() }, categoryId, accountId) }

    fun setAccountOrder(categories: List<AccountCategory>, categoryId: String, orderedIds: List<String>) =
        mapped { coreCategorySetAccountOrder(categories.map { it.toCore() }, categoryId, orderedIds) }

    fun removing(categories: List<AccountCategory>, accountIds: List<String>) =
        mapped { coreCategoriesRemovingAccounts(categories.map { it.toCore() }, accountIds) }

    /** Adds newly added accounts to the given category; returns the list unchanged for `null` or a category that no longer exists. */
    fun adding(categories: List<AccountCategory>, accountIds: List<String>, categoryId: String?): List<AccountCategory> {
        if (categoryId == null) return categories
        return accountIds.fold(categories) { result, id -> runCatching { add(result, categoryId, id) }.getOrDefault(result) }
    }

    private inline fun mapped(body: () -> List<com.gicek.kakey.core.CoreCategory>): List<AccountCategory> = try {
        body().map { it.toCategory() }
    } catch (error: KakeyException) {
        throw VaultException(error)
    }
}

/**
 * Platform form of a core error: holds only a string resource ID, resolved at display time so a language change never leaves
 * stale text. The error -> localization key table is maintained once in the core (`core_error_l10n_key`); this only maps
 * semantic keys to generated resource IDs (resource name = key with `.` replaced by `_`, see scripts/android_strings.py).
 * `CoreErrorsTest` ensures every variant has a resource.
 */
class VaultException(val error: KakeyException) : Exception(error.toString()) {
    val text: UiText
        get() {
            val key = coreErrorL10nKey(error)
            val id = ERROR_STRINGS[key] ?: return UiText.Raw(key)
            return if (key == "err.category.name_too_long") UiText.Res(id, Core.maxCategoryNameChars) else UiText.Res(id)
        }

    companion object {
        /** Semantic key -> resource ID. Lookup by name at runtime would be stripped by resource shrinking, so references stay explicit. */
        val ERROR_STRINGS: Map<String, Int> = mapOf(
            "err.vault.empty_password" to R.string.err_vault_empty_password,
            "err.vault.unacceptable_password" to R.string.err_vault_unacceptable_password,
            "err.vault.invalid_password" to R.string.err_vault_invalid_password,
            "err.vault.corrupt" to R.string.err_vault_corrupt,
            "err.vault.key_derivation" to R.string.err_vault_key_derivation,
            "err.vault.invalid_key" to R.string.err_vault_invalid_key,
            "err.vault.crypto_failure" to R.string.err_vault_crypto_failure,
            "err.import.password_required" to R.string.err_import_password_required,
            "err.import.invalid_file" to R.string.err_import_invalid_file,
            "err.import.wrong_password" to R.string.err_import_wrong_password,
            "err.import.no_supported" to R.string.err_import_no_supported,
            "err.category.empty_name" to R.string.err_category_empty_name,
            "err.category.name_too_long" to R.string.err_category_name_too_long,
            "err.category.duplicate_name" to R.string.err_category_duplicate_name,
            "err.category.not_found" to R.string.err_category_not_found,
        )
    }
}

/** Text for cloud storage failures: the key comes from core `core_cloud_error_l10n_key`; server errors include the status code. */
val CloudSyncException.text: UiText
    get() {
        val key = coreCloudErrorL10nKey(error)
        val id = CLOUD_ERROR_STRINGS[key] ?: return UiText.Raw(key)
        val server = error as? CoreCloudException.Server
        return if (server != null) UiText.Res(id, server.status.toInt()) else UiText.Res(id)
    }

/** Semantic key -> resource ID (explicit references survive resource shrinking); `CoreErrorsTest` ensures every core key is listed. */
val CLOUD_ERROR_STRINGS: Map<String, Int> = mapOf(
    "err.cloud.reauth" to R.string.err_cloud_reauth,
    "err.cloud.forbidden" to R.string.err_cloud_forbidden,
    "err.cloud.not_found" to R.string.err_cloud_not_found,
    "err.cloud.conflict" to R.string.err_cloud_conflict,
    "err.cloud.quota" to R.string.err_cloud_quota,
    "err.cloud.rate_limited" to R.string.err_cloud_rate_limited,
    "err.cloud.server" to R.string.err_cloud_server,
    "err.cloud.invalid_response" to R.string.err_cloud_invalid_response,
    "err.cloud.too_large" to R.string.err_cloud_too_large,
    "err.cloud.insecure_redirect" to R.string.err_cloud_insecure_redirect,
    "err.cloud.insecure_address" to R.string.err_cloud_insecure_address,
    "err.cloud.invalid_address" to R.string.err_cloud_invalid_address,
    "err.cloud.invalid_path" to R.string.err_cloud_invalid_path,
    "err.cloud.invalid_connection" to R.string.err_cloud_invalid_connection,
    "err.cloud.authorization_denied" to R.string.err_cloud_authorization_denied,
    "err.cloud.authorization_failed" to R.string.err_cloud_authorization_failed,
    "err.cloud.internal" to R.string.err_cloud_internal,
)

/** Text for parse failure reasons (the core returns only the reason; key names are in `parse_failure_l10n_key`). */
val CoreParseFailure.message: UiText
    get() = UiText.Res(
        when (this) {
            CoreParseFailure.BAD_URL -> R.string.otp_err_bad_url
            CoreParseFailure.BAD_BASE32 -> R.string.otp_err_bad_base32
            CoreParseFailure.NOT_OTPAUTH -> R.string.otp_err_not_otpauth
            CoreParseFailure.NOT_TOTP -> R.string.otp_err_not_totp
            CoreParseFailure.MISSING_SECRET -> R.string.otp_err_missing_secret
            CoreParseFailure.DIGITS -> R.string.otp_err_digits
            CoreParseFailure.PERIOD -> R.string.otp_err_period
            CoreParseFailure.BAD_MIGRATION -> R.string.otp_err_bad_migration
            CoreParseFailure.UNSUPPORTED_ALGORITHM -> R.string.otp_err_unsupported_algorithm
        },
    )

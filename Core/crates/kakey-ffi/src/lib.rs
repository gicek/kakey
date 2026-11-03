//! The only public boundary of the Kakey core (UniFFI), generating the Swift and Kotlin bindings.
//!
//! - Coarse-grained interface: one call does one thing. Slow calls such as Argon2id derivation are synchronous; platforms
//!   call them on a background thread.
//! - UUIDs cross as uppercase strings, times as `SystemTime` (Swift `Date` / Kotlin `Instant`), and keys and file
//!   contents as byte strings.
//! - All errors are [`KakeyError`]; localization keys come from [`error_l10n_key`] (`core_error_l10n_key`), with the
//!   table maintained only once, in the core.
//! - Enums identical to core types (algorithm, parse failure, password strength, sync decision, remote version) export
//!   the core types directly via `#[uniffi::remote(Enum)]`, still named `Core*` externally, with no hand-written mirrors
//!   or conversions.
//! - Exported names are prefixed: functions `core_*` (Swift `coreXxx`, Kotlin `coreXxx`), types `Core*`, so they do not
//!   shadow existing same-named types (`Account`, `PasswordStrength`) and wrapper methods on each platform.
//! - UniFFI catches panics at the boundary; core code paths should not panic.
//! - Passwords passed in are wrapped in `Zeroizing` as soon as they enter the core and wiped after use. Records holding
//!   TOTP secrets or vault keys have hand-written `Debug` impls so `{:?}` never prints those values.

use std::time::SystemTime;

mod cloud;
pub use cloud::*;

use kakey_core::merge::{self, AccountChange};
use kakey_core::model::TotpAlgorithm;
use kakey_core::otpauth::ParseFailure;
use kakey_core::password::PasswordStrength;
use kakey_core::sync::{RemoteVersion, SyncDecision};
use kakey_core::{authenticator, base32, canonical, category, dedup, model, otpauth, password, search, sync, totp, vault};
use uuid::Uuid;
use zeroize::Zeroizing;

uniffi::setup_scaffolding!();

const REDACTED: &str = "<redacted>";

/// The core [`model::TotpAlgorithm`] exported directly as `CoreTotpAlgorithm`; variants must match the core definition.
#[uniffi::remote(Enum)]
#[uniffi(name = "CoreTotpAlgorithm")]
pub enum TotpAlgorithm {
    Sha1,
    Sha256,
    Sha512,
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreAccount {
    /// Uppercase UUID string.
    pub id: String,
    pub issuer: String,
    pub username: String,
    pub secret: String,
    pub algorithm: TotpAlgorithm,
    pub digits: u32,
    pub period: u32,
    pub created_at: SystemTime,
    pub added_by: String,
}

impl std::fmt::Debug for CoreAccount {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CoreAccount")
            .field("id", &self.id)
            .field("issuer", &self.issuer)
            .field("username", &self.username)
            .field("secret", &model::redacted_secret(&self.secret))
            .field("algorithm", &self.algorithm)
            .field("digits", &self.digits)
            .field("period", &self.period)
            .field("created_at", &self.created_at)
            .field("added_by", &self.added_by)
            .finish()
    }
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CorePlaceholders {
    pub unknown_issuer: String,
    pub empty_username: String,
}

impl From<&CorePlaceholders> for model::Placeholders {
    fn from(value: &CorePlaceholders) -> Self {
        model::Placeholders { unknown_issuer: value.unknown_issuer.clone(), empty_username: value.empty_username.clone() }
    }
}

/// Variants are error codes; localization keys come from [`error_l10n_key`] (the table lives on each core error type's
/// `l10n_key` and is only reused here). Adding or removing a variant breaks the exhaustive `switch` / `when` over
/// `KakeyError` on each platform, so change them in the same commit.
#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum KakeyError {
    /// `err.vault.empty_password`
    #[error("password is empty")]
    EmptyPassword,
    /// `err.vault.unacceptable_password`: the export password breaks the rules (fewer than 8 characters, disallowed
    /// characters, or `Weak` strength); the UI blocks this first and the core is the backstop.
    #[error("password is not acceptable")]
    UnacceptablePassword,
    /// `err.vault.invalid_password`
    #[error("wrong password or damaged ciphertext")]
    InvalidPassword,
    /// `err.vault.corrupt`
    #[error("vault file is corrupt or unsupported")]
    CorruptVault,
    /// `err.vault.key_derivation`
    #[error("key derivation failed")]
    KeyDerivationFailed,
    /// `err.vault.invalid_key`: the vault key passed in is not 32 bytes (for example, a corrupted Keychain / Keystore
    /// item).
    #[error("vault key must be 32 bytes")]
    InvalidKey,
    /// `err.vault.crypto_failure`: the system RNG or a crypto operation failed.
    #[error("system crypto operation failed")]
    CryptoFailure,
    /// `err.import.password_required`
    #[error("a password is required")]
    PasswordRequired,
    /// `err.import.invalid_file`
    #[error("not a supported backup file")]
    InvalidFile,
    /// `err.import.wrong_password`
    #[error("wrong password")]
    WrongPassword,
    /// `err.import.no_supported`
    #[error("no supported accounts")]
    NoSupportedAccounts,
    /// The caller passed an unparseable UUID (a programming error, not user-facing); its text is the "category not found"
    /// one (matching the original Android table).
    #[error("invalid account id")]
    InvalidId,
    /// `err.category.empty_name`
    #[error("category name is empty")]
    EmptyCategoryName,
    /// `err.category.name_too_long`
    #[error("category name is too long")]
    CategoryNameTooLong,
    /// `err.category.duplicate_name`
    #[error("a category with this name already exists")]
    DuplicateCategoryName,
    /// `err.category.not_found`: the category was deleted (after a sync from another device, for example), or the caller
    /// passed a wrong ID.
    #[error("category not found")]
    CategoryNotFound,
}

impl KakeyError {
    /// The matching localization key (a semantic String Catalog key; Android uses a resource of the same name). The table
    /// is maintained only once, in the core: variants are mapped back to core errors to look up the key, and `InvalidId`,
    /// which is not a core error, uses the "category not found" key.
    pub fn l10n_key(self) -> &'static str {
        match self {
            KakeyError::EmptyPassword => vault::VaultError::EmptyPassword.l10n_key(),
            KakeyError::UnacceptablePassword => vault::VaultError::UnacceptablePassword.l10n_key(),
            KakeyError::InvalidPassword => vault::VaultError::InvalidPassword.l10n_key(),
            KakeyError::CorruptVault => vault::VaultError::CorruptVault.l10n_key(),
            KakeyError::KeyDerivationFailed => vault::VaultError::KeyDerivationFailed.l10n_key(),
            KakeyError::InvalidKey => vault::VaultError::InvalidKey.l10n_key(),
            KakeyError::CryptoFailure => vault::VaultError::CryptoFailure.l10n_key(),
            KakeyError::PasswordRequired => authenticator::ImportError::PasswordRequired.l10n_key(),
            KakeyError::InvalidFile => authenticator::ImportError::InvalidFile.l10n_key(),
            KakeyError::WrongPassword => authenticator::ImportError::WrongPassword.l10n_key(),
            KakeyError::NoSupportedAccounts => authenticator::ImportError::NoSupportedAccounts.l10n_key(),
            KakeyError::EmptyCategoryName => category::CategoryError::EmptyName.l10n_key(),
            KakeyError::CategoryNameTooLong => category::CategoryError::NameTooLong.l10n_key(),
            KakeyError::DuplicateCategoryName => category::CategoryError::DuplicateName.l10n_key(),
            KakeyError::CategoryNotFound | KakeyError::InvalidId => category::CategoryError::NotFound.l10n_key(),
        }
    }
}

/// Localization key for an error (see [`KakeyError::l10n_key`]), so platforms need not maintain their own tables.
#[uniffi::export(name = "core_error_l10n_key")]
pub fn error_l10n_key(error: KakeyError) -> String {
    error.l10n_key().to_owned()
}

impl From<category::CategoryError> for KakeyError {
    fn from(value: category::CategoryError) -> Self {
        match value {
            category::CategoryError::EmptyName => KakeyError::EmptyCategoryName,
            category::CategoryError::NameTooLong => KakeyError::CategoryNameTooLong,
            category::CategoryError::DuplicateName => KakeyError::DuplicateCategoryName,
            category::CategoryError::NotFound => KakeyError::CategoryNotFound,
        }
    }
}

impl From<vault::VaultError> for KakeyError {
    fn from(value: vault::VaultError) -> Self {
        match value {
            vault::VaultError::EmptyPassword => KakeyError::EmptyPassword,
            vault::VaultError::InvalidPassword => KakeyError::InvalidPassword,
            vault::VaultError::CorruptVault => KakeyError::CorruptVault,
            vault::VaultError::KeyDerivationFailed => KakeyError::KeyDerivationFailed,
            vault::VaultError::InvalidKey => KakeyError::InvalidKey,
            vault::VaultError::CryptoFailure => KakeyError::CryptoFailure,
            vault::VaultError::UnacceptablePassword => KakeyError::UnacceptablePassword,
        }
    }
}

impl From<authenticator::ImportError> for KakeyError {
    fn from(value: authenticator::ImportError) -> Self {
        match value {
            authenticator::ImportError::PasswordRequired => KakeyError::PasswordRequired,
            authenticator::ImportError::InvalidFile => KakeyError::InvalidFile,
            authenticator::ImportError::WrongPassword => KakeyError::WrongPassword,
            authenticator::ImportError::NoSupportedAccounts => KakeyError::NoSupportedAccounts,
            authenticator::ImportError::Vault(error) => error.into(),
        }
    }
}

fn id_string(id: Uuid) -> String {
    id.hyphenated().encode_upper(&mut Uuid::encode_buffer()).to_owned()
}

fn parse_id(value: &str) -> Result<Uuid, KakeyError> {
    Uuid::parse_str(value).map_err(|_| KakeyError::InvalidId)
}

fn parse_ids(values: &[String]) -> Result<Vec<Uuid>, KakeyError> {
    values.iter().map(|value| parse_id(value)).collect()
}

impl From<&model::Account> for CoreAccount {
    fn from(value: &model::Account) -> Self {
        CoreAccount {
            id: id_string(value.id),
            issuer: value.issuer.clone(),
            username: value.username.clone(),
            secret: value.secret.clone(),
            algorithm: value.algorithm,
            digits: value.digits,
            period: value.period,
            created_at: value.created_at,
            added_by: value.added_by.clone(),
        }
    }
}

impl TryFrom<&CoreAccount> for model::Account {
    type Error = KakeyError;

    fn try_from(value: &CoreAccount) -> Result<Self, KakeyError> {
        Ok(model::Account {
            id: parse_id(&value.id)?,
            issuer: value.issuer.clone(),
            username: value.username.clone(),
            secret: value.secret.clone(),
            algorithm: value.algorithm,
            digits: value.digits,
            period: value.period,
            created_at: value.created_at,
            added_by: value.added_by.clone(),
        })
    }
}

fn to_core_accounts(accounts: &[CoreAccount]) -> Result<Vec<model::Account>, KakeyError> {
    accounts.iter().map(model::Account::try_from).collect()
}

fn from_core_accounts(accounts: &[model::Account]) -> Vec<CoreAccount> {
    accounts.iter().map(CoreAccount::from).collect()
}

// MARK: - TOTP and Base32

#[uniffi::export(name = "core_totp_code")]
pub fn totp_code(secret: String, algorithm: TotpAlgorithm, digits: u32, period: u32, at: SystemTime) -> String {
    totp::code(&secret, algorithm, digits, period, at)
}

/// Inserts a space in the middle when longer than 4 digits.
#[uniffi::export(name = "core_totp_formatted")]
pub fn totp_formatted(code: String) -> String {
    totp::formatted(&code)
}

#[uniffi::export(name = "core_totp_seconds_remaining")]
pub fn totp_seconds_remaining(period: u32, at: SystemTime) -> u32 {
    totp::seconds_remaining(period, at)
}

/// Fraction of the current period remaining, in (0, 1].
#[uniffi::export(name = "core_totp_progress")]
pub fn totp_progress(period: u32, at: SystemTime) -> f64 {
    totp::progress(period, at)
}

#[uniffi::export(name = "core_is_valid_secret")]
pub fn is_valid_secret(secret: String) -> bool {
    totp::is_valid_secret(&secret)
}

#[uniffi::export(name = "core_base32_encode")]
pub fn base32_encode(data: Vec<u8>) -> String {
    base32::encode(&data)
}

#[uniffi::export(name = "core_base32_decode")]
pub fn base32_decode(value: String) -> Option<Vec<u8>> {
    base32::decode(&value)
}

// MARK: - Standardization, parsing, deduplication

#[uniffi::export(name = "core_clean_text")]
pub fn clean_text(value: String) -> String {
    canonical::clean_text(&value)
}

#[uniffi::export(name = "core_standardized_secret")]
pub fn standardized_secret(value: String) -> Option<String> {
    canonical::standardized_secret(&value)
}

#[uniffi::export(name = "core_stripping_issuer_prefix")]
pub fn stripping_issuer_prefix(username: String, issuer: String) -> String {
    canonical::stripping_issuer_prefix(&username, &issuer)
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreCanonicalFields {
    pub issuer: String,
    pub username: String,
    pub secret: String,
    pub algorithm: TotpAlgorithm,
    pub digits: u32,
    pub period: u32,
}

impl std::fmt::Debug for CoreCanonicalFields {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CoreCanonicalFields")
            .field("issuer", &self.issuer)
            .field("username", &self.username)
            .field("secret", &model::redacted_secret(&self.secret))
            .field("algorithm", &self.algorithm)
            .field("digits", &self.digits)
            .field("period", &self.period)
            .finish()
    }
}

/// Standardization applied before saving; `None` when digits is not 6 / 8 or the secret is invalid.
#[uniffi::export(name = "core_canonical_fields")]
pub fn canonical_fields(
    issuer: String,
    username: String,
    secret: String,
    algorithm: TotpAlgorithm,
    digits: u32,
    period: u32,
    placeholders: CorePlaceholders,
) -> Option<CoreCanonicalFields> {
    canonical::fields(&issuer, &username, &secret, algorithm, digits, period, &(&placeholders).into()).map(|fields| CoreCanonicalFields {
        issuer: fields.issuer,
        username: fields.username,
        secret: fields.secret,
        algorithm: fields.algorithm,
        digits: fields.digits,
        period: fields.period,
    })
}

/// Standard otpauth URI for single-account QR code export.
#[uniffi::export(name = "core_otpauth_url")]
pub fn otpauth_url(account: CoreAccount, placeholders: CorePlaceholders) -> Result<String, KakeyError> {
    Ok(canonical::otpauth_url(&model::Account::try_from(&account)?, &(&placeholders).into()))
}

/// The core [`otpauth::ParseFailure`] exported directly as `CoreParseFailure`; for localization keys see
/// [`parse_failure_l10n_key`].
#[uniffi::remote(Enum)]
#[uniffi(name = "CoreParseFailure")]
pub enum ParseFailure {
    BadUrl,
    NotOtpauth,
    NotTotp,
    MissingSecret,
    BadBase32,
    Digits,
    Period,
    BadMigration,
    UnsupportedAlgorithm,
}

/// Localization key for a parse failure (`otp.err.*`; the table is in the core).
#[uniffi::export(name = "core_parse_failure_l10n_key")]
pub fn parse_failure_l10n_key(failure: ParseFailure) -> String {
    failure.l10n_key().to_owned()
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreParsedOtpAuth {
    /// `None` means valid.
    pub failure: Option<ParseFailure>,
    pub issuer: String,
    pub account: String,
    pub secret: String,
    pub algorithm: TotpAlgorithm,
    pub digits: u32,
    pub period: u32,
}

impl std::fmt::Debug for CoreParsedOtpAuth {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CoreParsedOtpAuth")
            .field("failure", &self.failure)
            .field("issuer", &self.issuer)
            .field("account", &self.account)
            .field("secret", &model::redacted_secret(&self.secret))
            .field("algorithm", &self.algorithm)
            .field("digits", &self.digits)
            .field("period", &self.period)
            .finish()
    }
}

impl From<&otpauth::ParsedOtpAuth> for CoreParsedOtpAuth {
    fn from(value: &otpauth::ParsedOtpAuth) -> Self {
        CoreParsedOtpAuth {
            failure: value.failure,
            issuer: value.issuer.clone(),
            account: value.account.clone(),
            secret: value.secret.clone(),
            algorithm: value.algorithm,
            digits: value.digits,
            period: value.period,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreScanResult {
    pub accounts: Vec<CoreParsedOtpAuth>,
    pub is_google_migration: bool,
    /// Distinguishes batches when merging several migration QR codes; `None` for non-migration codes.
    pub batch_key: Option<String>,
    pub batch_size: Option<i64>,
    pub batch_index: Option<i64>,
    pub batch_id: Option<i64>,
}

#[uniffi::export(name = "core_parse_otpauth")]
pub fn parse_otpauth(line: String, placeholders: CorePlaceholders) -> CoreParsedOtpAuth {
    (&otpauth::parse(&line, &(&placeholders).into())).into()
}

/// Full result of one scan / one block of text (migration codes expand into several entries).
#[uniffi::export(name = "core_parse_scan_result")]
pub fn parse_scan_result(line: String, placeholders: CorePlaceholders) -> CoreScanResult {
    let result = otpauth::parse_scan_result(&line, &(&placeholders).into());
    CoreScanResult {
        accounts: result.accounts.iter().map(Into::into).collect(),
        is_google_migration: result.is_google_migration,
        batch_key: result.batch_key(),
        batch_size: result.batch_size,
        batch_index: result.batch_index,
        batch_id: result.batch_id,
    }
}

/// Parses pasted or dropped text line by line.
#[uniffi::export(name = "core_parse_otpauth_lines")]
pub fn parse_otpauth_lines(text: String, placeholders: CorePlaceholders) -> Vec<CoreParsedOtpAuth> {
    otpauth::parse_lines(&text, &(&placeholders).into()).iter().map(Into::into).collect()
}

#[uniffi::export(name = "core_deduplication_key")]
pub fn deduplication_key(account: CoreAccount, placeholders: CorePlaceholders) -> String {
    dedup::deduplication_key(
        &account.issuer,
        &account.username,
        &account.secret,
        account.algorithm,
        account.digits,
        account.period,
        &(&placeholders).into(),
    )
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreAccountCandidate {
    pub issuer: String,
    pub username: String,
    pub secret: String,
    pub algorithm: TotpAlgorithm,
    pub digits: u32,
    pub period: u32,
    /// Category names to add the account to once inserted (matched case-insensitively, created if missing); a candidate
    /// skipped as a duplicate changes no category.
    pub category_names: Vec<String>,
    /// `None` means the insertion time.
    pub created_at: Option<SystemTime>,
}

impl std::fmt::Debug for CoreAccountCandidate {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CoreAccountCandidate")
            .field("issuer", &self.issuer)
            .field("username", &self.username)
            .field("secret", &model::redacted_secret(&self.secret))
            .field("algorithm", &self.algorithm)
            .field("digits", &self.digits)
            .field("period", &self.period)
            .field("category_names", &self.category_names)
            .field("created_at", &self.created_at)
            .finish()
    }
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreInsertResult {
    pub accounts: Vec<CoreAccount>,
    pub categories: Vec<CoreCategory>,
    pub inserted_ids: Vec<String>,
}

/// The single insertion path: standardizes, skips invalid entries and duplicates (including within the batch), and
/// inserts new accounts at the top.
#[uniffi::export(name = "core_insert_accounts")]
pub fn insert_accounts(
    existing: Vec<CoreAccount>,
    categories: Vec<CoreCategory>,
    candidates: Vec<CoreAccountCandidate>,
    added_by: String,
    now: SystemTime,
    placeholders: CorePlaceholders,
) -> Result<CoreInsertResult, KakeyError> {
    let candidates: Vec<dedup::Candidate> = candidates
        .iter()
        .map(|candidate| dedup::Candidate {
            issuer: candidate.issuer.clone(),
            username: candidate.username.clone(),
            secret: candidate.secret.clone(),
            algorithm: candidate.algorithm,
            digits: candidate.digits,
            period: candidate.period,
            category_names: candidate.category_names.clone(),
            created_at: candidate.created_at,
        })
        .collect();
    let result = dedup::insert_accounts(
        &to_core_accounts(&existing)?,
        &to_core_categories(&categories)?,
        &candidates,
        &added_by,
        now,
        &(&placeholders).into(),
    )?;
    Ok(CoreInsertResult {
        accounts: from_core_accounts(&result.accounts),
        categories: from_core_categories(&result.categories),
        inserted_ids: result.inserted_ids.into_iter().map(id_string).collect(),
    })
}

// MARK: - Categories

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreCategory {
    /// Uppercase UUID string.
    pub id: String,
    pub name: String,
    /// Order is the order within the category and also defines membership.
    pub account_ids: Vec<String>,
}

fn to_core_categories(categories: &[CoreCategory]) -> Result<Vec<category::Category>, KakeyError> {
    categories
        .iter()
        .map(|c| Ok(category::Category { id: parse_id(&c.id)?, name: c.name.clone(), account_ids: parse_ids(&c.account_ids)? }))
        .collect()
}

fn from_core_categories(categories: &[category::Category]) -> Vec<CoreCategory> {
    categories
        .iter()
        .map(|c| CoreCategory {
            id: id_string(c.id),
            name: c.name.clone(),
            account_ids: c.account_ids.iter().copied().map(id_string).collect(),
        })
        .collect()
}

fn update_categories(
    categories: &[CoreCategory],
    operation: impl FnOnce(&[category::Category]) -> Result<Vec<category::Category>, category::CategoryError>,
) -> Result<Vec<CoreCategory>, KakeyError> {
    Ok(from_core_categories(&operation(&to_core_categories(categories)?)?))
}

/// Maximum characters in a category name (for limiting UI input fields).
#[uniffi::export(name = "core_max_category_name_chars")]
pub fn max_category_name_chars() -> u32 {
    category::MAX_NAME_CHARS as u32
}

/// Creates an empty category at the end and returns the new list; the new category is the last element.
#[uniffi::export(name = "core_category_create")]
pub fn category_create(categories: Vec<CoreCategory>, name: String) -> Result<Vec<CoreCategory>, KakeyError> {
    let id = vault::random_uuid()?;
    update_categories(&categories, |c| category::create(c, &name, id))
}

#[uniffi::export(name = "core_category_rename")]
pub fn category_rename(categories: Vec<CoreCategory>, id: String, name: String) -> Result<Vec<CoreCategory>, KakeyError> {
    let id = parse_id(&id)?;
    update_categories(&categories, |c| category::rename(c, id, &name))
}

/// Deletes the category itself, not the accounts in it.
#[uniffi::export(name = "core_category_delete")]
pub fn category_delete(categories: Vec<CoreCategory>, id: String) -> Result<Vec<CoreCategory>, KakeyError> {
    let id = parse_id(&id)?;
    update_categories(&categories, |c| Ok(category::delete(c, id)))
}

#[uniffi::export(name = "core_category_reorder")]
pub fn category_reorder(categories: Vec<CoreCategory>, ordered_ids: Vec<String>) -> Result<Vec<CoreCategory>, KakeyError> {
    let ordered_ids = parse_ids(&ordered_ids)?;
    update_categories(&categories, |c| Ok(category::reorder(c, &ordered_ids)))
}

#[uniffi::export(name = "core_category_add_account")]
pub fn category_add_account(categories: Vec<CoreCategory>, id: String, account_id: String) -> Result<Vec<CoreCategory>, KakeyError> {
    let (id, account_id) = (parse_id(&id)?, parse_id(&account_id)?);
    update_categories(&categories, |c| category::add_account(c, id, account_id))
}

#[uniffi::export(name = "core_category_remove_account")]
pub fn category_remove_account(categories: Vec<CoreCategory>, id: String, account_id: String) -> Result<Vec<CoreCategory>, KakeyError> {
    let (id, account_id) = (parse_id(&id)?, parse_id(&account_id)?);
    update_categories(&categories, |c| category::remove_account(c, id, account_id))
}

/// Commits a drag reorder within a category: existing members are arranged in the given order, and unlisted members stay
/// at the end.
#[uniffi::export(name = "core_category_set_account_order")]
pub fn category_set_account_order(
    categories: Vec<CoreCategory>,
    id: String,
    ordered_account_ids: Vec<String>,
) -> Result<Vec<CoreCategory>, KakeyError> {
    let (id, ordered) = (parse_id(&id)?, parse_ids(&ordered_account_ids)?);
    update_categories(&categories, |c| category::set_account_order(c, id, &ordered))
}

/// Removes deleted accounts from every category.
#[uniffi::export(name = "core_categories_removing_accounts")]
pub fn categories_removing_accounts(categories: Vec<CoreCategory>, account_ids: Vec<String>) -> Result<Vec<CoreCategory>, KakeyError> {
    let account_ids = parse_ids(&account_ids)?;
    update_categories(&categories, |c| Ok(category::removing_accounts(c, &account_ids)))
}

// MARK: - Search and display

#[uniffi::export(name = "core_matches_search")]
pub fn matches_search(issuer: String, username: String, query: String) -> bool {
    search::matches_search(&issuer, &username, &query)
}

#[uniffi::export(name = "core_mask_username")]
pub fn mask_username(username: String) -> String {
    search::mask_username(&username)
}

#[uniffi::export(name = "core_monogram")]
pub fn monogram(issuer: String) -> String {
    search::monogram(&issuer)
}

/// Badge color index 0..8: blue, purple, orange, green, indigo, pink, teal, brown.
#[uniffi::export(name = "core_palette_index")]
pub fn palette_index(issuer: String) -> u32 {
    search::palette_index(&issuer)
}

/// The core [`password::PasswordStrength`] exported directly as `CorePasswordStrength`.
#[uniffi::remote(Enum)]
#[uniffi(name = "CorePasswordStrength")]
pub enum PasswordStrength {
    Empty,
    Weak,
    Fair,
    Good,
    Strong,
}

#[uniffi::export(name = "core_evaluate_password")]
pub fn evaluate_password(password: String) -> PasswordStrength {
    password::evaluate(&Zeroizing::new(password))
}

/// Minimum characters in master and export passwords (the number in UI hint text matches this).
#[uniffi::export(name = "core_min_password_length")]
pub fn min_password_length() -> u32 {
    password::MIN_PASSWORD_LENGTH as u32
}

/// Filter for new master password and export password fields: keeps only digits, English letters, and ASCII symbols (no
/// space); all three platforms use the same rule.
#[uniffi::export(name = "core_filter_password_input")]
pub fn filter_password_input(input: String) -> String {
    password::filter_password_input(&Zeroizing::new(input))
}

/// Acceptable when creating a vault or changing the master password: 8 to 128 allowed characters with strength of at
/// least `Fair`; for `Fair`, the UI asks the user to confirm before submitting.
#[uniffi::export(name = "core_is_acceptable_master_password")]
pub fn is_acceptable_master_password(password: String) -> bool {
    password::is_acceptable_master_password(&Zeroizing::new(password))
}

/// Acceptable for an encrypted export: the same rule as the master password.
#[uniffi::export(name = "core_is_acceptable_export_password")]
pub fn is_acceptable_export_password(password: String) -> bool {
    password::is_acceptable_export_password(&Zeroizing::new(password))
}

/// Seconds to wait after consecutive failed attempts; `None` when no wait is needed.
#[uniffi::export(name = "core_unlock_lockout_seconds")]
pub fn unlock_lockout_seconds(consecutive_failures: u32) -> Option<f64> {
    password::lockout_seconds(consecutive_failures)
}

// MARK: - Vault

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreVaultContents {
    pub accounts: Vec<CoreAccount>,
    pub categories: Vec<CoreCategory>,
    /// Non-empty only when importing an Authenticator backup: the pinned entries; the platform then calls
    /// [`adopt_pinned`].
    pub pinned_ids: Vec<String>,
}

impl CoreVaultContents {
    fn to_core(&self) -> Result<vault::VaultContents, KakeyError> {
        Ok(vault::VaultContents {
            accounts: to_core_accounts(&self.accounts)?,
            categories: to_core_categories(&self.categories)?,
            pinned_ids: parse_ids(&self.pinned_ids)?,
        })
    }

    fn from_core(value: &vault::VaultContents) -> Self {
        CoreVaultContents {
            accounts: from_core_accounts(&value.accounts),
            categories: from_core_categories(&value.categories),
            pinned_ids: value.pinned_ids.iter().copied().map(id_string).collect(),
        }
    }
}

/// Turns Authenticator's pinned entries into a category named `name` (the platform passes "Favorites" in the UI
/// language), joining an existing category with that name. Called after importing a backup file; without pinned entries
/// the input is returned unchanged.
#[uniffi::export(name = "core_adopt_pinned")]
pub fn adopt_pinned(contents: CoreVaultContents, name: String) -> Result<CoreVaultContents, KakeyError> {
    Ok(CoreVaultContents::from_core(&contents.to_core()?.adopting_pinned(&name, vault::random_uuid)?))
}

/// Turns an import result (already adopted) into insertion candidates: each account carries the names of the categories
/// it belongs to in the import file.
#[uniffi::export(name = "core_candidates_from_import")]
pub fn candidates_from_import(imported: CoreVaultContents) -> Result<Vec<CoreAccountCandidate>, KakeyError> {
    Ok(dedup::candidates_from_import(&imported.to_core()?)
        .into_iter()
        .map(|candidate| CoreAccountCandidate {
            issuer: candidate.issuer,
            username: candidate.username,
            secret: candidate.secret,
            algorithm: candidate.algorithm,
            digits: candidate.digits,
            period: candidate.period,
            category_names: candidate.category_names,
            created_at: candidate.created_at,
        })
        .collect())
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreEnvelopeInfo {
    pub version: i64,
    pub kdf: String,
    pub created_at: SystemTime,
    pub updated_at: SystemTime,
}

impl From<&vault::EnvelopeInfo> for CoreEnvelopeInfo {
    fn from(value: &vault::EnvelopeInfo) -> Self {
        CoreEnvelopeInfo { version: value.version, kdf: value.kdf.clone(), created_at: value.created_at, updated_at: value.updated_at }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreCreatedVault {
    /// Vault file contents for the platform to write atomically.
    pub data: Vec<u8>,
    /// 32-byte vault key: kept only in memory, or stored in the Keychain / Keystore under biometric protection.
    pub key: Vec<u8>,
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreUnlockedVault {
    pub contents: CoreVaultContents,
    pub key: Vec<u8>,
    pub info: CoreEnvelopeInfo,
}

impl std::fmt::Debug for CoreCreatedVault {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("CoreCreatedVault").field("data", &self.data.len()).field("key", &REDACTED).finish()
    }
}

impl std::fmt::Debug for CoreUnlockedVault {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CoreUnlockedVault")
            .field("contents", &self.contents)
            .field("key", &REDACTED)
            .field("info", &self.info)
            .finish()
    }
}

/// Creates a vault, or rewrites it under a new master password (password change).
#[uniffi::export(name = "core_vault_create")]
pub fn vault_create(password: String, contents: CoreVaultContents, now: SystemTime) -> Result<CoreCreatedVault, KakeyError> {
    let password = Zeroizing::new(password);
    let (data, key) = vault::create(&password, &contents.to_core()?, now)?;
    Ok(CoreCreatedVault { data, key: key.as_bytes().to_vec() })
}

#[uniffi::export(name = "core_vault_unlock")]
pub fn vault_unlock(data: Vec<u8>, password: String) -> Result<CoreUnlockedVault, KakeyError> {
    let password = Zeroizing::new(password);
    let unlocked = vault::unlock(&data, &password)?;
    Ok(CoreUnlockedVault {
        contents: CoreVaultContents::from_core(&unlocked.contents),
        key: unlocked.key.as_bytes().to_vec(),
        info: (&unlocked.info).into(),
    })
}

/// Opens with the in-memory key or the local protection key released by biometrics.
#[uniffi::export(name = "core_vault_open")]
pub fn vault_open(data: Vec<u8>, key: Vec<u8>) -> Result<CoreVaultContents, KakeyError> {
    let key = vault::VaultKey::from_bytes(&Zeroizing::new(key))?;
    Ok(CoreVaultContents::from_core(&vault::open(&data, &key)?))
}

/// Whether the local vault key opens this envelope (for sync decisions; AES-GCM authenticated decryption only, no KDF).
/// False for a corrupt envelope or a wrong key alike.
#[uniffi::export(name = "core_vault_opens_with_key")]
pub fn vault_opens_with_key(data: Vec<u8>, key: Vec<u8>) -> bool {
    vault::VaultKey::from_bytes(&Zeroizing::new(key)).is_ok_and(|key| vault::open(&data, &key).is_ok())
}

/// Saves while unlocked: keeps the existing envelope's salt, KDF metadata, and creation time.
#[uniffi::export(name = "core_vault_reseal")]
pub fn vault_reseal(existing: Vec<u8>, key: Vec<u8>, contents: CoreVaultContents, now: SystemTime) -> Result<Vec<u8>, KakeyError> {
    let key = vault::VaultKey::from_bytes(&Zeroizing::new(key))?;
    Ok(vault::reseal(&existing, &key, &contents.to_core()?, now)?)
}

/// Envelope validation and metadata without a password (for last-known-good snapshots and sync snapshots).
#[uniffi::export(name = "core_vault_envelope_info")]
pub fn vault_envelope_info(data: Vec<u8>) -> Result<CoreEnvelopeInfo, KakeyError> {
    Ok((&vault::envelope_info(&data)?).into())
}

#[uniffi::export(name = "core_vault_is_valid_envelope")]
pub fn vault_is_valid_envelope(data: Vec<u8>) -> bool {
    vault::is_valid_envelope(&data)
}

// MARK: - Export and import

/// Only categories (and members) of the exported accounts are included; empty categories are not exported. The export
/// password must pass [`is_acceptable_export_password`] or the core rejects it (all whitespace reports `EmptyPassword`,
/// any other failure `UnacceptablePassword`).
#[uniffi::export(name = "core_export_accounts")]
pub fn export_accounts(
    accounts: Vec<CoreAccount>,
    categories: Vec<CoreCategory>,
    password: String,
    now: SystemTime,
) -> Result<Vec<u8>, KakeyError> {
    let password = Zeroizing::new(password);
    Ok(vault::export(&to_core_accounts(&accounts)?, &to_core_categories(&categories)?, &password, now)?)
}

/// Imports only the Authenticator backup format (plain / v3 encrypted). Pinned entries go into `pinned_ids`.
#[uniffi::export(name = "core_import_authenticator")]
pub fn import_authenticator(
    data: Vec<u8>,
    password: String,
    now: SystemTime,
    placeholders: CorePlaceholders,
) -> Result<CoreVaultContents, KakeyError> {
    let password = Zeroizing::new(password);
    Ok(CoreVaultContents::from_core(&authenticator::import_authenticator_contents(&data, &password, now, &(&placeholders).into())?))
}

/// Decrypts and imports only Kakey's own encrypted export files (no fallback to other formats). No accounts are returned
/// when authentication fails.
#[uniffi::export(name = "core_import_kakey_export")]
pub fn import_kakey_export(data: Vec<u8>, password: String) -> Result<CoreVaultContents, KakeyError> {
    let password = Zeroizing::new(password);
    Ok(CoreVaultContents::from_core(&vault::import_export(&data, &password)?))
}

#[uniffi::export(name = "core_is_kakey_export")]
pub fn is_kakey_export(data: Vec<u8>) -> bool {
    vault::is_kakey_export(&data)
}

/// Imports a Kakey encrypted export or an Authenticator backup (plain / v3 encrypted). The result is not yet deduplicated
/// against existing accounts; the platform calls [`adopt_pinned`] first, then passes [`candidates_from_import`] to
/// [`insert_accounts`].
#[uniffi::export(name = "core_import_backup")]
pub fn import_backup(
    data: Vec<u8>,
    password: String,
    now: SystemTime,
    placeholders: CorePlaceholders,
) -> Result<CoreVaultContents, KakeyError> {
    let password = Zeroizing::new(password);
    Ok(CoreVaultContents::from_core(&authenticator::import_file(&data, &password, now, &(&placeholders).into())?))
}

// MARK: - Sync

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreLocalSnapshot {
    pub data: Vec<u8>,
    pub vault_updated_at: SystemTime,
}

/// The core [`sync::RemoteVersion`] exported directly as `CoreRemoteVersion`.
#[uniffi::remote(Enum)]
#[uniffi(name = "CoreRemoteVersion")]
pub enum RemoteVersion {
    ModifiedAt { at: SystemTime },
    Revision { value: String },
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreRemoteSnapshot {
    pub data: Vec<u8>,
    pub version: Option<RemoteVersion>,
    /// Whether the current local vault key opens it ([`vault_opens_with_key`]).
    pub readable: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreSyncMarks {
    pub last_local_updated_at: Option<SystemTime>,
    pub last_remote_version: Option<RemoteVersion>,
}

/// The core [`sync::SyncDecision`] exported directly as `CoreSyncDecision`.
#[uniffi::remote(Enum)]
#[uniffi(name = "CoreSyncDecision")]
pub enum SyncDecision {
    NoLocalVault,
    Upload,
    Download,
    UpToDate,
    Conflict,
    Unreadable,
}

#[uniffi::export(name = "core_decide_sync")]
pub fn decide_sync(local: Option<CoreLocalSnapshot>, remote: Option<CoreRemoteSnapshot>, marks: CoreSyncMarks) -> SyncDecision {
    let local = local.map(|snapshot| sync::LocalSnapshot { data: snapshot.data, vault_updated_at: snapshot.vault_updated_at });
    let remote =
        remote.map(|snapshot| sync::RemoteSnapshot { data: snapshot.data, version: snapshot.version, readable: snapshot.readable });
    let marks = sync::SyncMarks { last_local_updated_at: marks.last_local_updated_at, last_remote_version: marks.last_remote_version };
    sync::decide(local.as_ref(), remote.as_ref(), &marks)
}

/// Persisted text of the remote version in a sync marker (same format on all three platforms).
#[uniffi::export(name = "core_encode_remote_version")]
pub fn encode_remote_version(version: RemoteVersion) -> String {
    version.encode()
}

/// Returns `None` if unreadable; the platform treats that as never synced.
#[uniffi::export(name = "core_decode_remote_version")]
pub fn decode_remote_version(text: String) -> Option<RemoteVersion> {
    RemoteVersion::decode(&text)
}

// MARK: - Conflict comparison and merging (see docs/TECHNICAL.md)

/// The core [`merge::AccountChange`] exported directly as `CoreAccountChange`.
#[uniffi::remote(Enum)]
#[uniffi(name = "CoreAccountChange")]
pub enum AccountChange {
    Issuer,
    Username,
    Secret,
    Parameters,
    Categories,
}

/// An account present on both sides but different. Holds secrets: only used in memory for comparison and merging; the UI
/// must not display `secret`.
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreChangedAccount {
    pub local: CoreAccount,
    pub remote: CoreAccount,
    pub changes: Vec<AccountChange>,
}

impl std::fmt::Debug for CoreChangedAccount {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("CoreChangedAccount").field("local", &self.local).field("changes", &self.changes).finish()
    }
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreRenamedCategory {
    pub local: String,
    pub remote: String,
}

/// Differences between local and backup ([`merge::diff`]).
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreVaultDiff {
    pub only_local: Vec<CoreAccount>,
    pub only_remote: Vec<CoreAccount>,
    pub changed: Vec<CoreChangedAccount>,
    pub categories_only_local: Vec<String>,
    pub categories_only_remote: Vec<String>,
    pub categories_renamed: Vec<CoreRenamedCategory>,
}

#[uniffi::export(name = "core_vault_diff")]
pub fn vault_diff(
    local: CoreVaultContents,
    remote: CoreVaultContents,
    placeholders: CorePlaceholders,
) -> Result<CoreVaultDiff, KakeyError> {
    let result = merge::diff(&local.to_core()?, &remote.to_core()?, &(&placeholders).into());
    Ok(CoreVaultDiff {
        only_local: from_core_accounts(&result.only_local),
        only_remote: from_core_accounts(&result.only_remote),
        changed: result
            .changed
            .iter()
            .map(|change| CoreChangedAccount {
                local: CoreAccount::from(&change.local),
                remote: CoreAccount::from(&change.remote),
                changes: change.changes.clone(),
            })
            .collect(),
        categories_only_local: result.categories_only_local,
        categories_only_remote: result.categories_only_remote,
        categories_renamed: result.categories_renamed.into_iter().map(|(local, remote)| CoreRenamedCategory { local, remote }).collect(),
    })
}

/// Merges both sides ([`merge::merge`]): `prefer_remote_ids` are the local account IDs, changed on both sides, for which
/// the backup version wins.
#[uniffi::export(name = "core_vault_merge")]
pub fn vault_merge(
    local: CoreVaultContents,
    remote: CoreVaultContents,
    prefer_remote_ids: Vec<String>,
    placeholders: CorePlaceholders,
) -> Result<CoreVaultContents, KakeyError> {
    let prefer_remote = parse_ids(&prefer_remote_ids)?.into_iter().collect();
    Ok(CoreVaultContents::from_core(&merge::merge(&local.to_core()?, &remote.to_core()?, &prefer_remote, &(&placeholders).into())))
}

/// Core version (matches the workspace version in `Core/Cargo.toml`).
#[uniffi::export(name = "core_version")]
pub fn version() -> String {
    env!("CARGO_PKG_VERSION").to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn placeholders() -> CorePlaceholders {
        CorePlaceholders { unknown_issuer: "Unknown service".into(), empty_username: "No account".into() }
    }

    fn empty_contents() -> CoreVaultContents {
        CoreVaultContents { accounts: vec![], categories: vec![], pinned_ids: vec![] }
    }

    fn contents_key_probe() -> Vec<u8> {
        vault_create("pw".into(), empty_contents(), SystemTime::now()).unwrap().data
    }

    #[test]
    fn password_policy_is_exposed() {
        assert_eq!(min_password_length(), 8);
        assert!(!is_acceptable_master_password("12345678".into()), "weak passwords are rejected");
        assert!(is_acceptable_master_password("Abcdefgh1".into()));
        assert!(!is_acceptable_master_password("1234567".into()));
        assert_eq!(filter_password_input("密码Ab1！ ~".into()), "Ab1~");
        assert!(!is_acceptable_export_password("aaaaaaaa".into()));
        assert!(is_acceptable_export_password("Abcdefgh1".into()));
    }

    #[test]
    fn scan_insert_seal_round_trip_through_ffi_types() {
        let now = SystemTime::now();
        let scan = parse_scan_result("otpauth://totp/GitHub:alex?secret=mzxw6ytboi&issuer=GitHub".into(), placeholders());
        let candidates = scan
            .accounts
            .iter()
            .map(|parsed| CoreAccountCandidate {
                issuer: parsed.issuer.clone(),
                username: parsed.account.clone(),
                secret: parsed.secret.clone(),
                algorithm: parsed.algorithm,
                digits: parsed.digits,
                period: parsed.period,
                category_names: vec!["工作".into()],
                created_at: None,
            })
            .collect();
        let inserted = insert_accounts(vec![], vec![], candidates, "import".into(), now, placeholders()).unwrap();
        assert_eq!(inserted.inserted_ids.len(), 1);
        assert_eq!(inserted.categories.len(), 1);
        assert_eq!(inserted.categories[0].account_ids, inserted.inserted_ids);
        let contents =
            CoreVaultContents { accounts: inserted.accounts.clone(), categories: inserted.categories.clone(), pinned_ids: vec![] };
        let created = vault_create("pw".into(), contents.clone(), now).unwrap();
        assert_eq!(vault_open(created.data.clone(), created.key.clone()).unwrap().accounts[0].secret, "MZXW6YTBOI");
        assert_eq!(vault_open(created.data.clone(), created.key.clone()).unwrap().categories, inserted.categories);
        let unlocked = vault_unlock(created.data, "pw".into()).unwrap();
        assert_eq!(unlocked.key, created.key);
        assert_eq!(vault_unlock(vec![], "pw".into()).unwrap_err(), KakeyError::CorruptVault);
        assert_eq!(vault_open(contents_key_probe(), vec![0; 16]).unwrap_err(), KakeyError::InvalidKey);
        assert!(!format!("{unlocked:?}").contains("MZXW6YTBOI"), "Debug must not print the secret");
        assert_eq!(
            insert_accounts(
                vec![],
                vec![CoreCategory { id: "nope".into(), name: "x".into(), account_ids: vec![] }],
                vec![],
                "x".into(),
                now,
                placeholders()
            )
            .unwrap_err(),
            KakeyError::InvalidId
        );
    }

    /// Error classification across the FFI: localization keys match the core table one by one; a too-short export
    /// password is `UnacceptablePassword`; wrong passwords on Kakey exports and Authenticator backups are
    /// `InvalidPassword` / `WrongPassword` respectively; a short salt is `CorruptVault`.
    #[test]
    fn errors_are_classified_and_keyed_through_ffi() {
        let keys: Vec<(KakeyError, &str)> = vec![
            (KakeyError::EmptyPassword, "err.vault.empty_password"),
            (KakeyError::UnacceptablePassword, "err.vault.unacceptable_password"),
            (KakeyError::InvalidPassword, "err.vault.invalid_password"),
            (KakeyError::CorruptVault, "err.vault.corrupt"),
            (KakeyError::KeyDerivationFailed, "err.vault.key_derivation"),
            (KakeyError::InvalidKey, "err.vault.invalid_key"),
            (KakeyError::CryptoFailure, "err.vault.crypto_failure"),
            (KakeyError::PasswordRequired, "err.import.password_required"),
            (KakeyError::InvalidFile, "err.import.invalid_file"),
            (KakeyError::WrongPassword, "err.import.wrong_password"),
            (KakeyError::NoSupportedAccounts, "err.import.no_supported"),
            (KakeyError::InvalidId, "err.category.not_found"),
            (KakeyError::EmptyCategoryName, "err.category.empty_name"),
            (KakeyError::CategoryNameTooLong, "err.category.name_too_long"),
            (KakeyError::DuplicateCategoryName, "err.category.duplicate_name"),
            (KakeyError::CategoryNotFound, "err.category.not_found"),
        ];
        for (error, key) in keys {
            assert_eq!(error_l10n_key(error), key, "{error:?}");
        }
        assert_eq!(parse_failure_l10n_key(ParseFailure::BadBase32), "otp.err.bad_base32");

        let now = SystemTime::now();
        assert_eq!(export_accounts(vec![], vec![], "short".into(), now).unwrap_err(), KakeyError::UnacceptablePassword);
        assert_eq!(export_accounts(vec![], vec![], "   ".into(), now).unwrap_err(), KakeyError::EmptyPassword);
        let export = export_accounts(vec![], vec![], "export-pw".into(), now).unwrap();
        assert_eq!(import_backup(export.clone(), "wrong".into(), now, placeholders()).unwrap_err(), KakeyError::InvalidPassword);
        assert_eq!(import_backup(export.clone(), "".into(), now, placeholders()).unwrap_err(), KakeyError::PasswordRequired);
        assert_eq!(import_kakey_export(export.clone(), "wrong".into()).unwrap_err(), KakeyError::InvalidPassword);
        let authenticator = br#"{"e": {"dataType": "EncOTPStorage", "keyId": "k", "data": "x"}}"#.to_vec();
        assert_eq!(import_backup(authenticator.clone(), "wrong".into(), now, placeholders()).unwrap_err(), KakeyError::WrongPassword);
        assert_eq!(import_authenticator(authenticator, "".into(), now, placeholders()).unwrap_err(), KakeyError::PasswordRequired);
        assert_eq!(import_backup(b"[]".to_vec(), "".into(), now, placeholders()).unwrap_err(), KakeyError::InvalidFile);

        let created = vault_create("pw".into(), empty_contents(), now).unwrap();
        let text = String::from_utf8(created.data).unwrap();
        let short_salt: Vec<String> = text
            .lines()
            .map(|line| {
                if line.trim_start().starts_with("\"salt\"") {
                    "  \"salt\": \"AAAAAAAAAAAAAAAAAAAAAA==\",".to_owned()
                } else {
                    line.to_owned()
                }
            })
            .collect();
        let short_salt = short_salt.join("\n").into_bytes();
        assert!(!vault_is_valid_envelope(short_salt.clone()));
        assert_eq!(vault_envelope_info(short_salt.clone()).unwrap_err(), KakeyError::CorruptVault);
        assert_eq!(vault_unlock(short_salt.clone(), "pw".into()).unwrap_err(), KakeyError::CorruptVault);
        assert_eq!(vault_open(short_salt, created.key).unwrap_err(), KakeyError::CorruptVault);
    }

    #[test]
    fn category_operations_map_errors() {
        let created = category_create(vec![], " 工作 ".into()).unwrap();
        assert_eq!(created[0].name, "工作");
        assert_eq!(category_create(created.clone(), "工作".into()).unwrap_err(), KakeyError::DuplicateCategoryName);
        assert_eq!(category_create(created.clone(), " ".into()).unwrap_err(), KakeyError::EmptyCategoryName);
        let account = id_string(Uuid::from_u128(9));
        let added = category_add_account(created.clone(), created[0].id.clone(), account.clone()).unwrap();
        assert_eq!(added[0].account_ids, vec![account.clone()]);
        assert_eq!(categories_removing_accounts(added.clone(), vec![account.clone()]).unwrap()[0].account_ids, Vec::<String>::new());
        let missing = id_string(Uuid::from_u128(1));
        assert_eq!(category_rename(added, missing, "x".into()).unwrap_err(), KakeyError::CategoryNotFound);
    }
}

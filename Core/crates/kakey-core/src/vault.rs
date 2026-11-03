//! Encrypted vault and encrypted export files (format in docs/SECURITY.md).
//!
//! - A single format, v2: Argon2id (t=3, m=65536 KiB, p=1, 32 bytes) + AES-256-GCM, with a random 32-byte salt per vault.
//!   t=3 follows the second recommended option of RFC 9106. Parameters are stored in each file, so files with other
//!   in-limit parameters (such as t=2) still open; resealing with an unlocked key (`reseal`) keeps the file's
//!   parameters, and only new vaults, master password changes, and exports use the current ones.
//!   Any other version or KDF is rejected as `CorruptVault` (v1 / PBKDF2 is not supported).
//! - The AES-GCM field `ciphertext` is nonce(12) ‖ ciphertext ‖ tag(16) (CryptoKit `SealedBox.combined`), and decryption
//!   uses only the nonce inside it; the separate `nonce` field in the envelope must match it or the file is rejected as
//!   `CorruptVault`.
//! - The KDF parameters in the envelope come from the file and may be corrupt or malicious: they are rejected above the
//!   `MAX_*` limits when read, so a single unlock or import cannot run for hours or exhaust memory. The limits leave
//!   room to raise the parameters later; the worst case costs about 20 times the current parameters.
//! - The payload's `categories` are user categories; missing means empty. Accounts carry no favorite flag, and
//!   `isFavorite` / `favoriteOrderIDs` are neither read nor written.
//! - Any failure after authenticated decryption succeeds (contents are not valid JSON, unknown field values) is
//!   `CorruptVault`: the password was actually right and must not count as a failed attempt toward the wait.
//!
//! Only pure transformations live here: file IO, last-known-good snapshots, and atomic replacement are up to the
//! platform.

use std::time::SystemTime;

use aes_gcm::aead::{Aead, Nonce};
use aes_gcm::{Aes256Gcm, KeyInit};
use argon2::{Algorithm, Argon2, Params, Version};
use serde::{Deserialize, Serialize};
use uuid::Uuid;
use zeroize::Zeroizing;

use std::collections::HashSet;

use crate::category::{self, Category};
use crate::model::{Account, TotpAlgorithm};
use crate::{json, password};

pub const CURRENT_VERSION: i64 = 2;
pub const CIPHER: &str = "AES-256-GCM";
pub const KDF: &str = "Argon2id";
pub const ARGON2_TIME_COST: u32 = 3;
pub const ARGON2_MEMORY_KIB: u32 = 64 * 1024;
pub const ARGON2_PARALLELISM: u32 = 1;
pub const KEY_LENGTH: usize = 32;
/// Upper limits for KDF parameters accepted when reading files (the parameters written today are far below them).
pub const MAX_ARGON2_TIME_COST: u32 = 10;
pub const MAX_ARGON2_MEMORY_KIB: u32 = 256 * 1024;
pub const MAX_ARGON2_PARALLELISM: u32 = 4;
const SALT_LENGTH: usize = 32;
const NONCE_LENGTH: usize = 12;
const TAG_LENGTH: usize = 16;
const EXPORT_APP: &str = "kakey";
const EXPORT_KIND: &str = "encrypted-account-export";

#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
pub enum VaultError {
    #[error("password is empty")]
    EmptyPassword,
    #[error("wrong password or damaged ciphertext")]
    InvalidPassword,
    #[error("vault file is corrupt or unsupported")]
    CorruptVault,
    #[error("key derivation failed")]
    KeyDerivationFailed,
    #[error("vault key must be 32 bytes")]
    InvalidKey,
    #[error("system crypto operation failed")]
    CryptoFailure,
    /// The export password does not satisfy [`crate::password::is_acceptable_export_password`] (enforced by the core,
    /// not just the UI).
    #[error("export password is not acceptable")]
    UnacceptablePassword,
}

impl VaultError {
    pub fn l10n_key(self) -> &'static str {
        match self {
            VaultError::EmptyPassword => "err.vault.empty_password",
            VaultError::InvalidPassword => "err.vault.invalid_password",
            VaultError::CorruptVault => "err.vault.corrupt",
            VaultError::KeyDerivationFailed => "err.vault.key_derivation",
            VaultError::InvalidKey => "err.vault.invalid_key",
            VaultError::CryptoFailure => "err.vault.crypto_failure",
            VaultError::UnacceptablePassword => "err.vault.unacceptable_password",
        }
    }
}

/// Random UUID (v4). Reports `CryptoFailure` instead of panicking when the system RNG fails (`Uuid::new_v4` panics).
pub fn random_uuid() -> Result<Uuid, VaultError> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).map_err(|_| VaultError::CryptoFailure)?;
    Ok(uuid::Builder::from_random_bytes(bytes).into_uuid())
}

/// Vault symmetric key (32 bytes). Held in memory as `Zeroizing`, wiped on drop.
#[derive(Clone, PartialEq, Eq)]
pub struct VaultKey(Zeroizing<Vec<u8>>);

impl VaultKey {
    pub fn from_bytes(bytes: &[u8]) -> Result<Self, VaultError> {
        if bytes.len() != KEY_LENGTH {
            return Err(VaultError::InvalidKey);
        }
        Ok(VaultKey(Zeroizing::new(bytes.to_vec())))
    }

    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }
}

impl std::fmt::Debug for VaultKey {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("VaultKey(<redacted>)")
    }
}

#[derive(Clone, Serialize, Deserialize)]
struct PersistedAccount {
    #[serde(with = "json::uuid_upper")]
    id: Uuid,
    issuer: String,
    username: String,
    secret: String,
    algorithm: String,
    digits: i64,
    period: i64,
    #[serde(rename = "createdAt", with = "json::date")]
    created_at: SystemTime,
    #[serde(rename = "addedBy")]
    added_by: String,
}

impl PersistedAccount {
    fn new(account: &Account) -> Self {
        PersistedAccount {
            id: account.id,
            issuer: account.issuer.clone(),
            username: account.username.clone(),
            secret: account.secret.clone(),
            algorithm: account.algorithm.raw_value().to_owned(),
            digits: i64::from(account.digits),
            period: i64::from(account.period),
            created_at: account.created_at,
            added_by: account.added_by.clone(),
        }
    }

    fn into_account(self) -> Option<Account> {
        Some(Account {
            id: self.id,
            issuer: self.issuer,
            username: self.username,
            secret: self.secret,
            algorithm: TotpAlgorithm::from_raw_value(&self.algorithm)?,
            digits: u32::try_from(self.digits).ok()?,
            period: u32::try_from(self.period).ok()?,
            created_at: self.created_at,
            added_by: self.added_by,
        })
    }
}

#[derive(Clone, Serialize, Deserialize)]
struct PersistedCategory {
    #[serde(with = "json::uuid_upper")]
    id: Uuid,
    name: String,
    #[serde(rename = "accountIDs", with = "json::uuid_upper_vec")]
    account_ids: Vec<Uuid>,
}

#[derive(Clone, Serialize, Deserialize)]
struct PersistedPayload {
    accounts: Vec<PersistedAccount>,
    #[serde(default)]
    categories: Vec<PersistedCategory>,
    #[serde(rename = "updatedAt", with = "json::date")]
    updated_at: SystemTime,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct KdfFields {
    version: i64,
    cipher: String,
    kdf: String,
    iterations: i64,
    #[serde(rename = "memoryKiB", default, skip_serializing_if = "Option::is_none")]
    memory_kib: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    parallelism: Option<i64>,
    #[serde(rename = "keyLength", default, skip_serializing_if = "Option::is_none")]
    key_length: Option<i64>,
    #[serde(with = "json::bytes")]
    salt: Vec<u8>,
    #[serde(with = "json::bytes")]
    nonce: Vec<u8>,
    #[serde(with = "json::bytes")]
    ciphertext: Vec<u8>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct VaultFile {
    #[serde(flatten)]
    kdf: KdfFields,
    #[serde(rename = "createdAt", with = "json::date")]
    created_at: SystemTime,
    #[serde(rename = "updatedAt", with = "json::date")]
    updated_at: SystemTime,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct ExportFile {
    app: String,
    kind: String,
    #[serde(flatten)]
    kdf: KdfFields,
    #[serde(rename = "accountCount")]
    account_count: i64,
    #[serde(rename = "exportedAt", with = "json::date")]
    exported_at: SystemTime,
}

/// Non-sensitive metadata of a vault envelope.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EnvelopeInfo {
    pub version: i64,
    pub kdf: String,
    pub created_at: SystemTime,
    pub updated_at: SystemTime,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct VaultContents {
    pub accounts: Vec<Account>,
    pub categories: Vec<Category>,
    /// Non-empty only when importing an Authenticator backup: pinned (`pinned`) entries in order of appearance. Always
    /// empty when reading or writing vaults and export files.
    pub pinned_ids: Vec<Uuid>,
}

impl VaultContents {
    /// Turns pinned entries into a category named `name` (joining an existing category with that name) and clears
    /// `pinned_ids`. The platform calls this once after importing an Authenticator backup; without pinned entries the
    /// input is returned unchanged. `new_id` is only called when a new category is needed (usually [`random_uuid`]); on
    /// failure its error is returned for the whole call.
    pub fn adopting_pinned<E>(mut self, name: &str, new_id: impl FnOnce() -> Result<Uuid, E>) -> Result<VaultContents, E> {
        if !self.pinned_ids.is_empty() {
            self.categories = category::adding_to_named(&self.categories, name, &self.pinned_ids, new_id)?;
            self.pinned_ids.clear();
        }
        Ok(self)
    }
}

#[derive(Clone, Debug)]
pub struct UnlockedVault {
    pub contents: VaultContents,
    pub key: VaultKey,
    pub info: EnvelopeInfo,
}

fn random_bytes(count: usize) -> Result<Vec<u8>, VaultError> {
    let mut bytes = vec![0u8; count];
    getrandom::fill(&mut bytes).map_err(|_| VaultError::CryptoFailure)?;
    Ok(bytes)
}

fn validate_password(password: &str) -> Result<(), VaultError> {
    if password.trim().is_empty() { Err(VaultError::EmptyPassword) } else { Ok(()) }
}

fn current_kdf_fields(salt: Vec<u8>, nonce: Vec<u8>, ciphertext: Vec<u8>) -> KdfFields {
    KdfFields {
        version: CURRENT_VERSION,
        cipher: CIPHER.to_owned(),
        kdf: KDF.to_owned(),
        iterations: i64::from(ARGON2_TIME_COST),
        memory_kib: Some(i64::from(ARGON2_MEMORY_KIB)),
        parallelism: Some(i64::from(ARGON2_PARALLELISM)),
        key_length: Some(KEY_LENGTH as i64),
        salt,
        nonce,
        ciphertext,
    }
}

/// Whether Argon2 parameters are within the accepted range (shared by vaults, export files, and Authenticator PHC
/// verification strings).
pub fn argon2_params_within_limits(time_cost: u32, memory_kib: u32, parallelism: u32) -> bool {
    (1..=MAX_ARGON2_TIME_COST).contains(&time_cost)
        && memory_kib <= MAX_ARGON2_MEMORY_KIB
        && (1..=MAX_ARGON2_PARALLELISM).contains(&parallelism)
}

fn argon2_params(fields: &KdfFields) -> Result<Params, VaultError> {
    let valid = |value: Option<i64>| value.and_then(|v| u32::try_from(v).ok());
    let time_cost = valid(Some(fields.iterations)).ok_or(VaultError::CorruptVault)?;
    let memory = valid(fields.memory_kib).ok_or(VaultError::CorruptVault)?;
    let parallelism = valid(fields.parallelism).ok_or(VaultError::CorruptVault)?;
    if fields.key_length != Some(KEY_LENGTH as i64) || !argon2_params_within_limits(time_cost, memory, parallelism) {
        return Err(VaultError::CorruptVault);
    }
    Params::new(memory, time_cost, parallelism, Some(KEY_LENGTH)).map_err(|_| VaultError::CorruptVault)
}

/// Raw Argon2id hash (version 0x13, matching the PHC reference `argon2id_hash_raw`). Caller-supplied parameters are not
/// checked against the limits.
pub fn argon2id_raw(
    password: &[u8],
    salt: &[u8],
    time_cost: u32,
    memory_kib: u32,
    parallelism: u32,
    length: usize,
) -> Option<Zeroizing<Vec<u8>>> {
    let params = Params::new(memory_kib, time_cost, parallelism, Some(length)).ok()?;
    let mut output = Zeroizing::new(vec![0u8; length]);
    Argon2::new(Algorithm::Argon2id, Version::V0x13, params).hash_password_into(password, salt, &mut output).ok()?;
    Some(output)
}

/// Envelope structure check: algorithm identifier, version and KDF combination, KDF parameter limits, and salt / nonce
/// lengths (vaults and export files are always written with a 32-byte salt and 12-byte nonce; any other length means the
/// file is corrupt or tampered with, so the KDF is not run).
/// The ciphertext must hold at least a nonce and a tag, and its leading nonce must match the `nonce` field (both come
/// from the same source when written). Ciphertext damage that is visible without the password is reported here, so the
/// first restore can flag a fetched backup without waiting for the password.
fn validate_envelope(fields: &KdfFields) -> Result<(), VaultError> {
    if fields.cipher != CIPHER || fields.salt.len() != SALT_LENGTH || fields.nonce.len() != NONCE_LENGTH {
        return Err(VaultError::CorruptVault);
    }
    if fields.ciphertext.len() < NONCE_LENGTH + TAG_LENGTH || fields.ciphertext[..NONCE_LENGTH] != fields.nonce[..] {
        return Err(VaultError::CorruptVault);
    }
    if fields.version != CURRENT_VERSION || fields.kdf != KDF {
        return Err(VaultError::CorruptVault);
    }
    argon2_params(fields).map(|_| ())
}

fn derive_key(password: &str, fields: &KdfFields) -> Result<VaultKey, VaultError> {
    validate_password(password)?;
    validate_envelope(fields)?;
    let mut output = Zeroizing::new(vec![0u8; KEY_LENGTH]);
    Argon2::new(Algorithm::Argon2id, Version::V0x13, argon2_params(fields)?)
        .hash_password_into(password.as_bytes(), &fields.salt, &mut output)
        .map_err(|_| VaultError::KeyDerivationFailed)?;
    Ok(VaultKey(output))
}

fn derive_new_key(password: &str) -> Result<(VaultKey, Vec<u8>), VaultError> {
    validate_password(password)?;
    let salt = random_bytes(SALT_LENGTH)?;
    let key = argon2id_raw(password.as_bytes(), &salt, ARGON2_TIME_COST, ARGON2_MEMORY_KIB, ARGON2_PARALLELISM, KEY_LENGTH)
        .ok_or(VaultError::KeyDerivationFailed)?;
    Ok((VaultKey(key), salt))
}

/// AES-256-GCM encryption; returns (nonce, nonce ‖ ciphertext ‖ tag).
fn seal(key: &VaultKey, plaintext: &[u8]) -> Result<(Vec<u8>, Vec<u8>), VaultError> {
    let cipher = Aes256Gcm::new_from_slice(key.as_bytes()).map_err(|_| VaultError::InvalidKey)?;
    let nonce_bytes = random_bytes(NONCE_LENGTH)?;
    let nonce = Nonce::<Aes256Gcm>::try_from(nonce_bytes.as_slice()).map_err(|_| VaultError::CryptoFailure)?;
    let sealed = cipher.encrypt(&nonce, plaintext).map_err(|_| VaultError::CryptoFailure)?;
    let mut combined = nonce_bytes.clone();
    combined.extend_from_slice(&sealed);
    Ok((nonce_bytes, combined))
}

/// Only an authentication tag mismatch (wrong password or key) is `InvalidPassword`; a ciphertext too short to hold the
/// nonce and tag is file corruption.
fn open_combined(key: &VaultKey, combined: &[u8]) -> Result<Zeroizing<Vec<u8>>, VaultError> {
    if combined.len() < NONCE_LENGTH + TAG_LENGTH {
        return Err(VaultError::CorruptVault);
    }
    let cipher = Aes256Gcm::new_from_slice(key.as_bytes()).map_err(|_| VaultError::InvalidKey)?;
    let (nonce, sealed) = combined.split_at(NONCE_LENGTH);
    let nonce = Nonce::<Aes256Gcm>::try_from(nonce).map_err(|_| VaultError::CorruptVault)?;
    cipher.decrypt(&nonce, sealed).map(Zeroizing::new).map_err(|_| VaultError::InvalidPassword)
}

fn decrypt_payload(key: &VaultKey, combined: &[u8]) -> Result<VaultContents, VaultError> {
    let plaintext = open_combined(key, combined)?;
    // Authentication has passed at this point: later failures are corrupt contents or an unsupported version, not a wrong
    // password.
    let payload: PersistedPayload = serde_json::from_slice(&plaintext).map_err(|_| VaultError::CorruptVault)?;
    let accounts =
        payload.accounts.into_iter().map(PersistedAccount::into_account).collect::<Option<Vec<_>>>().ok_or(VaultError::CorruptVault)?;
    let existing: HashSet<Uuid> = accounts.iter().map(|account| account.id).collect();
    let categories: Vec<Category> = payload
        .categories
        .into_iter()
        .map(|category| Category { id: category.id, name: category.name, account_ids: category.account_ids })
        .collect();
    Ok(VaultContents { accounts, categories: category::sanitized(&categories, &existing), pinned_ids: Vec::new() })
}

fn payload_json(accounts: &[Account], categories: &[Category], now: SystemTime) -> Zeroizing<Vec<u8>> {
    let existing: HashSet<Uuid> = accounts.iter().map(|account| account.id).collect();
    let payload = PersistedPayload {
        accounts: accounts.iter().map(PersistedAccount::new).collect(),
        categories: category::sanitized(categories, &existing)
            .into_iter()
            .map(|category| PersistedCategory { id: category.id, name: category.name, account_ids: category.account_ids })
            .collect(),
        updated_at: now,
    };
    Zeroizing::new(json::to_sorted_pretty(&payload))
}

fn parse_vault_file(data: &[u8]) -> Result<VaultFile, VaultError> {
    let file: VaultFile = serde_json::from_slice(data).map_err(|_| VaultError::CorruptVault)?;
    validate_envelope(&file.kdf)?;
    Ok(file)
}

fn info(file: &VaultFile) -> EnvelopeInfo {
    EnvelopeInfo { version: file.kdf.version, kdf: file.kdf.kdf.clone(), created_at: file.created_at, updated_at: file.updated_at }
}

/// Parses and validates a vault envelope without a password. The platform uses this to decide whether a file can serve
/// as the last-known-good snapshot.
pub fn envelope_info(data: &[u8]) -> Result<EnvelopeInfo, VaultError> {
    parse_vault_file(data).map(|file| info(&file))
}

pub fn is_valid_envelope(data: &[u8]) -> bool {
    parse_vault_file(data).is_ok()
}

/// Assembles the file and validates it once in memory (re-parsing and decrypting with the same key) before handing it to
/// the platform to write.
fn write(
    key: &VaultKey,
    salt: Vec<u8>,
    template: Option<&KdfFields>,
    contents: &VaultContents,
    created_at: SystemTime,
    now: SystemTime,
) -> Result<Vec<u8>, VaultError> {
    let now = json::truncate_to_seconds(now);
    let plaintext = payload_json(&contents.accounts, &contents.categories, now);
    let (nonce, ciphertext) = seal(key, &plaintext)?;
    let kdf = match template {
        Some(template) => KdfFields { salt, nonce, ciphertext, ..template.clone() },
        None => current_kdf_fields(salt, nonce, ciphertext),
    };
    let file = VaultFile { kdf, created_at: json::truncate_to_seconds(created_at), updated_at: now };
    let data = json::to_sorted_pretty(&file);
    let reparsed = parse_vault_file(&data)?;
    decrypt_payload(key, &reparsed.kdf.ciphertext)?;
    Ok(data)
}

/// Creates a vault, or rewrites it under a new master password (password change): new random salt, current KDF.
pub fn create(password: &str, contents: &VaultContents, now: SystemTime) -> Result<(Vec<u8>, VaultKey), VaultError> {
    let (key, salt) = derive_new_key(password)?;
    let data = write(&key, salt, None, contents, now, now)?;
    Ok((data, key))
}

/// Unlocks with the master password.
pub fn unlock(data: &[u8], password: &str) -> Result<UnlockedVault, VaultError> {
    let file = parse_vault_file(data)?;
    let key = derive_key(password, &file.kdf)?;
    let contents = decrypt_payload(&key, &file.kdf.ciphertext)?;
    Ok(UnlockedVault { contents, key, info: info(&file) })
}

/// Opens the vault with an unlocked key (or the local protection key released by biometrics).
pub fn open(data: &[u8], key: &VaultKey) -> Result<VaultContents, VaultError> {
    let file = parse_vault_file(data)?;
    decrypt_payload(key, &file.kdf.ciphertext)
}

/// Saves while unlocked: keeps the existing envelope's salt, KDF metadata, and creation time, replacing only the nonce
/// and ciphertext. The existing ciphertext is first opened with `key`: if the in-memory key does not match the file
/// (another device changed the master password, or sync just replaced the file), this reports `InvalidPassword` instead
/// of writing ciphertext under the old key with the new salt, which would leave the file openable by neither password.
pub fn reseal(existing: &[u8], key: &VaultKey, contents: &VaultContents, now: SystemTime) -> Result<Vec<u8>, VaultError> {
    let file = parse_vault_file(existing)?;
    open_combined(key, &file.kdf.ciphertext)?;
    write(key, file.kdf.salt.clone(), Some(&file.kdf), contents, file.created_at, now)
}

/// Encrypted export: its own salt, nonce, and export password. Only categories (and members) of the exported accounts
/// are included; empty categories are not exported. The export password must satisfy
/// [`password::is_acceptable_export_password`] (all whitespace reports `EmptyPassword`; any other failure, such as fewer
/// than [`password::MIN_PASSWORD_LENGTH`] characters, reports `UnacceptablePassword`).
pub fn export(accounts: &[Account], categories: &[Category], password: &str, now: SystemTime) -> Result<Vec<u8>, VaultError> {
    validate_password(password)?;
    if !password::is_acceptable_export_password(password) {
        return Err(VaultError::UnacceptablePassword);
    }
    let (key, salt) = derive_new_key(password)?;
    let now = json::truncate_to_seconds(now);
    let existing: HashSet<Uuid> = accounts.iter().map(|account| account.id).collect();
    let categories: Vec<Category> =
        category::sanitized(categories, &existing).into_iter().filter(|category| !category.account_ids.is_empty()).collect();
    let plaintext = payload_json(accounts, &categories, now);
    let (nonce, ciphertext) = seal(&key, &plaintext)?;
    let file = ExportFile {
        app: EXPORT_APP.to_owned(),
        kind: EXPORT_KIND.to_owned(),
        kdf: current_kdf_fields(salt, nonce, ciphertext),
        account_count: accounts.len() as i64,
        exported_at: now,
    };
    Ok(json::to_sorted_pretty(&file))
}

fn parse_export(data: &[u8]) -> Option<ExportFile> {
    serde_json::from_slice::<ExportFile>(data).ok().filter(|file| file.app == EXPORT_APP && file.kind == EXPORT_KIND)
}

/// Whether this is a Kakey encrypted export file (the password is not checked).
pub fn is_kakey_export(data: &[u8]) -> bool {
    parse_export(data).is_some()
}

/// Decrypts and imports a Kakey encrypted export file. No accounts are returned when authentication fails.
///
/// A wrong password reports `InvalidPassword` (the same errors as the vault; a wrong password on an Authenticator backup
/// is [`crate::authenticator::ImportError::WrongPassword`]); the platform maps it to "wrong file password" for imports.
pub fn import_export(data: &[u8], password: &str) -> Result<VaultContents, VaultError> {
    // As on Mac: a file whose structure fails to parse counts as a "wrong password" (pinned by golden files), while a
    // well-formed file whose app / kind / envelope does not match counts as "corrupt file".
    let file: ExportFile = serde_json::from_slice(data).map_err(|_| VaultError::InvalidPassword)?;
    if file.app != EXPORT_APP || file.kind != EXPORT_KIND {
        return Err(VaultError::CorruptVault);
    }
    validate_envelope(&file.kdf)?;
    let key = derive_key(password, &file.kdf)?;
    decrypt_payload(&key, &file.kdf.ciphertext)
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, UNIX_EPOCH};

    use super::*;
    use crate::model::provenance;

    fn sample_accounts() -> Vec<Account> {
        vec![Account {
            id: Uuid::parse_str("E621E1F8-C36C-495A-93FC-0C247A3E6E5F").unwrap(),
            issuer: "GitHub".into(),
            username: "alex@example.com".into(),
            secret: "MZXW6YTBOI".into(),
            algorithm: TotpAlgorithm::Sha256,
            digits: 8,
            period: 60,
            created_at: UNIX_EPOCH + Duration::from_secs(1_700_000_000),
            added_by: provenance::MANUAL.into(),
        }]
    }

    fn now() -> SystemTime {
        UNIX_EPOCH + Duration::from_millis(1_800_000_000_750)
    }

    #[test]
    fn create_unlock_reseal_round_trip() {
        let accounts = sample_accounts();
        let categories = vec![Category { id: Uuid::from_u128(1), name: "工作".into(), account_ids: vec![accounts[0].id] }];
        let contents = VaultContents { accounts: accounts.clone(), categories: categories.clone(), pinned_ids: vec![] };
        let (data, key) = create("correct horse", &contents, now()).unwrap();

        let unlocked = unlock(&data, "correct horse").unwrap();
        assert_eq!(unlocked.key, key);
        assert_eq!(unlocked.info.updated_at, UNIX_EPOCH + Duration::from_secs(1_800_000_000));
        assert_eq!(unlocked.contents.accounts[0].username, "alex@example.com");
        assert_eq!(unlocked.contents.categories, categories);
        assert!(unlocked.contents.pinned_ids.is_empty());

        let later = now() + Duration::from_secs(10);
        let resealed = reseal(&data, &key, &unlocked.contents, later).unwrap();
        let resealed_info = envelope_info(&resealed).unwrap();
        assert_eq!(resealed_info.created_at, unlocked.info.created_at);
        assert_eq!(open(&resealed, &key).unwrap(), unlocked.contents);

        assert_eq!(unlock(&data, "wrong").unwrap_err(), VaultError::InvalidPassword);
        assert_eq!(unlock(&data, "   ").unwrap_err(), VaultError::EmptyPassword);
        assert_eq!(unlock(b"{}", "x").unwrap_err(), VaultError::CorruptVault);
    }

    #[test]
    fn writes_mac_compatible_field_encoding() {
        let contents = VaultContents { accounts: sample_accounts(), ..Default::default() };
        let (data, _) = create("pw", &contents, now()).unwrap();
        let text = String::from_utf8(data).unwrap();
        assert!(text.contains("\"memoryKiB\": 65536"));
        assert!(text.contains("\"updatedAt\": \"2027-01-15T08:00:00Z\""));
        let keys: Vec<&str> = text.lines().filter_map(|line| line.trim().split('"').nth(1)).collect();
        let mut sorted = keys.clone();
        sorted.sort();
        assert_eq!(keys, sorted);
    }

    #[test]
    fn export_import_round_trip() {
        let accounts = sample_accounts();
        let categories = vec![
            Category { id: Uuid::from_u128(1), name: "工作".into(), account_ids: vec![accounts[0].id, Uuid::from_u128(99)] },
            Category { id: Uuid::from_u128(2), name: "空".into(), account_ids: vec![Uuid::from_u128(99)] },
        ];
        let data = export(&accounts, &categories, "export-pw", now()).unwrap();
        assert!(is_kakey_export(&data));
        let imported = import_export(&data, "export-pw").unwrap();
        assert_eq!(imported.accounts[0].secret, "MZXW6YTBOI");
        assert_eq!(
            imported.categories,
            vec![Category { id: Uuid::from_u128(1), name: "工作".into(), account_ids: vec![accounts[0].id] }],
            "only members of exported accounts are exported; empty categories are not"
        );
        assert_eq!(import_export(&data, "nope").unwrap_err(), VaultError::InvalidPassword);
        assert_eq!(import_export(b"not json", "x").unwrap_err(), VaultError::InvalidPassword);
        assert!(!is_kakey_export(b"{\"app\":\"other\"}"));
    }

    /// Export password rules are enforced by the core: all whitespace is still `EmptyPassword`; fewer than 8 characters,
    /// disallowed characters (spaces, CJK, and so on), or `Weak` strength is `UnacceptablePassword`.
    #[test]
    fn export_rejects_unacceptable_passwords() {
        assert_eq!(export(&[], &[], "  \t ", now()).unwrap_err(), VaultError::EmptyPassword);
        assert_eq!(export(&[], &[], "short7!", now()).unwrap_err(), VaultError::UnacceptablePassword);
        assert_eq!(export(&[], &[], " 1234567", now()).unwrap_err(), VaultError::UnacceptablePassword, "spaces are not allowed");
        assert_eq!(export(&[], &[], "密码密码密码密码", now()).unwrap_err(), VaultError::UnacceptablePassword, "CJK is not allowed");
        assert_eq!(export(&[], &[], "12345678", now()).unwrap_err(), VaultError::UnacceptablePassword, "weak passwords cannot export");
        let file = export(&[], &[], "Abcdefgh1", now()).unwrap();
        let value: serde_json::Value = serde_json::from_slice(&file).unwrap();
        assert_eq!(value["iterations"], ARGON2_TIME_COST, "newly written files use the current parameters");
        assert_eq!(VaultError::UnacceptablePassword.l10n_key(), "err.vault.unacceptable_password");
    }

    /// A wrong salt or nonce length is corruption outright, without running the KDF (vaults and export files always write a
    /// 32-byte salt and 12-byte nonce).
    #[test]
    fn rejects_envelopes_with_short_salt_or_nonce() {
        let (vault_data, key) = create("pw", &VaultContents::default(), now()).unwrap();
        let export_data = export(&[], &[], "export-pw", now()).unwrap();
        let encode = |bytes: &[u8]| base64::Engine::encode(&base64::engine::general_purpose::STANDARD, bytes);
        let cases = [("salt", vec![7u8; 16]), ("salt", vec![7u8; 33]), ("salt", vec![]), ("nonce", vec![1u8; 8]), ("nonce", vec![1u8; 16])];
        for (name, bytes) in cases {
            let vault = with_field(&vault_data, name, encode(&bytes).into());
            assert!(!is_valid_envelope(&vault), "{name}={}", bytes.len());
            assert_eq!(envelope_info(&vault).unwrap_err(), VaultError::CorruptVault, "{name}={}", bytes.len());
            assert_eq!(unlock(&vault, "pw").unwrap_err(), VaultError::CorruptVault, "{name}={}", bytes.len());
            assert_eq!(open(&vault, &key).unwrap_err(), VaultError::CorruptVault, "{name}={}", bytes.len());
            let export = with_field(&export_data, name, encode(&bytes).into());
            assert!(is_kakey_export(&export), "the outer layer is still recognized as an export file");
            assert_eq!(import_export(&export, "export-pw").unwrap_err(), VaultError::CorruptVault, "{name}={}", bytes.len());
        }
    }

    /// The ciphertext cannot hold nonce + tag, or its leading nonce differs from the `nonce` field: corrupt without
    /// needing the password.
    #[test]
    fn rejects_envelopes_with_damaged_ciphertext_framing() {
        let (vault_data, _) = create("pw", &VaultContents::default(), now()).unwrap();
        let export_data = export(&[], &[], "export-pw", now()).unwrap();
        let encode = |bytes: &[u8]| base64::Engine::encode(&base64::engine::general_purpose::STANDARD, bytes);
        for data in [&vault_data, &export_data] {
            let value: serde_json::Value = serde_json::from_slice(data).unwrap();
            let mut ciphertext =
                base64::Engine::decode(&base64::engine::general_purpose::STANDARD, value["ciphertext"].as_str().unwrap()).unwrap();
            let truncated = with_field(data, "ciphertext", encode(&ciphertext[..NONCE_LENGTH + TAG_LENGTH - 1]).into());
            ciphertext[0] ^= 0xFF;
            let mismatched_nonce = with_field(data, "ciphertext", encode(&ciphertext).into());
            for damaged in [truncated, mismatched_nonce] {
                if is_kakey_export(&damaged) {
                    assert_eq!(import_export(&damaged, "export-pw").unwrap_err(), VaultError::CorruptVault);
                } else {
                    assert!(!is_valid_envelope(&damaged));
                    assert_eq!(envelope_info(&damaged).unwrap_err(), VaultError::CorruptVault);
                    assert_eq!(unlock(&damaged, "pw").unwrap_err(), VaultError::CorruptVault);
                }
            }
        }
    }

    #[test]
    fn random_uuids_are_v4_and_distinct() {
        let (a, b) = (random_uuid().unwrap(), random_uuid().unwrap());
        assert_ne!(a, b);
        assert_eq!(a.get_version(), Some(uuid::Version::Random));
        assert_eq!(a.get_variant(), uuid::Variant::RFC4122);
    }

    #[test]
    fn rejects_unsupported_envelopes() {
        let contents = VaultContents::default();
        let (data, _) = create("pw", &contents, now()).unwrap();
        let mut value: serde_json::Value = serde_json::from_slice(&data).unwrap();
        value["keyLength"] = 16.into();
        assert!(!is_valid_envelope(&serde_json::to_vec(&value).unwrap()));
        value["keyLength"] = 32.into();
        value["cipher"] = "ChaCha20".into();
        assert!(!is_valid_envelope(&serde_json::to_vec(&value).unwrap()));
        // v1 / PBKDF2 is not read: rejected as corrupt as well, without running the KDF.
        value["cipher"] = CIPHER.into();
        value["version"] = 1.into();
        value["kdf"] = "PBKDF2-HMAC-SHA256".into();
        value["iterations"] = 310_000.into();
        let legacy = serde_json::to_vec(&value).unwrap();
        assert!(!is_valid_envelope(&legacy));
        assert_eq!(unlock(&legacy, "pw").unwrap_err(), VaultError::CorruptVault);
    }

    fn with_field(data: &[u8], name: &str, field: serde_json::Value) -> Vec<u8> {
        let mut value: serde_json::Value = serde_json::from_slice(data).unwrap();
        value[name] = field;
        serde_json::to_vec(&value).unwrap()
    }

    /// KDF parameters in the file above the limits are corruption outright, without actually running them (otherwise a
    /// single import could hang for hours or exhaust memory).
    #[test]
    fn rejects_kdf_parameters_beyond_limits() {
        let contents = VaultContents::default();
        let (vault_data, _) = create("pw", &contents, now()).unwrap();
        let export_data = export(&[], &[], "export-pw", now()).unwrap();
        let oversized = [
            ("iterations", serde_json::Value::from(MAX_ARGON2_TIME_COST + 1)),
            ("iterations", u32::MAX.into()),
            ("memoryKiB", (MAX_ARGON2_MEMORY_KIB + 1).into()),
            ("memoryKiB", u32::MAX.into()),
            ("parallelism", (MAX_ARGON2_PARALLELISM + 1).into()),
            ("iterations", 0.into()),
        ];
        for (name, field) in oversized {
            let vault = with_field(&vault_data, name, field.clone());
            assert!(!is_valid_envelope(&vault), "{name}={field}");
            assert_eq!(unlock(&vault, "pw").unwrap_err(), VaultError::CorruptVault, "{name}={field}");
            let export = with_field(&export_data, name, field.clone());
            assert_eq!(import_export(&export, "export-pw").unwrap_err(), VaultError::CorruptVault, "{name}={field}");
        }
    }

    /// Contents that cannot be read after authentication passed mean a corrupt file or unsupported version, never a wrong
    /// password (the platform counts wrong passwords toward the wait).
    #[test]
    fn authenticated_but_unreadable_payload_is_corrupt_not_wrong_password() {
        let contents = VaultContents { accounts: sample_accounts(), ..Default::default() };
        let (data, key) = create("pw", &contents, now()).unwrap();
        let reseal_payload = |plaintext: &[u8]| {
            let (nonce, ciphertext) = seal(&key, plaintext).unwrap();
            let mut value: serde_json::Value = serde_json::from_slice(&data).unwrap();
            value["nonce"] = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, nonce).into();
            value["ciphertext"] = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, ciphertext).into();
            serde_json::to_vec(&value).unwrap()
        };

        let not_json = reseal_payload(b"not json");
        assert_eq!(unlock(&not_json, "pw").unwrap_err(), VaultError::CorruptVault);
        assert_eq!(open(&not_json, &key).unwrap_err(), VaultError::CorruptVault);

        let mut payload: serde_json::Value = serde_json::from_slice(&payload_json(&contents.accounts, &[], now())).unwrap();
        payload["accounts"][0]["algorithm"] = "SHA3-256".into();
        let unknown_algorithm = reseal_payload(&serde_json::to_vec(&payload).unwrap());
        assert_eq!(unlock(&unknown_algorithm, "pw").unwrap_err(), VaultError::CorruptVault);

        assert_eq!(unlock(&not_json, "wrong").unwrap_err(), VaultError::InvalidPassword);
        let truncated = with_field(&data, "ciphertext", "AAAA".into());
        assert_eq!(unlock(&truncated, "pw").unwrap_err(), VaultError::CorruptVault);
    }

    #[test]
    fn rejects_keys_of_the_wrong_length() {
        assert_eq!(VaultKey::from_bytes(&[0u8; 16]).unwrap_err(), VaultError::InvalidKey);
        assert!(VaultKey::from_bytes(&[0u8; KEY_LENGTH]).is_ok());
    }
}

# Kakey Core Changelog

Observable behavior, format, and FFI interface changes in the shared core. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow semantic versioning. Entries that change golden state why. For `cloudset` details, see `crates/cloudset/CHANGELOG.md`.

## [Unreleased]

### Added

- Rust shared core: account model, Base32 and TOTP, field normalization, otpauth and migration code parsing, deduplication, search and masking, password rules and unlock delay, vault and encrypted export, Authenticator import, and sync decisions, exposed to every platform through a coarse-grained UniFFI interface. Golden was generated from the original Mac implementation, and the Mac verifies that it can open files the Rust core writes.
- Categories: naming rules, create / rename / delete, membership and order, cleanup when accounts are deleted. The payload and encrypted exports carry `categories` (new `golden/categories.json`).
- Error localization keys live only in the core (`core_error_l10n_key`).
- Conflict diff and merge (`core_vault_diff`, `core_vault_merge`): accounts pair by ID, then by deduplication key; categories pair by ID, then by name. A difference in order alone isn't a difference.
- Sync only trusts the local key: `SyncDecision::Unreadable` and `core_vault_opens_with_key` (authenticated decryption only, no KDF).
- Cloud storage backup: the `backup` module and the generic `cloudset` component, supporting WebDAV, Nextcloud, Dropbox, OneDrive, and Google Drive. OAuth 2.0 + PKCE with automatic refresh, Dropbox app authorization, pinning of server certificates the user has confirmed, server address completion, and a check that restore only offers folders containing a backup. Public client IDs are read from `cloud-keys.toml` at build time.
- Android build (`make core-android`).

### Changed

- Master and export passwords share one rule: 8–128 characters, ASCII 0x21–0x7E only, zxcvbn strength at least `Fair`. `vault::export` rejects weak passwords. Golden `password.json` has strengths recomputed with zxcvbn and new input filtering and truncation samples.
- Argon2id for new writes uses 3 passes instead of 2 (the second recommended option in RFC 9106). Parameters are stored with each file, so golden keeps its `time=2` samples as a readable baseline.
- The sync remote version is generalized to `RemoteVersion` (modification time with 0.5-second tolerance, or a revision compared exactly).
- Envelope structure problems (wrong lengths, ciphertext shorter than nonce + tag, nonce not matching the field) and KDF parameters over the limit return `CorruptVault` without a password or a KDF run. Content that authenticates but can't be parsed also returns `CorruptVault` instead of counting as a wrong password.
- Search case folding uses `caseless` to match Foundation.

### Fixed

- `insert_accounts` puts a batch of new accounts first in candidate order instead of reversing the batch, so imports, pasted lines, and several scanned QR codes keep their order (no golden covers this order; a unit test does).

### Security

- KDF parameters and Authenticator keyId counts from files are capped; TOTP digits are capped at 10.
- `reseal` opens the existing file with the given key before writing; RNG failures return `CryptoFailure` instead of panicking.
- Passwords, password hashes, decrypted plaintext, and key bytes passed through the FFI are zeroed after use; `Debug` output of types holding secrets is redacted.

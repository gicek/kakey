# Kakey Core Technical Notes

> Implementation details of the shared Rust core, for anyone changing `Core/`. Cross-platform contracts live in [TECHNICAL](../../docs/TECHNICAL.md) and [SECURITY](../../docs/SECURITY.md), which take precedence.

## Layout

```text
Core/
├── Cargo.toml  Cargo.lock  rust-toolchain.toml  deny.toml  rustfmt.toml
├── crates/
│   ├── kakey-core/      Pure logic: no IO, no UniFFI
│   ├── kakey-ffi/       UniFFI interface, the only external boundary (lib + staticlib + cdylib); build.rs embeds the cloud storage public client IDs
│   ├── cloudset/        Generic sans-IO cloud storage client; no dependency on kakey-* or UniFFI; has its own README / CHANGELOG / golden
│   └── uniffi-bindgen/  CLI that generates the Swift / Kotlin bindings (runs on the build machine only)
├── golden/              Behavior baseline (see golden/README.md)
├── scripts/             build-apple.sh, build-android.sh, cloudset-standalone.sh
└── docs/                This file, CHANGELOG
```

`kakey-core` modules:

| Module | Contents |
|---|---|
| `model` | `Account`, `TotpAlgorithm`, `Placeholders`, source constants |
| `base32` / `totp` | RFC 4648 Base32, RFC 6238 TOTP |
| `canonical` | Text cleanup, secret normalization, `issuer:` prefix, otpauth URI generation |
| `otpauth` | otpauth and Google migration code parsing |
| `dedup` | Deduplication key and the single insertion path |
| `category` | Category naming rules, create / rename / delete, membership and order, cleanup when accounts are deleted, stale ID removal |
| `search` | Search normalization, masking, monogram, palette index |
| `password` | zxcvbn strength levels, master and export password rules, input filtering, unlock delay |
| `vault` | Vault and export envelope v2, parameter limits, `reseal` |
| `authenticator` | Authenticator plaintext / v3 encrypted import, CryptoJS; `import_file` dispatches between Kakey exports and Authenticator backups |
| `sync` | Sync decision `decide`; remote version `RemoteVersion` (modification time with 0.5-second tolerance, revision compared exactly) and its persisted text |
| `merge` | Account / category pairing, diff, and merge for conflicts |
| `backup` | Remote layout (envelope + metadata), folder checks `is_usable_folder` / `folder_has_backup`, composed `cloudset` operations |
| `json` (private) | On-disk JSON rules shared with the Apple side |

`cloudset` modules:

| Module | Contents |
|---|---|
| `operation` | State machine `Operation` / `Step` / `Done`, synchronous driver `drive` |
| `client` / `entry` / `error` | Entry point `Client`, remote entries and revisions, `CloudError` |
| `http` | Plain request / response data, same-origin redirects, size limits, status code mapping, redacted `Debug` |
| `path` / `connection` | Remote path validation, server address and completion, certificate pinning, versioned serialization and zeroizing of the connection blob |
| `webdav` / `multistatus` / `nextcloud` | WebDAV, PROPFIND parsing, Nextcloud login flow |
| `oauth` / `authorized` | PKCE, callback validation, token exchange, refresh, Dropbox app authorization; generic driver for OAuth operations (adds the Bearer token, refreshes ahead of expiry or on 401 and replays once) |
| `dropbox` / `onedrive` / `gdrive` / `providers` | Providers; `gdrive` resolves paths segment by segment, picks the oldest item on duplicate names, and emulates conditional writes |
| `testing` (`testing` feature) | In-memory servers |

For usage and executor conventions, see `crates/cloudset/README.md`.

## Dependencies

Licenses and versions are in [THIRD_PARTY_NOTICES](../../THIRD_PARTY_NOTICES.md).

- All cryptography comes from RustCrypto. Argon2id matches the PHC reference implementation byte for byte (`golden/kdf.json`).
- Formats and text: `serde` / `serde_json`, `base64`, `uuid`, `time` (RFC 3339), `url`, `percent-encoding`, `prost` (migration code protobuf), `unicode-normalization`, `caseless` (Foundation folds `ß` to `ss`, which `to_lowercase` can't), `data-encoding` (hex). Password strength uses `zxcvbn` only.
- Randomness comes from `getrandom`. Salts, nonces, and UUIDs all go through the random functions in `vault` (`random_uuid` and others), which return `CryptoFailure` on failure. Don't use `Uuid::new_v4`, which panics. Memory is cleared with `zeroize`, and the crypto crates enable their `zeroize` feature.
- **Two pieces are hand-written on purpose** (their semantics are pinned by golden): Base32, which accepts any length and drops trailing bits short of a full byte (mature libraries reject this); and strict percent-decoding, which treats invalid `%` sequences or non-UTF-8 results as failures (`percent-encoding` passes them through).

## Parameters and Limits

| Parameter | Value | Constant |
|---|---|---|
| Argon2id for new writes | time 3, memory 64 MiB, parallelism 1, 32-byte output | `vault::ARGON2_*` |
| Limits on Argon2id parameters from files | time ≤ 10, memory ≤ 256 MiB, parallelism ≤ 4 | `vault::MAX_ARGON2_*`, shared through `argon2_params_within_limits` |
| Envelope salt / nonce / tag | 32 / 12 / 16 bytes | Private constants in `vault.rs` (`SALT_LENGTH` and others) |
| Distinct Authenticator keyIds | 16 | `authenticator::MAX_KEY_IDS` |
| TOTP digits (display) | 10 | Private constant `MAX_DIGITS` in `totp.rs` |
| Password length | 8–128 | `password::MIN_PASSWORD_LENGTH` / `MAX_PASSWORD_LENGTH` |
| Failed attempts | 5 free, then 30 seconds doubling up to 300 seconds | `password::FREE_ATTEMPTS` / `BASE_DELAY_SECONDS` / `MAX_DELAY_SECONDS` |
| Category name | 40 characters | `category::MAX_NAME_CHARS` |

Values over a limit or with the wrong length return `CorruptVault` / `InvalidFile` without running the KDF. For Authenticator v3, the core first hashes the candidate password with fixed parameters (19 MiB) for each keyId, then runs `verify_phc` with the parameters in the PHC string; a mismatch returns `WrongPassword` right away.

## Error Mapping

Localization keys are maintained once, in the core: `VaultError`, `ImportError`, and `CategoryError` each have `l10n_key()`. The FFI `KakeyError` reuses them and exports them through `core_error_l10n_key`. `core_parse_failure_l10n_key` returns the `otp.err.*` keys.

| Case | `KakeyError` | Localization key | Counts as a failed attempt |
|---|---|---|---|
| Master password is all whitespace | `EmptyPassword` | `err.vault.empty_password` | No |
| AES-GCM authentication fails (wrong vault or Kakey export password) | `InvalidPassword` | `err.vault.invalid_password` | Yes |
| Content isn't a valid payload; bad envelope structure (cipher, version, salt / nonce length, ciphertext shorter than nonce + tag, nonce doesn't match the field); KDF parameters over the limit | `CorruptVault` | `err.vault.corrupt` | No |
| Argon2id derivation itself fails | `KeyDerivationFailed` | `err.vault.key_derivation` | No |
| Vault key isn't 32 bytes | `InvalidKey` | `err.vault.invalid_key` | No |
| System RNG or a crypto operation fails | `CryptoFailure` | `err.vault.crypto_failure` | No |
| Export password breaks the rules | `UnacceptablePassword` | `err.vault.unacceptable_password` | No |
| Encrypted file without a password | `PasswordRequired` | `err.import.password_required` | No |
| Unsupported format; Authenticator parameters or keyId count over the limit | `InvalidFile` | `err.import.invalid_file` | No |
| Wrong Authenticator backup password | `WrongPassword` | `err.import.wrong_password` | No |
| No importable accounts in an Authenticator backup | `NoSupportedAccounts` | `err.import.no_supported` | No |
| Category name empty / too long / duplicate, or category missing | `EmptyCategoryName` and others | `err.category.*` | No |
| Caller passes an unparseable UUID | `InvalidId` | `err.category.not_found` | No |

- A parse failure of the export file's outer JSON returns `InvalidPassword` (pinned by golden).
- For imports, platforms map both `InvalidPassword` and `WrongPassword` to "wrong file password". Only `InvalidPassword` during unlock counts as a failed attempt.
- Under AES-GCM, a wrong password and corruption in the middle of the ciphertext look the same, so both return `InvalidPassword`. Any structural problem that can be detected without a password returns `CorruptVault`, so the first restore can report a damaged backup as soon as it fetches it.

## On-Disk JSON

`json.rs` implements the rules shared with `JSONEncoder.kakey` on the Apple side:

- Keys are sorted by byte order with two-space indentation. Whitespace differs from Foundation's output, which doesn't affect interop; golden compares parsed content only.
- Byte strings are standard base64 with padding. UUIDs are uppercase with hyphens. Times are RFC 3339 UTC, to the second, ending in `Z` (Foundation's `.iso8601` rejects fractional seconds). Empty optional fields are omitted.
- The payload's `categories` go through `category::sanitized` on read and write, which drops categories with duplicate IDs, IDs that point to missing accounts, and duplicate IDs within a category. Pinned entries from an Authenticator backup go into `VaultContents.pinned_ids`; the platform calls `core_adopt_pinned` to merge them into a "Favorites" category in the UI language. The list is always empty when reading a vault or an export file.

## FFI Conventions

- The interface is coarse-grained: one call does one job. Argon2id derivation is synchronous, so platforms must call it on a background thread.
- Exported names are prefixed: functions `core_*` (`coreXxx` in Swift / Kotlin), types `Core*`.
- UUIDs cross the boundary as uppercase strings and are parsed in the FFI (failure is `InvalidId`; don't use `custom_type!`, which panics). Times use `SystemTime`. File contents and keys are byte strings.
- Enums that mirror core types (`TotpAlgorithm`, `ParseFailure`, `PasswordStrength`, `SyncDecision`, and others) are exported directly with `#[uniffi::remote(Enum)]`, with no hand-written mirrors. `KakeyError` variants are the error codes. Every platform matches them exhaustively (`switch` / `when`), so adding or removing a variant changes all platforms in the same commit.
- UniFFI catches panics at the boundary. The core only uses `expect` on in-memory serialization paths that can't fail. Types holding secrets have a hand-written `Debug` that prints `<redacted>`.
- Export only what the platforms actually call. Bindings are generated and not committed.
- Cloud storage: `kakey-ffi` reads the current time and the PKCE / `state` randomness once and passes them to `cloudset`, which reads neither the clock nor a random source itself. When `KAKEY_CLOUD_CONFIG` points to `cloud-keys.toml`, `build.rs` generates the public client ID constants (a malformed file fails the build). When it isn't set, all OAuth providers are hidden.

## Build and Test

- `make test-core` runs `cargo fmt --check` → `cargo clippy --all-targets -D warnings` → `cargo test` (unit, golden, `cloudset` end-to-end) → a `cargo tree` check that `cloudset`'s dependency graph contains no `kakey-*` or `uniffi` → `scripts/cloudset-standalone.sh`, which copies `cloudset` out of the workspace and builds, lints, and tests it on its own (and rejects any mention of Kakey) → `cargo deny check licenses bans` (skipped locally when cargo-deny isn't installed). clippy and test run with `--locked`. The RustSec check needs the network, so it is a separate `make core-audit` (CI runs it every time); ignored advisories go in `deny.toml` with a reason and date.
- Golden tests locate `Core/golden/` at run time through `CARGO_MANIFEST_DIR`, not a compile-time `env!`: after the repository moves, an old test binary would look for the files at the old path.
- `make core-apple` builds static libraries for the three Apple targets in Release, packages them into `Build/Core/apple/KakeyCore.xcframework`, and generates `KakeyCore.swift`. Unchanged outputs aren't replaced, so Xcode doesn't rebuild.
- `make core-android` uses cargo-ndk to build `libkakey_ffi.so` for `arm64-v8a` (API 33), the Kotlin bindings, and a macOS dylib for JVM unit tests, all in `Build/Core/android/`.
- Release profile: `lto = "thin"`, `codegen-units = 1`, `strip = "debuginfo"`. Every platform links the Release build.
- For core crate versions, see [TECHNICAL](../../docs/TECHNICAL.md).

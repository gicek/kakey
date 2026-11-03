# Kakey Technical Architecture

> Technical choices, layers, data contracts, and test strategy that hold on every platform. Security rules are in [SECURITY](SECURITY.md) and interaction in [DESIGN](DESIGN.md). Platform details: [Core](../Core/docs/TECHNICAL.md), [Mac](../Apple/Mac/docs/TECHNICAL.md), [iOS / iPadOS](../Apple/iOS/docs/TECHNICAL.md), [Android](../Android/docs/TECHNICAL.md).

## Technical Choices

- **Shared Rust core with UniFFI**: all three platforms share one copy of the non-UI logic, so the vault format and sync rules exist only once. One interface generates both the Swift and Kotlin bindings. `Core/golden/` pins the behavior.
- **No IO in the core**: the core only does pure transforms (bytes and fields in, bytes and fields out). Platforms inject files, network, Keychain / Keystore, and the clock. The cloud storage protocols are sans-IO state machines too (`cloudset`); platforms only execute the HTTP requests.
- **Encrypted local JSON file, no database**: the data set is small, and encrypting and writing the whole vault is simple and auditable. Atomic writes plus a last-known-good snapshot guard against corruption.
- **RustCrypto for cryptography**: pure Rust; Argon2id matches the PHC reference implementation byte for byte.
- **Sync through the user's own storage**: Apple devices sync through the iCloud CloudKit private database (server-side conditional writes and push). Any platform can use a sync folder or cloud storage (WebDAV, Nextcloud, Dropbox, OneDrive, Google Drive).
- **Native UI on each platform**: SwiftUI in an AppKit shell on the Mac, SwiftUI on iOS / iPadOS, and Jetpack Compose with Material 3 on Android.

## Tech Stack

Exact dependency versions live in the lock files (`Core/Cargo.lock`, `Android/gradle/libs.versions.toml`, the committed `Package.resolved`) and in [THIRD_PARTY_NOTICES](../THIRD_PARTY_NOTICES.md). Update this table when a dependency is added or removed, or when a toolchain version changes.

| Component | Language / framework | Targets | Key dependencies |
|---|---|---|---|
| Shared core `Core/` | Rust 1.97.1 (`rust-toolchain.toml`), UniFFI 0.32.2 | `aarch64-apple-darwin` / `-ios` / `-ios-sim`, `aarch64-linux-android` | RustCrypto (argon2, aes-gcm, aes, cbc, hmac, sha1, sha2, md-5), serde / serde_json, base64, data-encoding, percent-encoding, url, uuid, time, prost (migration codes), unicode-normalization, caseless, zxcvbn, zeroize, getrandom, thiserror; `cloudset` adds quick-xml and httpdate; `kakey-ffi` uses toml at build time |
| Mac `Apple/Mac` | Swift 6 (strict concurrency), SwiftUI + AppKit | macOS 14, arm64 | KakeyCore.xcframework (statically linked), KeyboardShortcuts, Atkinson Hyperlegible Mono |
| iOS / iPadOS `Apple/iOS` | Swift 6, SwiftUI (`@Observable`) | iOS 17, iPhone + iPad | KakeyCore.xcframework, Atkinson Hyperlegible Mono; system frameworks AVFoundation, Vision, LocalAuthentication, PhotosUI, CloudKit, AuthenticationServices |
| Android `Android/` | Kotlin 2.4.21, Jetpack Compose (BOM 2026.09.00) + Material 3; AGP 9.4.1, Gradle 9.7.1 | minSdk 33, targetSdk 36, compileSdk 37, arm64-v8a | Core `.so` + UniFFI Kotlin bindings (JNA), Navigation 3, CameraX, ZXing, biometric, DataStore, DocumentFile, OkHttp, Atkinson Hyperlegible Mono |
| Project and scripts | XcodeGen 2.45.4, Makefile, Python 3 (standard library) | Xcode 26.5; JDK 21, Android SDK 37, NDK, cargo-ndk 4.1.2, cargo-deny 0.20.2 | Static checks: swift-format, ktlint, detekt, Android Lint. `make icons` and DMG packaging also need Pillow and dmgbuild (`requirements-dev.txt`; not shipped with the apps) |

## System Structure

```text
┌─────────────── Each platform: UI, state, system services ────────────────┐
│ Mac: SwiftUI + AppKit shell · iOS / iPadOS: SwiftUI · Android: Compose   │
│ Single source of state: VaultStore (Mac) / MobileVaultStore (iOS) /      │
│   VaultStore (Android)                                                   │
│ Atomic file writes and snapshots, Keychain / Secure Enclave / Keystore,  │
│ biometrics, camera and photos, clipboard, CloudKit / folder / HTTP       │
│ executors, browser sign-in, localization                                 │
└─────────────────────────────────────┬────────────────────────────────────┘
                                      │ UniFFI (`core*` functions, `Core*` types)
┌─────────────────────────────────────▼────────────────────────────────────┐
│ kakey-ffi: the only external boundary; embeds the cloud developer keys   │
│ kakey-core (no IO): TOTP / Base32, otpauth and migration parsing,        │
│   normalization and dedup, categories, vault and export encryption,      │
│   Authenticator import, search and masking, password rules, unlock       │
│   delays, sync decisions, conflict comparison and merge, backup layout   │
│ cloudset (no IO, independent of Kakey): WebDAV, Nextcloud, Dropbox,      │
│   OneDrive, Google Drive                                                 │
└──────────────────────────────────────────────────────────────────────────┘
```

- Views go through their platform's single source of state and never depend on persistence services directly. The state source only orchestrates; persistence, key storage, clipboard, authentication, clock, and backup backends are all injected through interfaces, and tests use in-memory implementations.
- Localized text stays out of the core. Platforms pass placeholder text (unknown service, the "Favorites" category name, and so on) in the current language. Errors and parse failures come back as enums, and `core_error_l10n_key` / `core_parse_failure_l10n_key` supply their string keys.
- Both Apple targets share `Apple/Shared/`: models, `CoreBridge.swift`, `L10n` and the String Catalog, the vault session layer (`VaultDocument`, `VaultFileStore`), backup backends (`Services/Sync/`), and the injected interfaces.

## Data Contracts

### Vault

- Envelope v2 (Argon2id + AES-256-GCM) is the only format. Any other version or KDF is rejected as a corrupt file. Envelope fields, KDF parameters, and limits are in [SECURITY](SECURITY.md); the JSON encoding rules are in [Core TECHNICAL](../Core/docs/TECHNICAL.md).
- Encrypted payload:

  ```json
  {
    "accounts":   [ { "id": "UUID", "issuer": "…", "username": "…", "secret": "BASE32", "algorithm": "SHA1", "digits": 6, "period": 30, … } ],
    "categories": [ { "id": "UUID", "name": "Work", "accountIDs": ["UUID", "…"] } ],
    "updatedAt":  "2026-10-27T08:00:00Z"
  }
  ```

  The order of `accounts` is the order of "All". The order of `categories` is the sidebar order, and `accountIDs` gives both membership and the order within the category. A missing `categories` reads as no categories; unknown fields are ignored.

### Export Files

An export is its own envelope (its own salt and nonce; the outer layer also holds `app`, `kind`, the account count, and the export time). The payload has the same structure as the vault and holds only the exported accounts and their categories. Import merges categories into existing ones by name (case-insensitive).

### Backup Locations

- **Folders and cloud storage**: the directory holds only `vault.kakeyvault` (a verbatim copy of the encrypted envelope) and `vault.metadata.json` (device name, update time). The envelope is written first, then the metadata on a best-effort basis. Missing or corrupt metadata doesn't affect sync decisions.
- **iCloud**: the private database of container `iCloud.com.gicek.kakey`, with one `Vault` record (name `vault`) in the custom zone `Kakey`. Its `envelope` asset holds the same encrypted envelope bytes as a folder backup; device name and time go in `encryptedValues`. The remote version is the `recordChangeTag`. The database subscription `kakey-vault-changes` sends silent pushes only.
- **Remote version**: the core's `RemoteVersion` is either a modification time (folders, 0.5-second tolerance) or a revision (ETag / rev / changeTag, exact match). The sync marker records the remote version and the local `updatedAt` from the last sync.
- **Sync decision** (core `sync::decide`): if only one side changed, upload or fetch. If both changed, or it can't tell, that's a conflict. If the remote changed since the last sync and the local key can't decrypt it, the result is `Unreadable`. Writes are conditional on the remote version seen at decision time; if a write is rejected, the core decides once more.
- **Conflict comparison and merge** (core `merge`): accounts pair by ID, then by dedup key; categories pair by ID, then by name. A difference in order alone is not a difference. A merge keeps every account from both sides, and the user picks one by one where both sides changed. Category members are combined; on a name conflict the local name wins, and the local order comes first. Comparison happens only in memory.

### Local Preferences

Preferences hold only non-sensitive settings (see [DESIGN](DESIGN.md)). Accounts, category names, and secrets live only in the encrypted payload.

## Backup Backends

Users keep an encrypted backup in their own storage without installing a cloud drive client, and restore it on any platform by signing in to the same storage. One location is active at a time; switching runs the first-sync decision once, because several active backends would create multi-way conflicts.

| Backend | Mac | iOS / iPadOS | Android | Authentication |
|---|---|---|---|---|
| iCloud (CloudKit) | ✓ | ✓ | — | System account |
| Sync folder | ✓ | ✓ | ✓ (SAF) | None |
| WebDAV | ✓ | ✓ | ✓ | Address, user name, password |
| Nextcloud | ✓ | ✓ | ✓ | Login Flow v2 (app password) |
| Dropbox, OneDrive, Google Drive | ✓ | ✓ | ✓ | OAuth 2.0 + PKCE, public clients |

Android has no iCloud: CloudKit web services would need an extra API token and a web sign-in.

### Design

- **Own protocol implementation**: no provider SDKs and no generic OAuth library. The surface is small (RFC 6749 / 7636 / 8252 public clients, a few REST endpoints per provider, five WebDAV methods), while SDKs multiplied by platforms and providers add many large dependencies, some with telemetry.
- **`cloudset`** is a cloud storage client with no IO and no knowledge of Kakey: no `kakey-*` or UniFFI dependency, no files, environment, clock, or randomness, and no mention of Kakey in its source, tests, or README (`make test-core` checks the dependency graph and builds it standalone). Usage, the executor contract, and per-provider behavior are in `Core/crates/cloudset/README.md`.
- **Kakey's side** (`kakey-core::backup`, `kakey-ffi`): the remote layout, sync decisions, and developer configuration. Developer keys come from the uncommitted root `cloud-keys.toml`, compiled in by `kakey-ffi`'s `build.rs`; a provider without keys is hidden in the UI.
- **Platforms only execute**: HTTP goes through `URLSession` (ephemeral configuration) on Apple and OkHttp on Android, which keeps the system proxy and certificate trust and needs no TLS stack in Rust. Sign-in uses the system browser (`ASWebAuthenticationSession`, non-ephemeral; Android Custom Tab), as RFC 8252 requires. Each provider has its own callback scheme (Dropbox `db-<app key>://2/token`, Microsoft `msal<client id>://auth`, Google `com.googleusercontent.apps.<id>:/oauth2redirect`); `kakey://` is never used for callbacks.
- **Credentials** are a versioned opaque blob that the core serializes and refreshes and platforms store as is, so a new provider changes no platform code. Storage and exposure are in [SECURITY](SECURITY.md).
- **Access scope**: "Kakey Folder Only" by default, used directly as the backup folder, so a leaked token reaches only Kakey's ciphertext. "Any Folder" is offered only when the developer configuration enables full access.
- **Google**: all platforms share one iOS-type client. Google doesn't allow custom URI schemes for Android-type clients, App Links need a verifiable HTTPS domain that Kakey doesn't have, and the Play services `AuthorizationClient` is closed source and issues only one-hour access tokens. If Google ever checks the calling platform, Android moves to App Links. Drive has no app folder and `appDataFolder` is invisible to users, so Kakey uses `drive.file` plus a visible `Kakey` folder in My Drive.

### Architecture

```text
Platform (Mac / iOS / Android)
  UI: location list, connect screens, remote folder browser, status, conflict view
  Sync orchestration (Apple: SyncBackend protocol extension; Android: SyncCoordinator)
    └─ SyncBackend: read remote / conditionally write remote
         ├─ FolderSyncBackend   folder
         ├─ ICloudSyncBackend   CloudKit (Apple)
         └─ CloudSyncBackend    drives core operations
  Injected: HTTP executor · browser sign-in · connection blob storage
                │ UniFFI
kakey-ffi: wraps cloudset, compiles in developer keys, reads the current time and randomness once
kakey-core::backup: remote layout (envelope + metadata), folder suitability checks
kakey-core::sync / merge: sync decisions, conflict comparison and merging
cloudset: WebDAV, Nextcloud, Dropbox, OneDrive, Google Drive protocol state machines (no IO)
```

Each remote operation is a state machine: the caller executes the request the core returns and feeds back the response until it finishes. Token refresh, replay, Nextcloud polling, and OneDrive pre-signed downloads happen inside. A refreshed connection blob comes back with the result, and the platform stores it immediately.

### Remote Layout

| Backend | Kakey Folder Only | Any Folder |
|---|---|---|
| Dropbox | Apps › Kakey (an App folder type app) | Remote folder browser (a separate Full Dropbox type app) |
| OneDrive | Apps › Kakey (`special/approot`, `Files.ReadWrite.AppFolder`) | Remote folder browser (`Files.ReadWrite`) |
| Google Drive | My Drive › Kakey (`drive.file`) | Remote folder browser (`drive`) |
| WebDAV / Nextcloud | — | Remote folder browser; `Kakey/` is suggested |

The folder holds only `vault.kakeyvault` and `vault.metadata.json`; if an app folder unexpectedly holds other files, Kakey falls back to the folder browser.

| Backend | Remote version | Conditional write |
|---|---|---|
| WebDAV / Nextcloud | `getetag` from `PROPFIND` | `If-Match` / `If-None-Match: *`; a weak ETag falls back to comparing before writing (brief race window) |
| Dropbox | `rev` | Upload `mode` `update` / `add` / `overwrite` with `strict_conflict` |
| OneDrive | `eTag` | `If-Match`; creation uses `conflictBehavior=fail` |
| Google Drive | `headRevisionId` | Emulated: check before writing, list revisions after; if another device wrote in between, its version is written back on top and the write reports a conflict |

Drive v3 has no `If-Match`, so the emulation keeps the other device's data as the current version instead of overwriting it while that device believes it is in sync. Remaining window: a third device writing within the few hundred milliseconds of the write-back, or Drive pruning the overwritten revision within seconds; if the revision list can't be read, the write counts as successful.

## Concurrency and Lifecycle

- UI state lives on the main actor. Argon2id derivation (about 0.1–0.3 seconds) and file IO run in the background. Core FFI calls are synchronous; the platform decides the thread.
- Vault file reads and writes go through one serial channel per platform (on Apple, the `VaultFileStore` actor plus `SerialTaskQueue`; on Android, the single-threaded `files` dispatcher). Replacing the file and swapping the in-memory key (password change, fetching a backup, restore) is a non-cancellable critical section.
- Locking is a hard lock: it clears the accounts and vault key from memory, and any write requires unlocking first. Saves queued before the lock finish with their own copy of the key.

## Logging and Diagnostics

Logs must never contain the master password, TOTP secrets, codes, the vault key, account names, service names, URL query strings, request headers, or request and response bodies. Diagnostics record only states and error types. The core doesn't log, and types that hold secrets implement `Debug` by hand to print `<redacted>`.

## Versioning

- The app version is defined once in `Apple/project.yml`; see [DEVELOPMENT](DEVELOPMENT.md).
- The core has its own version (the workspace `version` in `Core/Cargo.toml`), exposed through `core_version()` and shown as `Core x.y.z` after the app version in the iOS settings screen. It identifies the implementation of the vault format and core behavior, is independent of the app version, and is bumped by semantic versioning only when observable core behavior or the format changes.

## Test Strategy

- **Pure logic in the core** (`make test-core`): unit tests plus entry-by-entry comparison against `Core/golden/`. `cloudset` runs end-to-end and golden tests against in-memory servers (WebDAV, Dropbox, OneDrive, Google Drive), and is also copied out of the workspace and built and tested on its own (`Core/scripts/cloudset-standalone.sh`).
- **Each platform**: the wrapper layer matches golden (Mac `GoldenVectorTests`, Android `GoldenVaultTest`, iOS reads golden samples). State source and platform integration tests cover locking, password changes, sync and conflicts, cloud storage backends driving the real core through in-memory servers, iCloud through an in-memory CloudKit, and HTTP executors through `URLProtocol` stubs / MockWebServer. Tests never touch the real Keychain / Keystore, preferences, iCloud, or the network.
- **UI**: mobile screenshots of the demo vault are compared against DESIGN. Android instrumented tests cover the main flows (they need a device and are not part of `make test`).
- **On device / manual**: biometrics, camera, Screen Recording permission, iCloud, and real cloud storage services, tracked in [VALIDATION](VALIDATION.md).

## Failure and Recovery

- Vault writes: the core reparses the result in memory and decrypts it with the same key before handing it to the platform. The platform updates last-known-good only when the current file's outer envelope decodes, then atomically replaces the main file.
- Sync: a rejected conditional write triggers a new decision; the user resolves conflicts; when the remote can't be decrypted, sync stops and only an explicit restore is allowed.
- Biometric material that is invalid or doesn't match the current vault is deleted, and unlocking falls back to the master password.
- Expired cloud storage credentials: if a request still gets 401 after one refresh, the user must sign in again. Local data is unaffected.

# Kakey Security

> Report vulnerabilities privately through GitHub's private vulnerability reporting for this repository; don't open a public issue.

> Check every rule here when you change encryption, the KDF, locking, import/export, sync, networking, or automation interfaces. Any relaxation must state its reason in this document and in the commit message. For the trust model summary, see [PROJECT](PROJECT.md); for data contracts, see [TECHNICAL](TECHNICAL.md).

## Threat Model

- **In scope**: a lost device, or someone briefly using a signed-in device; other local processes (including apps granted automation access) silently reading codes while the app is unlocked; corrupt or malicious files and server responses causing data loss or resource exhaustion; backup locations, sync tools, and cloud storage services seeing plaintext; offline brute force against a stolen backup (countered by KDF cost and password strength requirements).
- **Out of scope**: an attacker who can already read the current user's files and stay resident long term (biometric unlock is a local convenience; users who need high security should use only the master password); a compromised operating system.
- **Known limitations**: old ciphertext in cloud storage version history and local snapshots is outside Kakey's control, and the old master password still opens it after a password change. Memory wiping covers only material the core holds (see "Vault"). Items marked "deliberate relaxation" are conscious trade-offs.

## Network Boundary

- There is no Kakey server or account system, no telemetry, and no update check.
- Only the backup location a user enables talks to the network: iCloud through the system's CloudKit; cloud storage (WebDAV, Nextcloud, Dropbox, OneDrive, Google Drive) through requests that only the core can build and that the platform executor sends as is. Every other feature works with no network access.
- QR codes, screenshots, image recognition, and text imports are parsed on the device. Nothing is uploaded.

## Vault

- Account data is stored as a local encrypted JSON file. Plaintext exists only in memory and is encrypted right after serialization, before it touches the disk.
- The outer envelope may contain only the version, algorithm identifiers, KDF parameters, salt, nonce, timestamps, and ciphertext.
- Format v2: AES-256-GCM with a key derived from the master password by Argon2id (`time=3`, `memory=65536 KiB`, `parallelism=1`, `keyLength=32`; time and memory follow the second recommended option in RFC 9106, with parallelism 1). Each vault has a random 32-byte salt, a 12-byte nonce, and a 16-byte authentication tag. The parameters are stored in the file: rewrites with the unlocked key keep the file's parameters, while creating a vault, changing the master password, and exporting write the current parameters.
- Only v2 and Argon2id are accepted. A mismatched version or KDF identifier is rejected as a corrupt file without running the KDF.
- Random numbers come from the system CSPRNG (the core uses `getrandom`). An RNG failure returns an error on every path and never panics.
- Unlocking succeeds only by decrypting with the key derived from the master password or with the local protected key released by biometrics. There must be no demo password, fixed key, or plaintext fallback. An invalid password, damaged ciphertext, or failed authentication returns no partial data.
- Changing the master password first decrypts with the current master password, then rewrites the whole vault with the new key. A wrong current password counts as a failed attempt, just like unlocking. If backup is on, the app syncs right away and waits for the result. On failure it says clearly that the backup is still encrypted with the old password (if the old password was replaced because it was weak or leaked, it still opens the old backup).
- Each rewrite first keeps the previous decodable envelope (last-known-good). The new vault atomically replaces the main file only after it passes authenticated decryption in memory. The snapshot is updated only when the current file's outer envelope decodes, so a corrupt file never overwrites the last recoverable ciphertext.
- File reads and writes go through one serial channel per platform. Replacing the file and switching the in-memory key happen in the same non-cancelable critical section, so an interruption can't leave the file with a new salt while memory still holds the old key. Before rewriting with the unlocked key, the core's `reseal` opens the current file with that key; on a mismatch it reports a wrong password and writes nothing.
- The core wipes from memory: the vault key, intermediate derivation results, payloads before encryption and after decryption, the Authenticator passphrase hash and its derived AES key and IV, passwords passed over FFI, Argon2 working memory, AES key schedules, and HMAC / GHASH internal state. Temporary serialization values, account strings, and platform-side copies are not covered.

### Error Classification

| Situation | Error | Counts as a failed attempt |
|---|---|---|
| AES-GCM authentication tag mismatch | Wrong password | Yes (the only one that counts) |
| Authentication passes but the content can't be parsed; malformed envelope (version, algorithm, salt not 32 bytes, nonce not 12 bytes, ciphertext shorter than nonce + tag, leading nonce in the ciphertext differs from the field); KDF parameters over the limit | Corrupt file | No |
| Stored vault key has the wrong length | Invalid key | No |
| System RNG or crypto operation fails | Crypto operation failed | No |
| Export password fails the password rules | Unacceptable password | No |

Reason: counting a correct password toward the wait would lock users out of their own vault. The mapping from errors to string keys lives only in the core.

### Limits on External Parameters

Computation parameters from files and servers are checked against these limits before any work starts. Anything over a limit is rejected as corrupt or invalid, without running the KDF:

| Parameter | Limit | Location |
|---|---|---|
| Argon2id time / memory / parallelism (vault, export, and Authenticator backups) | 10 / 256 MiB / 4 | `kakey-core/src/vault.rs` |
| Distinct `keyId` values in an Authenticator backup | 16 | `kakey-core/src/authenticator.rs` |
| TOTP digits | 10 | `kakey-core/src/totp.rs` |
| Imported files, and vaults in a sync folder or iCloud | 16 MiB (checked before reading into memory) | Apple `ExternalFileLimits`, Android `FileLimits` |
| Cloud storage response body / entries per listing / redirects | 16 MiB / 10,000 / 5 | `cloudset::Limits` |
| WebDAV XML nesting depth | 32 | `cloudset` `multistatus.rs` |

Reason: a corrupt or malicious file can make a single unlock or import run for hours and exhaust memory (iOS kills the app). The limits leave room to raise the parameters later.

## Locking and Unlocking

- **Auto-Lock** counts from the last activity (1, 5, or 30 minutes; there is no "never"). Activity means only input events this app receives (a local `NSEvent` monitor on the Mac, a window-level gesture observer on iOS, `onUserInteraction` on Android). It reads no content and ignores system-wide idle time. Moving to the background or closing a window doesn't count as activity. Every unlock path, including windowless entry points on the Mac such as the AppleScript `copy code` command and screenshot recognition from a global shortcut, starts the timer at the moment of unlock. With no activity, the vault stays in memory for at most "last activity + the chosen duration". Locking the device locks the app immediately.
- **Failed attempts**: from the 5th failure, wait 30 seconds, doubling each time up to 5 minutes (30, 60, 120, 240, 300 seconds). A successful unlock resets the count. The rules live in the core's `password.rs`. Android stores "total seconds + start" on a monotonic clock, so changing the system time can't skip the wait, and a restart waits the full time again.
- **Master and export password rules** (the core's `password.rs`, the same on all platforms): 8 to 128 characters, printable ASCII only (0x21 to 0x7E, no space), and strength at least Fair. Strength comes only from zxcvbn: 0 and 1 are Weak, 2 is Fair, 3 is Strong, and 4 is Very Strong. The product name counts as a user-related word. Fewer than 8 characters or a disallowed character is Weak outright. Evaluation happens only in memory. Fair asks the user to confirm before submitting. Passwords typed to unlock or import are neither filtered nor length-limited. Reason: the master password also encrypts backups, and anyone holding a backup can brute-force it offline, where the wait after failed attempts doesn't help. With Argon2id at 64 MiB, one high-end GPU makes roughly one to two thousand guesses per second, so Weak (within about 10^6 guesses) falls in minutes and Fair (within about 10^8 guesses) in about a day.
- While locked, the Mac's Security and Advanced settings pages show only a locked notice. While unlocked, turning off the failed-attempt wait and resetting the app also require on-the-spot `deviceOwnerAuthentication`, so a bystander can't turn off the wait and then try passwords without limit. iOS and Android also verify on the spot before a reset (on a device with no passcode, only a confirmation).
- The plaintext master password is never written to disk, logs, preferences, or crash reports, and never passes through AppleScript, the URL scheme, or any script. Unlocking happens only in the native UI.

### Biometric Unlock

Each platform stores the wrapped vault key, never the master password. Unlocking first requires an explicit biometric check. If the material is invalidated or doesn't match the current vault, it is deleted and the app falls back to the master password. After a master password unlock or a password change, the material is saved again with the new key.

- **Mac**: a Secure Enclave P-256 key (access control `.privateKeyUsage | .biometryCurrentSet`, non-exportable, permanently invalidated when the enrolled fingerprints change) wraps the vault key with ECIES (ECDH → HKDF-SHA256 → AES-256-GCM), stored in `biometric-key.json` (mode 0600). The file holds only the enclave key handle, the ephemeral public key, and the ciphertext. Touch ID completes first, then the same `LAContext` restores the handle. The Keychain isn't used: on macOS, items with biometric access control require the data protection keychain and a Team-signed application identifier, which ad-hoc builds don't have.
- **iOS / iPadOS**: a Keychain generic password item with access control `.biometryCurrentSet` and accessibility `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` (unavailable without a device passcode, never migrated through backups). Biometrics complete first, then the same `LAContext` reads the item.
- **Android**: a 2048-bit RSA key pair in Keystore (alias `com.gicek.kakey.vault-key`, non-exportable, `AUTH_BIOMETRIC_STRONG` required on every use, invalidated when biometric enrollment changes). The vault key is wrapped with the public key using RSA-OAEP (SHA-256, MGF1-SHA1) and stored in `noBackupFilesDir/Kakey/biometric-key.bin`; unwrapping goes through `BiometricPrompt.CryptoObject`. An asymmetric key is used because wrapping needs no authentication; only unwrapping does.

## Sensitive Content

- Before showing a secret or a single-account QR code (which contains the full `otpauth://` URI), every platform requires on-the-spot biometric or system password verification. Canceling shows no message and no content. On mobile, a shown secret is cleared when the user leaves the details or the app leaves the foreground.
- Clipboard: the Mac marks items `org.nspasteboard.ConcealedType` and `TransientType` (clipboard history tools don't record them) and clears them on expiry if the clipboard still holds what Kakey wrote. iOS writes only to the local pasteboard (`localOnly`, never Universal Clipboard) with an `expirationDate`. Android marks clips `EXTRA_IS_SENSITIVE`. Lifetimes: one period for a code, 60 seconds for a secret URI.
- On iOS, while unlocked, a privacy cover appears in the app switcher and in the background. Android sets `FLAG_SECURE` while the home screen (the account list and the details sheet over it) is visible, and clears it on leaving the home screen or locking. Onboarding, the lock screen, settings, scanning, and adding screens show no codes or secrets and allow screenshots.
- The demo vault is compiled only into Debug builds (on Android in `src/debug`, with an empty Release implementation). It uses a temporary directory and an in-memory key, never touches the real vault, Keychain, or Keystore, and doesn't set `FLAG_SECURE`, so screenshots work.

## Account Data

- TOTP secrets go only into the encrypted payload, never into unencrypted files, preferences, or persisted UI state. Category names and assignments likewise go only into the encrypted payload and encrypted exports; preferences store only the ID of the category selected in the menu bar.
- Adding and importing normalize the same way before saving (the core's `canonical`): trim leading and trailing whitespace and common percent-encoding, re-encode Base32 as uppercase with no separators, decode `issuer:account` before splitting it, and remove a redundant `issuer:` prefix. Single-account QR code export reuses the same URI generation.
- Import merging skips accounts whose service name, account name, secret, algorithm, digits, and period all match. Invalid category names from files are ignored.

## Export and Import

- Export files use their own salt and nonce with authenticated encryption. The outer layer holds `app`, `kind`, version, algorithm, KDF parameters, salt, nonce, account count, export time, and ciphertext. Export passwords follow the master password rules, and the core's `export` rejects passwords that don't. Reason: export files are the easiest to forward or copy.
- Import must decrypt with the export password and pass authentication first. On failure, no account is imported.
- Authenticator plaintext and v3 encrypted JSON: the import reproduces its Argon2id passphrase check (`time=2, memory=19 MiB, parallelism=1`), then decrypts each record in the CryptoJS `Salted__` format. Each distinct `keyId` is verified once, a failure returns immediately, and Argon2id never reruns per record. `totp` entries with Base32 and `hex` secrets are supported; `hotp`, `steam`, `battle`, GOST, and others are skipped rather than downgraded to a wrong algorithm.

## Sync and Backup

- A backup location holds only the encrypted envelope and non-sensitive metadata (device name, time), never plaintext accounts or the master password.
- **Only the local key counts**: before enabling a location, a read-only link check runs. If the remote already has a backup that differs from the local vault and the local key can't open it, the location isn't enabled. During regular sync, a remote that changed since the last sync and can't be opened is `Unreadable`: nothing is uploaded or fetched, it never enters conflict resolution, and Back Up Now and Keep This Device's Copy refuse to overwrite it. The only option is an explicit Restore from Backup, which first opens that backup with its password in memory and replaces the local vault only on success. Wrong passwords here don't count as failed attempts (the ciphertext already sits in the backup location, so a counter can't stop offline attempts). The trial open uses `core_vault_opens_with_key` (authenticated decryption only, no KDF).
- **Conflicts**: these arise only when the local key opens the remote. The user sees the account differences and chooses Keep This Device's Copy, Use the Backup's Copy, or Merge Both. Nothing is ever overwritten silently. Comparing and merging happen only in memory, and the UI shows no secrets.
- **Conditional writes**: an upload carries the remote version seen at decision time. If the remote changed after the decision, the write is rejected and the decision runs again. Only an explicit overwrite by the user (Keep This Device's Copy, or a Back Up Now judged safe to overwrite) writes unconditionally.
- **Folders**: iOS keeps a security-scoped bookmark and reads and writes through `NSFileCoordinator`. Android keeps a persistent SAF URI permission and releases it when sync stops or the app is reset.
- **System backups**: Android sets `allowBackup=false`, and `data_extraction_rules` excludes all data from cloud backup and device transfer. On Apple platforms, biometric material and credentials are `ThisDeviceOnly`.

### iCloud

- Backups go to the CloudKit private database of the user's own iCloud account, which only that account can access. The container is bound to the development team and entitlement, so other developers' apps can't read or write it, and it doesn't appear in iCloud Drive.
- The `envelope` asset is the encrypted envelope as is; the device name and time go in `encryptedValues` (always end-to-end encrypted). The asset file written to a temporary directory before upload is already ciphertext and is deleted right after saving. Reads check the size limit and the envelope first.
- The server enforces conditional writes with `ifServerRecordUnchanged`.
- On linking, the app records the account's opaque user record name in the container. Before the first read or write and on `CKAccountChanged`, it confirms the account hasn't changed. If it has, sync stops in an "account changed" state and never writes local data into another account.
- Push notifications are only silent wake-ups (`content-available`) with no content, and are ignored while locked.
- Turning iCloud off keeps the backup in iCloud by default. If the user chooses to delete it, the app waits for queued syncs to finish, then deletes the whole zone; on failure, it stays on. Resetting the app only cancels the local subscription.
- iCloud and push are restricted entitlements, enabled only in builds with a development team configured. Ad-hoc builds, the simulator, and tests don't include them.

### Cloud Storage

The protocols live in the core's general-purpose `cloudset` component; platforms only execute the requests it builds. Architecture and design: [TECHNICAL](TECHNICAL.md).

#### Requests and Responses

- **Request origins**: WebDAV and Nextcloud send requests only to the origin in the connection (scheme + host + port). OAuth providers send only to fixed HTTPS origins: Dropbox `api.dropboxapi.com` / `content.dropboxapi.com`, OneDrive `graph.microsoft.com`, Google Drive `www.googleapis.com`, plus each token endpoint. Google's revocation endpoint `oauth2.googleapis.com/revoke` gets no Bearer header; the token goes only in the form body. The core rechecks the origin of every request that carries an access token (including pagination URLs). OneDrive's pre-signed download URLs carry no credentials and must be HTTPS.
- **Executor contract**: never follow redirects (3xx goes back to the core, which accepts only same-origin redirects and never HTTPS → HTTP); no cookies, no cache, no automatic retries; read at most the limit + 1 byte of a body.
- **Untrusted responses**: WebDAV XML rejects `DOCTYPE`, never expands custom entities, nests at most 32 levels, and lists at most 10,000 entries at a time. Remote paths outside the root or containing `..` or control characters are dropped. Downloaded envelopes go through the KDF parameter limits first.
- **Google Drive** has no conditional writes. Kakey checks `headRevisionId` before writing and the revision list after; if another device wrote in between, it restores that version and reports a conflict instead of overwriting silently (the remaining race window is in [TECHNICAL](TECHNICAL.md)).

#### Plain HTTP and Pinned Certificates

- **Plain HTTP** (deliberate relaxation): WebDAV and Nextcloud allow `http://` for self-hosted NAS and LAN services without certificates. The user must explicitly confirm the unencrypted connection; without that, the core refuses to build it, and the UI keeps showing "Unencrypted connection". This exposes the storage account password and the fact that a backup exists; the vault stays encrypted. Apple platforms set `NSAllowsArbitraryLoads` because the host is user-entered; Android's `network_security_config` allows cleartext and trusts only system certificates. The real constraint is the core's origin check.
- **Untrusted certificates** (deliberate relaxation): when the system rejects a WebDAV or Nextcloud `https://` certificate (self-signed, internal CA, host name mismatch), the executor returns the SHA-256 of the leaf certificate's DER. After the user checks it against the server, the connection pins that certificate. Later requests run system validation first; if it fails, only the pinned fingerprint is accepted (constant-time comparison, host name no longer checked), and a mismatch stops sync as "certificate changed". **There is no one-tap trust for a new certificate.** OAuth providers and plain HTTP connections can't pin. The UI keeps showing "Certificate not verified". A man-in-the-middle on the first connection gets the same exposure as plain HTTP; any later one fails. Apple platforms decide in the `URLSession` server trust challenge; Android uses an `X509TrustManager` that delegates to the system and applies only to pinned connections.

#### Credentials

- **Storage**: the connection blob (WebDAV or Nextcloud password or app password; OAuth refresh and access tokens) is opaque bytes serialized by the core, wrapped in `Zeroizing`, and never parsed by platforms. It stays on the device, never migrates through backups, and needs no biometrics (the first restore downloads the envelope before the vault is unlocked). iOS: Keychain, `AfterFirstUnlockThisDeviceOnly`. Mac: wrapped by a Secure Enclave key that requires only `.privateKeyUsage`, in `cloud-connection.json` (mode 0600). Android: encrypted with a non-exportable AES-256-GCM Keystore key, in `noBackupFilesDir/Kakey/cloud-connection.bin`.
- **Exposure**: credentials aren't encrypted with the master password. A leak at worst allows reading and writing Kakey's ciphertext in the chosen folder (the whole drive with "Any Folder"): backups can be deleted or rolled back, not decrypted. The access token shares the blob with the refresh token because it has fewer rights and expires within an hour.
- **During the first restore**: authorized blobs and WebDAV / Nextcloud form values (address, user name, password, plain HTTP confirmation, trusted fingerprint) are cached only in memory, keyed by service and access scope, and released when a restore succeeds, a vault is created, or the process ends. They never reach the Keychain, Keystore, or disk.
- **Disconnect and reset**: turning off cloud storage or switching locations revokes the server-side authorization on a best-effort basis (Nextcloud deletes the app password, Dropbox revokes the token, Google revokes the whole grant; Microsoft has no revocation endpoint). Local credentials are deleted immediately; a failed revocation blocks nothing. Remote backups stay.

#### Sign-In

- **Nextcloud**: Login Flow v2 in the system browser, so Kakey never sees the account password. The polling URL, login page, and returned server address must share the origin the user entered (an upgrade to HTTPS on the same host is allowed).
- **OAuth** (Dropbox, OneDrive, Google Drive): public clients with no client secret; authorization code + PKCE S256 (32-byte CSPRNG verifier); `state` is another 32 random bytes. The callback address is checked first, then `state` in constant time; a mismatch or an `error` is dropped without sending any request. By default only app folder access is requested (Dropbox App folder, `Files.ReadWrite.AppFolder`, Google `drive.file`); OneDrive adds `User.Read` only to show the account email, and Google's email comes from Drive `about`. A Google token response without the required Drive scope (the user unchecked it) counts as a denied authorization. Full-drive access is offered only when the developer configuration enables it, and the UI says so. The access token is refreshed 60 seconds before expiry or on a 401 and the request replayed once; a second 401 asks the user to sign in again.
  - Apple platforms use `ASWebAuthenticationSession` (non-ephemeral, sharing the default browser's sign-in; credentials come only from this PKCE exchange). Android uses a Custom Tab, and the callback activity passes back only callbacks the core recognizes as this sign-in's. Someone who claims the callback scheme still can't get a token without the verifier.
  - Google: all platforms share one iOS-type client and its `com.googleusercontent.apps.<id>:/oauth2redirect` callback. Security is unchanged, since the client is public either way; the reasoning is in [TECHNICAL](TECHNICAL.md).
  - Dropbox official app: on Android, the `AUTHENTICATE_V2` intent goes only to `com.dropbox.android` signed with Dropbox's certificate (SHA-256 checked). On iOS, the app opens `dbapi-2` / `dbapi-8-emm` and returns through `db-<app key>://1/connect`; the target's signature can't be checked, so an impostor gets only the PKCE challenge. The same `state` check and verifier apply. Without the app, the browser flow is used. The Dropbox SDK isn't used (it exchanges tokens itself and keeps the verifier).
  - Developer keys are public client IDs, kept in the uncommitted `cloud-keys.toml` and compiled into the core at build time.

## Mac Automation

Kakey exposes two AppleScript commands through `Kakey.sdef` (Cocoa Scripting), authorized per app by macOS Automation (TCC). The "Enable Third-Party Plugin Interface" setting in Settings → Advanced is off by default and applies before TCC: when it's off, both commands are refused and no search index is built. Resetting the app turns it off too.

- `copy code <account id>`: **every call requires on-the-spot Touch ID or system password verification**, whether or not the app is unlocked. This stops local malware from using an authorized automation channel to read codes silently while the app happens to be unlocked. It looks up only a known ID and offers no enumeration. Failure, cancellation, or timeout returns an empty string. The return value is the code itself (deliberate relaxation): the code is also on the clipboard, which a caller inside the same permission boundary can already read. This lets Alfred show the code in a system notification; the user knowingly accepts the exposure that Notification Center adds.
- `find accounts <query>`: fuzzy-matches the full service and account names and returns only masked results as JSON (`{enabled, ready, accounts: [{id, issuer, username}]}`, for example `k***@example.com`), with no secrets or codes and no re-verification. The data comes from an in-memory search index that Hard Lock doesn't clear (so search works while locked); before the first unlock it returns `ready:false`. Deliberate relaxation: TCC grants at the level of "can this app control Kakey", so other workflows inside an approved app can call it too, and matching on account names lets the match result leak a few unmasked characters. The added exposure is acceptable.
- `kakey://reveal?id=` only brings the main window to the front and must never be able to copy anything; otherwise any process could bypass TCC and per-call verification with `open`.
- `Kakey.alfredworkflow` is generated deterministically by a script at build time and signed with the app. Install Alfred Workflow only opens this static file.
- There is no extra authentication or session mechanism, and no unprotected local socket or unauthenticated entry point may be added.

## Platform Permissions and Distribution

- **Mac**: not sandboxed, with Hardened Runtime. The entitlements declare only the camera (builds with a development team configured add iCloud and push). Screen Recording, camera, and automation permissions are requested through the system flow. Without a Developer ID, the build is ad-hoc signed and runs only on the local Mac.
- **iOS**: the vault file uses `.completeFileProtection` (unreadable while the device is locked). The camera is requested through the system flow; the photo library uses `PhotosPicker`, which needs no permission.
- **Android**: the source manifest declares only `CAMERA` (requested when scanning opens) and `INTERNET` (only for cloud storage backup), plus the biometric permission merged in from `androidx.biometric`. Permissions that dependencies bring in, such as `ACCESS_NETWORK_STATE`, are removed with `tools:node="remove"`, and the `check<Variant>ManifestPermissions` build task checks the merged manifest and fails the build if any other network permission appears. Release builds are signed with the keystore configured in `local.mk`; the keystore and its passwords are never committed. Without one, the build falls back to the Debug keystore with a warning, and such a build must not be distributed.

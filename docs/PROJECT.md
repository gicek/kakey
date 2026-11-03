# Kakey Project Definition

> Product positioning, scope, and confirmed decisions. The other documents build on this one. Interaction is in [DESIGN](DESIGN.md), technology in [TECHNICAL](TECHNICAL.md), security in [SECURITY](SECURITY.md), phases in [ROADMAP](ROADMAP.md), and status in [VALIDATION](VALIDATION.md).

## Product

**Kakey** is a native, locally encrypted two-factor code (TOTP) manager for macOS, iOS / iPadOS, and Android phones and tablets.

Getting a TOTP code usually means picking up a phone and opening an authenticator, or trusting a vendor's cloud with your secrets. The first breaks your flow; the second requires trusting a third-party server. Kakey keeps codes at hand on the device you're using: on the Mac through the main window, a menu bar panel, and a global shortcut; on phones and tablets with a single tap to copy. Data lives only in an encrypted vault on the device, and syncing copies encrypted files through the user's own storage. There is no Kakey server and no Kakey account.

## Users

Privacy-minded individuals who are willing to set a master password, want their secrets to exist only as ciphertext on their own devices and in storage they choose, and like keyboard-driven tools (menu bar, shortcuts, Alfred).

## Product Principles

- **Local first**: no Kakey server, no telemetry, no update checks. Only the backup location the user enables uses the network (see [SECURITY](SECURITY.md)).
- **Sensitive data stays in the encrypted vault**: the master password and TOTP secrets never reach disk in plaintext and never appear in logs. New account fields go only into the encrypted payload.
- **Verify sensitive actions on the spot**: showing a secret, exporting a QR code, and fetching a code through automation all require biometrics or the system password, even when the app is already unlocked.
- **Recoverable**: after a failed write, a damaged file, or a sync conflict, the user can always return to the latest decryptable data. The user resolves conflicts after seeing the differences; nothing is silently overwritten.
- **Native on each platform, one core**: system components, semantic colors, light and dark appearance, and system text sizes. Non-UI logic is implemented once, in the Rust shared core.

## Scope

### Platforms

| Platform | Minimum OS |
|---|---|
| macOS | 14, Apple silicon only |
| iOS / iPadOS (one app) | 17 |
| Android phones and tablets (one app) | 13 (API 33), arm64-v8a |

### Feature Matrix

| Feature | Mac | iPhone / iPad | Android phone / tablet |
|---|---|---|---|
| TOTP (SHA1 / SHA256 / SHA512, 6 or 8 digits) with countdown; click or tap to copy | ✓ | ✓ | ✓ |
| Add: manual entry, camera, image, Google Authenticator migration codes, otpauth text | ✓ (plus screen selection) | ✓ (plus drag and drop on iPad) | ✓ |
| Search, custom categories (an account can be in several), drag to reorder | ✓ | ✓ | ✓ |
| Account editing; showing the secret or a single-account QR code (with re-verification) | ✓ | ✓ | ✓ |
| Master password, auto-lock, lock with the device, delay after wrong passwords | ✓ | ✓ | ✓ |
| Biometric unlock | Touch ID | Face ID / Touch ID | Strong biometrics |
| Change master password, reset the app | ✓ | ✓ | ✓ |
| Encrypted export and import (interchangeable across platforms); Authenticator backup import | ✓ | ✓ | ✓ |
| Restore the last good copy when the vault is damaged | ✓ | ✓ | — (the snapshot is kept, no restore UI yet) |
| Backup locations (one at a time) | iCloud, folder, Dropbox, OneDrive, Google Drive, WebDAV, Nextcloud | Same as Mac | Folder (SAF), Dropbox, OneDrive, Google Drive, WebDAV, Nextcloud |
| Sync conflict review: keep this device's copy, use the backup's copy, or merge both | ✓ | ✓ | ✓ |
| Appearance and in-app language switching (English, Simplified and Traditional Chinese) | ✓ | ✓ | ✓ |
| Menu bar panel, global shortcuts, screen capture recognition | ✓ | — | — |
| AppleScript interface and Alfred workflow | ✓ | — | — |
| Launch at login, Dock icon options | ✓ | — | — |

- Mobile platforms have no menu bar, global shortcuts, Apple Events, or screen selection; reading from photos replaces screen capture recognition.
- Dropbox, OneDrive, and Google Drive appear only when the build has developer keys configured (see [DEVELOPMENT](DEVELOPMENT.md)).
- A vault or export file written on any platform opens on the others with the same password.

### Non-Goals

Before adding any of the following, update this document and ROADMAP and get approval:

- A Kakey account, app server sync, telemetry, in-app update checks.
- Browser extensions and web autofill; system-level code autofill (an iOS credential provider extension, an Android autofill service).
- Home screen / desktop widgets; an Apple Watch client.
- Proprietary code algorithms such as Steam or Battle.net.

These would significantly widen the network, interprocess communication, or key distribution boundary. HOTP and recovery key bundles would change the data model or key management. They're listed under pending separate review in [ROADMAP](ROADMAP.md), need their own approved proposal, and must not be added along the way.

## Trust Model

The threat model and specific rules are in [SECURITY](SECURITY.md). In short: the vault is encrypted with AES-256-GCM using a key derived from the master password with Argon2id; biometrics only unseal a vault key protected by the system on the device; backup locations hold only ciphertext; on the Mac, external automation goes only through AppleScript commands authorized by macOS Automation, is off by default, and verifies identity for every code.

## Success Criteria

- When unlocked, getting a code onto the clipboard takes no more than two steps from pressing the global shortcut (Mac) or opening the app (mobile).
- After any single failed write, damaged file, or sync conflict, the user can restore the latest decryptable vault.
- Each platform opens the vaults, backups, and export files written by the others with the same master password.
- `make test` passes, and every security-relevant behavior has a matching entry in SECURITY.

## Confirmed Decisions

| Decision | Choice |
|---|---|
| Platforms | macOS, iPhone, iPad, Android phones and tablets. No Apple Watch client, which would widen the key distribution boundary |
| Shared core | Rust `Core/` shared by all three platforms through UniFFI. One implementation, so every platform behaves the same, checked by the shared golden vectors |
| Encryption | Argon2id and AES-256-GCM, implemented with RustCrypto and byte-for-byte identical to the PHC reference implementation, so vaults and exports move between platforms |
| Minimum OS | macOS 14; iOS / iPadOS 17 (the same generation); Android 13 |
| Distribution | Mac: direct download (Developer ID signed and notarized, not sandboxed, Hardened Runtime). Mobile: development builds first; store release to be decided separately |
| UI languages | English as the source language, Simplified and Traditional Chinese as translations, switchable in the app |
| License | MIT |
| Network | Only the backup location the user enables uses the network, talking directly to the user's own cloud storage through its API (this isn't app server sync); every other feature is offline |
| Backup locations | One at a time: iCloud (CloudKit private database, between Apple devices), any synced folder, or cloud storage (WebDAV, Nextcloud, Dropbox, OneDrive, Google Drive); see [TECHNICAL](TECHNICAL.md) |
| Sync conflicts | The user sees the account differences, then keeps this device's copy, uses the backup's copy, or merges both; nothing is overwritten silently. A remote backup the local key can't decrypt only allows an explicit "Restore from Backup" |
| External automation | The Mac AppleScript interface is off by default and verifies identity for every code, since any app the user grants Automation access can call it |

## Tunable Parameters

Each current value is maintained in exactly one place:

- Auto-lock options and default: [DESIGN](DESIGN.md) (settings).
- Delay curve after wrong passwords, password rules, KDF parameters, and clipboard clearing times: [SECURITY](SECURITY.md).
- Number of backup history entries: [DESIGN](DESIGN.md) (back up and sync).

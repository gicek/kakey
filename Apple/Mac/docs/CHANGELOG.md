# Kakey Mac Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow semantic versioning.

## [Unreleased]

### Added

- "Backup & Sync": back up to iCloud (CloudKit private database, with push for instant sync), any folder, WebDAV, Nextcloud, Dropbox, OneDrive, or Google Drive, one at a time. Cloud storage signs in inside the app, accesses only Kakey's own folder by default, and lets you browse and create remote folders. Plain HTTP needs confirmation and stays flagged; a self-signed WebDAV or Nextcloud certificate is trusted after you check its fingerprint, and a changed certificate stops sync.
- Conflict handling: lists the accounts that differ on each side (without showing secrets). Choose "Merge Both" and pick which version to keep for each account, or "Keep This Mac’s Copy", "Use the Backup’s Copy", or "Decide Later". "Back Up Now" uses the same decision as automatic sync.
- Sync only trusts the local key: it stops at a backup the local key can't open, and the only way forward is "Restore from Backup" with that backup's password.
- First-time restore from iCloud, cloud storage, a folder, or a Kakey exported file, offered side by side in two columns. Nothing is written to this Mac until the password opens the backup; an exported file can keep its password as the master password or set a new one.
- Custom categories replace "Favorites": create, rename, delete, and reorder them in the sidebar; an account can belong to several categories, and the menu bar panel can show a single category. Encrypted exports carry categories, and imports merge them by name.
- Alfred workflow and AppleScript interface (`find accounts`, `copy code`): `kk` filters by service and account name, and every copy asks for verification again. Controlled by "Enable Third-Party Plugin Interface" in Settings, off by default.
- "Background Launch Only" setting.
- When the vault is damaged and a good snapshot exists, the lock screen offers "Restore Last Good Copy".

### Changed

- The main window shows accounts as cards by default.
- Auto-lock counts from the last activity (1 / 5 / 30 minutes, 5 by default) and locks immediately when the screen locks or the screen saver starts. Touch ID prompts automatically only the first time the lock screen appears after launch.
- The shared core enforces password rules: 8–128 printable ASCII characters, strength rated by zxcvbn, weak passwords rejected. New writes use 3 Argon2id passes. Changing the master password updates the backup right away.
- The Secure Enclave protects Touch ID material, and availability is rechecked when Kakey returns to the foreground.
- Clipboard contents are marked concealed and transient and clear automatically (one period for codes, 60 seconds for otpauth URIs).
- Redesigned onboarding, lock screen, Settings window, and sheets; drag to reorder is an in-app gesture.
- The Rust shared core handles encryption, parsing, import, search, password rules, and sync decisions; key derivation runs in the background.
- Import files and backups over 16 MiB are rejected as invalid.
- Distributed as a signed, notarized DMG.

### Fixed

- Importing an exported file or recognizing several QR codes at once reversed the order of the new accounts.
- A vault that decrypted but couldn't be read was treated as a wrong password and counted toward the delay.
- A maliciously crafted backup could stall import for a long time through its KDF parameters.
- The vault stayed in memory after a windowless unlock (AppleScript, global shortcut).
- "Show QR Code" didn't require authentication.

### Removed

- The "Favorites" star (replaced by categories).

## [0.1.0] - 2026-07-16

The first feature-complete local release, distributed directly and not publicly released.

### Added

- TOTP codes (RFC 6238), main window list / card views, search, drag to reorder, and a quick menu bar panel.
- Add accounts by manual entry, camera, image, screenshot recognition, or bulk otpauth text import; account details, editing, and QR code export.
- Vault encrypted with Argon2id + AES-256-GCM under a master password, Touch ID unlock, auto-lock, delay after failed attempts, last good snapshot, and app reset.
- Encrypted export / import, Authenticator plaintext and encrypted JSON import, encrypted iCloud Drive sync, and backup history.
- Global shortcuts, launch at login, Dock icon and menu bar icon settings, and single instance; three UI languages and light / dark appearance.

# Kakey Android Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Version numbers share `MARKETING_VERSION` with the Apple platforms.

## [Unreleased]

The first release for Android phones and tablets. It shares the Rust core with the Mac and iOS, so vaults, backups, and export files work across all platforms.

### Added

- **First run**: create an encrypted vault (master password with a strength meter, optional strong biometrics), or restore a backup from a folder, cloud storage, or a Kakey export file. A backup is unlocked with its password before anything is written to the device; restoring an export file can keep the export password or set a new master password.
- **Lock screen**: unlock with the master password or biometrics, with a wait after repeated failed attempts that neither changing the system time nor rebooting can skip.
- **Accounts**: Material 3 Expressive with dynamic color; large codes with a countdown ring; tap to copy. Long-press menu, drag to reorder, category filters, and search. Tablets show a card grid, plus a permanent sidebar on wide screens.
- **Adding accounts**: scan a QR code (including multi-part Google migration codes), detect from an image, paste a setup link or enter it manually, or import a Kakey export or an Authenticator backup, all with deduplication. Accounts added together keep their original order.
- **Details**: copy, rename, categories, and parameters. Revealing the secret or the export QR code asks for verification again.
- **Sync and backup**: a sync folder, WebDAV, Nextcloud, Dropbox (sign-in through the Dropbox app when installed), OneDrive, and Google Drive. Plain HTTP needs confirmation, and a self-signed certificate is pinned after you check its fingerprint. Conflicts show the differing accounts, then merge or keep one side. A backup this device can't decrypt can be restored with that backup's master password. Backup history.
- **Settings**: biometrics, auto-lock (1, 5, or 30 minutes after the last activity; locks at once when the screen turns off), change master password (updates the backup right away), category management, export and import, appearance, app language, and reset.
- **Security**: the account list and details block screenshots and screen recording; master and export passwords must be at least Fair strength; data is excluded from system cloud backup and device transfer; the only network permission is `INTERNET`, used only for cloud storage backup; the biometric vault key is protected by Keystore.

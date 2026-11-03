# Kakey iOS / iPadOS Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Version numbers share `MARKETING_VERSION` with the Mac.

## [Unreleased]

The first iPhone and iPad release. It shares the Rust core with the Mac, so vaults, backups, and export files work across all platforms.

### Added

- **First run**: create an encrypted vault (master password with a strength meter, optional Face ID / Touch ID), or restore a backup from iCloud, cloud storage, a folder, or a Kakey export file. A backup is unlocked with its password before anything is written to the device; restoring an export file can keep the export password or set a new master password.
- **Lock screen**: unlock with the master password or biometrics, with a wait after repeated failed attempts. A damaged vault can be recovered from an intact snapshot.
- **Accounts**: large codes with a countdown ring; tap to copy. Search, delete, drag to reorder, and categories. iPad adds a sidebar and a card grid, hardware keyboard shortcuts, and drag and drop of images or text.
- **Adding accounts**: scan with the camera (including multi-part Google migration codes), detect from photos, paste a setup link, enter manually, or import a Kakey export or an Authenticator backup, all with deduplication. Accounts added together keep their original order.
- **Details**: rename, categories, and parameters. Revealing the secret or the export QR code asks for verification again.
- **Sync and backup**: iCloud (instant sync through push), a folder, WebDAV, Nextcloud, Dropbox (sign-in through the Dropbox app when installed), OneDrive, and Google Drive. Plain HTTP needs confirmation, and a self-signed certificate is pinned after you check its fingerprint. Conflicts show the differing accounts, then merge or keep one side. A backup this device can't decrypt can be restored with that backup's master password. Sync history.
- **Settings**: biometrics, auto-lock (1, 5, or 30 minutes after the last activity; locks at once when the device locks), change master password (updates the backup right away), export and import, appearance, language (English, Simplified Chinese, Traditional Chinese, switched instantly), and reset.
- **Security**: a privacy cover in the background and the app switcher; the biometric vault key lives in the Keychain, bound to this device and the current biometric enrollment; the clipboard stays on this device and expires; master and export passwords must be at least Fair strength.

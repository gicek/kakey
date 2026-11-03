# Kakey

Kakey is a native, locally encrypted two-factor code (TOTP) manager for macOS, iOS / iPadOS, and Android. Accounts are stored on your device, encrypted with a key derived from your master password. There is no Kakey server and no Kakey account; to sync across devices, Kakey copies encrypted files through storage you choose.

Kakey hasn't had a public release yet. To try it, build it from source (see "Quick Start").

## Features

- **Codes**: RFC 6238 TOTP (SHA1 / SHA256 / SHA512, 6 or 8 digits) with a countdown. Click or tap to copy.
- **Adding accounts**: scan with the camera, read from an image (or select an area of the screen on the Mac), combine multiple Google Authenticator migration codes, paste an otpauth link, or enter a secret by hand.
- **Organizing**: search, custom categories (an account can belong to several), drag to reorder, edit, and export a single account as a QR code.
- **Security**: an Argon2id and AES-256-GCM encrypted vault; unlock with Touch ID, Face ID, or Android biometrics; auto-lock after idle time and lock when the device locks; a delay after repeated wrong passwords; identity verification before revealing a secret or QR code.
- **Data**: encrypted export and import that work across all three platforms; import of plain and encrypted Authenticator backups; recovery from the last good copy if the vault is damaged (Mac, iPhone, and iPad).
- **Back up and sync**: iCloud (Mac, iPhone, and iPad), any synced folder, WebDAV, Nextcloud, Dropbox, OneDrive, or Google Drive, one at a time. Only encrypted files are uploaded. On a conflict, review the differences, then keep this device's copy, use the backup's copy, or merge both.
- **Mac**: a menu bar panel, global shortcuts, QR code recognition from a screen selection, and an Alfred workflow that verifies your identity for every code.
- **Languages**: English, Simplified Chinese, and Traditional Chinese, switchable in the app.

## Platforms

| Platform | Minimum OS |
|---|---|
| macOS | 14, Apple silicon |
| iOS / iPadOS | 17 |
| Android phones and tablets | 13 (API 33), arm64-v8a |

## Quick Start

You need an Apple silicon Mac, Xcode 26.5, and rustup (the Rust version is pinned in `Core/rust-toolchain.toml`). Android also needs JDK 21, the Android SDK and NDK, and cargo-ndk. See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for the full requirements.

```bash
make help                # List all commands
make mac-run             # Build and launch the Mac app (Build/macOS/Debug/Kakey.app)
make test                # Run all tests: core, Mac, iOS, Android
make ios-simulator-run   # Run in the iOS Simulator
make android-install     # Install on a connected Android device
```

Dropbox, OneDrive, and Google Drive need your own developer keys; without them, those backup options are hidden. [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) covers developer keys, working in Xcode or Android Studio, and signing.

## Privacy

- No telemetry and no update checks. Only the backup location you enable uses the network: iCloud goes through the system's CloudKit, and cloud storage connects only to the service you chose. A backup location holds only encrypted files plus metadata such as the device name and time.
- The master password and TOTP secrets never reach disk in plaintext and never appear in logs. For biometric unlock, the device stores only vault key material protected by the system (Secure Enclave, Keychain, Android Keystore).
- The Mac app isn't sandboxed and uses the Hardened Runtime; screen recording, camera, and automation permissions are requested through the system's standard flow. On Android, the network permission is used only for cloud storage backups, and app data is excluded from system cloud backup and device transfer.
- See [docs/SECURITY.md](docs/SECURITY.md) for the security model.

## Repository Layout

```text
Core/          Rust shared core (kakey-core, UniFFI boundary kakey-ffi, cloud storage protocols cloudset) and the golden behavior baseline
Apple/         Xcode project (generated from project.yml)
  Shared/      Models, core wrapper, sync backends, and localization resources shared by Mac and iOS
  Mac/         macOS app (target Kakey)
  iOS/         iPhone and iPad app (target KakeyMobile)
Android/       Android phone and tablet app (Gradle, single module :app)
design/        Masters for the logo, brand icons, and DMG art
scripts/       Localization guard, Android string generation, icon and cloud config scripts
docs/          Project documentation
Makefile       The single entry point for build, test, and release; all output goes to Build/ (not committed)
```

## Documentation

- [docs/PROJECT.md](docs/PROJECT.md): what Kakey is, its scope, and what it deliberately doesn't do.
- [docs/SECURITY.md](docs/SECURITY.md): threat model, cryptography, and security rules.
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md): toolchain, build, test, and release.
- [CONTRIBUTING.md](CONTRIBUTING.md): how to contribute, with a map of all project documents.

## Contributing

Contributions are welcome; start with [CONTRIBUTING.md](CONTRIBUTING.md). Report security issues privately as described in [.github/SECURITY.md](.github/SECURITY.md).

## License

[MIT](LICENSE). Third-party dependencies and their licenses are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The Atkinson Hyperlegible Mono font ships with the app under the SIL OFL 1.1.

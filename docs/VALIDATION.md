# Kakey Implementation and Verification Status

> The one place that answers "how far along is it". Features are in the [README](../README.md), phases in [ROADMAP](ROADMAP.md), and change history in each component's CHANGELOG. Status terms: **verified** (automated tests or a local hands-on check), **accepted** (confirmed in a real environment), **pending** (specific checks listed below).

## Current Status

| Component | Automated verification | Acceptance |
|---|---|---|
| Shared core | `make test-core`: fmt, clippy, unit tests, golden comparison, `cloudset` end-to-end tests against in-memory servers (WebDAV, Nextcloud, Dropbox, OneDrive, Google Drive) and a standalone build, FFI round trips, license check; `make core-audit` reports no unhandled advisories | Accepted |
| Mac | `make test-mac`: localization guard, swift-format, unit and integration tests | An earlier build accepted on device; later changes pending (see below) |
| iOS / iPadOS | `make test-ios` (iPhone Simulator); `make ios-screenshots` checked against DESIGN | Pending on-device acceptance |
| Android | `make test-android`: localization guard, ktlint, detekt, Lint, JVM tests; `make test-android-device` passes on a physical device; a Release build tested on a physical device for vault creation and adding accounts | Main flows accepted on device; cloud storage and cross-platform pending |
| Cross-platform | Core golden: all three platforms open vaults and exports written by the Mac; iOS and Android tests import Mac exports and Authenticator backups; each platform's cloud storage backend drives the real core against in-memory WebDAV | Pending |

Confirmed in a real environment:

- A personal OneDrive account signs in on the Mac, makes the first upload to the app folder, and reads an existing backup.
- The signed Mac build carries the iCloud and push entitlements and passes `codesign --verify --deep --strict`.
- The `make mac-dist` DMG lays out correctly in light appearance on macOS 26, and the app signature verifies.

## Pending

### Cross-Platform

See the cross-platform exit criteria in [ROADMAP](ROADMAP.md).

### Back Up and Sync (All Platforms)

- **iCloud** (Mac and iPhone, same Apple Account): two-way sync; the other device fetches changes within seconds when unlocked, or after unlocking when locked; alternating offline changes cause a conflict; the prompt when not signed in to iCloud; after deleting Kakey's data in iCloud storage management, the next sync uploads again; after switching iCloud accounts, the account-changed notice appears; after "Turn Off and Delete iCloud Backup", the other device uploads again; CloudKit Console shows only `Vault` records, with `deviceName` and `vaultUpdatedAt` as encrypted fields.
- **WebDAV / Nextcloud** (for example `rclone serve webdav`, Synology, Nextcloud): connecting and the wrong-password message; the confirmation and "Unencrypted connection" label for plain HTTP; Nextcloud browser sign-in, continuing as soon as the user returns to the app, and the 10-minute timeout; browsing, creating, and choosing remote folders; first upload; conflicts from alternating changes; the app password is deleted on the server after sync stops; restoring across all three platforms.
- **Self-signed certificates**: the displayed fingerprint matches the NAS admin page; after confirming, connecting and syncing work and Settings shows "Certificate not verified"; after the NAS changes its certificate, sync fails with the certificate-changed message and there's no one-click trust; access by IP address (hostname mismatch) still works with the pinned certificate.
- **Dropbox / OneDrive** (requires `cloud-keys.toml`): the sign-in window and canceling; the app folder (only two files in "Apps › Kakey"); choosing any folder; restoring across all three platforms; conflicts from alternating changes; automatic token refresh, and a sign-in prompt after revocation; Dropbox authorization is revoked after sync stops; the status card shows the account email; `Files.ReadWrite.AppFolder` for OneDrive work / school accounts; whether Dropbox accepts the unregistered `db-<app key>://2/token` callback.
- **Google Drive** (requires an iOS-type client in `cloud-keys.toml`): sign-in on Mac, iOS, and Android (whether Android can still borrow the iOS client's callback scheme); unchecking Drive access on the consent page shows an authorization-denied message; the app folder is created at "My Drive › Kakey" with only two files, and is recreated on the next sync after deleting it on the web; restoring and alternating-change conflicts across all three platforms; when two devices upload almost at once, one reports a conflict and the overwritten version is visible in the revision history; automatic token refresh; after sync stops, Kakey disappears from the Google Account's third-party apps; the status card shows the account email; choosing any folder as a test user with `full_access = true`.
- **Dropbox app authorization** (iOS and Android devices): with Dropbox installed, the app opens and finishes automatically after the user allows access; denying or going back returns to the form; after uninstalling, sign-in falls back to the browser. On Android, the callback returns to the app with a non-Chrome default browser, and going to the background during sign-in isn't interrupted by auto-lock.
- **Conflict handling**: after two offline devices each change accounts, names, and categories, the difference groups and counts are correct; after merging, accounts from both sides are present, accounts chosen from the backup take the backup's fields, and category members are combined; if another device writes during the merge, the decision is made again; "Use the Backup’s Copy" doesn't lock; layout in light and dark appearance and all three languages.
- **Local key only**: choosing a backup folder that belongs to another vault is rejected; after another device changes the master password, this device shows "Backup Can’t Be Opened", the old password gives an error and leaves the device unchanged, and the new password replaces the contents with the backup without locking, after which biometrics still work; changing the master password locally keeps uploading; changing it while offline shows "Backup not updated", and once online, another device can restore with the new password.
- **First restore**: on all three platforms, restoring from iCloud, a folder, cloud storage, and an export file stops at "Backup found", and a wrong-password message appears near the button; going back returns to the location list, and going back again allows creating a new vault; going back is disabled while unlocking; when restoring from an export file, "Use as Master Password" is on by default, turning it off reveals the new password and confirmation fields, the button is disabled for a weak password, and "Fair" requires confirmation first.
- **Platform details**: Apple's `URLSessionHTTPExecutor` doesn't follow redirects on a real network (`URLProtocol` stubs can't cover this); saving, reading, and deleting on reset of the Mac's `cloud-connection.json`; iOS Keychain connection items don't migrate with a device backup; Android treats a reinstall as having no connection.

### Locking and Passwords (All Platforms)

- Auto-lock: continuous activity past the chosen time doesn't lock, and the app locks once idle for that long; monitoring doesn't interfere with taps, scrolling, drag to reorder, or long-press menus; on mobile, the app locks on return after being suspended in the background; actual behavior on Android while a dialog or bottom sheet stays open.
- Locking when the device locks: on the Mac, ⌃⌘Q, the screen saver, sleep, display off, and switching users; on iOS with a passcode, the side button; on Android, the power button or screen timeout.
- No automatic biometric prompt after locking: returning to the app after a manual lock, auto-lock, or device lock stays on the unlock screen; only a cold launch prompts once.
- Password entry: new password fields filter out non-ASCII characters (including from input methods and pasting); the button is disabled for weak passwords, and "Fair" requires confirmation; with a Chinese input method on the Mac, every password and secret field accepts all letters without showing a candidate window.
- Unlocking with 3 Argon2id iterations takes an acceptable time on the lowest-spec supported device.

### Mac

- Touch ID: turning it on, unlocking, and falling back to the password after canceling; after adding or removing a fingerprint, a prompt to turn it on again with the master password; after connecting a keyboard with Touch ID or enrolling a fingerprint, it works as soon as Kakey is active again, and the option hides when the keyboard is unplugged.
- Screen capture recognition: the screen recording permission guide (first grant, and granting after a denial); Google migration codes accumulating across sources (screen selection, image, camera).
- Menu bar panel: the feel of real clicks; unlocking in the panel with the master password and Touch ID; the material background, "Reduce transparency", and high contrast on macOS 14 / 15; bounce with trackpad and mouse wheel scrolling; content updates after changing language and appearance.
- Drag to reorder: in the list, cards, and sidebar categories; Esc cancels; auto-scroll at the edges; dropping on the desktop or a text field produces nothing; activation with VoiceOver.
- Touch ID verification and canceling for the details view and the "Show QR Code" context menu item; the clipboard clears when it expires and doesn't appear in clipboard history tools.
- Onboarding at the minimum window size (880 × 654): when restoring from an export file and setting a separate master password, no control is hidden behind the bottom buttons.
- The logo in the Dock, Finder, the About window, and the menu bar template image (light, dark, highlighted); no truncation in the main screens in all three languages.
- Alfred: the main switch is off by default; once on, `kk` searches, and Return verifies identity, copies, and shows a notification; the guidance item after Automation is denied; searching doesn't launch Kakey when it isn't running.
- Release: after deploying the CloudKit schema to Production, the Developer ID build from `make mac-release` syncs and passes notarization; a downloaded DMG opens on another Mac for the first time without a Gatekeeper block (including offline); DMG icon labels are readable in dark appearance; DMG window height on macOS 14 / 15.

### iOS / iPadOS (Device, Requires `DEVELOPMENT_TEAM`)

- Face ID / Touch ID: turning it on, unlocking, and falling back to the master password after canceling; after adding a face or fingerprint, a prompt to turn it on again.
- Camera scanning: a plain otpauth code; scan progress for multiple Google migration codes, reaching the confirmation screen only when all are scanned.
- The app switcher doesn't show codes or revealed secrets; a copied code doesn't appear on the Mac through Universal Clipboard, and can't be pasted after it expires.
- iPhone: "Done" after "Edit", and drag to reorder.
- iPad: size changes in Split View and Stage Manager; hardware keyboard ⌘F / ⌘N / ⌘, / ⌘L; dragging in from Files or Photos for recognition; card long-press menus and drag to reorder; codes aren't truncated when rotated or with large text.
- No untranslated text in any screen when the system language differs from the in-app language.

### Android (Device)

- Strong biometrics: turning it on, returning to the password after canceling, and turning it on again after re-enrolling fingerprints invalidates the key; verification for "Show Secret" and "Export QR Code" (including the screen lock credential).
- Camera scanning (including multiple migration codes) and the guidance after camera permission is denied; recognition from the photo library.
- Synced folders: uploading to and fetching from the Mac through a cloud drive app or Syncthing, and choosing a side in a conflict; saving exports through the system picker; importing Kakey exports and Authenticator backups.
- The real-finger feel of long-press menus, drag to reorder, the "Add to" bottom sheet, and tap to copy.
- After switching the in-app language, the screen and back stack are kept; main flows in dark appearance, at the largest font size, and with TalkBack; with `FLAG_SECURE`, Recents and screenshots show no content; the themed monochrome icon.
- The dialog can't be dismissed while the master password is being changed; the wrong-password delay can't be skipped by changing the system time or restarting; verification for resetting the app on devices with and without a screen lock.
- Uploading an AAB signed with the release keystore to the Play Console internal testing track.

### Engineering

- All five CI jobs (project, core, build-and-test, ios, android) pass on `macos-26`.
- A full `make mac-release` run: the DMG and `.env` land in `Build/macOS/Dist/`, and the build number increments in both `project.yml` and `project.pbxproj`. With `MAC_DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY` set, the archive is exported to `Build/macOS/Export/` and `Build/macOS/Release/Kakey.app` links to it.
- `make ios-device` and `ios-device-install` on a real device with the `Build/iOS/Device/` layout.

## Pre-Release Manual Checklist

Go through this before every release (these depend on real devices, system permissions, or other apps, which `make test` can't cover):

- Biometric unlock, and falling back to the password after canceling.
- Permission flows for camera and screen capture recognition (first grant, and granting after a denial).
- The current backup location: upload, restore on another device, and choosing a side in a conflict.
- Auto-lock and locking when the device locks.
- Mac Alfred integration (see above).
- Light and dark appearance and all three languages.

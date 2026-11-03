# Kakey iOS / iPadOS Technical Notes

> Implementation details of the `KakeyMobile` target shared by iPhone and iPad. For cross-platform contracts see [TECHNICAL](../../../docs/TECHNICAL.md) and [SECURITY](../../../docs/SECURITY.md); for interaction see [DESIGN](../../../docs/DESIGN.md); for the `Apple/Shared/` code shared with the Mac see [Mac TECHNICAL](../../Mac/docs/TECHNICAL.md).

## Project

- Target `KakeyMobile` (`Apple/project.yml`): iOS 17, device family iPhone + iPad, bundle ID `com.gicek.kakey`, product and module name `Kakey`.
- Sources: `Apple/iOS/` (platform-only), `Apple/Shared/` (shared), and `Build/Core/apple/KakeyCore.swift` (generated bindings). `KakeyCore.xcframework` is linked statically. Every `make ios-*` target depends on `make core-apple`.
- Build output: `make ios-simulator` uses `Build/iOS/Simulator/` and `make ios-device` uses `Build/iOS/Device/`, each with its own `DerivedData/`. `<Config>/Kakey.app` in each directory is a relative symlink into `DerivedData/Build/Products/`, and the install and run targets resolve it to the real path first. `make test-ios` builds into `Build/iOS/Simulator/Tests/`.
- XcodeGen generates Info.plist from `project.yml`. The camera and Face ID usage descriptions are English source strings, localized through `InfoPlist.xcstrings`. `UIBackgroundModes` includes `remote-notification`. `NSAllowsArbitraryLoads` allows the plaintext HTTP backup locations a user has confirmed; the real restriction is the origin check in the core's `cloudset`. `LSApplicationQueriesSchemes` is fixed to `dbapi-2` and `dbapi-8-emm`. The Makefile passes the `db-<app key>` scheme in `CFBundleURLTypes` from `cloud-keys.toml` (`IOS_CLOUD_FLAGS`, `scripts/cloud-config.py --xcode-settings`); without it, a placeholder is used. The iCloud entitlement (`KakeyICloud.entitlements`) is only in device builds with `DEVELOPMENT_TEAM` set; simulator and test builds don't have it.
- Orientation: iPhone supports portrait only. iPad supports all orientations, Split View, and Stage Manager.
- Icons: `scripts/export-app-icon.py` strips the alpha channel from `design/logo/kakey-logo-1024-background.png` to make the AppIcon. The in-app `BrandMark` uses the transparent version.
- The Debug-only `App/DemoVault.swift` reads launch arguments for screenshots and UI checks: `-KakeyDemoVault YES` (a demo vault in a temporary directory), `-KakeyDemoLocked`, `-KakeyDemoEmpty`, and `-KakeyDemoScreen <screen>`.

## Structure

```text
App/        KakeyMobileApp (scene lifecycle, auto-lock and device lock observers, URL callbacks, silent pushes), DemoVault (Debug only)
Store/      MobileVaultStore (@Observable, single source of truth) and its extensions, MobilePreferences
Services/   BiometricService (strings), DropboxAppAuthenticator, KeychainCloudConnectionStore,
            PlatformServices (local clipboard, privacy cover, haptics, Vision QR detection, device name)
Views/      RootView, Onboarding, Lock, Main (MainView, SidebarView, AccountListView, AccountRow, GridReorder, CategoryViews),
            Detail, Add (AddFlows, ScannerView), Settings (SettingsView, SyncLocationViews, ConflictResolutionScreen), Components
Tests/      MobileVaultStoreTests
scripts/    export-app-icon.py, screenshots.sh
```

- `MobileVaultStore` only orchestrates. It is split into extensions by concern: the main file (stored properties, injection and wiring, list reads, notices, save queue), `+Unlock` (create and unlock, biometrics, failed attempts, auto-lock, lock), `+Accounts` (including import and copy), `+Categories`, `+Vault` (change password, export, reset), and `+Sync` (backup locations, automatic and manual sync, conflicts, first-run restore, iCloud, history). Account editing, file IO, sync backends, and import/export all use the Shared implementations.
- Dependencies are injected (wired in `makeForApp()`): `VaultKeyStoring` (`KeychainVaultKeyStore`), `SettingsStore`, `SecretClipboard`, `BiometricAuthenticating`, `BiometricCapability` (probed once at launch), `ICloudVaultStoring` (nil when the build has no iCloud capability), the cloud connection store, `DropboxAppAuthenticating`, and a clock. The vault path goes through `VaultPersistenceService.vaultURLOverride`.
- `MobilePreferences` decodes each field with `decodeIfPresent`. A field that can't be read falls back to its default.

## Lifecycle

- **Auto-lock**: `UserActivityObserver`, a window-level gesture recognizer that only listens, records touches and hardware key presses as activity. When the scene returns to the foreground, the timer is checked again and the vault locks at once if time is up. `protectedDataWillBecomeUnavailableNotification` (the device locks with a passcode set) locks immediately.
- **Automatic biometric prompt**: the `autoBiometricPromptSuppressed` flag starts as false and turns true after any `lock()` or a user cancel, so only the lock screen right after launch prompts on its own.
- Argon2id derivation runs on the `VaultFileStore` actor. Saves and syncs are serialized through `SerialTaskQueue`; changing the password first waits for queued tasks to finish.
- "Reset App" goes through `resetApplicationAfterAuthentication()`: data is erased only after `.deviceOwnerAuthentication` succeeds. On `LAError.passcodeNotSet`, the confirmation dialog is the only check.

## Layout

- `MainView` picks the layout from the window's `horizontalSizeClass`. Compact width uses `NavigationStack` + `List`, with the section menu in the middle of the navigation bar; edit mode uses an injected `EditMode` the view owns (an `EditButton` inside a menu can't put "Done" at the top leading edge). Regular width uses a two-column `NavigationSplitView` (sidebar 200–300 pt) + `LazyVGrid` (three columns when the card area is at least 820 pt, otherwise two). Each column of a split view reports a compact size class of its own, so `MainView` passes the layout down explicitly.
- iPad card reordering: `onDrag` provides the private type `com.gicek.kakey.account-reorder` (declared in `UTExportedTypeDeclarations`, visible only to this process). The whole grid has a single `DropDelegate`, which moves the card within the `GridReorder` preview order based on the finger position and saves once on release; dragging out of the grid cancels. With a drop target per card, `performDrop` often doesn't fire where the finger lifts, so there is only one.
- The iPad search field is a custom text field in the toolbar, because the system `searchable` is pinned to the right of the button group on iPadOS 26.
- Confirmations (delete, reset, turning off backup, unencrypted connection, certificate trust) always use a centered `alert`, never `confirmationDialog`: on iOS 26 `confirmationDialog` becomes a popover pointing at empty space and has no Cancel button.
- `MainView` presents details through a single `.sheet(item:)` (containing a `NavigationStack`). Row countdowns use a per-row `TimelineView(.periodic(by: 1))`. Hardware shortcuts are registered with `keyboardShortcut` on invisible buttons. After a language change, the root view is rebuilt with `.id(language)`.

## Platform Capabilities

- **Biometrics**: `evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` runs first, then the same context reads the Keychain (`kSecUseAuthenticationContext`), so the user sees one prompt. `hasKey()` probes with an `interactionNotAllowed` context and shows no UI.
- **Scanning** (`ScannerView`): `AVCaptureSession` + `AVCaptureMetadataOutput` (QR only). Session start and stop are serialized on one background task chain. Each code is handled once while it stays in frame. Multi-part migration codes are merged by `MigrationBatchCollector`. Without a camera (the simulator), the view shows "Can’t open the camera".
- **Image detection**: `VNDetectBarcodesRequest`, with images from `PhotosPicker` (no photo library permission needed) or drag and drop.
- **Clipboard** (`LocalPasteboardClipboard`): `UIPasteboard.setItems(_:options:)` with `.localOnly` and `.expirationDate`.
- **Privacy cover** (`PrivacyCoverController`): while unlocked, when a scene leaves `.active`, a window at `windowLevel = .alert + 1` is added to each `UIWindowScene`, so sheets are covered too. Details also hide any revealed secret and QR code.
- **Folder sync**: the folder is picked with `fileImporter(.folder)`, and the Shared `SyncFolderService` stores a security-scoped bookmark (when the parent folder is picked, its `Kakey/` subfolder is used). Reads and writes go through `NSFileCoordinator`, so the system downloads iCloud Drive files that aren't local yet.
- **iCloud**: `KakeyMobileAppDelegate` (`@UIApplicationDelegateAdaptor`) receives silent pushes, syncs when it recognizes the subscription, and returns a `UIBackgroundFetchResult`.
- **Cloud storage**: the connection blob is a Keychain generic password item (`KeychainCloudConnectionStore`, `AfterFirstUnlockThisDeviceOnly`). Sign-in uses the Shared `SystemWebAuthenticator`, anchored to the current key window. Dropbox tries the official app first: `OfficialDropboxAppAuthenticator` checks `canOpenURL` on the `dbapi-2` / `dbapi-8-emm` URL the core provides and opens it. The callback arrives through `onOpenURL` and goes to `DropboxAppCallbacks`, which forwards only URLs the core confirms belong to the current sign-in. If the app can't be opened, sign-in falls back to the system authentication session.

## Tests

- `make test-ios`: the localization guard and swift-format, then `MobileVaultStoreTests` in the simulator. Coverage: first run and restore; create, lock, and unlock; failed attempts (only wrong passwords count); snapshot recovery; adding and deduplication; categories; search; importing Mac exports and Authenticator backups (golden samples); export round trips; auto-lock; biometrics and invalidated key material; prompt suppression; clipboard expiry; changing the master password; reset (including the fallback without a device passcode); sync (upload, fetch, conflicts, undecryptable remote, restore from a folder).
- The test host uses the `Test` configuration: the vault lives in a temporary directory, and `makeForApp()` wires an in-memory key store, in-memory settings, and stub authentication. The sync folder is a temporary directory and the clock is controllable.
- UI: `make ios-screenshots` captures every iPhone and iPad screen from the demo vault × light and dark appearance × three languages into `Build/Screenshots/ios/`.

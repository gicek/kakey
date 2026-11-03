# Kakey Mac Technical Notes

> Implementation details of the Mac app, for anyone changing `Apple/Mac/`. Cross-platform contracts are in [TECHNICAL](../../../docs/TECHNICAL.md) and [SECURITY](../../../docs/SECURITY.md), interaction is in [DESIGN](../../../docs/DESIGN.md), and the shared core is in [Core TECHNICAL](../../../Core/docs/TECHNICAL.md).

## Technology Choices

- **Swift 6 + SwiftUI in an AppKit shell**: AppKit sets up the menu bar `NSStatusItem`, an `NSPanel` that can take keyboard focus, global shortcuts, and the Dock policy. All content views are SwiftUI.
- **KeyboardShortcuts** manages global shortcuts (clearable, with a recorder UI).
- **Cocoa Scripting (`Kakey.sdef`) for automation**: macOS Automation TCC provides per-app authorization, so there's no custom IPC.

## Layout

```text
Views (SwiftUI) ──► VaultStore (@MainActor, ObservableObject, single source of truth) ──► Services ──► Core (Rust)
App layer (AppKit shell): KakeyApp / KakeyAppDelegate / MainWindowController / single instance / quit
```

- `App/`: `KakeyApp.swift` (scenes, `KakeyAppDelegate`, URL scheme, push, `AppTerminationController`) and `MainWindowController` (the only entry point for opening and positioning the main window; the window registers itself when mounted).
- `ViewModels/`: `VaultStore` is split into extension files by concern. The main file holds stored properties, injection and assembly, list reads, and the save queue. `+Lock` covers locking, auto-lock, and system lock observers; `+Unlock` covers master password and Touch ID unlock, failed attempts, vault creation, and password changes; then `+Accounts`, `+Categories`, `+ExportImport`, `+Sync` (backup location, iCloud push and account, restore, conflicts, history), `+Automation` (screen capture recognition, AppleScript, filter index, URL scheme), and `+Settings` (appearance, language, Dock, login item, reset). Properties that extensions share across files are module-internal; views only read them.
- `Views/`: one screen per file. Multi-step screens live in `AddAccount/`, `Onboarding/`, and `PermissionGuide/`; small cross-screen views live in `Components/` (`UnlockForm`, `LabeledSecureField`, `CodeWithCountdown`, `ReorderSession`, `SyncLocationPicker`, `WindowEventsView`, `SettingsComponents`, and others). Keep each view file under about 500 lines.
- `Services/`: system wiring only. `MacSystemIntegration` (Dock, login item, shortcuts, appearance, device name, push registration), `SecureEnclaveSealing` and the `SecureEnclaveVaultKeyStore` / `SecureEnclaveCloudConnectionStore` built on it, `PasteboardClipboard`, `BiometricAuthService`, `QRCodeService`, `ScreenCapturePermissionController` + `SystemSettingsWindow`, `MenuBarStatusItemController`, `DesktopToastController`, `AppleScriptCommands`, `AppShortcutListener` / `AppShortcutNames`, `AlfredWorkflowExporter`, `SearchIndexService`, `SystemDeviceService`.
- `Utilities/`: `KakeyStyle` (panel appearance differences across macOS versions), `RomanInputOnly` (keeps password fields on an English input source), `DisplayLinkAnimator`, `UnlockFeedback`, `OTPAuthTextDropResolver`.
- Shared with iOS (`Apple/Shared/`): `VaultDocument` (the unlocked accounts and categories with all edit operations, a value type), `VaultFileStore` (an actor that is the only reader and writer of the vault file; Argon2id runs on it), `Services/Sync/` (`SyncBackend` with folder, iCloud, and cloud storage implementations, the `CloudSetupModel` connection flow, `URLSessionHTTPExecutor`, `SystemWebAuthenticator`, `RestoreCloudConnections`, `SyncFolderService` bookmarks), `ExternalFileLimits` (16 MiB cap on external files), `UnlockLockout`, `MigrationBatchCollector` (combines multi-part Google migration codes), `BiometricAuth`, `VaultKeyStoring`, `SettingsStore`, `SecretClipboard`, `SerialTaskQueue`, and `CoreBridge` (`Core*` type conversion).

## Dependency Injection

`VaultStore` takes every dependency through its initializer, and `makeForApp()` assembles the production implementations: settings storage (`UserDefaults` / in-memory), key storage, clipboard, authentication, Touch ID probe, `MacSystemIntegration`, iCloud storage (nil when the build has no iCloud capability), cloud connection storage, HTTP executor, and clock. The core's `coreErrorL10nKey` supplies L10n keys for error messages; Swift only classifies errors by context.

## Linking the Shared Core

- `make core-apple` produces `Build/Core/apple/KakeyCore.xcframework` (static library) and `KakeyCore.swift`. `project.yml` links the XCFramework statically into the main executable (not embedded) and compiles the bindings as target sources in the same module.
- `make mac` / `make test-mac` depend on `make core-apple` and `make alfred-workflow` (which packages `Resources/Kakey.alfredworkflow`) automatically. Before building in the Xcode GUI, run both once by hand.

## Build Output

- `make mac` builds with `-derivedDataPath Build/macOS/DerivedData`. `Build/macOS/Debug/Kakey.app` (or `Release/Kakey.app` with `CONFIGURATION=Release`) is a relative symlink to `DerivedData/Build/Products/<Configuration>/Kakey.app`. Don't replace it with a copy: a second copy of the app makes Launch Services, the URL scheme, AppleScript, and TCC see two apps.
- `make test-mac` builds the test host in its own `Build/macOS/Tests/DerivedData` with the `Test` configuration, so test runs never replace the app product.

## Data and Settings

- For file locations, see "Persistence" in [DESIGN](../../../docs/DESIGN.md). The test host uses `$TMPDIR/kakey-testhost/` instead.
- `UserDefaults` keys: `usesCardView`, `hasCompletedOnboarding`, `dockIconMode`, `menuBarListScope`, `launchMinimized`, `alfredIntegrationEnabled`, `appearanceMode`, `languageMode`, `autoLockMode`, `syncLocation`, `touchIDUserEnabled`, `menuBarIconVisible`, `lockoutDelayEnabled`, `failedUnlockCount`, `lockoutUntil`, `syncLastSyncAt`, `syncLastRemoteVersion`, `syncLastLocalUpdatedAt`, plus KeyboardShortcuts' own shortcut entries. Unreadable values fall back to their defaults.
- `applicationDidFinishLaunching` reads "Background Launch Only" through `VaultStore.isLaunchMinimized(in:)` before the store is assembled, so the key is defined only once.

## Locking and Touch ID

- **Auto-lock**: on unlock, `lastActivityAt` (from the injected clock) is set to the unlock time and `scheduleAutoLock()` runs. A local `NSEvent` monitor (`keyDown`, mouse down, `scrollWheel`) only refreshes that time; it doesn't rebuild the timer. When the timer's `Task.sleep` ends, it rechecks against the latest time and sleeps again if there was activity. `observeSystemSleep()` locks immediately on `NSWorkspace` sleep, screen sleep, and session switch, and on the distributed notifications `com.apple.screenIsLocked` and `com.apple.screensaver.didstart`.
- **Touch ID material**: `SecureEnclaveVaultKeyStore` creates a Secure Enclave P-256 key (`.privateKeyUsage | .biometryCurrentSet`) and wraps the 32-byte vault key with ECIES into `biometric-key.json`. To unwrap, it calls `evaluatePolicy` first, then restores the key handle with the same `LAContext` for key agreement, so the user sees one prompt. It doesn't use the Keychain: items with biometric access control need the data protection Keychain and a Team-signed application identifier, and ad-hoc builds get `errSecMissingEntitlement` (-34018).
- **Availability**: `VaultStore.biometricsAvailable` is probed at launch through `BiometricCapability.current`, and probed again in the background on `NSApplication.didBecomeActiveNotification` (`canEvaluatePolicy` is a synchronous XPC call). New triggers are ignored while a probe is running. When Touch ID becomes available while unlocked and no material exists, the material is stored; when it becomes unavailable, only the gate changes. Opening the menu bar panel doesn't activate the app, so it doesn't trigger a probe.
- Touch ID prompts automatically only the first time the lock screen appears after launch; every lock while running sets a suppression flag.

## Clipboard

`PasteboardClipboard` writes `public.utf8-plain-text` and declares `org.nspasteboard.ConcealedType` and `TransientType`. It clears the pasteboard on expiry (one period for codes, 60 seconds for otpauth URIs) if `changeCount` still matches its own write.

## Cloud Storage and iCloud

- `SyncLocation` (Shared, stored under the settings key `syncLocation`) picks the backend: `FolderSyncBackend` (the Mac isn't sandboxed, so the bookmark only tracks folder renames and moves), `ICloudSyncBackend`, or `CloudSyncBackend`.
- **iCloud**: `ICloudSyncBackend` reads and writes through the narrow `ICloudVaultStoring` interface. The production implementation is `CloudKitVaultStore` (an actor; a conditional write modifies the server record it read and saves with `ifServerRecordUnchanged`; if the zone is missing or deleted, it recreates the zone and writes once more). Tests use `MemoryICloudVaultStore`. `ICloudSyncError.from` maps `CKError` to UI messages. The container comes from `KakeyICloudContainer` in Info.plist (empty in ad-hoc builds, which disables iCloud). `linkICloud()` checks the account status and user record name before linking; `enableICloudPush()` registers for push and subscribes; `KakeyAppDelegate.application(_:didReceiveRemoteNotification:)` recognizes the subscription and syncs; `.CKAccountChanged` triggers an account check.
- **Cloud storage**: the connection flow is in the shared `CloudSetupModel` (`@Observable`, used by both Mac and iOS), and networking is in `CloudSetupService`. `SystemWebAuthenticator` opens the sign-in page (`ASWebAuthenticationSession`, not ephemeral). The core's `coreCloudOauthProviders` decides which providers are offered. `URLSessionHTTPExecutor` gives each request its own task delegate: it refuses automatic redirects (the core decides on 3xx itself) and, for a WebDAV or Nextcloud connection with a pinned certificate, accepts a server certificate the system doesn't trust only when its SHA-256 fingerprint matches the pin (constant-time comparison); a mismatch is reported as a changed certificate. `SecureEnclaveCloudConnectionStore` keeps the connection blob (it requires only `.privateKeyUsage`, so no Touch ID prompt) in `cloud-connection.json`, which reset deletes.

## Automation

- `copy code <id>` and `find accounts <query>` are in `AppleScriptCommands.swift`; behavior and security constraints are in SECURITY. `performDefaultImplementation` is inherited from the nonisolated `NSScriptCommand`, and Cocoa Scripting dispatches on the main thread, so reads of `VaultStore` use `MainActor.assumeIsolated`.
- The filter index in `SearchIndexService` exists only in `VaultStore` memory (id, service name, account name) and isn't built when the master switch is off. `find accounts` and the main window search both use the core's `coreMatchesSearch`.
- The Alfred workflow scripts (`scripts/alfred/search.py`, `reveal.sh`) ship only inside the `.alfredworkflow`:
  - The Script Filter runs on every keystroke. It first checks whether Kakey is running with `pgrep -x Kakey` (`tell application "Kakey"` itself would launch the app) and shows only a guide item when it isn't.
  - On AppleScript error `-1743` (Automation not authorized), it shows a guide item; Return opens the Automation pane in System Settings. Without this, `kk` would fail silently forever after the user declines once.
  - After a successful copy, `copy code` returns the code, and `reveal.sh` passes it to Alfred's "Post Notification" node.
  - `scripts/build-alfred-workflow.py` writes the strings in all three languages from the String Catalog into placeholders in the scripts at packaging time; `AlfredWorkflowTests` checks the package.
- Cold launch: when an Apple Event cold-launches the app, SwiftUI creates no default window, so `applicationDidFinishLaunching` runs a fallback setup that doesn't depend on the main window. If the first `copy code` arrives within 3 seconds of launch while locked and the main window is visible, the window goes to the Dock before the Touch ID prompt. "Background Launch Only" avoids the flash entirely.

## Concurrency and Lifecycle

- UI and `VaultStore` run on `@MainActor`; file IO runs on the `VaultFileStore` actor. `SerialTaskQueue` serializes saves and syncs in the order they start. Before a password change, `drain()` waits for queued tasks, then the latest file content is re-encrypted.
- Single instance: at launch, if another instance with the same bundle ID is running, the app activates it and quits. Quitting always goes through `AppTerminationController`, which dismisses SwiftUI sheets before terminating.
- Per-second refresh is limited to codes and countdowns: each `CodeWithCountdown` instance has its own `TimelineView` aligned to whole seconds. Don't hang a shared timer on an outer view: a parent rebuild resets it, and it redraws the whole screen every second. Rows and cards don't observe `VaultStore`; they receive state by value.
- **Drag to reorder** (`ReorderSession<ID>`, shared by the account list / cards and the sidebar categories) doesn't use a system drag session, so dropping onto another app produces nothing. Rows attach `DragGesture(minimumDistance: 4)`, and the container declares a coordinate space and collects row frames. Moving only changes the session's preview order; `onEnded` commits once inside the container and cancels outside it; Esc cancels through a local key monitor. The drag image is an overlay on the container with its position in a separate state object, so pointer moves don't redraw the list. Hovering in the 44 pt zones at the top and bottom auto-scrolls, driven by a `TimelineView(.periodic)` every 0.16 seconds. The pure calculations and the session state machine have unit tests.
- **Menu bar panel** (`MenuBarStatusItemController`): the `.nonactivatingPanel` becomes key itself, and `showPanel()` doesn't call `NSApp.activate`. Content is built once; hiding only calls `orderOut` and tells the panel to clear transient state. The panel records the language and color scheme it was built with and rebuilds only when they change. `CodeWithCountdown` stops producing frames while hidden. Only ↑↓ trigger programmatic scrolling. Hover uses `onContinuousHover` with row height math, and `ListHoverTracker` updates only when the pointer actually moves on screen. The context menu is a standard `NSMenu` (temporarily attached to the status item, `performClick`, then detached). The menu bar icon uses a fixed `autosaveName`; otherwise its position can fall into the hidden area next to the notch.
- **Panel appearance** lives only in `KakeyStyle.swift`: macOS 26 uses `NSGlassEffectView` over a same-shaped layer at 4% opacity (without it, a borderless window can't compute a shadow); macOS 14–25 use the `.menu` material plus window background color; with Reduce Transparency on, the background is opaque.
- All window events go through `WindowEventsView`. Focus requests are deferred to the next run loop turn (`Task { @MainActor in }`), not a fixed delay.
- The title-bar-less style of onboarding and the lock screen is declared only with SwiftUI toolbar modifiers (`toolbar(removing: .title)` on macOS 15 and later, an empty `navigationTitle` on 14), with `VaultStore.showsImmersiveMainWindow` as the only condition. Don't change window properties from AppKit; SwiftUI reverts them on update.
- Camera scanning: the AVFoundation pipeline is a `Sendable` object. Sample callbacks run on the serial queue that `AVCaptureVideoDataOutput` requires (GCD is used only where AppKit or AVFoundation requires it), and results return to the main actor through a `@Sendable` callback.
- Remaining polling (all bounded): Screen Recording authorization every 0.5 seconds (TCC posts no change notification); the guide card follows the System Settings window every 120 ms (cross-process window moves have no public notification; it stops when System Settings quits). The fly-in animation advances frame by frame with `CADisplayLink`.

## Localization

- `Localizable.xcstrings` + `InfoPlist.xcstrings` compile into per-language `.lproj` folders at build time (English plurals also produce a `.stringsdict`).
- `L10n` switches language at run time by loading the `.lproj` sub-bundle for the language code. `L10n.format` takes the template directly and calls `String(format:locale:)`, which keeps plural rules.
- `LocalizationTests` checks English plurals, positional placeholders, and translations of core error codes.

## Tests

- `Tests/` (XCTest): `GoldenVectorTests` (the wrapper layer matches `Core/golden/`); `VaultStoreTests` (in-memory settings, in-memory key storage, a recording clipboard, stub authentication, a no-op system integration, a temporary directory, and a controllable clock; covers locking, auto-lock, failed attempts, password changes, Touch ID material, snapshot restore, sync and conflicts, and reset); `CloudSyncBackendTests` (an in-memory WebDAV server drives the real core), `ICloudSyncBackendTests` (in-memory CloudKit), `URLSessionHTTPExecutorTests` (`URLProtocol` stub). Other tests cover parsing, password rules, error mapping, settings storage, drop import, reorder math, localization, and Alfred packaging.
- The test host is the full app (`Test` configuration, bundle ID `com.gicek.kakey.testhost`): the single-instance check doesn't hit a Kakey running on the same Mac, the UserDefaults domain is separate from the real app's, the vault directory is a temporary directory, no menu bar icon is installed, and key storage is in memory.

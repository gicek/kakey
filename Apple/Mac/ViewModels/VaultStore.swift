import CryptoKit
import SwiftUI

/// The Mac's single source of truth: lock session, accounts and categories, appearance / language / lock policy, and backups.
///
/// Account and category editing lives in the shared `VaultDocument`, file IO goes through the `VaultFileStore` actor, and sync goes
/// through `SyncBackend`. Settings storage, key storage, clipboard, authentication, AppKit capabilities and the clock are all
/// injected, so unit tests use in-memory implementations.
///
/// This file holds only stored properties, assembly and saving; each concern lives in an extension in `VaultStore+*.swift`.
/// State and dependencies that extensions access across files must be module-visible, so the properties below are not `private` /
/// `private(set)`; views still only read them.
@MainActor
final class VaultStore: ObservableObject {
    /// Accounts and categories after unlocking; when the selected category is deleted (including disappearing after a sync download),
    /// the selection returns to "All".
    @Published var document = VaultDocument() {
        didSet {
            if !document.contains(selectedSection) {
                selectedSection = .all
            }
        }
    }
    @Published var selectedSection: VaultSection = .all
    @Published var searchText = ""
    @Published var usesCardView: Bool {
        didSet {
            settings.set(usesCardView, forKey: Self.usesCardViewKey)
        }
    }
    @Published var activeSheet: ActiveSheet?
    @Published var isLocked = false
    /// First-run restore is finding / fetching a backup. Meanwhile onboarding cannot be left and `createVault` refuses to run;
    /// otherwise completing the fetch would wipe the in-memory state and Touch ID material of a just-created vault.
    @Published var isFetchingOnboardingRestore = false
    @Published var hasCompletedOnboarding: Bool {
        didSet {
            settings.set(hasCompletedOnboarding, forKey: Self.hasCompletedOnboardingKey)
        }
    }
    /// Touch ID unlock switch (on by default); key material is actually saved only when the hardware is available and the vault is
    /// unlocked.
    @Published var touchIDEnabled: Bool {
        didSet {
            settings.set(touchIDEnabled, forKey: Self.touchIDEnabledKey)
            if touchIDEnabled {
                Task { await persistKeyForTouchID() }
            } else {
                keyStore.remove()
                biometricKeyAvailable = false
            }
        }
    }
    /// Whether Touch ID material is usable on this Mac; once invalidated (fingerprints changed, file corrupt) it takes one master
    /// password unlock to save it again.
    @Published var biometricKeyAvailable = false
    @Published var backupStatus: BackupStatus {
        // Leaving the conflict state (resolved, turned off, resynced) drops the cached backup, so the conflict page never gets stale
        // content.
        didSet { if backupStatus != .conflict { conflictRemote = nil } }
    }
    /// The current backup location; nil when backups are off.
    @Published var syncLocation: SyncLocation?
    @Published var backupHistory: [BackupHistoryItem] = []
    @Published var selectedSettingsPanel: SettingsPanel = .general
    @Published var dockIconMode: DockIconMode {
        didSet {
            settings.set(dockIconMode.rawValue, forKey: Self.dockIconModeKey)
            // The reverse of the menu bar icon guard: choosing "Never" for the Dock forces the menu bar icon back on.
            if dockIconMode == .never, !menuBarIconVisible {
                menuBarIconVisible = true
            }
            applyDockIconPolicy()
        }
    }
    /// Whether the menu bar panel shows all accounts or one category. Only the category ID is stored; a missing category shows "All".
    @Published var menuBarListScope: MenuBarListScope {
        didSet {
            settings.set(menuBarListScope.rawValue, forKey: Self.menuBarListScopeKey)
        }
    }
    /// When on, the main window never appears at launch: `AppLaunchInfo.shouldSuppressWindowOpen` closes any main window that attaches
    /// or becomes key during the launch grace period, before it reaches the screen, so it does not flash.
    /// Only affects that launch; reopening the main window manually afterwards is unaffected.
    @Published var launchMinimized: Bool {
        didSet {
            settings.set(launchMinimized, forKey: Self.launchMinimizedKey)
        }
    }
    /// Off by default: the master switch for Alfred `kk` search / copy. While off, `find accounts` never builds the non-secret
    /// in-memory cache and `copy code` refuses outright, so the majority of users who never turned the feature on have none of this
    /// attack surface (even though it is already limited to automation apps approved through TCC). Turning it on while unlocked builds
    /// the cache immediately instead of waiting for the next unlock; turning it off clears the existing cache immediately.
    @Published var alfredIntegrationEnabled: Bool {
        didSet {
            settings.set(alfredIntegrationEnabled, forKey: Self.alfredIntegrationEnabledKey)
            if alfredIntegrationEnabled {
                if !isLocked {
                    refreshSearchIndex()
                }
            } else {
                searchIndexEntries = []
                hasPopulatedSearchIndex = false
            }
        }
    }
    @Published var appearanceMode: AppearanceMode {
        didSet {
            settings.set(appearanceMode.rawValue, forKey: Self.appearanceModeKey)
            applyAppearance()
        }
    }
    @Published var languageMode: LanguageMode {
        didSet {
            settings.set(languageMode.rawValue, forKey: Self.languageModeKey)
            applyLanguage()
        }
    }
    @Published var autoLockMode: AutoLockMode {
        didSet {
            settings.set(autoLockMode.rawValue, forKey: Self.autoLockModeKey)
            // Recheck against the last activity time: if the new duration has already passed, lock immediately.
            scheduleAutoLock()
        }
    }
    /// Launch at login switch. The real state comes from `SMAppService.mainApp`; when registration fails, the system state is read
    /// back and an error is reported.
    @Published var launchAtLoginEnabled: Bool {
        didSet {
            guard !isSyncingLaunchAtLogin, oldValue != launchAtLoginEnabled else { return }
            applyLaunchAtLogin()
        }
    }
    @Published var launchAtLoginError: String?
    /// Whether the menu bar icon is shown, bound to `MenuBarExtra(isInserted:)`.
    /// It cannot be `@Published`: SwiftUI writes the current value back into the binding on every scene update, and `@Published`
    /// sends objectWillChange even for identical values, causing an endless scene rebuild loop. It publishes manually and silently
    /// swallows write-backs of an unchanged value.
    var menuBarIconVisible: Bool {
        get { menuBarIconVisibleStorage }
        set {
            guard newValue != menuBarIconVisibleStorage else { return }
            objectWillChange.send()
            menuBarIconVisibleStorage = newValue
            settings.set(newValue, forKey: Self.menuBarIconVisibleKey)
            // The menu bar icon and the Dock icon cannot both be hidden, or the app could no longer be reached.
            if !newValue, dockIconMode == .never {
                dockIconMode = .mainWindowOnly
            }
        }
    }
    private var menuBarIconVisibleStorage: Bool
    /// Progressive delay after repeated wrong master passwords, following the core rules; turning it off requires Touch ID or the
    /// system password on the spot (`setLockoutDelayEnabled`).
    @Published var lockoutDelayEnabled: Bool
    /// The color scheme in effect; following the system still resolves to a concrete light / dark so switching is immediate.
    @Published var resolvedColorScheme: ColorScheme = .light
    /// Incremented on language changes to force the UI to rebuild with the new bundle.
    @Published var languageRevision = 0
    @Published var isMainWindowUnlockRevealSuspended = false

    /// The main window is showing the lock screen (after onboarding, while locked, or briefly held after a menu bar unlock).
    var showsMainWindowLockScreen: Bool {
        hasCompletedOnboarding && (isLocked || isMainWindowUnlockRevealSuspended)
    }

    /// The main window shows an immersive page (onboarding and lock screen): no title bar, content extends under the traffic lights
    /// (see `immersiveWindowChrome()`).
    var showsImmersiveMainWindow: Bool {
        !hasCompletedOnboarding || showsMainWindowLockScreen
    }
    @Published var pendingCaptureImportResult: CaptureImportResult?
    /// Copy requests triggered by the URL scheme are queued while locked; after unlocking, the lock screen view consumes them and
    /// shows a toast.
    @Published var pendingCopyResultIssuer: String?
    @Published var copiedAccountID: Account.ID?
    @Published var vaultError: String?
    /// True when the main file is corrupt and a last-known-good snapshot exists; the lock screen offers "Restore Good Copy".
    @Published var lastKnownGoodRestoreAvailable = false
    /// A slow operation is running: unlock, password change, import / export, and so on (Argon2id runs on a background actor).
    @Published var isWorking = false

    private static let usesCardViewKey = "usesCardView"
    private static let hasCompletedOnboardingKey = "hasCompletedOnboarding"
    private static let dockIconModeKey = "dockIconMode"
    private static let menuBarListScopeKey = "menuBarListScope"
    static let launchMinimizedKey = "launchMinimized"
    private static let alfredIntegrationEnabledKey = "alfredIntegrationEnabled"
    private static let appearanceModeKey = "appearanceMode"
    private static let languageModeKey = "languageMode"
    private static let autoLockModeKey = "autoLockMode"
    /// The backup location (`SyncLocation` as JSON); the key is absent when not configured.
    static let syncLocationKey = "syncLocation"
    private static let touchIDEnabledKey = "touchIDUserEnabled"
    private static let menuBarIconVisibleKey = "menuBarIconVisible"
    static let lockoutDelayEnabledKey = "lockoutDelayEnabled"
    static let failedUnlockCountKey = "failedUnlockCount"
    static let lockoutUntilKey = "lockoutUntil"
    static let lastBackupSyncAtKey = "syncLastSyncAt"
    static let lastRemoteVersionKey = "syncLastRemoteVersion"
    static let lastLocalUpdatedAtKey = "syncLastLocalUpdatedAt"
    static let allSettingsKeys = [
        usesCardViewKey, hasCompletedOnboardingKey, dockIconModeKey, menuBarListScopeKey, launchMinimizedKey,
        alfredIntegrationEnabledKey, appearanceModeKey, languageModeKey, autoLockModeKey, syncLocationKey,
        touchIDEnabledKey, menuBarIconVisibleKey, lockoutDelayEnabledKey, failedUnlockCountKey, lockoutUntilKey,
        lastBackupSyncAtKey, lastRemoteVersionKey, lastLocalUpdatedAtKey,
    ]

    let settings: any SettingsStore
    let keyStore: any VaultKeyStoring
    let clipboard: any SecretClipboard
    let authenticator: any BiometricAuthenticating
    let system: any MacSystemIntegration
    let files: VaultFileStore
    /// CloudKit storage for iCloud backups; nil when the build has no iCloud capability; tests inject an in-memory implementation.
    let iCloud: (any ICloudVaultStoring)?
    /// Storage for the cloud storage connection blob and the HTTP executor (tests inject in-memory implementations and an in-memory
    /// WebDAV server).
    let cloudConnections: any CloudConnectionStoring
    let httpExecutor: any HTTPExecuting
    /// Whether Touch ID is usable (hardware present and enrolled). Probed once at launch, then re-checked in the background only when
    /// the app becomes active (`refreshBiometricsAvailability()`); never polled. The UI always reads this and never calls
    /// `canEvaluatePolicy`.
    @Published var biometricsAvailable: Bool
    /// Probes Touch ID availability again. The real implementation is a synchronous XPC call, so it is only called on a background
    /// thread. Tests inject a fixed or mutable value.
    let detectBiometrics: @Sendable () -> Bool
    var biometricsRefreshTask: Task<Void, Never>?
    var appActivationObserver: NSObjectProtocol?
    let now: @Sendable () -> Date
    /// Saves and syncs run serially in the order they were started.
    let persistence = SerialTaskQueue()

    var vaultKey: SymmetricKey?
    var pendingCaptureAccountsAfterPasswordUnlock: [ParsedOTPAuth] = []
    var pendingCopyAccountIDAfterUnlock: UUID?
    var lastTouchIDErrorWasUserFallback = false
    /// Whether the automatic Touch ID prompt is suppressed: true after a manual lock, or after the user cancels / switches to the
    /// password in the prompt; reset to false on a natural lock (launch, timeout, sleep). Affects only the automatic prompt, not
    /// clicking the Touch ID button.
    var autoTouchIDSuppressed = false
    /// The encrypted backup fetched by first-run "Restore from Backup", not yet confirmed with the master password; onboarding uses it
    /// to switch to the password step.
    @Published var pendingOnboardingRestore: PendingOnboardingRestore?
    /// The Kakey encrypted export file chosen during first run: its content lives only in memory, and after the export password is
    /// entered it is used to create the vault. At most one of this and `pendingOnboardingRestore` is non-nil at a time.
    @Published var pendingOnboardingExport: PendingOnboardingExport?
    /// Non-secret index cache read by the `find accounts` AppleScript command. Memory only; not cleared by Hard Lock (so search works
    /// while locked), only by `resetApplication()`.
    var searchIndexEntries: [SearchIndexService.Entry] = []
    var hasPopulatedSearchIndex = false
    var isMainWindowOpen = false
    var isSyncingLaunchAtLogin = false
    var isUnlocking = false
    var isRekeying = false
    var systemThemeObserver: NSObjectProtocol?
    var systemLocaleObserver: NSObjectProtocol?
    var systemSleepObservers: [NSObjectProtocol] = []
    /// Time of the last activity (injected clock): the unlock time at unlock, refreshed on every activity afterwards, and used to
    /// compute auto-lock; nil once locked.
    var lastActivityAt: Date?
    var userActivityMonitor: Any?
    var autoLockTask: Task<Void, Never>?
    /// Coalesces automatic sync to 2 seconds after a save (consecutive edits sync once).
    var syncDebounceTask: Task<Void, Never>?
    var syncBackend: (any SyncBackend)?
    /// The backup read when the conflict was last detected: the conflict page compares against it without downloading again (the
    /// merge upload does a conditional write against its version).
    var conflictRemote: RemoteVaultSnapshot?
    var syncBackendLocation: SyncLocation?
    var iCloudAccountObserver: NSObjectProtocol?

    init(
        settings: any SettingsStore,
        keyStore: any VaultKeyStoring,
        clipboard: any SecretClipboard,
        authenticator: any BiometricAuthenticating,
        system: any MacSystemIntegration,
        biometricsAvailable: Bool,
        detectBiometrics: (@Sendable () -> Bool)? = nil,
        files: VaultFileStore = .shared,
        iCloud: (any ICloudVaultStoring)? = nil,
        cloudConnections: any CloudConnectionStoring = InMemoryCloudConnectionStore(),
        httpExecutor: any HTTPExecuting = URLSessionHTTPExecutor(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.settings = settings
        self.keyStore = keyStore
        self.clipboard = clipboard
        self.authenticator = authenticator
        self.system = system
        self.biometricsAvailable = biometricsAvailable
        self.detectBiometrics = detectBiometrics ?? { biometricsAvailable }
        self.files = files
        self.iCloud = iCloud
        self.cloudConnections = cloudConnections
        self.httpExecutor = httpExecutor
        self.now = now

        let hasVault = VaultPersistenceService.vaultExists
        // Cards by default; an explicit choice of the list is kept.
        self.usesCardView = settings.object(forKey: Self.usesCardViewKey) as? Bool ?? true
        self.hasCompletedOnboarding = hasVault
        self.isLocked = hasVault
        self.touchIDEnabled = settings.object(forKey: Self.touchIDEnabledKey) as? Bool ?? true
        let syncLocation = SyncLocation.decode(settings.data(forKey: Self.syncLocationKey))
        self.syncLocation = syncLocation
        self.backupStatus =
            syncLocation != nil
            ? .enabled(lastBackup: settings.date(forKey: Self.lastBackupSyncAtKey) ?? now())
            : .disabled
        self.dockIconMode = DockIconMode(rawValue: settings.string(forKey: Self.dockIconModeKey) ?? "") ?? .mainWindowOnly
        self.menuBarListScope = MenuBarListScope(storedValue: settings.string(forKey: Self.menuBarListScopeKey))
        self.launchMinimized = Self.isLaunchMinimized(in: settings)
        self.alfredIntegrationEnabled = settings.bool(forKey: Self.alfredIntegrationEnabledKey)
        self.appearanceMode = AppearanceMode(rawValue: settings.string(forKey: Self.appearanceModeKey) ?? "") ?? .system
        self.languageMode = LanguageMode(rawValue: settings.string(forKey: Self.languageModeKey) ?? "") ?? .system
        self.autoLockMode = AutoLockMode(rawValue: settings.string(forKey: Self.autoLockModeKey) ?? "") ?? .fiveMinutes
        self.launchAtLoginEnabled = system.isLaunchAtLoginEnabled
        self.menuBarIconVisibleStorage = settings.object(forKey: Self.menuBarIconVisibleKey) as? Bool ?? true
        self.lockoutDelayEnabled = settings.object(forKey: Self.lockoutDelayEnabledKey) as? Bool ?? true
        self.backupHistory = BackupHistoryStore.load()
        self.biometricKeyAvailable = biometricsAvailable && touchIDEnabled && keyStore.hasKey()
        observeSystemThemeChanges()
        observeSystemLocaleChanges()
        observeSystemSleep()
        observeAppActivationForBiometrics()
        observeUserActivity()
        observeICloudAccount()
        applyLanguage()
        applyAppearance()
        // `didSet` does not fire for assignments in the class's own init (Swift semantics), so the `dockIconMode = ...` line above
        // does not call `applyDockIconPolicy()`. With "Launch to menu bar only" the main window never opens, so
        // `mainWindowDidOpen()` never applies it either; call it explicitly here, or the activation policy would stay at the default
        // `.regular` and the Dock icon would not hide when it should.
        applyDockIconPolicy()
        if syncLocation?.isICloud == true { enableICloudPush() }
        Self.shared = self
    }

    /// Default assembly for the real app and the test host: the test host never touches Secure Enclave material.
    static func makeForApp() -> VaultStore {
        VaultStore(
            settings: UserDefaults.standard,
            keyStore: AppEnvironment.isTestHost ? InMemoryVaultKeyStore() : SecureEnclaveVaultKeyStore(),
            clipboard: PasteboardClipboard.shared,
            authenticator: BiometricAuthService.authenticator,
            system: AppKitSystemIntegration(),
            biometricsAvailable: BiometricCapability.current.isAvailable,
            detectBiometrics: { BiometricCapability.detect().isAvailable },
            iCloud: AppEnvironment.isTestHost ? nil : ICloudVault.makeLiveStore(),
            cloudConnections: AppEnvironment.isTestHost ? InMemoryCloudConnectionStore() : SecureEnclaveCloudConnectionStore()
        )
    }

    /// The app is single-instance and this lives as long as the process; lets entry points that cannot use SwiftUI environment
    /// injection (AppleScript NSScriptCommand) read the current state. Assigned exactly once at the end of `init()`.
    static weak var shared: VaultStore?

    /// The "Launch to menu bar only" switch; `applicationDidFinishLaunching` reads it before the store is assembled, so the key is
    /// defined only here.
    static func isLaunchMinimized(in settings: any SettingsStore) -> Bool {
        settings.bool(forKey: launchMinimizedKey)
    }

    // MARK: - Reading

    var accounts: [Account] { document.accounts }
    var categories: [AccountCategory] { document.categories }

    var sectionAccounts: [Account] {
        document.accounts(in: selectedSection)
    }

    var filteredAccounts: [Account] {
        sectionAccounts.filter { $0.matchesSearch(searchText) }
    }

    /// The category the menu bar panel actually shows; nil when the category chosen in Settings no longer exists (shows "All").
    var menuBarCategory: AccountCategory? {
        guard case .category(let id) = menuBarListScope else { return nil }
        return document.category(id)
    }

    var menuBarAccounts: [Account] {
        guard let menuBarCategory else { return accounts }
        return document.accounts(in: .category(menuBarCategory.id))
    }

    func category(_ id: AccountCategory.ID) -> AccountCategory? {
        document.category(id)
    }

    func isAccount(_ accountID: Account.ID, in categoryID: AccountCategory.ID) -> Bool {
        document.isAccount(accountID, in: categoryID)
    }

    /// The vault file and its directory, for showing and opening "Storage Location" in Settings, so views do not depend on the
    /// persistence service directly.
    var vaultFileURL: URL { VaultPersistenceService.vaultURL }
    var vaultDirectoryURL: URL { VaultPersistenceService.vaultDirectoryURL }

    // MARK: - Saving

    /// When unlocked, rewrites the vault with the current key (keeping the salt and KDF metadata, only changing the nonce), queued in
    /// the order started and followed by one coalesced sync.
    func saveVault() {
        guard let vaultKey else { return }
        let snapshot = document.contents
        let files = files
        refreshSearchIndex()
        persistence.enqueue { [weak self] in
            do {
                try await files.save(snapshot, key: vaultKey)
                self?.vaultError = nil
                self?.scheduleAutomaticSync()
            } catch {
                self?.vaultError = error.localizedDescription
            }
        }
    }

    /// Waits until all queued saves and syncs complete (tests, before quitting).
    func waitForPendingPersistence() async {
        await persistence.drain()
    }

    func canWriteVault() -> Bool {
        guard !isLocked, vaultKey != nil, !isRekeying else {
            vaultError = L10n.tr("Unlock Kakey first")
            return false
        }
        return true
    }
}

import CryptoKit
import Foundation
import Observation
import UIKit

/// Single source of truth for iOS / iPadOS: lock session, account editing, auto-lock, sync, and import/export.
///
/// Account and category edits live in the shared `VaultDocument`, file IO goes through the `VaultFileStore` actor, and sync goes
/// through `SyncBackend` (all shared with the Mac). Keychain, preference storage, pasteboard, authentication, biometric capability,
/// and the clock are injected, so tests never touch real system state.
///
/// This file holds only stored properties, wiring, list reads, and saving; each concern lives in a `MobileVaultStore+*.swift`
/// extension. State and dependencies the extensions access across files must be module-visible, so the properties below have no
/// `private` / `private(set)`; views still treat them as read-only.
@MainActor
@Observable
final class MobileVaultStore {
    enum Phase: Equatable {
        case onboarding
        case locked
        case unlocked
    }

    enum SyncStatus: Equatable {
        case notConfigured
        case idle
        case running
        case conflict
        /// This device's key cannot decrypt the remote backup: sync stops and the only way forward is "Restore from Backup".
        case unreadable
        case failed(String)
    }

    struct Toast: Equatable, Identifiable {
        let id = UUID()
        var message: String
        var systemImage: String
    }

    var phase: Phase
    /// Accounts and categories after unlock; if the current section's category is deleted (including disappearing after a sync
    /// download), the section falls back to All.
    var document = VaultDocument() {
        didSet {
            if !document.contains(section) {
                section = .all
            }
        }
    }
    var isWorking = false
    var unlockError: String?
    var syncStatus: SyncStatus = .notConfigured {
        // Drop the cached backup when leaving the conflict (resolved, disabled, or re-synced) so the conflict screen never gets
        // stale content
        didSet { if syncStatus != .conflict { conflictRemote = nil } }
    }
    var syncHistory: [BackupHistoryItem] = []
    /// After biometrics become invalid (for example, re-enrolled), one master password unlock is required before re-enabling.
    var biometricKeyAvailable = false
    /// Whether the automatic biometric prompt is suppressed: true after any lock, after it has prompted once, or after the user
    /// cancels / picks the password in the system prompt; false at launch and after a reset.
    var autoBiometricPromptSuppressed = false
    /// True when the main file is corrupt and a last-known-good snapshot exists; the lock screen offers to restore it.
    var lastKnownGoodRestoreAvailable = false
    /// The last first-run restore failed because the location had no backup; onboarding then offers "Choose Folder" next to the
    /// cloud storage.
    var restoreMissedBackup = false
    /// Kakey export file chosen during first-run restore; onboarding then asks for the export password and, once it decrypts,
    /// creates a new vault with it as the master password.
    var pendingOnboardingExport: PendingOnboardingExport?
    /// Backup fetched during first-run restore (same as the Mac). Kept only in memory and written to disk, with the location
    /// enabled, only after it decrypts with its original master password on the restore screen; a user who cannot remember the
    /// password can still go back to onboarding to pick another source or create a new vault.
    var pendingOnboardingRestore: PendingOnboardingRestore?
    /// The device's biometric capability, probed once at launch (views never call `canEvaluatePolicy`).
    let biometrics: BiometricCapability
    var section: VaultSection = .all
    var searchText = ""
    var toast: Toast?
    var preferences: MobilePreferences {
        didSet {
            preferences.save(to: settings)
            if preferences.language != oldValue.language {
                L10n.apply(languageMode: preferences.language)
            }
            if preferences.autoLock != oldValue.autoLock {
                scheduleAutoLock()
            }
        }
    }

    var key: SymmetricKey?
    /// Time of the last activity (injected clock): the unlock time right after unlocking, then refreshed on every touch / key press;
    /// auto-lock is computed from it. Nil when locked. Not observed: it is written on every touch and must not trigger redraws.
    @ObservationIgnored var lastActivityAt: Date?
    /// Timer that locks on time in the foreground; the process is suspended in the background, so `willEnterForeground` re-checks
    /// on return.
    var autoLockTask: Task<Void, Never>?
    /// Coalesces automatic sync into one run 2 seconds after saving.
    var syncDebounceTask: Task<Void, Never>?
    var syncBackend: (any SyncBackend)?
    /// Backup read when the conflict was last detected: the conflict screen compares against it without downloading again (a merged
    /// upload writes conditionally against its version).
    var conflictRemote: RemoteVaultSnapshot?
    var syncBackendLocation: SyncLocation?
    @ObservationIgnored var iCloudAccountObserver: NSObjectProtocol?
    let settings: any SettingsStore
    let keyStore: any VaultKeyStoring
    let clipboard: any SecretClipboard
    /// On-the-spot re-authentication before destructive actions such as reset (Face ID / Touch ID or device passcode).
    let authenticator: any BiometricAuthenticating
    let files: VaultFileStore
    /// Storage for the cloud storage connection blob and HTTP execution (tests inject in-memory and in-memory WebDAV
    /// implementations).
    let cloudConnections: any CloudConnectionStoring
    let httpExecutor: any HTTPExecuting
    /// CloudKit store for the iCloud backup; nil when the build lacks the iCloud capability, in-memory in tests.
    let iCloud: (any ICloudVaultStoring)?
    /// Registers for remote notifications (change notifications for the iCloud backup); tests inject a no-op.
    let registerForRemoteNotifications: @MainActor () -> Void
    let now: @Sendable () -> Date
    /// Saves and syncs run serially in the order they were started.
    let persistence = SerialTaskQueue()

    init(
        settings: any SettingsStore = UserDefaults.standard,
        keyStore: any VaultKeyStoring = KeychainVaultKeyStore(),
        clipboard: any SecretClipboard = LocalPasteboardClipboard.shared,
        authenticator: any BiometricAuthenticating = BiometricService.authenticator,
        biometrics: BiometricCapability = .current,
        files: VaultFileStore = .shared,
        cloudConnections: any CloudConnectionStoring = KeychainCloudConnectionStore(),
        httpExecutor: any HTTPExecuting = URLSessionHTTPExecutor(),
        iCloud: (any ICloudVaultStoring)? = ICloudVault.makeLiveStore(),
        registerForRemoteNotifications: @escaping @MainActor () -> Void = { UIApplication.shared.registerForRemoteNotifications() },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.settings = settings
        self.keyStore = keyStore
        self.clipboard = clipboard
        self.authenticator = authenticator
        self.biometrics = biometrics
        self.files = files
        self.cloudConnections = cloudConnections
        self.httpExecutor = httpExecutor
        self.iCloud = iCloud
        self.registerForRemoteNotifications = registerForRemoteNotifications
        self.now = now
        let preferences = MobilePreferences.load(from: settings)
        self.preferences = preferences
        L10n.apply(languageMode: preferences.language)
        phase = VaultPersistenceService.vaultExists ? .locked : .onboarding
        syncHistory = BackupHistoryStore.load()
        syncStatus = preferences.syncLocation == nil ? .notConfigured : .idle
        biometricKeyAvailable = biometrics.isAvailable && preferences.biometricsEnabled && keyStore.hasKey()
        observeICloudAccount()
        if preferences.syncLocation?.isICloud == true { enableICloudPush() }
    }

    /// Default wiring for the real app and the test host: the test host never touches the Keychain or real preferences.
    static func makeForApp() -> MobileVaultStore {
        if AppEnvironment.isTestHost {
            return MobileVaultStore(
                settings: InMemorySettingsStore(), keyStore: InMemoryVaultKeyStore(), authenticator: StubBiometricAuthenticator(),
                biometrics: .none, cloudConnections: InMemoryCloudConnectionStore(), iCloud: nil, registerForRemoteNotifications: {})
        }
        return MobileVaultStore()
    }

    // MARK: - List

    var accounts: [Account] { document.accounts }
    var categories: [AccountCategory] { document.categories }

    var sectionAccounts: [Account] {
        document.accounts(in: section)
    }

    var sectionCategory: AccountCategory? {
        guard case .category(let id) = section else { return nil }
        return document.category(id)
    }

    /// Search matching (including whitespace handling) lives in the core's `search.rs`.
    var visibleAccounts: [Account] {
        sectionAccounts.filter { $0.matchesSearch(searchText) }
    }

    func account(id: Account.ID?) -> Account? {
        guard let id else { return nil }
        return document.account(id)
    }

    func showToast(_ message: String, systemImage: String) {
        toast = Toast(message: message, systemImage: systemImage)
    }

    /// When unlocked, rewrites with the current key (reusing the salt and KDF metadata, with a new nonce), queued in start order and
    /// followed by one coalesced sync.
    func persist() {
        guard let key else { return }
        let snapshot = document.contents
        let files = files
        persistence.enqueue { [weak self] in
            do {
                try await files.save(snapshot, key: key)
                self?.scheduleSync()
            } catch {
                self?.showToast(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, systemImage: "exclamationmark.triangle")
            }
        }
    }

    /// Waits for all queued saves and syncs to finish (for tests).
    func waitForPendingPersistence() async {
        await persistence.drain()
    }
}

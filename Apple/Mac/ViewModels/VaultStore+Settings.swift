import AppKit
import SwiftUI

/// Appearance, language, Dock policy, login item, system theme / language observation, and reset.
extension VaultStore {
    // MARK: - Appearance, language, Dock

    func applyDockIconPolicy() {
        let shouldShowDockIcon: Bool
        switch dockIconMode {
        case .always:
            shouldShowDockIcon = true
        case .mainWindowOnly:
            shouldShowDockIcon = isMainWindowOpen
        case .never:
            shouldShowDockIcon = false
        }
        system.setDockIconVisible(shouldShowDockIcon)
    }

    func applyAppearance() {
        let scheme: ColorScheme
        switch appearanceMode {
        case .light:
            scheme = .light
        case .dark:
            scheme = .dark
        case .system:
            // When following the system, AppleInterfaceThemeChangedNotification syncs it again.
            scheme = system.systemColorScheme()
        }
        system.applyAppearance(scheme)
        resolvedColorScheme = scheme
    }

    func applyLanguage() {
        L10n.apply(languageMode: languageMode)
        languageRevision &+= 1
    }

    func observeSystemThemeChanges() {
        systemThemeObserver = DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.appearanceMode == .system else { return }
                self.applyAppearance()
            }
        }
    }

    func applyLaunchAtLogin() {
        launchAtLoginError = nil
        do {
            try system.setLaunchAtLogin(launchAtLoginEnabled)
        } catch {
            launchAtLoginError = L10n.format("Couldn’t update login item: %@", error.localizedDescription)
            isSyncingLaunchAtLogin = true
            launchAtLoginEnabled = system.isLaunchAtLoginEnabled
            isSyncingLaunchAtLogin = false
        }
    }

    // MARK: - Reset

    /// "Reset" in Settings: requires Touch ID or the system password even when unlocked, so someone with brief access to an unlocked
    /// Mac cannot wipe the data.
    func resetApplicationAfterAuthentication() async -> Bool {
        do {
            try await authenticator.authenticate(.deviceOwner, reason: L10n.tr("reset Kakey and erase local data"))
        } catch {
            return false
        }
        syncDebounceTask?.cancel()
        await persistence.drain()
        resetApplication()
        return true
    }

    /// Resets the app: erases the local vault directory (including the last-known-good snapshot, backup history and Touch ID
    /// material), sync markers and all settings, and returns to onboarding. Encrypted backups in the backup location are kept.
    func resetApplication() {
        cancelScheduledAutoLock()
        lastActivityAt = nil
        syncDebounceTask?.cancel()
        document = VaultDocument()
        vaultKey = nil
        activeSheet = nil
        pendingOnboardingRestore = nil
        pendingOnboardingExport = nil
        pendingCopyAccountIDAfterUnlock = nil
        pendingCaptureAccountsAfterPasswordUnlock = []
        keyStore.remove()
        VaultPersistenceService.removeAllFiles()
        searchIndexEntries = []
        hasPopulatedSearchIndex = false
        backupHistory = []
        syncBackend = nil
        syncBackendLocation = nil
        // Cloud storage: revoke in the background on a best-effort basis; local credentials go with the data directory (the Mac
        // connection file lives in the vault directory).
        if syncLocation?.isCloud == true, let connection = try? cloudConnections.load() {
            let setup = cloudSetup
            Task.detached { await setup.revoke(connection) }
        }
        cloudConnections.remove()
        // iCloud: only stop this Mac's change push; backups in iCloud are kept (as with other locations).
        if syncLocation?.isICloud == true { disableICloudPush() }

        settings.removeObjects(forKeys: Self.allSettingsKeys)
        system.resetGlobalShortcuts()

        usesCardView = true
        dockIconMode = .mainWindowOnly
        menuBarListScope = .all
        launchMinimized = false
        alfredIntegrationEnabled = false
        appearanceMode = .system
        languageMode = .system
        autoLockMode = .fiveMinutes
        touchIDEnabled = true
        lockoutDelayEnabled = true
        menuBarIconVisible = true
        backupStatus = .disabled
        syncLocation = nil
        biometricKeyAvailable = false
        lastKnownGoodRestoreAvailable = false
        vaultError = nil
        isLocked = false
        hasCompletedOnboarding = false
    }

    func observeSystemLocaleChanges() {
        systemLocaleObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.languageMode == .system else { return }
                self.applyLanguage()
            }
        }
    }
}

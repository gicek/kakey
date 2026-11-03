import Foundation

/// External entry points: shortcut screen capture, AppleScript `copy code` / `find accounts`, copies and imports queued by the URL
/// scheme, and the Alfred search index.
extension VaultStore {
    enum CaptureImportResult: Equatable {
        case added(String)
        case duplicate(String)
    }

    enum CaptureImportError: LocalizedError, Equatable {
        case authorizationFailed(String)

        var errorDescription: String? {
            switch self {
            case .authorizationFailed(let message):
                return message
            }
        }
    }

    func captureQRCodeFromScreen(
        authorizeIfLocked: Bool = false,
        onLockedQRCodeRecognized: (() -> Void)? = nil
    ) async throws -> CaptureImportResult {
        // Before onboarding is complete there is no vault to write to, so skip the screen selection.
        guard hasCompletedOnboarding else {
            throw CaptureImportError.authorizationFailed(L10n.tr("Set up Kakey first"))
        }
        let wasLocked = isLocked
        let result = try await ScreenCaptureQRCodeService.captureInteractiveQRCode()
        let parsedAccounts = result.validAccounts

        if wasLocked {
            guard authorizeIfLocked else {
                throw CaptureImportError.authorizationFailed(L10n.tr("Unlock Kakey first"))
            }

            onLockedQRCodeRecognized?()

            guard await unlockWithTouchID(reason: L10n.tr("unlock Kakey to import the captured QR code")) else {
                if lastTouchIDErrorWasUserFallback {
                    pendingCaptureAccountsAfterPasswordUnlock = parsedAccounts
                }
                throw CaptureImportError.authorizationFailed(vaultError ?? L10n.tr("Unlock Kakey first"))
            }
        }

        let insertedCount = addParsedAccounts(parsedAccounts)
        let issuer = parsedAccounts.first?.issuer ?? L10n.tr("Unknown service")
        return insertedCount > 0 ? .added(issuer) : .duplicate(issuer)
    }

    func consumePendingCaptureImportResult() -> CaptureImportResult? {
        defer { pendingCaptureImportResult = nil }
        return pendingCaptureImportResult
    }

    func consumePendingCopyResultIssuer() -> String? {
        defer { pendingCopyResultIssuer = nil }
        return pendingCopyResultIssuer
    }

    /// External automation (AppleScript `copy code`) asks to copy an account's code. Every request must re-authenticate, even if
    /// the app happens to be unlocked, so local malware cannot silently read codes through an unlocked session. When unlocked, only
    /// identity is re-verified (Touch ID / login password, without decrypting the vault again); when locked, the vault must really be
    /// unlocked. If the user switches to the password in the Touch ID prompt, the request is queued until the next successful password
    /// unlock, and the caller must bring the main window forward to show the password lock screen (rather than forcing Touch ID).
    enum SecureCopyOutcome {
        case copied(issuer: String, code: String)
        case needsPasswordUnlock
        case failed
    }

    func requestSecureCopy(accountID: UUID, reason: String) async -> SecureCopyOutcome {
        if isLocked {
            guard await unlockWithTouchID(reason: reason) else {
                if lastTouchIDErrorWasUserFallback {
                    pendingCopyAccountIDAfterUnlock = accountID
                    return .needsPasswordUnlock
                }
                return .failed
            }
        } else {
            do {
                try await authenticator.authenticate(.deviceOwner, reason: reason)
            } catch {
                return .failed
            }
        }

        guard let account = document.account(accountID) else {
            return .failed
        }
        let code = copyCode(for: account)
        return .copied(issuer: account.issuer, code: code)
    }

    func resolvePendingCopyAfterUnlockIfNeeded() {
        guard let pendingID = pendingCopyAccountIDAfterUnlock else { return }
        pendingCopyAccountIDAfterUnlock = nil
        guard let account = document.account(pendingID) else { return }
        copyCode(for: account)
        pendingCopyResultIssuer = account.issuer
    }

    func importPendingCaptureAccountsAfterUnlockIfNeeded() {
        guard !pendingCaptureAccountsAfterPasswordUnlock.isEmpty else { return }

        let parsedAccounts = pendingCaptureAccountsAfterPasswordUnlock
        pendingCaptureAccountsAfterPasswordUnlock = []
        let insertedCount = addParsedAccounts(parsedAccounts)
        let issuer = parsedAccounts.first?.issuer ?? L10n.tr("Unknown service")
        pendingCaptureImportResult = insertedCount > 0 ? .added(issuer) : .duplicate(issuer)
    }

    /// Non-secret index for external automation such as Alfred to filter accounts by name. Refreshed only after the vault is
    /// actually written or unlocked, so it matches the real account list. Not built at all when the master switch is off.
    func refreshSearchIndex() {
        guard alfredIntegrationEnabled else { return }
        searchIndexEntries = SearchIndexService.entries(from: accounts)
        hasPopulatedSearchIndex = true
    }

    enum SearchIndexAvailability {
        /// Master switch is off: `FindAccountsCommand` should tell the user to turn it on in Settings.
        case disabled
        /// Switch is on, but this process has never unlocked successfully.
        case notReady
        case ready([SearchIndexService.Entry])
    }

    /// For `FindAccountsCommand`. Independent of the current `isLocked`, because locking does not clear the index.
    func searchIndexAvailability() -> SearchIndexAvailability {
        guard alfredIntegrationEnabled else { return .disabled }
        guard hasPopulatedSearchIndex else { return .notReady }
        return .ready(searchIndexEntries)
    }
}

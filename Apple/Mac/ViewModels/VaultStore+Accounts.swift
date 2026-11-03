import Foundation

/// Adding, updating, deleting, reordering and copying accounts, and re-authentication before revealing secrets.
extension VaultStore {
    // MARK: - Accounts

    @discardableResult
    /// - Parameter categoryID: Passed when adding from a category in the main window, so the new account also joins that category;
    ///   omitted by the menu bar and shortcut screen capture.
    func addAccount(
        issuer: String, username: String, secret: String, algorithm: TOTPAlgorithm, digits: Int, period: Int,
        into categoryID: AccountCategory.ID? = nil
    ) -> Bool {
        guard canWriteVault() else { return false }
        let candidate = CoreAccountCandidate.manual(
            issuer: issuer, username: username, secret: secret, algorithm: algorithm, digits: digits, period: period)
        let inserted = document.insert([candidate], addedBy: AccountProvenance.manual, into: categoryID, now: now()) > 0
        if inserted {
            saveVault()
        }
        return inserted
    }

    @discardableResult
    func addParsedAccounts(_ parsed: [ParsedOTPAuth], into categoryID: AccountCategory.ID? = nil) -> Int {
        guard canWriteVault() else { return 0 }
        let insertedCount = document.insert(
            CoreAccountCandidate.candidates(from: parsed), addedBy: AccountProvenance.imported, into: categoryID, now: now())
        if insertedCount > 0 {
            saveVault()
        }
        return insertedCount
    }

    func update(_ account: Account) {
        guard canWriteVault(), document.update(account) else { return }
        saveVault()
    }

    /// Result of re-authentication before revealing a secret / QR code: cancellation shows nothing, failure carries a message.
    enum SecretRevealOutcome: Equatable {
        case granted
        case cancelled
        case failed(String)
    }

    /// Requires Touch ID or the login password before revealing the secret or the QR code (which contains the full secret); shared
    /// by the detail view and the context menu.
    func authenticateToRevealSecret(reason: String) async -> SecretRevealOutcome {
        do {
            try await authenticator.authenticate(.deviceOwner, reason: reason)
            return .granted
        } catch {
            return BiometricAuth.isCancellation(error) ? .cancelled : .failed(BiometricAuthService.message(for: error))
        }
    }

    /// Context menu "Show QR Code": opens the QR code sheet after authentication; on failure only plays the alert sound.
    func presentQRCode(for account: Account) async {
        switch await authenticateToRevealSecret(reason: L10n.tr("show the account QR code")) {
        case .granted:
            guard !isLocked else { return }
            activeSheet = .accountQRCode(account)
        case .failed:
            system.beep()
        case .cancelled:
            break
        }
    }

    func delete(_ account: Account) {
        guard canWriteVault() else { return }
        document.delete(account.id)
        saveVault()
    }

    /// Applies the section's new order in one go when the drag ends, and saves it.
    /// The preview order during a drag lives entirely in `AccountReorderSession` memory and never touches the store: moving the
    /// `@Published` accounts on every row crossing would re-render every view observing `VaultStore` (including the always-alive
    /// menu bar panel), spiking CPU with 100+ accounts.
    func applyAccountOrder(_ orderedIDs: [Account.ID]) {
        guard canWriteVault(), document.applyAccountOrder(orderedIDs, in: selectedSection) else { return }
        saveVault()
    }

    func currentAccountOrderIDsForReorder() -> [Account.ID] {
        sectionAccounts.map(\.id)
    }

    /// How long "Copied" replaces the code after copying. It covers the code, so it should be short.
    static let copiedFeedbackDuration: Duration = .milliseconds(600)

    /// Copies the verification code: the pasteboard entry is marked concealed / transient and cleared after one period.
    @discardableResult
    func copyCode(for account: Account) -> String {
        let code = TOTPService.code(for: account)
        clipboard.copy(code, expiresAfter: TimeInterval(account.period))
        copiedAccountID = account.id
        Task {
            try? await Task.sleep(for: Self.copiedFeedbackDuration)
            if copiedAccountID == account.id {
                copiedAccountID = nil
            }
        }
        return code
    }

    /// Copies the account's full otpauth URI (including the secret); cleared after 60 seconds.
    func copySecretURI(for account: Account) {
        clipboard.copy(OTPAuthCanonicalizer.otpauthURLString(for: account), expiresAfter: ClipboardExpiry.secret)
    }
}

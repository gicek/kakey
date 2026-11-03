import Foundation

/// Account insertion, manual add, parsed results and backup import, update, deletion, ordering, and copying.
extension MobileVaultStore {
    // MARK: - Accounts

    /// Single insertion path (core `dedup.rs`): skips invalid entries and duplicates (including within this batch) and inserts new
    /// accounts at the top. Returns the number added.
    /// - Parameter categoryID: Category the new accounts also join (when adding a single account inside a category); not passed
    ///   for backup imports.
    @discardableResult
    func insert(_ candidates: [CoreAccountCandidate], addedBy: String, into categoryID: AccountCategory.ID? = nil) -> Int {
        guard phase == .unlocked else { return 0 }
        let count = document.insert(candidates, addedBy: addedBy, into: categoryID, now: now())
        if count > 0 { persist() }
        return count
    }

    /// Manual add. Returns nil on success, otherwise the error to display.
    func addManual(issuer: String, username: String, secret: String, algorithm: TOTPAlgorithm, digits: Int, period: Int) -> String? {
        guard OTPAuthCanonicalizer.standardizedSecret(secret) != nil else { return L10n.tr("Invalid secret key") }
        let candidate = CoreAccountCandidate.manual(
            issuer: issuer, username: username, secret: secret, algorithm: algorithm, digits: digits, period: period)
        return insert([candidate], addedBy: AccountProvenance.manual, into: section.categoryID) > 0
            ? nil : L10n.tr("Account already exists")
    }

    /// Results from scanning, pasting, or dropping. Returns the number added and shows a toast.
    @discardableResult
    func addParsed(_ parsed: [ParsedOTPAuth]) -> Int {
        // Scan, paste, and drop all start from the main screen: inside a category, new accounts also join that category
        let count = insert(CoreAccountCandidate.candidates(from: parsed), addedBy: AccountProvenance.imported, into: section.categoryID)
        announceAdded(count)
        return count
    }

    /// Imports a backup file (Kakey encrypted export or Authenticator backup). Returns the number added on success.
    /// Categories in the file are merged by name (created if missing); Authenticator pinned entries go into the Favorites category.
    func importBackup(_ data: Data, password: String) async throws -> Int {
        isWorking = true
        defer { isWorking = false }
        let imported = try await files.importBackup(data, password: password)
        let count = insert(imported.importCandidates, addedBy: AccountProvenance.imported)
        announceAdded(count)
        return count
    }

    private func announceAdded(_ count: Int) {
        if count > 0 {
            showToast(L10n.format("Added %lld accounts", count), systemImage: "checkmark.circle.fill")
            Haptics.success()
        } else {
            showToast(L10n.tr("Account already exists"), systemImage: "info.circle")
        }
    }

    func update(_ account: Account) {
        guard phase == .unlocked, document.update(account) else { return }
        persist()
    }

    func delete(_ account: Account) {
        guard phase == .unlocked else { return }
        document.delete(account.id)
        persist()
    }

    /// List drag reordering (iPhone edit mode); affects only the current section (All or one category).
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard phase == .unlocked, document.moveAccounts(fromOffsets: source, toOffset: destination, in: section) else { return }
        persist()
    }

    /// Commits the current section's new order in one go when an iPad card drag ends (the in-drag preview lives only in
    /// `GridReorder`'s memory).
    func applyAccountOrder(_ orderedIDs: [Account.ID]) {
        guard phase == .unlocked, document.applyAccountOrder(orderedIDs, in: section) else { return }
        persist()
    }

    /// Copies a verification code: local pasteboard only, expires after one period.
    func copyCode(for account: Account) {
        clipboard.copy(TOTPService.code(for: account), expiresAfter: TimeInterval(account.period))
        showToast(L10n.tr("Copied"), systemImage: "doc.on.doc.fill")
        Haptics.success()
    }

    /// Copies sensitive content that does not expire on its own, such as a secret: expires after 60 seconds.
    func copySensitive(_ text: String) {
        clipboard.copy(text, expiresAfter: ClipboardExpiry.secret)
        showToast(L10n.tr("Copied"), systemImage: "doc.on.doc.fill")
    }
}

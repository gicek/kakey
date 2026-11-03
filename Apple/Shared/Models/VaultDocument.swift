import Foundation

/// In-memory state of the unlocked vault and every edit operation, shared by the Mac `VaultStore` and iOS
/// `MobileVaultStore`.
///
/// The rules (field canonicalization, deduplication, category naming and membership) live in the core; this only
/// orchestrates. Each operation mutates the document, and the store then persists it. A value type: the store replaces it
/// wholesale, and the UI reads `accounts` / `categories`.
struct VaultDocument: Equatable, Sendable {
    var accounts: [Account]
    var categories: [AccountCategory]

    init(accounts: [Account] = [], categories: [AccountCategory] = []) {
        self.accounts = accounts
        self.categories = categories
    }

    init(_ contents: VaultContents) {
        self.init(accounts: contents.accounts, categories: contents.categories)
    }

    var contents: VaultContents {
        VaultContents(accounts: accounts, categories: categories)
    }

    // MARK: - Queries

    func accounts(in section: VaultSection) -> [Account] {
        switch section {
        case .all: accounts
        case .category(let id): categories.accounts(in: id, from: accounts)
        }
    }

    func category(_ id: AccountCategory.ID) -> AccountCategory? {
        categories.first { $0.id == id }
    }

    func account(_ id: Account.ID) -> Account? {
        accounts.first { $0.id == id }
    }

    /// When a section's category no longer exists (deleted, or gone after a sync), the store falls back to All.
    func contains(_ section: VaultSection) -> Bool {
        switch section {
        case .all: true
        case .category(let id): category(id) != nil
        }
    }

    func isAccount(_ accountID: Account.ID, in categoryID: AccountCategory.ID) -> Bool {
        category(categoryID)?.accountIDs.contains(accountID) ?? false
    }

    // MARK: - Accounts

    /// The single insertion path (core `dedup.rs`): canonicalizes fields, skips invalid entries and duplicates (including
    /// duplicates within the batch), inserts new accounts at the front in order, and adds them to the categories named by
    /// each candidate. Only the new accounts come back, so existing accounts do not round-trip through FFI.
    /// - Parameter categoryID: Passed for a single add inside a category, which also adds the new account to it; not passed
    ///   for backup import or screenshot recognition.
    mutating func insert(_ candidates: [CoreAccountCandidate], addedBy: String, into categoryID: AccountCategory.ID? = nil, now: Date)
        -> Int
    {
        guard !candidates.isEmpty,
            let result = try? coreInsertAccounts(
                existing: accounts.map(\.core),
                categories: categories.map(\.core),
                candidates: candidates,
                addedBy: addedBy,
                now: now,
                placeholders: .current
            ),
            !result.insertedIds.isEmpty
        else {
            return 0
        }
        let newAccounts = result.accounts.prefix(result.insertedIds.count).map(Account.init)
        accounts.insert(contentsOf: newAccounts, at: 0)
        categories = CategoryService.adding(newAccounts.map(\.id), to: categoryID, in: result.categories.map(AccountCategory.init))
        return result.insertedIds.count
    }

    /// Edits the service and account names through core canonicalization (cleans whitespace and percent-encoding, fills
    /// placeholders for empty values, strips a redundant `issuer:` prefix). Only these two names change; secret, algorithm,
    /// digits, period, creation time and source always come from the stored account, even if the copy passed in from the UI
    /// differs (the secret is read-only on the detail screen).
    @discardableResult
    mutating func update(_ account: Account) -> Bool {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return false }
        var updated = accounts[index]
        if let fields = coreCanonicalFields(
            issuer: account.issuer,
            username: account.username,
            secret: updated.secret,
            algorithm: updated.algorithm.core,
            digits: UInt32(clamping: updated.digits),
            period: UInt32(clamping: updated.period),
            placeholders: .current
        ) {
            updated.issuer = fields.issuer
            updated.username = fields.username
        } else {
            updated.issuer = account.issuer
            updated.username = account.username
        }
        accounts[index] = updated
        return true
    }

    /// Deletes the account and removes it from every category.
    mutating func delete(_ id: Account.ID) {
        accounts.removeAll { $0.id == id }
        categories = CategoryService.removing([id], from: categories)
    }

    /// Applies the section's new order in one step when a drag ends; in All, unlisted accounts follow in their existing
    /// relative order.
    @discardableResult
    mutating func applyAccountOrder(_ orderedIDs: [Account.ID], in section: VaultSection) -> Bool {
        guard !orderedIDs.isEmpty else { return false }
        switch section {
        case .all:
            let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
            let ordered = orderedIDs.compactMap { byID[$0] }
            guard ordered.count == orderedIDs.count else { return false }
            let orderedSet = Set(orderedIDs)
            accounts = ordered + accounts.filter { !orderedSet.contains($0.id) }
        case .category(let id):
            guard let updated = try? CategoryService.setAccountOrder(orderedIDs, in: id, of: categories) else { return false }
            categories = updated
        }
        return true
    }

    /// List-style move (iPhone edit mode): converted into the section's new order and passed to `applyAccountOrder`.
    @discardableResult
    mutating func moveAccounts(fromOffsets source: IndexSet, toOffset destination: Int, in section: VaultSection) -> Bool {
        var ordered = accounts(in: section).map(\.id)
        ordered.move(fromOffsets: source, toOffset: destination)
        return applyAccountOrder(ordered, in: section)
    }

    // MARK: - Categories

    /// Creates and returns a category; throws `CategoryError` for an invalid name.
    @discardableResult
    mutating func createCategory(named name: String) throws -> AccountCategory {
        let updated = try CategoryService.create(categories, name: name)
        categories = updated
        return updated[updated.count - 1]
    }

    mutating func renameCategory(_ id: AccountCategory.ID, to name: String) throws {
        categories = try CategoryService.rename(categories, id: id, to: name)
    }

    /// Deletes only the category; its accounts remain in All.
    mutating func deleteCategory(_ id: AccountCategory.ID) {
        categories = CategoryService.delete(categories, id: id)
    }

    mutating func reorderCategories(_ orderedIDs: [AccountCategory.ID]) {
        categories = CategoryService.reorder(categories, orderedIDs: orderedIDs)
    }

    mutating func moveCategories(fromOffsets source: IndexSet, toOffset destination: Int) {
        var ordered = categories.map(\.id)
        ordered.move(fromOffsets: source, toOffset: destination)
        reorderCategories(ordered)
    }

    @discardableResult
    mutating func addAccount(_ accountID: Account.ID, to categoryID: AccountCategory.ID) -> Bool {
        guard let updated = try? CategoryService.add(accountID, to: categoryID, in: categories) else { return false }
        categories = updated
        return true
    }

    @discardableResult
    mutating func removeAccount(_ accountID: Account.ID, from categoryID: AccountCategory.ID) -> Bool {
        guard let updated = try? CategoryService.remove(accountID, from: categoryID, in: categories) else { return false }
        categories = updated
        return true
    }

    /// Toggle for the "Add to ›" menu: removes the account if it is in the category, otherwise appends it.
    @discardableResult
    mutating func toggleAccount(_ accountID: Account.ID, in categoryID: AccountCategory.ID) -> Bool {
        isAccount(accountID, in: categoryID)
            ? removeAccount(accountID, from: categoryID)
            : addAccount(accountID, to: categoryID)
    }
}

extension CoreAccountCandidate {
    /// Manually entered fields; canonicalization and validation happen during core insertion.
    static func manual(issuer: String, username: String, secret: String, algorithm: TOTPAlgorithm, digits: Int, period: Int)
        -> CoreAccountCandidate
    {
        CoreAccountCandidate(
            issuer: issuer,
            username: username,
            secret: secret,
            algorithm: algorithm.core,
            digits: UInt32(clamping: digits),
            period: UInt32(clamping: period),
            categoryNames: [],
            createdAt: nil
        )
    }

    init(_ parsed: ParsedOTPAuth) {
        self.init(
            issuer: parsed.issuer,
            username: parsed.account,
            secret: parsed.secret,
            algorithm: parsed.algorithm.core,
            digits: UInt32(clamping: parsed.digits),
            period: UInt32(clamping: parsed.period),
            categoryNames: [],
            createdAt: nil
        )
    }

    /// The valid entries from scanned, pasted or dropped parse results.
    static func candidates(from parsed: [ParsedOTPAuth]) -> [CoreAccountCandidate] {
        parsed.filter(\.isValid).map(CoreAccountCandidate.init)
    }
}

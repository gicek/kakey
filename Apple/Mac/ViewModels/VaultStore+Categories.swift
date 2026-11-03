import Foundation

/// Creating, editing, deleting and reordering categories, and account membership.
extension VaultStore {
    // MARK: - Categories

    /// Creates and returns a category; throws `CategoryError` for an invalid name (shown inline in the UI).
    @discardableResult
    func createCategory(named name: String) throws -> AccountCategory {
        guard canWriteVault() else { throw CategoryError.notFound }
        let category = try document.createCategory(named: name)
        saveVault()
        return category
    }

    func renameCategory(_ id: AccountCategory.ID, to name: String) throws {
        guard canWriteVault() else { return }
        try document.renameCategory(id, to: name)
        saveVault()
    }

    /// Deletes only the category; its accounts stay in "All". If the menu bar is showing this category, it switches back to "All".
    func deleteCategory(_ id: AccountCategory.ID) {
        guard canWriteVault() else { return }
        document.deleteCategory(id)
        if menuBarListScope == .category(id) {
            menuBarListScope = .all
        }
        saveVault()
    }

    func reorderCategories(_ orderedIDs: [AccountCategory.ID]) {
        guard canWriteVault() else { return }
        document.reorderCategories(orderedIDs)
        saveVault()
    }

    /// Toggle for the "Add to ›" menu checkmark: removes the account if it is in the category, otherwise appends it.
    func toggleAccount(_ accountID: Account.ID, in categoryID: AccountCategory.ID) {
        guard canWriteVault(), document.toggleAccount(accountID, in: categoryID) else { return }
        saveVault()
    }

    func addAccount(_ accountID: Account.ID, to categoryID: AccountCategory.ID) {
        guard canWriteVault(), document.addAccount(accountID, to: categoryID) else { return }
        saveVault()
    }

    func removeAccount(_ accountID: Account.ID, from categoryID: AccountCategory.ID) {
        guard canWriteVault(), document.removeAccount(accountID, from: categoryID) else { return }
        saveVault()
    }
}

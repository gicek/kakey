import Foundation

/// Category creation, editing, deletion, ordering, and account membership.
extension MobileVaultStore {
    // MARK: - Categories

    /// Creates and returns a new category; throws `CategoryError` if the name is invalid.
    @discardableResult
    func createCategory(named name: String) throws -> AccountCategory {
        let category = try document.createCategory(named: name)
        persist()
        return category
    }

    func renameCategory(_ id: AccountCategory.ID, to name: String) throws {
        try document.renameCategory(id, to: name)
        persist()
    }

    /// Deletes only the category itself; its accounts remain under All.
    func deleteCategory(_ id: AccountCategory.ID) {
        document.deleteCategory(id)
        persist()
    }

    func moveCategories(fromOffsets source: IndexSet, toOffset destination: Int) {
        document.moveCategories(fromOffsets: source, toOffset: destination)
        persist()
    }

    func isAccount(_ accountID: Account.ID, in categoryID: AccountCategory.ID) -> Bool {
        document.isAccount(accountID, in: categoryID)
    }

    /// Toggle for the "Add to" menu: removes the account if it is already in the category, otherwise appends it.
    func toggleAccount(_ accountID: Account.ID, in categoryID: AccountCategory.ID) {
        guard document.toggleAccount(accountID, in: categoryID) else { return }
        persist()
    }
}

import Foundation

enum CategoryError: LocalizedError, Equatable {
    case emptyName
    case nameTooLong
    case duplicateName
    case notFound

    /// The localization key comes from the core's `core_error_l10n_key`.
    var coreError: KakeyError {
        switch self {
        case .emptyName: .EmptyCategoryName
        case .nameTooLong: .CategoryNameTooLong
        case .duplicateName: .DuplicateCategoryName
        case .notFound: .CategoryNotFound
        }
    }

    var errorDescription: String? {
        switch self {
        case .nameTooLong: L10n.format(coreErrorL10nKey(error: coreError), CategoryService.maxNameLength)
        default: L10n.tr(coreErrorL10nKey(error: coreError))
        }
    }
}

/// Thin wrapper for category operations. All rules (naming, deduplication, membership and ordering) live in the core
/// (`category.rs`); this only converts types and maps errors. Each operation returns a new category list, which callers
/// swap in wholesale before saving the vault.
enum CategoryService {
    static var maxNameLength: Int { Int(coreMaxCategoryNameChars()) }

    /// New categories are appended at the end.
    static func create(_ categories: [AccountCategory], name: String) throws -> [AccountCategory] {
        try run { try coreCategoryCreate(categories: categories.map(\.core), name: name) }
    }

    static func rename(_ categories: [AccountCategory], id: UUID, to name: String) throws -> [AccountCategory] {
        try run { try coreCategoryRename(categories: categories.map(\.core), id: id.uuidString, name: name) }
    }

    /// Deletes only the category; its accounts are untouched.
    static func delete(_ categories: [AccountCategory], id: UUID) -> [AccountCategory] {
        (try? run { try coreCategoryDelete(categories: categories.map(\.core), id: id.uuidString) }) ?? categories
    }

    static func reorder(_ categories: [AccountCategory], orderedIDs: [UUID]) -> [AccountCategory] {
        (try? run { try coreCategoryReorder(categories: categories.map(\.core), orderedIds: orderedIDs.map(\.uuidString)) }) ?? categories
    }

    static func add(_ accountID: UUID, to categoryID: UUID, in categories: [AccountCategory]) throws -> [AccountCategory] {
        try run {
            try coreCategoryAddAccount(categories: categories.map(\.core), id: categoryID.uuidString, accountId: accountID.uuidString)
        }
    }

    static func remove(_ accountID: UUID, from categoryID: UUID, in categories: [AccountCategory]) throws -> [AccountCategory] {
        try run {
            try coreCategoryRemoveAccount(categories: categories.map(\.core), id: categoryID.uuidString, accountId: accountID.uuidString)
        }
    }

    /// Commits a drag reorder within a category: listed members take the given order, unlisted members stay after them.
    static func setAccountOrder(_ orderedIDs: [UUID], in categoryID: UUID, of categories: [AccountCategory]) throws -> [AccountCategory] {
        try run {
            try coreCategorySetAccountOrder(
                categories: categories.map(\.core),
                id: categoryID.uuidString,
                orderedAccountIds: orderedIDs.map(\.uuidString)
            )
        }
    }

    /// Adds newly added accounts to a category (returns the list unchanged for `nil` or a category that no longer exists);
    /// used when a single add happens inside a category.
    static func adding(_ accountIDs: [UUID], to categoryID: UUID?, in categories: [AccountCategory]) -> [AccountCategory] {
        guard let categoryID else { return categories }
        return accountIDs.reduce(categories) { result, id in (try? add(id, to: categoryID, in: result)) ?? result }
    }

    /// Removes deleted accounts from every category.
    static func removing(_ accountIDs: [UUID], from categories: [AccountCategory]) -> [AccountCategory] {
        (try? run { try coreCategoriesRemovingAccounts(categories: categories.map(\.core), accountIds: accountIDs.map(\.uuidString)) })
            ?? categories
    }

    private static func run(_ body: () throws -> [CoreCategory]) throws -> [AccountCategory] {
        do {
            return try body().map(AccountCategory.init)
        } catch let error as KakeyError {
            throw error.categoryError
        }
    }
}

extension Array where Element == AccountCategory {
    /// The category's accounts in category order, skipping accounts that no longer exist.
    func accounts(in categoryID: AccountCategory.ID, from accounts: [Account]) -> [Account] {
        guard let category = first(where: { $0.id == categoryID }) else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        return category.accountIDs.compactMap { byID[$0] }
    }

    /// Categories containing this account, in sidebar order.
    func containing(_ accountID: Account.ID) -> [AccountCategory] {
        filter { $0.accountIDs.contains(accountID) }
    }
}

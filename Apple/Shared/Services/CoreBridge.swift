import Foundation

// Conversions between the Rust core (Core/: the UniFFI-generated `core*` functions and `Core*` types) and app types.
// Business rules are implemented once, in the core; this file only maps types and localizes.

extension TOTPAlgorithm {
    var core: CoreTotpAlgorithm {
        switch self {
        case .sha1: .sha1
        case .sha256: .sha256
        case .sha512: .sha512
        }
    }

    init(_ core: CoreTotpAlgorithm) {
        switch core {
        case .sha1: self = .sha1
        case .sha256: self = .sha256
        case .sha512: self = .sha512
        }
    }
}

extension Account {
    var core: CoreAccount {
        CoreAccount(
            id: id.uuidString,
            issuer: issuer,
            username: username,
            secret: secret,
            algorithm: algorithm.core,
            digits: UInt32(clamping: digits),
            period: UInt32(clamping: period),
            createdAt: createdAt,
            addedBy: addedBy
        )
    }

    /// Ids returned by the core are always valid uppercase UUIDs.
    init(_ core: CoreAccount) {
        self.init(
            id: UUID(uuidString: core.id) ?? UUID(),
            issuer: core.issuer,
            username: core.username,
            secret: core.secret,
            algorithm: TOTPAlgorithm(core.algorithm),
            digits: Int(core.digits),
            period: Int(core.period),
            createdAt: core.createdAt,
            addedBy: core.addedBy
        )
    }
}

extension AccountCategory {
    var core: CoreCategory {
        CoreCategory(id: id.uuidString, name: name, accountIds: accountIDs.map(\.uuidString))
    }

    /// Ids returned by the core are always valid uppercase UUIDs.
    init(_ core: CoreCategory) {
        self.init(
            id: UUID(uuidString: core.id) ?? UUID(),
            name: core.name,
            accountIDs: core.accountIds.compactMap(UUID.init(uuidString:))
        )
    }
}

extension VaultContents {
    var core: CoreVaultContents {
        CoreVaultContents(accounts: accounts.map(\.core), categories: categories.map(\.core), pinnedIds: [])
    }

    init(_ core: CoreVaultContents) {
        self.init(accounts: core.accounts.map(Account.init), categories: core.categories.map(AccountCategory.init))
    }

    /// Used after importing a backup file: pinned Authenticator entries are merged into a "Favorites" category named in the
    /// current UI language.
    init(adoptingPinned core: CoreVaultContents) {
        self.init((try? coreAdoptPinned(contents: core, name: L10n.tr("Favorites"))) ?? core)
    }
}

extension CorePlaceholders {
    /// Placeholder text written when the service or account name is empty, in the current UI language.
    static var current: CorePlaceholders {
        CorePlaceholders(unknownIssuer: L10n.tr("Unknown service"), emptyUsername: L10n.tr("No account"))
    }
}

extension ParsedOTPAuth {
    init(_ core: CoreParsedOtpAuth) {
        self.init(
            isValid: core.failure == nil,
            issuer: core.issuer,
            account: core.account,
            secret: core.secret,
            algorithm: TOTPAlgorithm(core.algorithm),
            digits: Int(core.digits),
            period: Int(core.period),
            reason: core.failure.map { L10n.tr(coreParseFailureL10nKey(failure: $0)) }
        )
    }
}

extension KakeyError {
    /// Maps to the app error type for each use case (unlock / category / import) so callers can branch on it (e.g. only
    /// `invalidPassword` counts toward repeated failures). The localization key comes from the core's `coreErrorL10nKey`.
    var vaultError: VaultPersistenceError {
        switch self {
        case .EmptyPassword: .emptyPassword
        case .UnacceptablePassword: .unacceptablePassword
        case .InvalidPassword, .InvalidId: .invalidPassword
        case .KeyDerivationFailed: .keyDerivationFailed
        case .InvalidKey: .invalidKey
        case .CryptoFailure: .cryptoFailure
        case .CorruptVault, .PasswordRequired, .InvalidFile, .WrongPassword, .NoSupportedAccounts,
            .EmptyCategoryName, .CategoryNameTooLong, .DuplicateCategoryName, .CategoryNotFound:
            .corruptVault
        }
    }

    var categoryError: Error {
        switch self {
        case .EmptyCategoryName: CategoryError.emptyName
        case .CategoryNameTooLong: CategoryError.nameTooLong
        case .DuplicateCategoryName: CategoryError.duplicateName
        case .CategoryNotFound, .InvalidId: CategoryError.notFound
        default: vaultError
        }
    }

    /// Errors for imported files: authentication failures and corrupt content in Kakey export files and Authenticator backups
    /// map to the same set of errors.
    var importError: Error {
        switch self {
        case .PasswordRequired: ExternalAccountImportError.passwordRequired
        case .WrongPassword, .InvalidPassword, .EmptyPassword, .UnacceptablePassword: ExternalAccountImportError.wrongPassword
        case .InvalidFile, .CorruptVault, .InvalidId: ExternalAccountImportError.invalidFile
        case .NoSupportedAccounts: ExternalAccountImportError.noSupportedAccounts
        case .KeyDerivationFailed, .InvalidKey, .CryptoFailure,
            .EmptyCategoryName, .CategoryNameTooLong, .DuplicateCategoryName, .CategoryNotFound:
            ExternalAccountImportError.failed
        }
    }
}

import Foundation
import SwiftUI

/// Ways to add an account, ordered by how common they are on the Mac: scan a QR code (screen selection / image / camera), enter a
/// secret, paste a link.
enum AddMethod: String, CaseIterable, Identifiable {
    case scan
    case key
    case text

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .scan: L10n.tr("Scan QR Code")
        case .key: L10n.tr("Enter Key")
        case .text: L10n.tr("Paste Links")
        }
    }
}

enum SettingsPanel: String, CaseIterable, Identifiable {
    case general
    case security
    case shortcuts
    case advanced

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .general: L10n.tr("General")
        case .security: L10n.tr("Security")
        case .shortcuts: L10n.tr("Shortcuts")
        case .advanced: L10n.tr("Advanced")
        }
    }
}

enum DockIconMode: String, CaseIterable, Identifiable {
    case always
    case mainWindowOnly
    case never

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .always: L10n.tr("Always Show")
        case .mainWindowOnly: L10n.tr("Only When Main Window Is Open")
        case .never: L10n.tr("Never Show")
        }
    }
}

/// Which accounts the menu bar panel shows. Persisted as a string: `all` or `category:<UUID>`.
enum MenuBarListScope: Hashable {
    case all
    case category(AccountCategory.ID)

    private static let categoryPrefix = "category:"

    /// Unrecognized values (including deleted categories) fall back to `.all`.
    init(storedValue: String?) {
        switch storedValue {
        case let value? where value.hasPrefix(Self.categoryPrefix):
            self = UUID(uuidString: String(value.dropFirst(Self.categoryPrefix.count))).map(MenuBarListScope.category) ?? .all
        default:
            self = .all
        }
    }

    var rawValue: String {
        switch self {
        case .all: "all"
        case .category(let id): Self.categoryPrefix + id.uuidString
        }
    }
}

enum ActiveSheet: Identifiable {
    case onboarding
    case addAccount
    case detail(Account)
    case accountQRCode(Account)
    case backupSync
    case exportImport
    case changePassword

    var id: String {
        switch self {
        case .onboarding: "onboarding"
        case .addAccount: "addAccount"
        case .detail(let account): "detail-\(account.id)"
        case .accountQRCode(let account): "accountQRCode-\(account.id)"
        case .backupSync: "backupSync"
        case .exportImport: "exportImport"
        case .changePassword: "changePassword"
        }
    }
}

import Foundation
import SwiftUI

// Models shared by Mac and iOS / iPadOS. Business rules live in the Rust core; this only maps for presentation.

/// A section of the account list: All, or one user category.
enum VaultSection: Hashable {
    case all
    case category(AccountCategory.ID)

    /// The category ID when the section is a category; an account added singly inside a category also joins it.
    var categoryID: AccountCategory.ID? {
        if case .category(let id) = self { return id }
        return nil
    }
}

/// A user category. Array order is sidebar order; `accountIDs` defines both membership and order within the category. An
/// account can belong to several categories. The rules (naming, create / rename / delete, membership and ordering) are
/// implemented only in the core (`category.rs`) and called through `CategoryService`.
struct AccountCategory: Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    var accountIDs: [UUID]
}

/// The decrypted contents of the vault.
struct VaultContents: Equatable {
    var accounts: [Account]
    var categories: [AccountCategory]
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case light
    case dark
    case system

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .light: L10n.tr("Light")
        case .dark: L10n.tr("Dark")
        case .system: L10n.tr("System")
        }
    }
}

/// Auto-lock: locks after the chosen idle time since the last interaction, regardless of foreground / background state or
/// whether windows are open (same on all three platforms). Only three options; an unreadable stored value falls back to
/// each platform's default, with no migration.
enum AutoLockMode: String, CaseIterable, Identifiable {
    case oneMinute = "1m"
    case fiveMinutes = "5m"
    case thirtyMinutes = "30m"

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .oneMinute: L10n.tr("1 minute")
        case .fiveMinutes: L10n.tr("5 minutes")
        case .thirtyMinutes: L10n.tr("30 minutes")
        }
    }

    /// Idle time before locking.
    var delaySeconds: TimeInterval {
        switch self {
        case .oneMinute: 60
        case .fiveMinutes: 5 * 60
        case .thirtyMinutes: 30 * 60
        }
    }
}

enum AccountProvenance {
    static let manual = "manual"
    static let imported = "import"

    static func localizedTitle(for stored: String) -> String {
        switch stored {
        case manual: L10n.tr("Added manually")
        case imported: L10n.tr("Imported")
        default: stored
        }
    }
}

enum TOTPAlgorithm: String, CaseIterable, Identifiable, Codable {
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"

    var id: String { rawValue }
}

struct Account: Identifiable, Equatable, Hashable {
    let id: UUID
    var issuer: String
    var username: String
    var secret: String
    var algorithm: TOTPAlgorithm
    var digits: Int
    var period: Int
    var createdAt: Date
    var addedBy: String

    init(
        id: UUID = UUID(),
        issuer: String,
        username: String,
        secret: String,
        algorithm: TOTPAlgorithm = .sha1,
        digits: Int = 6,
        period: Int = 30,
        createdAt: Date = .now,
        addedBy: String = AccountProvenance.manual
    ) {
        self.id = id
        self.issuer = issuer
        self.username = username
        self.secret = secret
        self.algorithm = algorithm
        self.digits = digits
        self.period = period
        self.createdAt = createdAt
        self.addedBy = addedBy
    }
}

extension Account {
    /// Badge color and monogram are always derived from the issuer, so they update immediately when it is edited.
    var color: Color { Self.color(for: issuer) }
    var monogram: String { Self.monogram(for: issuer) }
    var isRecentlyAdded: Bool { isRecentlyAdded(relativeTo: .now) }

    func isRecentlyAdded(relativeTo date: Date) -> Bool {
        let age = date.timeIntervalSince(createdAt)
        return age >= 0 && age <= Self.recentlyAddedInterval
    }

    /// The palette index comes from the core's FNV-1a hash of the issuer, so an issuer gets the same color on all three
    /// platforms; the palette order must match the core's.
    static func color(for issuer: String) -> Color {
        let palette: [Color] = [.blue, .purple, .orange, .green, .indigo, .pink, .teal, .brown]
        return palette[Int(corePaletteIndex(issuer: issuer)) % palette.count]
    }

    static func monogram(for issuer: String) -> String {
        coreMonogram(issuer: issuer)
    }

    private static let recentlyAddedInterval: TimeInterval = 30 * 60
}

extension Account {
    /// Deduplication key: accounts with identical issuer, username, secret, algorithm, digits and period are duplicates.
    /// Manual entry, QR codes, screenshots, text import and encrypted import all share this rule.
    var deduplicationKey: String {
        Self.deduplicationKey(issuer: issuer, username: username, secret: secret, algorithm: algorithm, digits: digits, period: period)
    }

    static func deduplicationKey(issuer: String, username: String, secret: String, algorithm: TOTPAlgorithm, digits: Int, period: Int)
        -> String
    {
        let probe = Account(issuer: issuer, username: username, secret: secret, algorithm: algorithm, digits: digits, period: period)
        return coreDeduplicationKey(account: probe.core, placeholders: .current)
    }
}

extension ParsedOTPAuth {
    var deduplicationKey: String {
        Account.deduplicationKey(issuer: issuer, username: account, secret: secret, algorithm: algorithm, digits: digits, period: period)
    }
}

extension Account {
    /// Substring or in-order fuzzy match on service and account names only (rules in the core's `search.rs`).
    func matchesSearch(_ query: String) -> Bool {
        coreMatchesSearch(issuer: issuer, username: username, query: query)
    }
}

struct ParsedOTPAuth: Identifiable {
    let id = UUID()
    var isValid: Bool
    var issuer: String
    var account: String
    var secret: String
    var algorithm: TOTPAlgorithm = .sha1
    var digits: Int = 6
    var period: Int = 30
    var reason: String?
}

enum BackupStatus: Equatable {
    case enabled(lastBackup: Date)
    case disabled
    case running
    case conflict
    /// The local key cannot decrypt the remote backup: sync stops, and the only way forward is "Restore from Backup".
    case unreadable
    case failed(message: String)
}

struct BackupHistoryItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var date: Date
    var device: String
    var size: String
    /// Stores an L10n key (e.g. `icloud.hist.auto`) and localizes at display time, so history follows language changes.
    var sourceKey: String
    var isFailure = false
    /// Data direction of a successful sync; nil for failures and conflicts.
    var direction: SyncDirection?
    /// Name of the location synced (OneDrive, iCloud, a folder name, ...), so records stay distinguishable after switching
    /// locations. Optional.
    var location: String?

    var isWarning: Bool { isFailure }

    var statusText: String {
        if isFailure { return L10n.format("icloud.hist.failed_fmt", L10n.tr(sourceKey)) }
        return L10n.tr(sourceKey)
    }

    /// The record title: the result for successes (uploaded / downloaded / no changes), otherwise the status (failures,
    /// conflicts and records without a direction).
    var title: String {
        guard !isWarning, let direction else { return statusText }
        switch direction {
        case .upload: return L10n.tr("Uploaded")
        case .download: return L10n.tr("Downloaded")
        case .unchanged: return L10n.tr("No changes")
        }
    }

    /// Second line: the location, the trigger (auto sync, manual backup, ...), and "from X" when the data came from another
    /// device. No trigger when the title is already the status. The device only matters for downloads and conflicts
    /// (uploads and failures are always this device) and is omitted when it matches this device's name.
    func detail(thisDevice: String) -> String? {
        let source = title == statusText ? nil : L10n.tr(sourceKey)
        let origin = direction == .upload || isFailure || device == thisDevice ? nil : L10n.format("From %@", device)
        let parts = [location, source, origin].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var systemImage: String {
        if isWarning { return "exclamationmark.triangle" }
        return direction?.systemImage ?? "clock.arrow.circlepath"
    }
}

/// Data direction of a successful sync.
enum SyncDirection: String, Codable, Sendable {
    /// This device overwrote the backup (upload, keep local, upload after merge).
    case upload
    /// The backup replaced this device's vault (download, use backup, restore).
    case download
    /// Both sides were already in sync.
    case unchanged

    var systemImage: String {
        switch self {
        case .upload: "arrow.up"
        case .download: "arrow.down"
        case .unchanged: "checkmark"
        }
    }
}

/// Wait policy after repeated wrong master passwords: 30 seconds from the 5th failure, doubling with each further failure,
/// capped at 5 minutes. The rules live in the core (`password.rs`).
enum UnlockThrottle {
    static func lockoutDuration(afterConsecutiveFailures count: Int) -> TimeInterval? {
        coreUnlockLockoutSeconds(consecutiveFailures: UInt32(clamping: count))
    }
}

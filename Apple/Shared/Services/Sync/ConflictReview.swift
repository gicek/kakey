import CryptoKit
import Foundation

/// Conflict comparison (see docs/TECHNICAL.md): decrypts the backup and compares it account by account with the local
/// vault, so the UI can show the differences and the outcome of each of the four choices. Kept in memory only; accounts
/// contain secrets, so the UI shows only service name, account name and "secret differs". The comparison rules live in the
/// core (`merge.rs`).
struct ConflictReview: Equatable {
    struct ChangedAccount: Identifiable, Equatable {
        var local: Account
        var remote: Account
        var changes: [CoreAccountChange]
        var id: UUID { local.id }

        /// Each side's name ("service · account") when the service or account name differs, shown side by side and labeled;
        /// nil when both match.
        var differingNames: (local: String, remote: String)? {
            guard local.issuer != remote.issuer || local.username != remote.username else { return nil }
            return (
                Self.name(of: local, showingUsername: local.username != remote.username),
                Self.name(of: remote, showingUsername: local.username != remote.username)
            )
        }

        private static func name(of account: Account, showingUsername: Bool) -> String {
            showingUsername && !account.username.isEmpty ? "\(account.issuer) · \(account.username)" : account.issuer
        }
    }

    var localCount: Int
    var remoteCount: Int
    var localUpdatedAt: Date
    var remoteUpdatedAt: Date
    var remoteDevice: String?
    var onlyLocal: [Account]
    var onlyRemote: [Account]
    var changed: [ChangedAccount]
    var categoriesOnlyLocal: [String]
    var categoriesOnlyRemote: [String]
    var categoriesRenamed: [(local: String, remote: String)]
    /// The decrypted backup contents and the remote version seen during comparison: merging uses these, and the upload
    /// requires the remote to still be this version.
    var remoteContents: VaultContents
    var remoteVersion: CoreRemoteVersion?

    /// Accounts changed on both sides default to the side saved more recently.
    var remoteIsNewer: Bool { remoteUpdatedAt > localUpdatedAt }

    static func == (lhs: ConflictReview, rhs: ConflictReview) -> Bool {
        lhs.remoteVersion == rhs.remoteVersion && lhs.localUpdatedAt == rhs.localUpdatedAt && lhs.changed == rhs.changed
            && lhs.onlyLocal == rhs.onlyLocal && lhs.onlyRemote == rhs.onlyRemote
    }

    /// Decrypts the backup with the local key and compares it with local contents; throws
    /// `VaultSyncError.unreadableRemote` if it cannot be decrypted.
    init(local: VaultContents, localUpdatedAt: Date, remote: RemoteVaultSnapshot, key: SymmetricKey) throws {
        let remoteCore: CoreVaultContents
        do {
            remoteCore = try coreVaultOpen(data: remote.encryptedData, key: key.withUnsafeBytes { Data($0) })
        } catch {
            throw VaultSyncError.unreadableRemote
        }
        let diff = try coreVaultDiff(local: local.core, remote: remoteCore, placeholders: .current)
        localCount = local.accounts.count
        remoteCount = remoteCore.accounts.count
        self.localUpdatedAt = localUpdatedAt
        remoteUpdatedAt = remote.vaultUpdatedAt
        remoteDevice = remote.deviceName
        onlyLocal = diff.onlyLocal.map(Account.init)
        onlyRemote = diff.onlyRemote.map(Account.init)
        changed = diff.changed.map { ChangedAccount(local: Account($0.local), remote: Account($0.remote), changes: $0.changes) }
        categoriesOnlyLocal = diff.categoriesOnlyLocal
        categoriesOnlyRemote = diff.categoriesOnlyRemote
        categoriesRenamed = diff.categoriesRenamed.map { ($0.local, $0.remote) }
        remoteContents = VaultContents(remoteCore)
        remoteVersion = remote.version
    }

    /// The merge result; `preferRemote` holds accounts changed on both sides for which the backup version was chosen.
    func merged(local: VaultContents, preferRemote: Set<UUID>) throws -> VaultContents {
        VaultContents(
            try coreVaultMerge(
                local: local.core, remote: remoteContents.core, preferRemoteIds: preferRemote.map { $0.uuidString.uppercased() },
                placeholders: .current))
    }

    /// Describes how an account differs between the two sides (never including secret values).
    static func describe(_ changes: [CoreAccountChange]) -> String {
        changes.map { change in
            switch change {
            case .issuer: L10n.tr("Name")
            case .username: L10n.tr("Account name")
            case .secret: L10n.tr("Secret key")
            case .parameters: L10n.tr("Algorithm, digits or period")
            case .categories: L10n.tr("Categories")
            }
        }.joined(separator: L10n.tr(", "))
    }
}

/// Used as a navigation destination: comparisons with the same remote version and local time are considered the same.
extension ConflictReview: Hashable, Identifiable {
    var id: Int { hashValue }

    func hash(into hasher: inout Hasher) {
        hasher.combine(remoteVersion)
        hasher.combine(localUpdatedAt)
        hasher.combine(changed.map(\.id))
    }
}

/// Message for the UI when the conflict comparison fails (cannot decrypt, offline, etc.).
struct ConflictReviewFailure: Error {
    var message: String
}

extension SyncBackend {
    /// Reads the backup and compares it with the local vault (called on conflict). Throws `missingRemoteVault` when the
    /// remote has no backup and `unreadableRemote` when it cannot be decrypted. `remote` is the backup already read when the
    /// conflict was detected; if given, it is not downloaded again. The merged upload is a conditional write against its
    /// version, so it is rejected if the backup changed in the meantime.
    func conflictReview(local: VaultContents, key: SymmetricKey, remote known: RemoteVaultSnapshot? = nil) async throws
        -> ConflictReview
    {
        let remote: RemoteVaultSnapshot
        if let known {
            remote = known
        } else {
            remote = try await requireRemote()
        }
        let localData = try await files.encryptedData()
        let localUpdatedAt = try localData.map { try VaultPersistenceService.encryptedVaultEnvelope(from: $0).updatedAt } ?? .distantPast
        return try ConflictReview(local: local, localUpdatedAt: localUpdatedAt, remote: remote, key: key)
    }

    /// Uploads after a merge. The merged result is already saved locally; this requires the backup to still be the compared
    /// version (conditional write) and throws `remoteChanged` if it changed in the meantime, so the caller syncs and
    /// compares again.
    func uploadMerged(deviceName: String, comparedVersion: CoreRemoteVersion?) async throws -> (
        snapshot: RemoteVaultSnapshot, marks: SyncMarks
    ) {
        guard let data = try await files.encryptedData() else { throw VaultSyncError.missingLocalVault }
        let updatedAt = try VaultPersistenceService.encryptedVaultEnvelope(from: data).updatedAt
        let expecting: RemoteExpectation = comparedVersion.map(RemoteExpectation.unchanged) ?? .any
        let version = try await writeRemote(data, vaultUpdatedAt: updatedAt, deviceName: deviceName, expecting: expecting)
        let snapshot = RemoteVaultSnapshot(encryptedData: data, vaultUpdatedAt: updatedAt, version: version, deviceName: deviceName)
        return (snapshot, SyncMarks(lastLocalUpdatedAt: updatedAt, lastRemoteVersion: version))
    }
}

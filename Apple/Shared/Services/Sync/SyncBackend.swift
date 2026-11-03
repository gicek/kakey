import CryptoKit
import Foundation

/// Backend interface for backup and sync (see docs/TECHNICAL.md).
///
/// A backend implements only two things: reading the remote envelope and writing it (returning the remote version after
/// the write). Upload / download / conflict decisions live in the core (`sync.rs`), and the orchestration is in the
/// extension below, shared by every backend so they cannot drift apart. Implementations must be actors, so all operations
/// on one backend run serially.
protocol SyncBackend: Actor {
    /// The single entry point for reading and writing the local vault file.
    var files: VaultFileStore { get }
    /// The remote envelope (format already validated) and metadata, or nil when the remote has no backup.
    func readRemote() async throws -> RemoteVaultSnapshot?
    /// Writes the envelope and metadata and returns the remote version after the write. If `expecting` is not met, throws
    /// `VaultSyncError.remoteChanged` and leaves the remote unchanged; backends without conditional writes (folder) ignore it.
    func writeRemote(_ data: Data, vaultUpdatedAt: Date, deviceName: String, expecting: RemoteExpectation) async throws
        -> CoreRemoteVersion?
}

/// What the remote state must be for a write to proceed.
enum RemoteExpectation: Equatable, Sendable {
    /// The user explicitly chose to overwrite (manual backup, keep local on conflict).
    case any
    /// The remote had no backup when the decision was made.
    case absent
    /// The remote was at this version when the decision was made.
    case unchanged(CoreRemoteVersion)
}

/// Only the local key is trusted (see docs/TECHNICAL.md): a remote that changed since the last sync and cannot be
/// decrypted with the current local vault key is not synced. No upload, no download, no conflict choice; the only option
/// is an explicit "Restore from Backup" (`downloadRemoteToLocal`, then unlock with that backup's master password).
extension SyncBackend {
    /// Uploads, downloads, or reports a conflict or unreadable remote, as decided by the core; returns new sync marks for the
    /// caller to persist. `key` is the current local vault key. If another device changed the remote during upload (the
    /// conditional write is rejected), reads and decides again. `prefetched` is a remote just read (by the link check) and
    /// is used only for the first decision, saving a full download; writes are still conditional, so a remote changed in
    /// the meantime is rejected and read again.
    func sync(marks: SyncMarks, deviceName: String, key: SymmetricKey, prefetched: RemoteRead? = nil) async throws
        -> VaultSyncOutcome
    {
        var attempt = 0
        var prefetched = prefetched
        while true {
            attempt += 1
            do {
                let remote: RemoteVaultSnapshot?
                if let read = prefetched {
                    remote = read.snapshot
                    prefetched = nil
                } else {
                    remote = try await readRemote()
                }
                return try await syncOnce(remote: remote, marks: marks, deviceName: deviceName, key: key)
            } catch VaultSyncError.remoteChanged where attempt < 2 {
                continue
            }
        }
    }

    /// Read-only check before linking a location: throws `VaultSyncError.unreadableRemote` if the remote has a backup that
    /// differs from the local vault and the local key cannot decrypt it, so the caller does not enable the location. Passes
    /// if it decrypts or there is no backup; differing contents become a conflict in the following first sync, where the
    /// user picks a direction. Returns the remote read so the caller can pass it to that first sync (`sync(prefetched:)`)
    /// without downloading again.
    @discardableResult
    func checkLink(key: SymmetricKey) async throws -> RemoteRead {
        guard let remote = try await readRemote() else { return RemoteRead(snapshot: nil) }
        let local = try await localSnapshot()
        if local?.data != remote.encryptedData, !Self.opens(remote, with: key) {
            throw VaultSyncError.unreadableRemote
        }
        return RemoteRead(snapshot: remote)
    }

    /// Manual backup / keep local on conflict: the local envelope overwrites the remote. Refuses if the remote changed since
    /// the last sync and the local key cannot decrypt it, so someone else's backup is never overwritten.
    func uploadLocal(deviceName: String, marks: SyncMarks, key: SymmetricKey) async throws -> (
        snapshot: RemoteVaultSnapshot, marks: SyncMarks
    ) {
        guard let local = try await localSnapshot() else { throw VaultSyncError.missingLocalVault }
        if let remote = try await readRemote(), remote.version == nil || remote.version != marks.lastRemoteVersion,
            remote.encryptedData != local.data, !Self.opens(remote, with: key)
        {
            throw VaultSyncError.unreadableRemote
        }
        return try await upload(local, deviceName: deviceName, expecting: .any)
    }

    static func opens(_ remote: RemoteVaultSnapshot, with key: SymmetricKey) -> Bool {
        coreVaultOpensWithKey(data: remote.encryptedData, key: key.withUnsafeBytes { Data($0) })
    }

    /// First-time restore / use remote on conflict: the remote envelope overwrites the local main file.
    func downloadRemoteToLocal() async throws -> (snapshot: RemoteVaultSnapshot, marks: SyncMarks) {
        let remote = try await requireRemote()
        return (remote, try await replaceLocal(with: remote))
    }

    /// Throws `VaultSyncError.missingRemoteVault` when the remote has no backup.
    func requireRemote() async throws -> RemoteVaultSnapshot {
        guard let remote = try await readRemote() else { throw VaultSyncError.missingRemoteVault }
        return remote
    }

    private func syncOnce(remote: RemoteVaultSnapshot?, marks: SyncMarks, deviceName: String, key: SymmetricKey) async throws
        -> VaultSyncOutcome
    {
        let local = try await localSnapshot()
        let decision = coreDecideSync(
            local: local.map { CoreLocalSnapshot(data: $0.data, vaultUpdatedAt: $0.updatedAt) },
            remote: remote.map { CoreRemoteSnapshot(data: $0.encryptedData, version: $0.version, readable: Self.opens($0, with: key)) },
            marks: CoreSyncMarks(lastLocalUpdatedAt: marks.lastLocalUpdatedAt, lastRemoteVersion: marks.lastRemoteVersion)
        )

        switch (decision, local, remote) {
        case (.noLocalVault, _, _):
            return .noLocalVault
        case (.upload, let local?, _):
            let expecting: RemoteExpectation = remote.map { $0.version.map(RemoteExpectation.unchanged) ?? .any } ?? .absent
            let (uploaded, newMarks) = try await upload(local, deviceName: deviceName, expecting: expecting)
            return .uploaded(uploaded, newMarks)
        case (.download, _, let remote?):
            return .downloaded(remote, try await replaceLocal(with: remote))
        case (.upToDate, let local?, _):
            return .upToDate(remote, SyncMarks(lastLocalUpdatedAt: local.updatedAt, lastRemoteVersion: remote?.version))
        case (.conflict, _, let remote?):
            return .conflict(remote)
        case (.unreadable, _, let remote?):
            return .unreadable(remote)
        default:
            // The core returns upload / download / in sync / conflict only when the corresponding snapshot exists.
            return .noLocalVault
        }
    }

    private func localSnapshot() async throws -> (data: Data, updatedAt: Date)? {
        guard let data = try await files.encryptedData() else { return nil }
        return (data, try VaultPersistenceService.encryptedVaultEnvelope(from: data).updatedAt)
    }

    private func upload(_ local: (data: Data, updatedAt: Date), deviceName: String, expecting: RemoteExpectation) async throws
        -> (snapshot: RemoteVaultSnapshot, marks: SyncMarks)
    {
        let version = try await writeRemote(local.data, vaultUpdatedAt: local.updatedAt, deviceName: deviceName, expecting: expecting)
        let snapshot = RemoteVaultSnapshot(
            encryptedData: local.data, vaultUpdatedAt: local.updatedAt, version: version, deviceName: deviceName)
        return (snapshot, SyncMarks(lastLocalUpdatedAt: local.updatedAt, lastRemoteVersion: version))
    }

    /// The remote envelope overwrites the local main file. First-time restore calls `requireRemote` and saves the credentials
    /// before calling this.
    func replaceLocal(with remote: RemoteVaultSnapshot) async throws -> SyncMarks {
        let envelope = try await files.replaceEncryptedVault(with: remote.encryptedData)
        return SyncMarks(lastLocalUpdatedAt: envelope.updatedAt, lastRemoteVersion: remote.version)
    }
}

/// The local envelope time and remote version recorded at the last successful sync, persisted by the caller. The remote
/// version is stored in the core's text form (`encodedRemoteVersion`).
struct SyncMarks: Equatable, Sendable {
    var lastLocalUpdatedAt: Date?
    var lastRemoteVersion: CoreRemoteVersion?

    static let none = SyncMarks()

    /// Persisted text form of the remote version (same format on all three platforms; see the core's `RemoteVersion::encode`).
    var encodedRemoteVersion: String? {
        lastRemoteVersion.map(coreEncodeRemoteVersion(version:))
    }

    init(lastLocalUpdatedAt: Date? = nil, lastRemoteVersion: CoreRemoteVersion? = nil) {
        self.lastLocalUpdatedAt = lastLocalUpdatedAt
        self.lastRemoteVersion = lastRemoteVersion
    }

    /// An unreadable remote version is treated as never synced (no legacy formats are read).
    init(lastLocalUpdatedAt: Date?, encodedRemoteVersion: String?) {
        self.init(lastLocalUpdatedAt: lastLocalUpdatedAt, lastRemoteVersion: encodedRemoteVersion.flatMap(coreDecodeRemoteVersion(text:)))
    }
}

struct RemoteVaultSnapshot: Sendable {
    var encryptedData: Data
    var vaultUpdatedAt: Date
    var version: CoreRemoteVersion?
    var deviceName: String?
}

/// Remote backup and location held in memory during first-time restore, written to disk only after the master password is
/// confirmed (same on all three platforms).
struct PendingOnboardingRestore {
    var snapshot: RemoteVaultSnapshot
    var location: SyncLocation
    var connection: Data?
}

/// A completed remote read (`snapshot` nil means the remote has no backup), passed to the next step to avoid downloading
/// again.
struct RemoteRead: Sendable {
    var snapshot: RemoteVaultSnapshot?
}

enum VaultSyncOutcome: Sendable {
    case uploaded(RemoteVaultSnapshot, SyncMarks)
    case downloaded(RemoteVaultSnapshot, SyncMarks)
    case upToDate(RemoteVaultSnapshot?, SyncMarks)
    case conflict(RemoteVaultSnapshot)
    /// The remote changed since the last sync and the local key cannot decrypt it: no sync, only an explicit "Restore from
    /// Backup".
    case unreadable(RemoteVaultSnapshot)
    case noLocalVault
}

enum VaultSyncError: LocalizedError {
    case folderUnavailable
    case missingLocalVault
    case missingRemoteVault
    case corruptRemoteVault
    /// Conditional write rejected: another device changed the remote after the decision.
    case remoteChanged
    /// The local key cannot decrypt the remote backup (a different vault, or another device changed the master password).
    case unreadableRemote
    case coordination(Error)

    var errorDescription: String? {
        switch self {
        case .folderUnavailable: L10n.tr("Can’t access the sync folder. Choose it again.")
        case .missingLocalVault: L10n.tr("No local encrypted vault available to sync.")
        case .missingRemoteVault: L10n.tr("No Kakey backup was found in that folder.")
        case .corruptRemoteVault: L10n.tr("The backup file format is invalid.")
        case .remoteChanged: L10n.tr(coreCloudErrorL10nKey(error: .Conflict))
        case .unreadableRemote:
            L10n.tr(
                "The backup here can’t be opened with this vault’s key. It belongs to another vault, or its master password was changed on another device."
            )
        case .coordination(let error): error.localizedDescription
        }
    }
}

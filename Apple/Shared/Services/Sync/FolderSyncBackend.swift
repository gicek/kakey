import Foundation

/// Folder backend: coordinated reads and writes of the encrypted vault in a user-chosen sync folder (iCloud Drive or a
/// folder synced by a cloud drive client).
///
/// Layout: `vault.kakeyvault` (the encrypted envelope, a verbatim copy of the local vault) plus `vault.metadata.json`
/// (device name and time, not sensitive). All remote reads and writes go through `NSFileCoordinator` (the system downloads
/// iCloud files that are not local yet; writes use `.forReplacing`). The remote version is the file modification time;
/// file systems have no conditional writes, so `expecting` is ignored and the core detects conflicts by modification time.

actor FolderSyncBackend: SyncBackend {
    static let vaultFileName = "vault.kakeyvault"
    static let metadataFileName = "vault.metadata.json"

    private struct Metadata: Codable {
        var schemaVersion: Int
        var deviceName: String
        var vaultUpdatedAt: Date
        var savedAt: Date
    }

    /// Root resolved from the security-scoped bookmark (iOS); nil on Mac, which is not sandboxed.
    private let accessRoot: URL?
    private let folder: URL
    let files: VaultFileStore

    init(folder: URL, accessRoot: URL? = nil, files: VaultFileStore = .shared) {
        self.folder = folder
        self.accessRoot = accessRoot
        self.files = files
    }

    private var vaultURL: URL { folder.appendingPathComponent(Self.vaultFileName) }
    private var metadataURL: URL { folder.appendingPathComponent(Self.metadataFileName) }

    func readRemote() throws -> RemoteVaultSnapshot? {
        try withAccess {
            guard let data = try Self.coordinatedRead(vaultURL) else { return nil }
            let envelope: CoreEnvelopeInfo
            do {
                envelope = try VaultPersistenceService.encryptedVaultEnvelope(from: data)
            } catch {
                throw VaultSyncError.corruptRemoteVault
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: vaultURL.path)
            let metadata = (try? Self.coordinatedRead(metadataURL)).flatMap { try? JSONDecoder.kakey.decode(Metadata.self, from: $0) }
            return RemoteVaultSnapshot(
                encryptedData: data,
                vaultUpdatedAt: envelope.updatedAt,
                version: Self.version(modifiedAt: attributes?[.modificationDate] as? Date),
                deviceName: metadata?.deviceName
            )
        }
    }

    func writeRemote(_ data: Data, vaultUpdatedAt: Date, deviceName: String, expecting: RemoteExpectation) throws
        -> CoreRemoteVersion?
    {
        try withAccess {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.coordinatedWrite(data, to: vaultURL)
            let metadata = Metadata(schemaVersion: 1, deviceName: deviceName, vaultUpdatedAt: vaultUpdatedAt, savedAt: .now)
            try Self.coordinatedWrite(try JSONEncoder.kakey.encode(metadata), to: metadataURL)
            return Self.version(modifiedAt: (try? FileManager.default.attributesOfItem(atPath: vaultURL.path))?[.modificationDate] as? Date)
        }
    }

    // MARK: - Internals

    private static func version(modifiedAt: Date?) -> CoreRemoteVersion? {
        modifiedAt.map { .modifiedAt(at: $0) }
    }

    private func withAccess<T>(_ body: () throws -> T) throws -> T {
        guard let accessRoot else { return try body() }
        let granted = accessRoot.startAccessingSecurityScopedResource()
        defer { if granted { accessRoot.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    /// Checks the file size against `ExternalFileLimits` before reading; an oversized file is treated as a corrupt remote file.
    private static func coordinatedRead(_ url: URL) throws -> Data? {
        var coordinationError: NSError?
        var result: Result<Data?, Error> = .success(nil)
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            guard FileManager.default.fileExists(atPath: readURL.path) else { return }
            result = Result { try ExternalFileLimits.read(contentsOf: readURL) }
        }
        if let coordinationError {
            if coordinationError.domain == NSCocoaErrorDomain, coordinationError.code == NSFileReadNoSuchFileError {
                return nil
            }
            throw VaultSyncError.coordination(coordinationError)
        }
        do {
            return try result.get()
        } catch is ExternalFileLimits.TooLarge {
            throw VaultSyncError.corruptRemoteVault
        }
    }

    private static func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error> = .success(())
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writeURL in
            result = Result { try data.write(to: writeURL, options: .atomic) }
        }
        if let coordinationError { throw VaultSyncError.coordination(coordinationError) }
        try result.get()
    }
}

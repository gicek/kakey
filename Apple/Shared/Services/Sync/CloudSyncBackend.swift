import Foundation

/// Cloud storage backend (see docs/TECHNICAL.md): `vault.kakeyvault` + `vault.metadata.json` in the chosen remote folder.
///
/// The protocols and Kakey's remote layout live in the core (`cloudset` + `kakey_core::backup`); this only drives
/// operations: it executes the requests the core returns, hands back the responses, and saves a new connection blob as soon
/// as an operation returns one. The remote version is an ETag / rev and writes are conditional: if the remote changed after
/// the sync decision, this throws `VaultSyncError.remoteChanged` and `SyncBackend.sync` decides again. Other failures are
/// `CloudSyncError`.
actor CloudSyncBackend: SyncBackend {
    let files: VaultFileStore
    private let folder: String
    private let runner: CloudOperationRunner

    /// `folder` is a path relative to the storage root, separated by `/`, e.g. `Kakey`.
    init(
        folder: String, connections: any CloudConnectionStoring, executor: any HTTPExecuting, userAgent: String,
        files: VaultFileStore = .shared
    ) {
        self.folder = folder
        self.files = files
        runner = CloudOperationRunner(connections: connections, executor: executor, userAgent: userAgent)
    }

    func readRemote() async throws -> RemoteVaultSnapshot? {
        let outcome = try await runner.run { connection, userAgent in
            try coreCloudFetchBackup(connection: connection, folder: folder, userAgent: userAgent)
        }
        guard case .backup(let backup) = outcome else { throw CloudSyncError.service(.Internal) }
        guard let backup else { return nil }
        let envelope: CoreEnvelopeInfo
        do {
            envelope = try VaultPersistenceService.encryptedVaultEnvelope(from: backup.data)
        } catch {
            throw VaultSyncError.corruptRemoteVault
        }
        return RemoteVaultSnapshot(
            encryptedData: backup.data, vaultUpdatedAt: envelope.updatedAt, version: backup.version, deviceName: backup.deviceName)
    }

    func writeRemote(_ data: Data, vaultUpdatedAt: Date, deviceName: String, expecting: RemoteExpectation) async throws
        -> CoreRemoteVersion?
    {
        let mode: CoreUploadMode =
            switch expecting {
            case .any: .overwrite
            case .absent: .ifUnchanged(expected: nil)
            case .unchanged(let version): .ifUnchanged(expected: version)
            }
        let outcome: CoreCloudOutcome
        do {
            outcome = try await runner.run { connection, userAgent in
                try coreCloudUploadBackup(
                    connection: connection, folder: folder, data: data, deviceName: deviceName, vaultUpdatedAt: vaultUpdatedAt,
                    savedAt: .now, mode: mode, userAgent: userAgent)
            }
        } catch CloudSyncError.service(.Conflict) {
            throw VaultSyncError.remoteChanged
        }
        guard case .uploaded(let version) = outcome else { throw CloudSyncError.service(.Internal) }
        return version
    }
}

/// Drives a core cloud storage operation: passes the saved connection blob to the constructor and executes requests until
/// the operation finishes, saving a new connection blob as soon as one is returned.
struct CloudOperationRunner: Sendable {
    let connections: any CloudConnectionStoring
    let executor: any HTTPExecuting
    let userAgent: String

    func run(_ make: @Sendable (_ connection: Data, _ userAgent: String) throws -> CoreCloudOperation) async throws -> CoreCloudOutcome {
        guard let connection = try connections.load() else { throw CloudSyncError.service(.ReauthRequired) }
        return try await drive(try Self.wrapping { try make(connection, userAgent) })
    }

    /// Operations that need no saved connection (Nextcloud sign-in) also go through here.
    func drive(_ operation: CoreCloudOperation) async throws -> CoreCloudOutcome {
        var response: CoreHttpResponse?
        while true {
            try Task.checkCancellation()
            switch try Self.wrapping({ try operation.advance(response: response) }) {
            case .send(let request):
                response = try await executor.execute(request)
            case .done(let outcome, let connection):
                if let connection { try connections.save(connection) }
                return outcome
            }
        }
    }

    private static func wrapping<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as CoreCloudError {
            throw CloudSyncError.service(error)
        }
    }
}

/// Platform form of a cloud storage failure (the `LocalizedError` that UniFFI generates for `CoreCloudError` only gives a
/// debug description). The localization key comes from the core's `core_cloud_error_l10n_key`; server errors include the
/// status code.
enum CloudSyncError: LocalizedError, Equatable {
    case service(CoreCloudError)

    var errorDescription: String? {
        switch self {
        case .service(let error):
            let key = coreCloudErrorL10nKey(error: error)
            if case .Server(let status) = error {
                return L10n.format(key, Int(status))
            }
            return L10n.tr(key)
        }
    }
}

/// Shared text for sync and connection failures: network and certificate errors use the app's own wording (in the UI
/// language); everything else uses `LocalizedError`.
enum SyncErrorText {
    /// `location` is where the error occurred: when the remote has no backup, the message names that location; without a
    /// location, a generic message is used.
    static func message(for error: Error, at location: SyncLocation? = nil) -> String {
        if case VaultSyncError.missingRemoteVault = error, let location {
            return location.missingBackupMessage
        }
        // A changed certificate gets no one-tap trust (docs/SECURITY.md): it may be a man-in-the-middle, so the
        // user must go back to the connection screen and verify again.
        switch error as? CloudCertificateError {
        case .untrusted: return L10n.tr("The server’s certificate can’t be verified")
        case .changed: return L10n.tr("The server’s certificate has changed. Set up this location again to check the new certificate")
        case nil: break
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .timedOut, .dnsLookupFailed:
                return L10n.tr("Can’t reach the server. Check the address and your network connection")
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
                .secureConnectionFailed:
                return L10n.tr("The server’s certificate isn’t trusted")
            default:
                return urlError.localizedDescription
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

import CloudKit
import Foundation

/// iCloud backup (see docs/SECURITY.md): a single record in the CloudKit private database.
///
/// The record lives in the custom zone `Kakey`, with type `Vault` and name `vault`. `envelope` is the encrypted envelope
/// as-is (an asset); device name and envelope time go in `encryptedValues` (always end-to-end encrypted). The remote
/// version is the record's `recordChangeTag`; the server checks the write condition and rejects writes if another device
/// changed the record after the decision (`VaultSyncError.remoteChanged`). Upload / download / conflict decisions reuse
/// the `SyncBackend` extension.
enum ICloudVault {
    static let zoneName = "Kakey"
    static let recordType = "Vault"
    static let recordName = "vault"
    static let subscriptionID = "kakey-vault-changes"

    /// This build's CloudKit container (`KakeyICloudContainer` in Info.plist, written from the signing configuration at
    /// build time). Builds without a development team (ad-hoc, CI) have no iCloud capability, so this is nil and the iCloud
    /// option is unavailable in the UI.
    static var containerIdentifier: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "KakeyICloudContainer") as? String,
            value.hasPrefix("iCloud.")
        else { return nil }
        return value
    }

    /// The production CloudKit store, or nil when the build has no iCloud capability.
    static func makeLiveStore() -> (any ICloudVaultStoring)? {
        containerIdentifier.map(CloudKitVaultStore.init(containerIdentifier:))
    }

    /// Whether a push comes from the backup record subscription (another device changed the backup).
    static func isVaultChange(_ userInfo: [AnyHashable: Any]) -> Bool {
        CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID == subscriptionID
    }
}

/// State of the iCloud account on this device.
enum ICloudAccountState: Sendable, Equatable {
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable
}

/// What the server record must be for a write to proceed (mirrors `RemoteExpectation`).
enum ICloudWriteCondition: Sendable, Equatable {
    /// The record does not exist.
    case absent
    /// The record is still at this version.
    case unchanged(changeTag: String)
    /// Overwrite unconditionally (the user's explicit choice).
    case any
}

/// The backup record on the server.
struct ICloudVaultRecord: Sendable, Equatable {
    var envelope: Data
    var deviceName: String?
    var changeTag: String
}

/// Narrow CloudKit interface: the backend reads and writes only through it, and tests use an in-memory implementation
/// that never touches real iCloud.
protocol ICloudVaultStoring: Sendable {
    func accountState() async throws -> ICloudAccountState
    /// The current iCloud account's user record name in this container (an opaque ID with no personal information), used to
    /// detect account switches.
    func accountID() async throws -> String
    /// Nil when there is no backup (including when the zone is missing or the user deleted it in Settings).
    func fetch() async throws -> ICloudVaultRecord?
    /// Returns the changeTag after the write; throws `ICloudSyncError.recordChanged` if the condition is not met.
    func save(envelope: Data, deviceName: String, vaultUpdatedAt: Date, condition: ICloudWriteCondition) async throws -> String
    /// Deletes the backup (the whole zone with its record); succeeds if it does not exist.
    func deleteBackup() async throws
    /// Subscribes to backup change pushes (subscribing again overwrites the same ID).
    func subscribe() async throws
    func unsubscribe() async throws
}

enum ICloudSyncError: LocalizedError, Equatable {
    case notSignedIn
    case restricted
    case temporarilyUnavailable
    /// The device switched iCloud accounts: this device's data is not written into the other account, and iCloud must be
    /// chosen again.
    case accountChanged
    case offline
    case quotaExceeded
    case busy
    /// The build has no iCloud capability (unsigned or missing the entitlement).
    case notEntitled
    /// The server record is no longer the version seen at decision time (conditional write rejected).
    case recordChanged
    case service(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: L10n.tr("Sign in to iCloud on this device to use iCloud backup.")
        case .restricted: L10n.tr("iCloud is restricted on this device, for example by Screen Time or device management.")
        case .temporarilyUnavailable: L10n.tr("iCloud is temporarily unavailable. Try again later.")
        case .accountChanged: L10n.tr("The iCloud account on this device changed. Choose iCloud again to back up to the new account.")
        case .offline: L10n.tr("Can’t reach iCloud. Check your internet connection.")
        case .quotaExceeded: L10n.tr("Your iCloud storage is full.")
        case .busy: L10n.tr("iCloud is busy. Kakey will try again later.")
        case .notEntitled: L10n.tr("This build of Kakey can’t use iCloud.")
        case .recordChanged: L10n.tr(coreCloudErrorL10nKey(error: .Conflict))
        case .service(let message): message
        }
    }

    /// Classifies CloudKit errors; for a partial failure, uses the first sub-error.
    static func from(_ error: Error) -> Error {
        guard let ckError = error as? CKError else { return error }
        switch ckError.code {
        case .partialFailure:
            if let first = ckError.partialErrorsByItemID?.values.first { return from(first) }
            return service(ckError.localizedDescription)
        case .notAuthenticated: return notSignedIn
        case .managedAccountRestricted: return restricted
        case .accountTemporarilyUnavailable: return temporarilyUnavailable
        case .networkUnavailable, .networkFailure: return offline
        case .quotaExceeded: return quotaExceeded
        case .serviceUnavailable, .requestRateLimited, .zoneBusy: return busy
        case .missingEntitlement, .badContainer, .permissionFailure: return notEntitled
        case .serverRecordChanged: return recordChanged
        default: return service(ckError.localizedDescription)
        }
    }
}

/// iCloud backend reading and writing through `ICloudVaultStoring`. Before its first read or write, each instance confirms
/// the account is available and is still the account linked earlier.
actor ICloudSyncBackend: SyncBackend {
    let files: VaultFileStore
    private let store: any ICloudVaultStoring
    /// The account at link time; nil during the link check (no account yet), which only confirms an account is available.
    private let linkedAccount: String?
    private var accountVerified = false

    init(store: any ICloudVaultStoring, linkedAccount: String?, files: VaultFileStore = .shared) {
        self.store = store
        self.linkedAccount = linkedAccount
        self.files = files
    }

    func readRemote() async throws -> RemoteVaultSnapshot? {
        try await verifyAccount()
        guard let record = try await mapped({ try await store.fetch() }) else { return nil }
        guard record.envelope.count <= ExternalFileLimits.maxBytes else { throw VaultSyncError.corruptRemoteVault }
        let envelope: CoreEnvelopeInfo
        do {
            envelope = try VaultPersistenceService.encryptedVaultEnvelope(from: record.envelope)
        } catch {
            throw VaultSyncError.corruptRemoteVault
        }
        return RemoteVaultSnapshot(
            encryptedData: record.envelope, vaultUpdatedAt: envelope.updatedAt, version: .revision(value: record.changeTag),
            deviceName: record.deviceName)
    }

    func writeRemote(_ data: Data, vaultUpdatedAt: Date, deviceName: String, expecting: RemoteExpectation) async throws
        -> CoreRemoteVersion?
    {
        try await verifyAccount()
        let condition: ICloudWriteCondition
        switch expecting {
        case .any: condition = .any
        case .absent: condition = .absent
        case .unchanged(.revision(let tag)): condition = .unchanged(changeTag: tag)
        // A version from another kind of location (should not happen): treat the remote as changed so it is read again.
        case .unchanged: throw VaultSyncError.remoteChanged
        }
        do {
            let tag = try await mapped {
                try await store.save(envelope: data, deviceName: deviceName, vaultUpdatedAt: vaultUpdatedAt, condition: condition)
            }
            return .revision(value: tag)
        } catch ICloudSyncError.recordChanged {
            throw VaultSyncError.remoteChanged
        }
    }

    private func verifyAccount() async throws {
        guard !accountVerified else { return }
        switch try await mapped({ try await store.accountState() }) {
        case .available: break
        case .noAccount: throw ICloudSyncError.notSignedIn
        case .restricted: throw ICloudSyncError.restricted
        case .temporarilyUnavailable: throw ICloudSyncError.temporarilyUnavailable
        }
        if let linkedAccount, try await mapped({ try await store.accountID() }) != linkedAccount {
            throw ICloudSyncError.accountChanged
        }
        accountVerified = true
    }

    private func mapped<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw ICloudSyncError.from(error)
        }
    }
}

/// The production CloudKit store. The fetched server record is kept in memory, and conditional writes modify and save it
/// (the server checks the changeTag).
actor CloudKitVaultStore: ICloudVaultStoring {
    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID = CKRecordZone.ID(zoneName: ICloudVault.zoneName, ownerName: CKCurrentUserDefaultName)
    private var recordID: CKRecord.ID { CKRecord.ID(recordName: ICloudVault.recordName, zoneID: zoneID) }
    private var lastRecord: CKRecord?

    init(containerIdentifier: String) {
        container = CKContainer(identifier: containerIdentifier)
        database = container.privateCloudDatabase
    }

    func accountState() async throws -> ICloudAccountState {
        switch try await container.accountStatus() {
        case .available: .available
        case .noAccount: .noAccount
        case .restricted: .restricted
        case .couldNotDetermine, .temporarilyUnavailable: .temporarilyUnavailable
        @unknown default: .temporarilyUnavailable
        }
    }

    func accountID() async throws -> String {
        try await container.userRecordID().recordName
    }

    func fetch() async throws -> ICloudVaultRecord? {
        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch let error as CKError where Self.isMissing(error) {
            lastRecord = nil
            return nil
        }
        lastRecord = record
        guard let asset = record["envelope"] as? CKAsset, let url = asset.fileURL else { throw VaultSyncError.corruptRemoteVault }
        let envelope: Data
        do {
            envelope = try ExternalFileLimits.read(contentsOf: url)
        } catch is ExternalFileLimits.TooLarge {
            throw VaultSyncError.corruptRemoteVault
        }
        return ICloudVaultRecord(
            envelope: envelope, deviceName: record.encryptedValues["deviceName"] as? String, changeTag: record.recordChangeTag ?? "")
    }

    func save(envelope: Data, deviceName: String, vaultUpdatedAt: Date, condition: ICloudWriteCondition) async throws -> String {
        do {
            return try await saveOnce(envelope: envelope, deviceName: deviceName, vaultUpdatedAt: vaultUpdatedAt, condition: condition)
        } catch let error as CKError where Self.isMissingZone(error) {
            // First write, or the user deleted the data under Manage Storage: create the zone and write again.
            _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
            lastRecord = nil
            return try await saveOnce(envelope: envelope, deviceName: deviceName, vaultUpdatedAt: vaultUpdatedAt, condition: condition)
        }
    }

    func deleteBackup() async throws {
        do {
            _ = try await database.modifyRecordZones(saving: [], deleting: [zoneID])
        } catch let error as CKError where Self.isMissing(error) {
            // Already gone.
        }
        lastRecord = nil
    }

    func subscribe() async throws {
        let subscription = CKDatabaseSubscription(subscriptionID: ICloudVault.subscriptionID)
        subscription.recordType = ICloudVault.recordType
        let info = CKSubscription.NotificationInfo()
        // Silent push: only wakes the app to sync, without showing a notification.
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try await database.save(subscription)
    }

    func unsubscribe() async throws {
        do {
            _ = try await database.deleteSubscription(withID: ICloudVault.subscriptionID)
        } catch let error as CKError where error.code == .unknownItem {
            // Never subscribed.
        }
    }

    // MARK: - Internals

    private func saveOnce(envelope: Data, deviceName: String, vaultUpdatedAt: Date, condition: ICloudWriteCondition) async throws
        -> String
    {
        let record: CKRecord
        let policy: CKModifyRecordsOperation.RecordSavePolicy
        switch condition {
        case .absent:
            // A new record implies "must not exist on the server": if it does, the server returns serverRecordChanged.
            record = CKRecord(recordType: ICloudVault.recordType, recordID: recordID)
            policy = .ifServerRecordUnchanged
        case .unchanged(let tag):
            record = try await serverRecord(matching: tag)
            policy = .ifServerRecordUnchanged
        case .any:
            record = try await currentRecordOrNew()
            policy = .allKeys
        }

        // The asset file is just the encrypted envelope, deleted right after the write.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kakey-\(UUID().uuidString).kakeyvault")
        try envelope.write(to: file, options: [.atomic, .completeFileProtection])
        defer { try? FileManager.default.removeItem(at: file) }
        record["envelope"] = CKAsset(fileURL: file)
        record.encryptedValues["deviceName"] = deviceName
        record.encryptedValues["vaultUpdatedAt"] = vaultUpdatedAt

        let (results, _) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: policy, atomically: true)
        guard let result = results[recordID] else { throw ICloudSyncError.service(L10n.tr("Unable to save the backup")) }
        let saved = try result.get()
        lastRecord = saved
        return saved.recordChangeTag ?? ""
    }

    /// Conditional writes must modify the server record: uses the in-memory copy if it is at this version, otherwise
    /// fetches again and compares.
    private func serverRecord(matching tag: String) async throws -> CKRecord {
        if let lastRecord, lastRecord.recordChangeTag == tag { return lastRecord }
        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch let error as CKError where Self.isMissing(error) {
            throw ICloudSyncError.recordChanged
        }
        guard record.recordChangeTag == tag else { throw ICloudSyncError.recordChanged }
        return record
    }

    private func currentRecordOrNew() async throws -> CKRecord {
        do {
            return try await database.record(for: recordID)
        } catch let error as CKError where Self.isMissing(error) {
            return CKRecord(recordType: ICloudVault.recordType, recordID: recordID)
        }
    }

    private static func isMissing(_ error: CKError) -> Bool {
        error.code == .unknownItem || isMissingZone(error)
    }

    private static func isMissingZone(_ error: CKError) -> Bool {
        error.code == .zoneNotFound || error.code == .userDeletedZone
    }
}

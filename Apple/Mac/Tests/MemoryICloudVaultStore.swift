import Foundation

@testable import Kakey

/// In-memory CloudKit private database shared by the Mac and iOS tests: one backup record per iCloud account plus an incrementing
/// changeTag, rejecting stale conditional writes like the server. Tests can switch account status and account (a different account
/// is a different private database), simulate a write from another device, and make the next call fail.
final class MemoryICloudVaultStore: ICloudVaultStoring, @unchecked Sendable {
    static let account = "_test-icloud-user"

    private let lock = NSLock()
    private var records: [String: ICloudVaultRecord] = [:]
    private var revision = 0
    private var state: ICloudAccountState = .available
    private var currentAccount = MemoryICloudVaultStore.account
    private var nextError: Error?
    private(set) var isSubscribed = false
    private(set) var saveCount = 0

    // MARK: - Test controls

    private var record: ICloudVaultRecord? {
        get { records[currentAccount] }
        set { records[currentAccount] = newValue }
    }

    var envelope: Data? { locked { record?.envelope } }
    var deviceName: String? { locked { record?.deviceName } }

    func setAccountState(_ state: ICloudAccountState) { locked { self.state = state } }
    func switchAccount(to account: String) { locked { currentAccount = account } }
    func failNextCall(with error: Error) { locked { nextError = error } }

    /// Another device writes new content (new changeTag).
    func overwrite(with data: Data, deviceName: String = "Other Device") {
        locked {
            revision += 1
            record = ICloudVaultRecord(envelope: data, deviceName: deviceName, changeTag: "tag-\(revision)")
        }
    }

    // MARK: - ICloudVaultStoring

    func accountState() async throws -> ICloudAccountState {
        try locked {
            try throwPending()
            return state
        }
    }

    func accountID() async throws -> String {
        try locked {
            try throwPending()
            return currentAccount
        }
    }

    func fetch() async throws -> ICloudVaultRecord? {
        try locked {
            try throwPending()
            return record
        }
    }

    func save(envelope: Data, deviceName: String, vaultUpdatedAt: Date, condition: ICloudWriteCondition) async throws -> String {
        try locked {
            try throwPending()
            switch condition {
            case .absent where record != nil: throw ICloudSyncError.recordChanged
            case .unchanged(let tag) where record?.changeTag != tag: throw ICloudSyncError.recordChanged
            default: break
            }
            revision += 1
            saveCount += 1
            record = ICloudVaultRecord(envelope: envelope, deviceName: deviceName, changeTag: "tag-\(revision)")
            return "tag-\(revision)"
        }
    }

    func deleteBackup() async throws {
        try locked {
            try throwPending()
            record = nil
        }
    }

    func subscribe() async throws { locked { isSubscribed = true } }
    func unsubscribe() async throws { locked { isSubscribed = false } }

    // MARK: - Internals

    private func throwPending() throws {
        if let error = nextError {
            nextError = nil
            throw error
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

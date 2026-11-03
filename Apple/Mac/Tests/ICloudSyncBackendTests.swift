import CloudKit
import CryptoKit
import XCTest

@testable import Kakey

/// iCloud backend (CloudKit injected as an in-memory implementation): conditional writes, account checks, record validation, and
/// CloudKit error classification.
final class ICloudSyncBackendTests: XCTestCase {
    private var directory: URL!
    private var store: MemoryICloudVaultStore!
    private var files: VaultFileStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KakeyICloudTests-\(UUID().uuidString)", isDirectory: true)
        VaultPersistenceService.vaultURLOverride = directory.appendingPathComponent("vault.json")
        store = MemoryICloudVaultStore()
        files = VaultFileStore()
    }

    override func tearDown() async throws {
        VaultPersistenceService.vaultURLOverride = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func backend(account: String? = MemoryICloudVaultStore.account) -> ICloudSyncBackend {
        ICloudSyncBackend(store: store, linkedAccount: account, files: files)
    }

    private func envelope(_ issuer: String = "GitHub") throws -> Data {
        let account = Account(issuer: issuer, username: "alex", secret: "MZXW6YTBOI")
        _ = try VaultPersistenceService.save(VaultContents(accounts: [account], categories: []), password: "pw", now: .now)
        return try VaultPersistenceService.encryptedVaultData()
    }

    func testWritesAreConditionalOnTheServerVersion() async throws {
        let backend = backend()
        let data = try envelope()
        let first = try await backend.writeRemote(data, vaultUpdatedAt: .now, deviceName: "Mac", expecting: .absent)
        guard case .revision(let tag)? = first else { return XCTFail("The version is the changeTag") }

        do {
            _ = try await backend.writeRemote(data, vaultUpdatedAt: .now, deviceName: "Mac", expecting: .absent)
            XCTFail("A must-not-exist write is rejected when a backup already exists")
        } catch VaultSyncError.remoteChanged {}

        store.overwrite(with: try envelope("Other"))
        do {
            _ = try await backend.writeRemote(data, vaultUpdatedAt: .now, deviceName: "Mac", expecting: .unchanged(.revision(value: tag)))
            XCTFail("Changed by another device after the check: rejected, not silently overwritten")
        } catch VaultSyncError.remoteChanged {}

        let read = try await backend.readRemote()
        XCTAssertEqual(read?.deviceName, "Other Device")
        let overwritten = try await backend.writeRemote(data, vaultUpdatedAt: .now, deviceName: "Mac", expecting: .any)
        XCTAssertNotEqual(overwritten, read?.version, "Writes unconditionally when the user explicitly chooses to overwrite")
        XCTAssertEqual(store.envelope, data)
    }

    /// First sync: with an empty remote, uploads as must-not-exist and records the server's version in the sync marks.
    func testFirstSyncUploadsAndRemembersTheServerVersion() async throws {
        let backend = backend()
        let key = try await files.create(password: "pw")
        let outcome = try await backend.sync(marks: .none, deviceName: "Mac", key: key)
        guard case .uploaded(_, let marks) = outcome else { return XCTFail("Empty remote: upload") }
        XCTAssertNotNil(store.envelope)
        let remote = try await backend.readRemote()
        XCTAssertEqual(marks.lastRemoteVersion, remote?.version)
    }

    func testReadValidatesTheRecord() async throws {
        store.overwrite(with: Data("not a vault".utf8))
        do {
            _ = try await backend().readRemote()
            XCTFail("Not a Kakey envelope")
        } catch VaultSyncError.corruptRemoteVault {}

        store.overwrite(with: Data(count: ExternalFileLimits.maxBytes + 1))
        do {
            _ = try await backend().readRemote()
            XCTFail("Over the limit is treated as corrupt")
        } catch VaultSyncError.corruptRemoteVault {}
    }

    func testAccountIsCheckedBeforeTheFirstRequest() async throws {
        store.setAccountState(.noAccount)
        do {
            _ = try await backend().readRemote()
            XCTFail("Not signed in")
        } catch ICloudSyncError.notSignedIn {}

        store.setAccountState(.available)
        store.switchAccount(to: "another")
        do {
            _ = try await backend().readRemote()
            XCTFail("Account changed")
        } catch ICloudSyncError.accountChanged {}

        let linking = backend(account: nil)
        let read = try await linking.readRemote()
        XCTAssertNil(read, "The link check only requires an available account")
    }

    func testCloudKitErrorsAreClassified() {
        func mapped(_ code: CKError.Code) -> ICloudSyncError? { ICloudSyncError.from(CKError(code)) as? ICloudSyncError }
        XCTAssertEqual(mapped(.notAuthenticated), .notSignedIn)
        XCTAssertEqual(mapped(.networkUnavailable), .offline)
        XCTAssertEqual(mapped(.networkFailure), .offline)
        XCTAssertEqual(mapped(.quotaExceeded), .quotaExceeded)
        XCTAssertEqual(mapped(.requestRateLimited), .busy)
        XCTAssertEqual(mapped(.missingEntitlement), .notEntitled)
        XCTAssertEqual(mapped(.serverRecordChanged), .recordChanged)
        XCTAssertEqual(mapped(.accountTemporarilyUnavailable), .temporarilyUnavailable)

        let id = CKRecord.ID(recordName: ICloudVault.recordName)
        let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [id: CKError(.serverRecordChanged)]])
        XCTAssertEqual(ICloudSyncError.from(partial) as? ICloudSyncError, .recordChanged, "Partial failure uses the inner error")

        let other = URLError(.badURL)
        XCTAssertEqual((ICloudSyncError.from(other) as? URLError)?.code, .badURL, "Non-CloudKit errors pass through unchanged")
    }

    func testVaultChangeNotificationIsRecognized() {
        XCTAssertFalse(ICloudVault.isVaultChange([:]))
        XCTAssertFalse(ICloudVault.isVaultChange(["aps": ["content-available": 1]]))
    }
}

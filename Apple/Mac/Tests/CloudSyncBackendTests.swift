import CryptoKit
import XCTest

@testable import Kakey

/// Cloud storage backend: drives the real core protocol (cloudset + kakey_core::backup) through in-memory WebDAV; the shared sync
/// orchestration lives in the `SyncBackend` extension.
final class CloudSyncBackendTests: XCTestCase {
    private var directory: URL!
    private var files: VaultFileStore!
    private var server: MemoryDavExecutor!
    private var connections: InMemoryCloudConnectionStore!
    private let clockBox = Locked(Date(timeIntervalSince1970: 1_800_000_000))

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("KakeyCloudTests-\(UUID().uuidString)", isDirectory: true)
        VaultPersistenceService.vaultURLOverride = directory.appendingPathComponent("vault.json")
        files = VaultFileStore(now: { [clockBox] in clockBox.value })
        server = MemoryDavExecutor()
        let connection = try coreCloudWebdavConnection(
            url: MemoryDavExecutor.base, username: "alice", password: "pw", allowInsecureHttp: false, trustedCertificate: nil)
        connections = InMemoryCloudConnectionStore(connection)
    }

    override func tearDown() async throws {
        VaultPersistenceService.vaultURLOverride = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func backend() -> CloudSyncBackend {
        CloudSyncBackend(folder: "Kakey", connections: connections, executor: server, userAgent: "Kakey-test", files: files)
    }

    private func advanceClock(_ seconds: TimeInterval = 60) {
        clockBox.value = clockBox.value.addingTimeInterval(seconds)
    }

    private var key: SymmetricKey!

    private func createLocalVault(password: String = "local password") async throws {
        key = try await files.create(password: password)
    }

    /// An envelope another device wrote with its own master password (this device's key cannot decrypt it).
    private func foreignVault(password: String) throws -> Data {
        try coreVaultCreate(
            password: password, contents: CoreVaultContents(accounts: [], categories: [], pinnedIds: []), now: clockBox.value
        ).data
    }

    /// A newer version of the same vault from another device (same key, decryptable here).
    private func sameVaultRemote() throws -> Data {
        advanceClock()
        return try coreVaultReseal(
            existing: try VaultPersistenceService.encryptedVaultData(), key: key.withUnsafeBytes { Data($0) },
            contents: CoreVaultContents(accounts: [], categories: [], pinnedIds: []), now: clockBox.value)
    }

    /// A local change (same key).
    private func changeLocal() throws {
        advanceClock()
        _ = try VaultPersistenceService.save(VaultContents(accounts: [], categories: []), key: key, now: clockBox.value)
    }

    func testFirstSyncUploadsWithFolderCreationThenDownloadsRemoteChanges() async throws {
        try await createLocalVault()
        let backend = backend()
        guard case .uploaded(let uploaded, let marks) = try await backend.sync(marks: .none, deviceName: "Mac", key: key) else {
            return XCTFail("First sync should upload")
        }
        let local = try await files.encryptedData()
        XCTAssertEqual(server.data(at: "Kakey/vault.kakeyvault"), local, "Local envelope uploaded unchanged")
        XCTAssertNotNil(server.data(at: "Kakey/vault.metadata.json"))
        XCTAssertEqual(uploaded.deviceName, "Mac")
        guard case .revision = marks.lastRemoteVersion else { return XCTFail("Cloud storage remote version is the ETag") }
        XCTAssertTrue(server.requests.contains { $0.method == "MKCOL" }, "Creates the directory first when missing")
        XCTAssertTrue(
            server.requests.allSatisfy { request in request.headers.contains { $0.name == "User-Agent" && $0.value == "Kakey-test" } })

        guard case .upToDate = try await backend.sync(marks: marks, deviceName: "Mac", key: key) else { return XCTFail("No changes") }

        let remote = try sameVaultRemote()
        server.putExternal("Kakey/vault.kakeyvault", remote)
        server.putExternal("Kakey/vault.metadata.json", Data(#"{"schemaVersion":1,"deviceName":"iPhone"}"#.utf8))
        guard case .downloaded(let downloaded, let newMarks) = try await backend.sync(marks: marks, deviceName: "Mac", key: key) else {
            return XCTFail("Only the remote changed and this key can decrypt it: download")
        }
        let downloadedLocal = try await files.encryptedData()
        XCTAssertEqual(downloadedLocal, remote)
        XCTAssertEqual(downloaded.deviceName, "iPhone", "Device name comes from the metadata written by the other device")
        XCTAssertNotEqual(newMarks.lastRemoteVersion, marks.lastRemoteVersion)
    }

    func testRemoteTheLocalKeyCannotOpenIsNeverSyncedOrOverwritten() async throws {
        try await createLocalVault()
        let backend = backend()
        guard case .uploaded(_, let marks) = try await backend.sync(marks: .none, deviceName: "Mac", key: key) else { return XCTFail() }
        let localBefore = try await files.encryptedData()

        let foreign = try foreignVault(password: "other")
        server.putExternal("Kakey/vault.kakeyvault", foreign)
        guard case .unreadable = try await backend.sync(marks: marks, deviceName: "Mac", key: key) else {
            return XCTFail("A different vault / another device changed the master password: do not sync")
        }
        try changeLocal()
        guard case .unreadable = try await backend.sync(marks: marks, deviceName: "Mac", key: key) else {
            return XCTFail("No conflict even when both sides changed")
        }
        do {
            _ = try await backend.uploadLocal(deviceName: "Mac", marks: marks, key: key)
            XCTFail("A manual backup must not overwrite an undecryptable remote either")
        } catch VaultSyncError.unreadableRemote {}
        do {
            try await backend.checkLink(key: key)
            XCTFail("Link check fails")
        } catch VaultSyncError.unreadableRemote {}
        XCTAssertEqual(server.data(at: "Kakey/vault.kakeyvault"), foreign, "Remote kept unchanged")
        let localAfter = try await files.encryptedData()
        XCTAssertNotEqual(localAfter, localBefore, "Local changes remain and are not replaced")

        _ = try await backend.downloadRemoteToLocal()
        let restored = try await files.encryptedData()
        XCTAssertEqual(restored, foreign, "Only an explicit Restore from Backup replaces this device")
    }

    func testLocalPasswordChangeStillUploadsOverItsOwnPreviousBackup() async throws {
        try await createLocalVault()
        let backend = backend()
        guard case .uploaded(_, let marks) = try await backend.sync(marks: .none, deviceName: "Mac", key: key) else { return XCTFail() }
        advanceClock()
        try await createLocalVault(password: "new password")
        guard case .uploaded = try await backend.sync(marks: marks, deviceName: "Mac", key: key) else {
            return XCTFail("Remote unchanged: the copy under the old key is this device's own last write, so upload as usual")
        }
        let local = try await files.encryptedData()
        XCTAssertEqual(server.data(at: "Kakey/vault.kakeyvault"), local)
    }

    func testBothSidesChangedIsAConflictAndKeepLocalOverwrites() async throws {
        try await createLocalVault()
        let backend = backend()
        guard case .uploaded(_, let marks) = try await backend.sync(marks: .none, deviceName: "Mac", key: key) else { return XCTFail() }

        server.putExternal("Kakey/vault.kakeyvault", try sameVaultRemote())
        try changeLocal()
        guard case .conflict = try await backend.sync(marks: marks, deviceName: "Mac", key: key) else { return XCTFail("Both changed") }
        try await backend.checkLink(key: key)

        let (_, kept) = try await backend.uploadLocal(deviceName: "Mac", marks: marks, key: key)
        let local = try await files.encryptedData()
        XCTAssertEqual(server.data(at: "Kakey/vault.kakeyvault"), local, "Keep this device: overwrite the remote")
        guard case .upToDate = try await backend.sync(marks: kept, deviceName: "Mac", key: key) else { return XCTFail() }
    }

    /// The remote read by the link check is handed to the first sync and the conflict screen, so the same backup is downloaded
    /// only once (OneDrive was observed reading it three times in a row).
    func testLinkCheckReadIsReusedBySyncAndConflictReview() async throws {
        try await createLocalVault()
        let backend = backend()
        guard case .uploaded(_, let marks) = try await backend.sync(marks: .none, deviceName: "Mac", key: key) else { return XCTFail() }
        server.putExternal("Kakey/vault.kakeyvault", try sameVaultRemote())
        try changeLocal()
        let downloads = { self.server.requests.filter { $0.method == "GET" && $0.url.hasSuffix("/vault.kakeyvault") }.count }

        let before = downloads()
        let checked = try await backend.checkLink(key: key)
        guard case .conflict(let remote) = try await backend.sync(marks: marks, deviceName: "Mac", key: key, prefetched: checked) else {
            return XCTFail("Both sides changed")
        }
        let review = try await backend.conflictReview(local: VaultContents(accounts: [], categories: []), key: key, remote: remote)
        XCTAssertEqual(review.remoteVersion, remote.version)
        XCTAssertEqual(downloads() - before, 1, "Check, sync, and conflict comparison share one download")

        // No further read either when the prefetch found no remote backup
        let empty = CloudSyncBackend(folder: "Empty", connections: connections, executor: server, userAgent: "Kakey-test", files: files)
        let checkedEmpty = try await empty.checkLink(key: key)
        let requests = server.requests.count
        guard case .uploaded = try await empty.sync(marks: .none, deviceName: "Mac", key: key, prefetched: checkedEmpty) else {
            return XCTFail()
        }
        XCTAssertEqual(server.requests[requests].method, "PUT", "The first sync request is the write, without reading the remote first")
    }

    func testRemoteWrittenDuringUploadIsRedecided() async throws {
        try await createLocalVault()
        let backend = backend()
        guard case .uploaded(_, let marks) = try await backend.sync(marks: .none, deviceName: "Mac", key: key) else { return XCTFail() }

        let other = try sameVaultRemote()
        try changeLocal()
        server.writeBeforeNextPut(other)
        guard case .conflict(let remote) = try await backend.sync(marks: marks, deviceName: "Mac", key: key) else {
            return XCTFail("Re-evaluated after the conditional write was rejected: both sides changed")
        }
        XCTAssertEqual(remote.encryptedData, other)
        XCTAssertEqual(server.data(at: "Kakey/vault.kakeyvault"), other, "A rejected write does not overwrite the other device's content")
    }

    func testRestoreDownloadsRemoteAndRejectsDamagedBackups() async throws {
        let backend = backend()
        do {
            _ = try await backend.downloadRemoteToLocal()
            XCTFail("No remote backup")
        } catch VaultSyncError.missingRemoteVault {}

        let remote = try foreignVault(password: "restore me")
        server.putExternal("Kakey/vault.kakeyvault", remote)
        let (snapshot, marks) = try await backend.downloadRemoteToLocal()
        XCTAssertEqual(snapshot.encryptedData, remote)
        let local = try await files.encryptedData()
        XCTAssertEqual(local, remote)
        XCTAssertNotNil(marks.lastRemoteVersion)

        server.putExternal("Kakey/vault.kakeyvault", Data("not a vault".utf8))
        do {
            _ = try await backend.requireRemote()
            XCTFail("Corrupt remote envelope")
        } catch VaultSyncError.corruptRemoteVault {}
    }

    func testMissingConnectionAndTransportFailures() async throws {
        try await createLocalVault()
        connections.remove()
        do {
            _ = try await backend().sync(marks: .none, deviceName: "Mac", key: key)
            XCTFail("No saved connection")
        } catch CloudSyncError.service(.ReauthRequired) {}
        XCTAssertTrue(server.requests.isEmpty)

        connections = InMemoryCloudConnectionStore(
            try coreCloudWebdavConnection(
                url: MemoryDavExecutor.base, username: "alice", password: "pw", allowInsecureHttp: false, trustedCertificate: nil))
        server.failNextRequest(with: URLError(.notConnectedToInternet))
        do {
            _ = try await backend().sync(marks: .none, deviceName: "Mac", key: key)
            XCTFail("Offline")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
    }

    func testCloudErrorsAreLocalized() {
        let reauth = CloudSyncError.service(.ReauthRequired).errorDescription ?? ""
        XCTAssertFalse(reauth.isEmpty)
        XCTAssertFalse(reauth.hasPrefix("err."), "Text comes from the String Catalog, not the semantic key itself")
        XCTAssertTrue(CloudSyncError.service(.Server(status: 503)).errorDescription?.contains("503") == true)
        XCTAssertEqual(VaultSyncError.remoteChanged.errorDescription, CloudSyncError.service(.Conflict).errorDescription)
    }

    @MainActor
    func testDefaultFolderIsCreatedInsideTheCurrentFolderAndStaysOnFailure() async throws {
        server.putExternal("home/notes.txt", Data("x".utf8))
        server.forbidCreatingFolders(in: "")
        let setup = CloudSetupService(executor: server, userAgent: "Kakey-test")
        let model = CloudSetupModel(provider: .webDAV, service: setup) { _ in }
        model.address = MemoryDavExecutor.base
        model.username = "alice"
        model.password = "pw"
        await model.submit()
        XCTAssertEqual(model.step, .chooseFolder)

        do {
            _ = try await model.useDefaultFolder()
            XCTFail("Creating a folder at the root is not allowed")
        } catch {}
        XCTAssertEqual(model.errorMessage, CloudSyncError.service(.Forbidden).errorDescription, "405 is not treated as already existing")
        XCTAssertEqual(model.currentPath, "", "Stays in place on failure")

        await model.open(try XCTUnwrap(model.folders.first { $0.name == "home" }))
        let result = try await model.useDefaultFolder()
        XCTAssertEqual(result.location.folder, "home/Kakey", "Creates Kakey in the current directory")
        XCTAssertEqual(model.currentFolderTitle, "home › Kakey")

        await model.goUp()
        let reused = try await model.useDefaultFolder()
        XCTAssertEqual(reused.location.folder, "home/Kakey", "Enters an existing Kakey directly")
    }

    @MainActor
    func testOnlyEmptyFoldersOrExistingBackupsCanBeChosen() async throws {
        server.putExternal("photos/a.jpg", Data("x".utf8))
        server.putExternal("old/.DS_Store", Data("x".utf8))
        server.putExternal("shared/vault.kakeyvault", Data("x".utf8))
        let model = CloudSetupModel(provider: .webDAV, service: CloudSetupService(executor: server, userAgent: "t")) { _ in }
        model.address = MemoryDavExecutor.base
        model.username = "alice"
        model.password = "pw"
        await model.submit()

        XCTAssertFalse(model.canUseCurrentFolder, "The root has subdirectories")
        XCTAssertThrowsError(try model.finish())
        for (name, usable) in [("photos", false), ("old", true), ("shared", true)] {
            await model.open(try XCTUnwrap(model.folders.first { $0.name == name }))
            XCTAssertEqual(model.canUseCurrentFolder, usable, name)
            await model.goUp()
        }

        server.putExternal("photos/Kakey/notes.txt", Data("x".utf8))
        await model.open(try XCTUnwrap(model.folders.first { $0.name == "photos" }))
        do {
            _ = try await model.useDefaultFolder()
            XCTFail("The existing Kakey directory contains other files")
        } catch {}
        XCTAssertEqual(model.errorMessage, CloudSetupModel.folderNotEmptyMessage)
    }

    /// The address may omit the scheme: a bare domain connects over HTTPS; a bare IP gets plain HTTP, which the user must confirm
    /// first.
    @MainActor
    func testAddressWithoutSchemeUsesHTTPSForDomainsAndAsksForIPs() async throws {
        let model = CloudSetupModel(provider: .webDAV, service: CloudSetupService(executor: server, userAgent: "t")) { _ in }
        model.address = String(MemoryDavExecutor.base.dropFirst("https://".count))
        model.username = "alice"
        model.password = "pw"
        await model.submit()
        XCTAssertFalse(model.needsInsecureConfirmation)
        XCTAssertEqual(model.step, .chooseFolder, "A domain gets https:// and connects directly")

        let ip = CloudSetupModel(provider: .webDAV, service: CloudSetupService(executor: server, userAgent: "t")) { _ in }
        ip.address = "192.168.1.10:5005/dav"
        ip.username = "alice"
        ip.password = "pw"
        await ip.submit()
        XCTAssertTrue(ip.needsInsecureConfirmation, "An IP gets http:// and the unencrypted connection must be confirmed first")
        XCTAssertEqual(ip.step, .form)
    }

    /// Self-signed certificate (docs/SECURITY.md): the first connection shows the fingerprint for the user to verify;
    /// after confirming, it reconnects with the fingerprint and the connection pins that certificate. If the certificate later
    /// changes, the connection fails without asking again (it could be a man-in-the-middle; the user must go back to the connection
    /// screen and verify again).
    @MainActor
    func testUntrustedCertificateIsPinnedOnlyAfterConfirmation() async throws {
        let certificate = Data(repeating: 0xab, count: 32)
        server.presentSelfSignedCertificate(certificate)
        let model = CloudSetupModel(provider: .webDAV, service: CloudSetupService(executor: server, userAgent: "t")) { _ in }
        model.address = MemoryDavExecutor.base
        model.username = "alice"
        model.password = "pw"
        await model.submit()
        XCTAssertEqual(model.untrustedCertificate, certificate)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.step, .form, "Does not connect before confirmation")

        // Like the iOS alert: the UI has already cleared the pending fingerprint before confirming, so the model uses only the
        // fingerprint passed in
        model.declineCertificate()
        await model.confirmCertificate(certificate)
        XCTAssertNil(model.untrustedCertificate)
        XCTAssertEqual(model.step, .chooseFolder)
        XCTAssertEqual(server.requests.last?.pinnedCertificate, certificate)
        let result = try model.finish()
        XCTAssertTrue(result.location.isCertificatePinned)
        XCTAssertTrue(try XCTUnwrap(coreCloudConnectionInfo(connectionBytes: result.connection)).hasPinnedCertificate)

        server.presentSelfSignedCertificate(Data(repeating: 0xcd, count: 32))
        await model.refresh()
        XCTAssertEqual(model.errorMessage, SyncErrorText.message(for: CloudCertificateError.changed(fingerprint: Data())))
        XCTAssertNil(model.untrustedCertificate, "A changed certificate is not offered one-tap trust")
    }

    /// For restore, only directories that already contain a backup can be chosen; an empty directory works for backup but has
    /// nothing to restore.
    @MainActor
    func testRestoreOnlyAcceptsFoldersWithABackup() async throws {
        server.putExternal("old/.DS_Store", Data("x".utf8))
        server.putExternal("shared/vault.kakeyvault", Data("x".utf8))
        let model = CloudSetupModel(provider: .webDAV, purpose: .restore, service: CloudSetupService(executor: server, userAgent: "t")) {
            _ in
        }
        model.address = MemoryDavExecutor.base
        model.username = "alice"
        model.password = "pw"
        await model.submit()

        XCTAssertEqual(model.title, L10n.format("Restore from %@", "WebDAV"))
        for (name, canRestore) in [("old", false), ("shared", true)] {
            await model.open(try XCTUnwrap(model.folders.first { $0.name == name }))
            XCTAssertTrue(model.canUseCurrentFolder, name)
            XCTAssertEqual(model.canFinish, canRestore, name)
            XCTAssertNil(model.folderHint, name)
            await model.goUp()
        }
    }

    /// Choosing WebDAV again during first-run restore prefills the form with the last input; if a reused connection falls back to
    /// the form after a transient network failure, it is not empty and tapping Connect retries.
    @MainActor
    func testRestoreReopenPrefillsTheFormWhenTheSavedConnectionFails() async throws {
        let connections = RestoreCloudConnections()
        let service = CloudSetupService(executor: server, userAgent: "t")
        let first = CloudSetupModel(provider: .webDAV, purpose: .restore, service: service) { _ in }
        guard case .open(nil) = connections.prepare(first) else { return XCTFail("First time opens the form") }
        first.address = MemoryDavExecutor.base
        first.username = "alice"
        first.password = "pw"
        await first.submit()
        XCTAssertEqual(first.step, .chooseFolder)
        XCTAssertEqual(first.password, "", "Fields are cleared after connecting")

        let again = CloudSetupModel(provider: .webDAV, purpose: .restore, service: service) { _ in }
        guard case .open(let resume?) = connections.prepare(again) else { return XCTFail("Reuses the last connection") }
        XCTAssertEqual(again.address, MemoryDavExecutor.base)
        XCTAssertEqual(again.username, "alice")
        XCTAssertEqual(again.password, "pw")

        server.failNextRequest(with: URLError(.timedOut))
        await again.resume(with: resume.location, connection: resume.connection)
        XCTAssertEqual(again.step, .form)
        XCTAssertNotNil(again.errorMessage)
        XCTAssertTrue(again.canSubmit, "The form still holds the last input")
        await again.submit()
        XCTAssertEqual(again.step, .chooseFolder)
    }

    /// Closing the connection screen cancels the operation in progress: the request is interrupted with the task instead of
    /// waiting in the background for a timeout.
    @MainActor
    func testClosingTheSetupCancelsItsOperations() async {
        let model = CloudSetupModel(provider: .webDAV, service: CloudSetupService(executor: server, userAgent: "t")) { _ in }
        let cancelled = expectation(description: "Operation cancelled")
        model.perform {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                cancelled.fulfill()
            }
        }
        model.cancel()
        await fulfillment(of: [cancelled], timeout: 5)
    }
}

import CloudKit
import Foundation

/// Backup and sync (see docs/TECHNICAL.md): location setup, automatic / manual sync, conflict handling, first-run restore, and
/// backup history. There is a single location (iCloud, a folder, or cloud storage). iCloud is a CloudKit private database (see
/// docs/SECURITY.md) and syncs immediately via silent push when another device changes the backup. The cloud storage connection
/// blob lives in `cloudConnections`; preferences hold only the non-sensitive `SyncLocation`.
extension MobileVaultStore {
    // MARK: - Location

    var syncLocation: SyncLocation? { preferences.syncLocation }

    /// Location name shown in Settings and lists.
    var syncFolderName: String? { syncLocation?.title }

    private var syncMarks: SyncMarks {
        get {
            SyncMarks(lastLocalUpdatedAt: preferences.lastSyncLocalUpdatedAt, encodedRemoteVersion: preferences.lastSyncRemoteVersion)
        }
        set {
            preferences.lastSyncLocalUpdatedAt = newValue.lastLocalUpdatedAt
            preferences.lastSyncRemoteVersion = newValue.encodedRemoteVersion
        }
    }

    var cloudSetup: CloudSetupService {
        var service = CloudSetupService(executor: httpExecutor, userAgent: Self.cloudUserAgent)
        // Dropbox authorizes through the official app when possible
        service.dropboxApp = OfficialDropboxAppAuthenticator()
        return service
    }

    static let cloudUserAgent = CloudSetupService.userAgent(platform: "iOS")

    /// Folder the user picked in the system file picker: picking a parent (such as the iCloud Drive root) uses its `Kakey/`
    /// subfolder, same as the Mac and Android.
    func syncLocation(forFolder url: URL) throws -> SyncLocation {
        .folder(bookmark: try SyncFolderService.bookmark(for: url), name: SyncFolderService.vaultFolder(for: url).lastPathComponent)
    }

    /// Syncs once right after a folder is chosen; returns an error message if the link check fails.
    @discardableResult
    func configureSync(folder: URL) async -> String? {
        do {
            return await configureSync(try syncLocation(forFolder: folder))
        } catch {
            return SyncErrorText.message(for: error)
        }
    }

    /// Enables or changes the backup location. Runs a read-only link check first: if the remote already has a backup that differs
    /// from this device and this device's key cannot decrypt it, the location is not enabled and an error message is returned.
    /// On success: cloud storage saves its connection blob first, and leaving cloud storage revokes and deletes the old connection
    /// on a best-effort basis; then the sync marks are cleared and one sync runs right away (decryptable but different content is
    /// judged a conflict by the core and the user picks a direction). Returns nil on success.
    @discardableResult
    func configureSync(_ location: SyncLocation, connection: Data? = nil) async -> String? {
        guard let key else { return L10n.tr("Unlock Kakey first") }
        let checked: RemoteRead
        do {
            let candidate = try makeSyncBackend(for: location, connections: InMemoryCloudConnectionStore(connection))
            checked = try await candidate.checkLink(key: key)
        } catch {
            return SyncErrorText.message(for: error)
        }
        syncDebounceTask?.cancel()
        do {
            if location.isCloud {
                guard let connection else { throw CloudSyncError.service(.ReauthRequired) }
                try cloudConnections.save(connection)
            } else if syncLocation?.isCloud == true {
                disconnectCloud()
            }
        } catch {
            syncStatus = .failed(SyncErrorText.message(for: error))
            return SyncErrorText.message(for: error)
        }
        if syncLocation?.isICloud == true, !location.isICloud {
            disableICloudPush()
        }
        preferences.syncLocation = location
        syncMarks = .none
        syncBackend = nil
        syncStatus = .idle
        if location.isICloud { enableICloudPush() }
        // The link check just read the remote: the first sync uses it instead of downloading again
        await sync(sourceKey: "icloud.hist.sync", prefetched: checked)
        return nil
    }

    /// Chooses iCloud: confirms this device is signed in to iCloud, records the current account, then links it like any other
    /// location. Returns an error message on failure.
    @discardableResult
    func linkICloud() async -> String? {
        do {
            return await configureSync(try await iCloudLocation())
        } catch {
            return SyncErrorText.message(for: error)
        }
    }

    /// Location for the current iCloud account; throws when the build lacks the iCloud capability or the account is signed out or
    /// restricted.
    func iCloudLocation() async throws -> SyncLocation {
        guard let iCloud else { throw ICloudSyncError.notEntitled }
        do {
            switch try await iCloud.accountState() {
            case .available: return .iCloud(account: try await iCloud.accountID())
            case .noAccount: throw ICloudSyncError.notSignedIn
            case .restricted: throw ICloudSyncError.restricted
            case .temporarilyUnavailable: throw ICloudSyncError.temporarilyUnavailable
            }
        } catch {
            throw ICloudSyncError.from(error)
        }
    }

    /// Turns off iCloud backup and deletes the backup in iCloud (the one copy shared by all devices). Waits for queued syncs first
    /// so it is not re-uploaded right after deletion; if deletion fails (offline, etc.) backup stays on and an error message is
    /// returned.
    func stopSyncDeletingICloudBackup() async -> String? {
        guard syncLocation?.isICloud == true, let iCloud else { return nil }
        syncDebounceTask?.cancel()
        await persistence.drain()
        do {
            try await iCloud.deleteBackup()
        } catch {
            return SyncErrorText.message(for: ICloudSyncError.from(error))
        }
        stopSync()
        return nil
    }

    /// Turns off backup: cloud storage also revokes authorization and deletes local credentials; an existing remote backup is not
    /// deleted (iCloud has a separate "also delete" option).
    func stopSync() {
        syncDebounceTask?.cancel()
        if syncLocation?.isCloud == true {
            disconnectCloud()
        }
        if syncLocation?.isICloud == true {
            disableICloudPush()
        }
        preferences.syncLocation = nil
        syncMarks = .none
        syncBackend = nil
        syncBackendLocation = nil
        syncStatus = .notConfigured
    }

    /// Revocation runs in the background without waiting (so the UI never hangs offline); local credentials are deleted
    /// immediately.
    func disconnectCloud() {
        if let connection = try? cloudConnections.load() {
            let setup = cloudSetup
            Task.detached { await setup.revoke(connection) }
        }
        cloudConnections.remove()
    }

    // MARK: - iCloud push and account

    /// Subscribes to backup changes and registers for push; the subscription is best effort (retried on next launch if offline).
    func enableICloudPush() {
        guard let iCloud else { return }
        registerForRemoteNotifications()
        Task.detached { try? await iCloud.subscribe() }
    }

    func disableICloudPush() {
        guard let iCloud else { return }
        Task.detached { try? await iCloud.unsubscribe() }
    }

    /// Another device changed the backup in iCloud (silent push, possibly waking the app in the background): when unlocked, syncs
    /// right away and waits for it; when locked, does nothing and syncs after unlock. Returns whether a sync ran.
    @discardableResult
    func iCloudBackupDidChange() async -> Bool {
        guard syncLocation?.isICloud == true, key != nil else { return false }
        await sync(sourceKey: "icloud.hist.auto")
        return true
    }

    func observeICloudAccount() {
        guard iCloud != nil else { return }
        iCloudAccountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.iCloudAccountDidChange() }
            }
        }
    }

    /// This device's iCloud account changed (signed out or switched): drops the backend bound to the confirmed account and syncs
    /// again. With a different account the backend reports "account changed" and sync stays failed, so data is never written into
    /// another account.
    func iCloudAccountDidChange() async {
        guard syncLocation?.isICloud == true else { return }
        syncBackend = nil
        await sync(sourceKey: "icloud.hist.auto")
    }

    // MARK: - Sync

    /// Coalesces to one sync 2 seconds after saving or unlocking (consecutive edits sync once).
    func scheduleSync() {
        guard syncLocation != nil else { return }
        syncDebounceTask?.cancel()
        syncDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            await self.sync(sourceKey: "icloud.hist.auto")
        }
    }

    /// The same location reuses the same actor, so all reads and writes are serialized.
    private func makeSyncBackend() throws -> any SyncBackend {
        guard let location = syncLocation else { throw VaultSyncError.folderUnavailable }
        if let syncBackend, syncBackendLocation == location { return syncBackend }
        let backend = try makeSyncBackend(for: location, connections: cloudConnections)
        syncBackend = backend
        syncBackendLocation = location
        return backend
    }

    private func makeSyncBackend(for location: SyncLocation, connections: any CloudConnectionStoring) throws -> any SyncBackend {
        switch location {
        case .folder(let bookmark, _):
            let root = try SyncFolderService.resolve(bookmark: bookmark)
            return FolderSyncBackend(folder: SyncFolderService.vaultFolder(for: root), accessRoot: root, files: files)
        case .cloud(let cloud):
            return CloudSyncBackend(
                folder: cloud.folder, connections: connections, executor: httpExecutor, userAgent: Self.cloudUserAgent, files: files)
        case .iCloud(let account):
            guard let iCloud else { throw ICloudSyncError.notEntitled }
            return ICloudSyncBackend(store: iCloud, linkedAccount: account, files: files)
        }
    }

    /// Uploads, downloads, or reports a conflict per the core's `sync.rs` decision; the user picks a direction for conflicts in
    /// Settings. Runs after queued saves and waits for completion.
    func sync(sourceKey: String = "icloud.hist.manual", prefetched: RemoteRead? = nil) async {
        // The decision needs this device's key to try the remote; no sync while locked, one runs after unlock
        guard syncLocation != nil, let key else { return }
        syncDebounceTask?.cancel()
        let deviceName = DeviceInfo.name
        await persistence.enqueue { [weak self] in
            guard let self else { return }
            self.syncStatus = .running
            do {
                let outcome = try await self.makeSyncBackend().sync(
                    marks: self.syncMarks, deviceName: deviceName, key: key, prefetched: prefetched)
                await self.apply(outcome, sourceKey: sourceKey)
            } catch {
                self.recordSyncFailure(error, sourceKey: sourceKey)
            }
        }.value
    }

    private func apply(_ outcome: VaultSyncOutcome, sourceKey: String) async {
        switch outcome {
        case .noLocalVault:
            syncStatus = .idle
        case .uploaded(let snapshot, let marks):
            syncMarks = marks
            syncStatus = .idle
            record(sourceKey, bytes: snapshot.encryptedData.count, direction: .upload)
        case .downloaded(let snapshot, let marks):
            await applyDownloaded(snapshot, marks: marks, sourceKey: sourceKey)
        case .upToDate(let snapshot, let marks):
            syncMarks = marks
            syncStatus = .idle
            // Automatic sync records no history when both sides match; a user-initiated "Back Up Now" needs a result (same as
            // the Mac)
            if sourceKey != "icloud.hist.auto", let snapshot {
                record(sourceKey, bytes: snapshot.encryptedData.count, device: snapshot.deviceName, direction: .unchanged)
            }
        // Conflict and "cannot decrypt" are states awaiting the user, with no data transfer, so no history; only the outcome after
        // resolution is recorded
        case .conflict(let snapshot):
            conflictRemote = snapshot
            syncStatus = .conflict
        case .unreadable:
            syncStatus = .unreadable
        }
    }

    /// On conflict, overwrites the remote with this device.
    func resolveConflictKeepingLocal() async {
        guard syncLocation != nil, let key else { return }
        let deviceName = DeviceInfo.name
        let marks = syncMarks
        await persistence.enqueue { [weak self] in
            guard let self else { return }
            self.syncStatus = .running
            do {
                let (snapshot, marks) = try await self.makeSyncBackend().uploadLocal(deviceName: deviceName, marks: marks, key: key)
                self.syncMarks = marks
                self.syncStatus = .idle
                self.record("icloud.manual_backup", bytes: snapshot.encryptedData.count, direction: .upload)
            } catch {
                self.recordSyncFailure(error, sourceKey: "icloud.manual_backup")
            }
        }.value
    }

    /// On conflict, overwrites this device with the remote version.
    func resolveConflictUsingRemote() async {
        guard syncLocation != nil else { return }
        await persistence.enqueue { [weak self] in
            guard let self else { return }
            self.syncStatus = .running
            do {
                let (snapshot, marks) = try await self.makeSyncBackend().downloadRemoteToLocal()
                await self.applyDownloaded(snapshot, marks: marks, sourceKey: "icloud.hist.restore")
            } catch {
                self.recordSyncFailure(error, sourceKey: "icloud.hist.restore")
            }
        }.value
    }

    /// "Restore from Backup" when the backup cannot be decrypted (same on all three platforms): decrypts in memory with that
    /// backup's master password first, and only on success overwrites this device, switches to its contents and key, and stays
    /// unlocked. On a wrong password or an unreadable backup nothing changes here and the state stays "cannot decrypt". Returns an
    /// error message, or nil on success. Overwriting first and then locking would strand a user who cannot remember that backup's
    /// password at the lock screen, with the original local vault already replaced.
    /// Wrong attempts do not count toward consecutive failures: this ciphertext already sits in the backup location, so a counter
    /// cannot stop offline guessing (same as first-run restore).
    func restoreUnreadableBackup(password: String) async -> String? {
        guard syncLocation != nil, key != nil else { return nil }
        var failure: String?
        await persistence.enqueue { [weak self] in
            guard let self else { return }
            do {
                let backend = try self.makeSyncBackend()
                let snapshot = try await backend.requireRemote()
                let unlocked = try await self.files.unlock(encryptedData: snapshot.encryptedData, password: password)
                self.syncMarks = try await backend.replaceLocal(with: snapshot)
                self.syncStatus = .idle
                self.record(
                    "icloud.hist.restore", bytes: snapshot.encryptedData.count, device: snapshot.deviceName, direction: .download)
                // Auto-locked while decrypting: the file is already the backup, so the next unlock uses the password just entered;
                // do not load contents and key back into a locked session
                guard self.phase == .unlocked else { return }
                self.document = VaultDocument(unlocked.contents)
                self.key = unlocked.key
                // Biometrics hold the old key: replace it with this backup's
                if self.preferences.biometricsEnabled { await self.storeBiometricKey() }
            } catch {
                failure = SyncErrorText.message(for: error, at: self.syncLocation)
            }
        }.value
        return failure
    }

    // MARK: - Conflict handling (see docs/TECHNICAL.md)

    /// Decrypts the backup and compares it with this device so the conflict screen can show the differences.
    func loadConflictReview() async -> Result<ConflictReview, ConflictReviewFailure> {
        guard let key else { return .failure(ConflictReviewFailure(message: L10n.tr("Unlock Kakey first"))) }
        do {
            return .success(try await makeSyncBackend().conflictReview(local: document.contents, key: key, remote: conflictRemote))
        } catch {
            if case VaultSyncError.unreadableRemote = error { syncStatus = .unreadable }
            return .failure(ConflictReviewFailure(message: SyncErrorText.message(for: error, at: syncLocation)))
        }
    }

    /// "Merge both" on conflict: keeps accounts from both sides, taking the backup version of accounts changed on both sides per
    /// `preferRemote`; saves locally first, then writes the backup conditionally. If the backup changed again after the comparison
    /// it is not overwritten and a re-sync runs (usually ending in a conflict again).
    func mergeWithBackup(_ review: ConflictReview, preferRemote: Set<UUID>) async {
        guard syncLocation != nil, let key else { return }
        let deviceName = DeviceInfo.name
        await persistence.enqueue { [weak self] in
            guard let self else { return }
            self.syncStatus = .running
            do {
                let merged = try review.merged(local: self.document.contents, preferRemote: preferRemote)
                try await self.files.save(merged, key: key)
                self.document = VaultDocument(merged)
                let (snapshot, marks) = try await self.makeSyncBackend().uploadMerged(
                    deviceName: deviceName, comparedVersion: review.remoteVersion)
                self.syncMarks = marks
                self.syncStatus = .idle
                self.record("icloud.hist.merge", bytes: snapshot.encryptedData.count, direction: .upload)
            } catch VaultSyncError.remoteChanged {
                self.syncStatus = .idle
            } catch {
                self.recordSyncFailure(error, sourceKey: "icloud.hist.merge")
            }
        }.value
        if syncStatus == .idle, syncHistory.first?.sourceKey != "icloud.hist.merge" {
            await sync(sourceKey: "icloud.hist.sync")
        }
    }

    // MARK: - First-run restore

    /// First run: fetches the encrypted vault from a sync folder into memory (see `restore(from:connection:)`). Returns an error
    /// message, or nil when a backup was found.
    func restore(from folder: URL) async -> String? {
        restoreMissedBackup = false
        do {
            return await restore(from: try syncLocation(forFolder: folder))
        } catch {
            return SyncErrorText.message(for: error)
        }
    }

    /// First run picked a file (same as the Mac): only confirms it is a Kakey encrypted export. Returns an error message, or nil
    /// on success.
    func prepareExportRestore(from url: URL) -> String? {
        restoreMissedBackup = false
        pendingOnboardingRestore = nil
        pendingOnboardingExport = PendingOnboardingExport(contentsOf: url)
        return pendingOnboardingExport == nil ? OnboardingExportError.notAnExport.errorDescription : nil
    }

    /// Decrypts the file with the export password, creates a new vault with `masterPassword`, and unlocks; with "Use as master
    /// password" on, that is the export password. No backup location is enabled. Returns an error message, or nil on success.
    func completeExportRestore(password: String, masterPassword: String, enableBiometrics: Bool) async -> String? {
        guard !isWorking, let pending = pendingOnboardingExport else { return nil }
        isWorking = true
        defer { isWorking = false }
        do {
            let contents = try await pending.restoredContents(password: password, masterPassword: masterPassword, files: files, now: now())
            let key = try await files.create(password: masterPassword, contents: contents)
            pendingOnboardingExport = nil
            finishUnlock(contents, key: key)
            if enableBiometrics { await setBiometricsEnabled(true) }
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? L10n.tr("Unable to restore from backup")
        }
    }

    /// First run: fetches the encrypted vault from iCloud into memory (see `restore(from:connection:)`). Returns an error message,
    /// or nil when a backup was found.
    func restoreFromICloud() async -> String? {
        restoreMissedBackup = false
        // The account check counts as part of the search: setting isWorking only afterwards would let a vault created by going
        // back in the meantime be overwritten by the restore that follows
        isWorking = true
        defer { isWorking = false }
        do {
            return await restore(from: try await iCloudLocation())
        } catch {
            return SyncErrorText.message(for: error)
        }
    }

    /// First run: fetches the encrypted vault from the chosen location and keeps it only in memory (`pendingOnboardingRestore`);
    /// the restore page then decrypts it with the original master password (`completeOnboardingRestore`). Returns an error message,
    /// or nil when a backup was found. Same as the Mac: nothing is overwritten yet, so a user who cannot remember that backup's
    /// password can still pick another source or create a new vault.
    func restore(from location: SyncLocation, connection: Data? = nil) async -> String? {
        isWorking = true
        restoreMissedBackup = false
        defer { isWorking = false }
        do {
            let fetched = InMemoryCloudConnectionStore(connection)
            let backend = try makeSyncBackend(for: location, connections: fetched)
            let snapshot = try await backend.requireRemote()
            // The access token may have been refreshed while fetching (the runner writes the new connection blob back into this
            // in-memory copy): after unlock the latest one is saved, not the stale connection passed in
            let latest = connection.map { (try? fetched.load()) ?? $0 }
            pendingOnboardingExport = nil
            pendingOnboardingRestore = PendingOnboardingRestore(snapshot: snapshot, location: location, connection: latest)
            return nil
        } catch {
            if case VaultSyncError.missingRemoteVault = error { restoreMissedBackup = true }
            return SyncErrorText.message(for: error, at: location)
        }
    }

    /// Decrypts the fetched backup with the original master password; only on success saves credentials, overwrites this device,
    /// enables the location, and unlocks. Returns an error message, or nil on success.
    /// Credentials are saved before overwriting and deleted if the overwrite fails: if they cannot be stored, the whole restore
    /// fails and no vault is left on this device.
    /// Wrong attempts do not count toward consecutive failures: the user already holds this ciphertext, so a counter cannot stop
    /// offline guessing and would only make someone who remembers the password wait (same as the Mac).
    func completeOnboardingRestore(password: String, enableBiometrics: Bool) async -> String? {
        guard !isWorking else { return nil }
        guard let pending = pendingOnboardingRestore else { return L10n.tr("Unable to restore from backup") }
        isWorking = true
        defer { isWorking = false }
        do {
            let unlocked = try await files.unlock(encryptedData: pending.snapshot.encryptedData, password: password)
            if let connection = pending.connection { try cloudConnections.save(connection) }
            let envelope: CoreEnvelopeInfo
            do {
                envelope = try await files.replaceEncryptedVault(with: pending.snapshot.encryptedData)
            } catch {
                if pending.connection != nil { cloudConnections.remove() }
                throw error
            }
            pendingOnboardingRestore = nil
            preferences.syncLocation = pending.location
            syncBackend = nil
            syncMarks = SyncMarks(lastLocalUpdatedAt: envelope.updatedAt, lastRemoteVersion: pending.snapshot.version)
            syncStatus = .idle
            if pending.location.isICloud { enableICloudPush() }
            record(
                "icloud.hist.restore", bytes: pending.snapshot.encryptedData.count, device: pending.snapshot.deviceName,
                direction: .download)
            finishUnlock(unlocked.contents, key: unlocked.key)
            if enableBiometrics { await setBiometricsEnabled(true) }
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? L10n.tr("Unable to restore from backup")
        }
    }

    /// Discards the found backup and returns to the location list to pick another source or create a vault (same as the Mac).
    func discardOnboardingRestore() {
        pendingOnboardingRestore = nil
        pendingOnboardingExport = nil
    }

    /// If the current key cannot open the downloaded vault (the remote uses another master password), locks and asks for that
    /// password.
    private func applyDownloaded(_ snapshot: RemoteVaultSnapshot, marks: SyncMarks, sourceKey: String) async {
        syncMarks = marks
        syncStatus = .idle
        record(sourceKey, bytes: snapshot.encryptedData.count, device: snapshot.deviceName, direction: .download)
        guard let key else { return }
        do {
            document = VaultDocument(try await files.open(key: key))
        } catch {
            lock()
            keyStore.remove()
            biometricKeyAvailable = false
            unlockError = L10n.tr("Downloaded the backup. Unlock again with its master password.")
        }
    }

    private func recordSyncFailure(_ error: Error, sourceKey: String) {
        if case VaultSyncError.unreadableRemote = error {
            syncStatus = .unreadable
            return
        }
        syncStatus = .failed(SyncErrorText.message(for: error, at: syncLocation))
        record(sourceKey, bytes: nil, isFailure: true)
    }

    /// `device` is where the data now in effect came from: this device for uploads and failures; for downloads, the device that
    /// wrote the backup (the location name when it did not say). `direction` is written to history: upload, download, or both sides
    /// already in sync.
    private func record(
        _ sourceKey: String, bytes: Int?, device: String? = nil, isFailure: Bool = false,
        direction: SyncDirection? = nil
    ) {
        let device = direction == .upload || isFailure ? DeviceInfo.name : device ?? syncLocation?.title ?? DeviceInfo.name
        BackupHistoryStore.append(
            .record(
                date: now(), device: device, bytes: bytes, sourceKey: sourceKey, isFailure: isFailure,
                direction: direction, location: syncLocation?.title),
            to: &syncHistory
        )
    }
}

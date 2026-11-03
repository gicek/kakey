import CloudKit
import CryptoKit
import Foundation

/// Backup and sync (see docs/TECHNICAL.md): location configuration, automatic / manual sync, restore, conflicts and backup history.
/// There is a single location (iCloud, any folder, or cloud storage). The cloud storage connection blob lives in `cloudConnections`;
/// settings store only the non-sensitive `SyncLocation`. iCloud uses the CloudKit private database (see docs/SECURITY.md); when another
/// device changes the backup, a silent push triggers an immediate sync.
extension VaultStore {
    // MARK: - Location

    /// Enables or changes the backup location. First runs a read-only link check: if the remote already has a backup that differs from
    /// this Mac and cannot be opened with this Mac's key, the location is not enabled and an error message is returned.
    /// On success: cloud storage saves the connection blob first, and leaving cloud storage revokes (best effort) and deletes the old
    /// connection; then sync markers are cleared and one sync runs immediately (uploading if the remote has no backup; if it can be
    /// opened but differs, the core reports a conflict and the user picks a direction). Returns nil on success.
    @discardableResult
    func configureSync(_ location: SyncLocation, connection: Data? = nil) async -> String? {
        guard let vaultKey else { return L10n.tr("Unlock Kakey first") }
        let checked: RemoteRead
        do {
            let candidate = try makeSyncBackend(for: location, connections: InMemoryCloudConnectionStore(connection))
            checked = try await candidate.checkLink(key: vaultKey)
        } catch {
            return Self.syncErrorMessage(error)
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
            markSyncFailed(error, sourceKey: "icloud.hist.sync")
            return Self.syncErrorMessage(error)
        }
        if syncLocation?.isICloud == true, !location.isICloud {
            disableICloudPush()
        }
        syncLocation = location
        settings.set(location.encoded(), forKey: Self.syncLocationKey)
        settings.removeObjects(forKeys: [Self.lastLocalUpdatedAtKey, Self.lastRemoteVersionKey])
        syncBackend = nil
        if location.isICloud { enableICloudPush() }
        // The link check just read the remote: the first sync uses that read instead of downloading again.
        startAutomaticSync(prefetched: checked)
        return nil
    }

    /// Chooses iCloud: confirms this Mac is signed in to iCloud, records the current account, then links it like any other location.
    /// Returns an error message on failure.
    @discardableResult
    func linkICloud() async -> String? {
        do {
            return await configureSync(try await iCloudLocation())
        } catch {
            return Self.syncErrorMessage(error)
        }
    }

    /// The location for the current iCloud account; throws when the build has no iCloud capability or the user is signed out or
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

    /// Turns off iCloud backup and deletes the backup in iCloud (the one shared by all devices). Waits for queued syncs to finish
    /// first, so the backup is not uploaded again right after deletion. If deletion fails (offline, ...), backup stays on and an error
    /// message is returned.
    func turnOffSyncDeletingICloudBackup() async -> String? {
        guard syncLocation?.isICloud == true, let iCloud else { return nil }
        syncDebounceTask?.cancel()
        await persistence.drain()
        do {
            try await iCloud.deleteBackup()
        } catch {
            return Self.syncErrorMessage(ICloudSyncError.from(error))
        }
        turnOffSync()
        return nil
    }

    /// Turns off backup. Cloud storage also revokes authorization and deletes local credentials; existing remote backups are not
    /// deleted (iCloud has a separate "also delete" option).
    func turnOffSync() {
        syncDebounceTask?.cancel()
        if syncLocation?.isCloud == true {
            disconnectCloud()
        }
        if syncLocation?.isICloud == true {
            disableICloudPush()
        }
        syncLocation = nil
        syncBackend = nil
        settings.removeObjects(forKeys: [Self.syncLocationKey, Self.lastLocalUpdatedAtKey, Self.lastRemoteVersionKey])
        backupStatus = .disabled
    }

    /// The folder the user picked in the open panel (folders synced by any cloud drive client work too); if the parent folder is
    /// picked, its `Kakey/` subfolder is used, consistent with iOS and Android.
    func syncLocation(forFolder url: URL) throws -> SyncLocation {
        .folder(bookmark: try SyncFolderService.bookmark(for: url), name: SyncFolderService.vaultFolder(for: url).lastPathComponent)
    }

    var cloudSetup: CloudSetupService {
        CloudSetupService(executor: httpExecutor, userAgent: Self.cloudUserAgent)
    }

    static let cloudUserAgent = CloudSetupService.userAgent(platform: "macOS")

    /// Revokes in the background without waiting (so being offline does not block the UI); local credentials are deleted immediately.
    private func disconnectCloud() {
        if let connection = try? cloudConnections.load() {
            let setup = cloudSetup
            Task.detached { await setup.revoke(connection) }
        }
        cloudConnections.remove()
    }

    // MARK: - iCloud push and account

    /// Subscribes to backup changes and registers for push; subscribing is best effort (when offline, it retries on the next launch).
    func enableICloudPush() {
        guard let iCloud else { return }
        system.registerForRemoteNotifications()
        Task.detached { try? await iCloud.subscribe() }
    }

    func disableICloudPush() {
        guard let iCloud else { return }
        Task.detached { try? await iCloud.unsubscribe() }
    }

    /// Another device changed the backup in iCloud (silent push): sync immediately when unlocked; when locked, wait for the sync after
    /// unlocking.
    func iCloudBackupDidChange() {
        guard syncLocation?.isICloud == true else { return }
        startAutomaticSync()
    }

    func observeICloudAccount() {
        guard iCloud != nil else { return }
        iCloudAccountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.iCloudAccountDidChange() }
        }
    }

    /// This Mac's iCloud account changed (signed out, switched accounts): drop the backend bound to the confirmed account and sync
    /// again. After an account switch the backend reports "account changed" and sync stops in a failed state, so data is never written
    /// into another account.
    func iCloudAccountDidChange() {
        guard syncLocation?.isICloud == true else { return }
        syncBackend = nil
        startAutomaticSync()
    }

    // MARK: - Sync

    /// Syncs once immediately (after unlocking, after configuring a location).
    func startAutomaticSync(prefetched: RemoteRead? = nil) {
        guard syncLocation != nil else { return }
        syncDebounceTask?.cancel()
        runSync(sourceKey: "icloud.hist.auto", prefetched: prefetched)
    }

    /// Coalesces to 2 seconds after a save (consecutive edits sync once), same as iOS.
    func scheduleAutomaticSync() {
        guard syncLocation != nil else { return }
        syncDebounceTask?.cancel()
        syncDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.runSync(sourceKey: "icloud.hist.auto")
        }
    }

    func runSync(sourceKey: String, prefetched: RemoteRead? = nil) {
        // The decision needs this Mac's key to try opening the remote; no sync while locked (it runs once after unlocking).
        guard let vaultKey else { return }
        backupStatus = .running
        let marks = syncMarks
        let deviceName = system.deviceName
        persistence.enqueue { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await self.makeSyncBackend().sync(
                    marks: marks, deviceName: deviceName, key: vaultKey, prefetched: prefetched)
                await self.applySyncOutcome(outcome, sourceKey: sourceKey)
            } catch {
                self.markSyncFailed(error, sourceKey: sourceKey)
            }
        }
    }

    /// "Back Up Now": uses the same decision as automatic sync (upload, download or conflict) and never blindly overwrites. If the
    /// backup was changed elsewhere since the last sync, it becomes a conflict and the user picks a direction (same on iOS / Android).
    func runManualBackup() {
        runSync(sourceKey: "icloud.hist.manual")
    }

    /// Keep this Mac on conflict: this Mac overwrites the backup (the user has seen the differences and chosen explicitly).
    func keepThisMacCopy() {
        guard syncLocation != nil, let vaultKey else { return }
        backupStatus = .running
        let deviceName = system.deviceName
        let marks = syncMarks
        persistence.enqueue { [weak self] in
            guard let self else { return }
            do {
                let (snapshot, marks) = try await self.makeSyncBackend().uploadLocal(deviceName: deviceName, marks: marks, key: vaultKey)
                self.syncMarks = marks
                self.markSyncSucceeded(snapshot, sourceKey: "icloud.hist.manual", direction: .upload)
            } catch {
                self.markSyncFailed(error, sourceKey: "icloud.hist.manual")
            }
        }
    }

    /// "Restore from Backup" for an unreadable backup (same on all platforms). First opens that backup in memory with its master
    /// password; only on success does it overwrite this Mac, switch to its content and key and stay unlocked. With a wrong password or
    /// an unreachable backup nothing changes here and the state stays "unreadable". Returns an error message, nil on success.
    /// Overwriting first and then locking would strand a user who cannot remember that backup's password at the lock screen, with the
    /// original vault already replaced.
    /// Wrong attempts do not count toward consecutive failures: the ciphertext already sits in the backup location, so a counter cannot
    /// stop offline attempts (same as first-run restore).
    func restoreUnreadableBackup(password: String) async -> String? {
        guard syncLocation != nil, vaultKey != nil else { return nil }
        var failure: String?
        await persistence.enqueue { [weak self] in
            guard let self else { return }
            do {
                let backend = try self.makeSyncBackend()
                let snapshot = try await backend.requireRemote()
                let unlocked = try await self.files.unlock(encryptedData: snapshot.encryptedData, password: password)
                self.syncMarks = try await backend.replaceLocal(with: snapshot)
                self.markSyncSucceeded(snapshot, sourceKey: "icloud.hist.restore", direction: .download)
                // Locked while opening (auto-lock, sleep): the file is already the backup, and the next unlock uses the password just
                // entered; do not load content and key into a locked session. The old key in Touch ID cannot open the new file and is
                // handled as the existing mismatch case (deleted, with a prompt to unlock once with the master password).
                guard !self.isLocked else { return }
                self.document = VaultDocument(unlocked.contents)
                self.vaultKey = unlocked.key
                self.refreshSearchIndex()
                // Touch ID holds the old key: replace it with this backup's.
                await self.persistKeyForTouchID()
            } catch {
                failure = Self.syncErrorMessage(error, at: self.syncLocation)
            }
        }.value
        return failure
    }

    // MARK: - Conflict resolution (see docs/TECHNICAL.md)

    /// Opens the backup and compares it with this Mac for the conflict page; returns an error message on failure.
    func loadConflictReview() async -> Result<ConflictReview, ConflictReviewFailure> {
        guard let vaultKey else { return .failure(ConflictReviewFailure(message: L10n.tr("Unlock Kakey first"))) }
        let local = document.contents
        do {
            return .success(try await makeSyncBackend().conflictReview(local: local, key: vaultKey, remote: conflictRemote))
        } catch {
            if case VaultSyncError.unreadableRemote = error { backupStatus = .unreadable }
            return .failure(ConflictReviewFailure(message: Self.syncErrorMessage(error, at: syncLocation)))
        }
    }

    /// "Use Backup" on conflict: the backup replaces this Mac. A conflicting backup can always be opened with this Mac's key, so it is
    /// reloaded directly, without locking or clearing Touch ID material.
    func useBackupCopy() {
        guard syncLocation != nil else { return }
        backupStatus = .running
        persistence.enqueue { [weak self] in
            guard let self else { return }
            do {
                let (snapshot, marks) = try await self.makeSyncBackend().downloadRemoteToLocal()
                self.syncMarks = marks
                await self.reloadCurrentVaultAfterDownload()
                self.markSyncSucceeded(snapshot, sourceKey: "icloud.hist.restore", direction: .download)
            } catch {
                self.markSyncFailed(error, sourceKey: "icloud.hist.restore")
            }
        }
    }

    /// "Merge Both" on conflict: accounts from both sides are kept, and for accounts changed on both sides the backup's version is used
    /// for those in `preferRemote`. Saves locally first, then writes the backup conditionally.
    /// If the backup changed again after the comparison, it is not overwritten; sync runs again (usually landing in a conflict again so
    /// the user can re-compare).
    func mergeWithBackup(_ review: ConflictReview, preferRemote: Set<UUID>) {
        guard syncLocation != nil, let vaultKey else { return }
        backupStatus = .running
        let deviceName = system.deviceName
        persistence.enqueue { [weak self] in
            guard let self else { return }
            do {
                let merged = try review.merged(local: self.document.contents, preferRemote: preferRemote)
                try await self.files.save(merged, key: vaultKey)
                self.document = VaultDocument(merged)
                self.refreshSearchIndex()
                let (snapshot, marks) = try await self.makeSyncBackend().uploadMerged(
                    deviceName: deviceName, comparedVersion: review.remoteVersion)
                self.syncMarks = marks
                self.markSyncSucceeded(snapshot, sourceKey: "icloud.hist.merge", direction: .upload)
            } catch VaultSyncError.remoteChanged {
                self.runSync(sourceKey: "icloud.hist.sync")
            } catch {
                self.markSyncFailed(error, sourceKey: "icloud.hist.merge")
            }
        }
    }

    // MARK: - First-run restore

    /// First run: fetches the encrypted vault from the chosen location (memory only); it is written to disk and the location enabled
    /// only after the master password is confirmed.
    /// On failure the reason is in `vaultError`; a location without a backup returns `.notFound`, and onboarding then offers "Choose
    /// Folder".
    func prepareOnboardingRestore(from location: SyncLocation, connection: Data? = nil) async -> OnboardingRestoreOutcome {
        isFetchingOnboardingRestore = true
        defer { isFetchingOnboardingRestore = false }
        vaultError = nil
        backupStatus = .running
        do {
            let fetched = InMemoryCloudConnectionStore(connection)
            let backend = try makeSyncBackend(for: location, connections: fetched)
            let snapshot = try await backend.requireRemote()
            // The access token may have been refreshed during the fetch (the runner writes the new connection blob back into this
            // in-memory copy): saving after unlock and enabling backup use the latest one, not the stale connection passed in.
            let latest = connection.map { (try? fetched.load()) ?? $0 }
            pendingOnboardingRestore = PendingOnboardingRestore(snapshot: snapshot, location: location, connection: latest)
            pendingOnboardingExport = nil
            document = VaultDocument()
            vaultKey = nil
            keyStore.remove()
            biometricKeyAvailable = false
            isLocked = false
            backupStatus = .disabled
            return .found
        } catch {
            pendingOnboardingRestore = nil
            backupStatus = .disabled
            vaultError = Self.syncErrorMessage(error, at: location)
            if case VaultSyncError.missingRemoteVault = error { return .notFound }
            return .failed
        }
    }

    /// First run: fetch from iCloud. The account lookup counts as part of finding the backup, so onboarding cannot be left while it
    /// runs.
    func prepareOnboardingRestoreFromICloud() async -> OnboardingRestoreOutcome {
        isFetchingOnboardingRestore = true
        defer { isFetchingOnboardingRestore = false }
        do {
            return await prepareOnboardingRestore(from: try await iCloudLocation())
        } catch {
            vaultError = SyncErrorText.message(for: error)
            return .failed
        }
    }

    /// Discards the found backup and returns to the location list, so choosing the wrong location or forgetting this backup's password
    /// does not require quitting onboarding.
    func discardOnboardingRestore() {
        pendingOnboardingRestore = nil
        pendingOnboardingExport = nil
        vaultError = nil
    }

    func completeRestoredOnboarding(password: String) async -> Bool {
        vaultError = nil
        guard let pending = pendingOnboardingRestore else {
            vaultError = L10n.tr("Unable to restore from backup")
            return false
        }

        isWorking = true
        defer { isWorking = false }
        do {
            let unlocked = try await files.unlock(encryptedData: pending.snapshot.encryptedData, password: password)
            // Save the credentials before overwriting this Mac and delete them if the overwrite fails. In the opposite order, a failure
            // to save the credentials would leave a local vault with no enabled location, and creating a new vault from onboarding
            // would then overwrite the one just restored.
            if let connection = pending.connection {
                try cloudConnections.save(connection)
            }
            let envelope: CoreEnvelopeInfo
            do {
                envelope = try await files.replaceEncryptedVault(with: pending.snapshot.encryptedData)
            } catch {
                if pending.connection != nil { cloudConnections.remove() }
                throw error
            }
            syncLocation = pending.location
            settings.set(pending.location.encoded(), forKey: Self.syncLocationKey)
            syncBackend = nil
            if pending.location.isICloud { enableICloudPush() }
            syncMarks = SyncMarks(lastLocalUpdatedAt: envelope.updatedAt, lastRemoteVersion: pending.snapshot.version)
            pendingOnboardingRestore = nil
            hasCompletedOnboarding = true
            markSyncSucceeded(pending.snapshot, sourceKey: "icloud.hist.restore", direction: .download)
            finishUnlock(unlocked.contents, key: unlocked.key)
            await persistKeyForTouchID()
            return true
        } catch {
            vaultError = error.localizedDescription
            return false
        }
    }

    // MARK: - Internals

    /// The same location reuses the same actor (all reads and writes are serial); the iCloud backend confirms the account on its first
    /// read or write.
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
        case .iCloud(let account):
            guard let iCloud else { throw ICloudSyncError.notEntitled }
            return ICloudSyncBackend(store: iCloud, linkedAccount: account, files: files)
        case .folder(let bookmark, _):
            let root = try SyncFolderService.resolve(bookmark: bookmark)
            return FolderSyncBackend(folder: SyncFolderService.vaultFolder(for: root), files: files)
        case .cloud(let cloud):
            return CloudSyncBackend(
                folder: cloud.folder, connections: connections, executor: httpExecutor, userAgent: Self.cloudUserAgent, files: files)
        }
    }

    private var syncMarks: SyncMarks {
        get {
            SyncMarks(
                lastLocalUpdatedAt: settings.date(forKey: Self.lastLocalUpdatedAtKey),
                encodedRemoteVersion: settings.string(forKey: Self.lastRemoteVersionKey)
            )
        }
        set {
            settings.set(newValue.lastLocalUpdatedAt, forKey: Self.lastLocalUpdatedAtKey)
            if let remote = newValue.encodedRemoteVersion {
                settings.set(remote, forKey: Self.lastRemoteVersionKey)
            }
        }
    }

    private func applySyncOutcome(_ outcome: VaultSyncOutcome, sourceKey: String) async {
        switch outcome {
        case .uploaded(let snapshot, let marks):
            syncMarks = marks
            markSyncSucceeded(snapshot, sourceKey: sourceKey, direction: .upload)
        case .downloaded(let snapshot, let marks):
            syncMarks = marks
            await reloadCurrentVaultAfterDownload()
            markSyncSucceeded(snapshot, sourceKey: sourceKey, direction: .download)
        case .upToDate(let snapshot, let marks):
            syncMarks = marks
            // Automatic sync finding both sides identical records no history (every unlock would add an entry); a user-initiated
            // "Back Up Now" needs a result.
            markSyncSucceeded(sourceKey == "icloud.hist.auto" ? nil : snapshot, sourceKey: sourceKey, direction: .unchanged)
        // Conflict and "unreadable" are states waiting for the user with no data transferred, so no history is recorded (the status
        // card already shows them); only the outcome after resolution is recorded.
        case .conflict(let snapshot):
            conflictRemote = snapshot
            backupStatus = .conflict
        case .unreadable:
            backupStatus = .unreadable
        case .noLocalVault:
            backupStatus = .failed(message: L10n.tr("No local encrypted vault available to sync"))
        }
    }

    /// If the current key cannot open the downloaded vault (the remote is encrypted with another master password), lock and require
    /// unlocking with that password.
    func reloadCurrentVaultAfterDownload() async {
        guard let vaultKey else {
            lock()
            return
        }
        do {
            let contents = try await files.open(key: vaultKey)
            document = VaultDocument(contents)
            refreshSearchIndex()
        } catch {
            lock()
            keyStore.remove()
            biometricKeyAvailable = false
            vaultError = L10n.tr("Downloaded the backup. Unlock again with its master password.")
        }
    }

    /// `direction` goes into history: upload, download, or already identical. The device recorded is the one the data currently in
    /// effect came from.
    private func markSyncSucceeded(_ snapshot: RemoteVaultSnapshot?, sourceKey: String, direction: SyncDirection) {
        let date = now()
        backupStatus = .enabled(lastBackup: date)
        settings.set(date, forKey: Self.lastBackupSyncAtKey)
        if let snapshot {
            appendBackupHistory(
                .record(
                    date: date, device: snapshot.deviceName ?? remoteDeviceFallback, bytes: snapshot.encryptedData.count,
                    sourceKey: sourceKey, direction: direction))
        }
    }

    private func markSyncFailed(_ error: Error, sourceKey: String) {
        if case VaultSyncError.unreadableRemote = error {
            backupStatus = .unreadable
            return
        }
        backupStatus = .failed(message: Self.syncErrorMessage(error, at: syncLocation))
        appendBackupHistory(.record(date: now(), device: system.deviceName, bytes: nil, sourceKey: sourceKey, isFailure: true))
    }

    static func syncErrorMessage(_ error: Error, at location: SyncLocation? = nil) -> String {
        SyncErrorText.message(for: error, at: location)
    }

    /// When the remote has no device name, history shows the location name.
    private var remoteDeviceFallback: String {
        syncLocation?.title ?? "iCloud"
    }

    /// Each record carries the location name at the time, so history stays clear after changing locations.
    private func appendBackupHistory(_ item: BackupHistoryItem) {
        var item = item
        item.location = syncLocation?.title
        BackupHistoryStore.append(item, to: &backupHistory)
    }

    /// The backup switch state in the UI: on for everything except "turned off".
    var isBackupSwitchOn: Bool {
        if case .disabled = backupStatus { return false }
        return true
    }
}

enum OnboardingRestoreOutcome {
    case found
    /// The location is reachable but contains no Kakey backup.
    case notFound
    case failed
}

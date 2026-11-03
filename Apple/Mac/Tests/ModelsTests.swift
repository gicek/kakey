import XCTest

@testable import Kakey

/// Evaluation lives in the core (`password.rs`, zxcvbn) with per-level samples in golden; this only checks the wrapper's mapping
/// and the four strength labels.
final class PasswordStrengthTests: XCTestCase {
    func testLevelsFollowKindsAndLength() {
        XCTAssertEqual(PasswordStrength.evaluate(""), .empty)
        XCTAssertEqual(PasswordStrength.evaluate("Ab1!xY"), .weak, "Shorter than 8 characters")
        XCTAssertEqual(PasswordStrength.evaluate("aaaabbbb"), .weak, "Repetitive")
        XCTAssertEqual(PasswordStrength.evaluate("Password1!"), .weak, "Common password")
        XCTAssertEqual(PasswordStrength.evaluate("vT8#qL2!mZ5@"), .strong, "Hard to guess")
        XCTAssertEqual(PasswordStrength.evaluate("correcthorsebatterystaple"), .strong, "Long passphrase")
    }

    func testEachLevelHasItsOwnLabel() {
        let labels = [PasswordStrength.weak, .fair, .good, .strong].map(\.label)
        XCTAssertEqual(Set(labels).count, 4)
    }
}

final class PasswordPolicyTests: XCTestCase {
    func testMasterPasswordNeedsLengthAllowedCharactersAndFairStrength() {
        XCTAssertEqual(PasswordPolicy.minimumLength, 8)
        XCTAssertFalse(PasswordPolicy.isAcceptableMasterPassword("12345678"), "Weak passwords are not accepted")
        XCTAssertTrue(PasswordPolicy.isAcceptableMasterPassword("Abcdefgh1"))
        XCTAssertFalse(PasswordPolicy.isAcceptableMasterPassword("1234567"))
        XCTAssertFalse(PasswordPolicy.isAcceptableMasterPassword("        "))
        XCTAssertFalse(PasswordPolicy.isAcceptableMasterPassword("密码密码密码密码"))
    }

    func testNewPasswordInputKeepsOnlyAllowedCharacters() {
        XCTAssertEqual(PasswordPolicy.filterInput("密码Ab1！ ~"), "Ab1~")
    }

    func testExportPasswordNeedsLengthAndAllowedCharacters() {
        XCTAssertFalse(PasswordPolicy.isAcceptableExportPassword("12345678"), "Same strength requirement as the master password")
        XCTAssertTrue(PasswordPolicy.isAcceptableExportPassword("Abcdefgh1"))
        XCTAssertFalse(PasswordPolicy.isAcceptableExportPassword("aaaaaaa"))
        XCTAssertFalse(PasswordPolicy.isAcceptableExportPassword("abcd efgh"))
    }
}

/// Password confirmation is checked as you type: no message while it is still a prefix of the new password, an immediate message
/// on a wrong character, and a message for an incomplete value after leaving the confirmation field.
final class PasswordConfirmationTests: XCTestCase {
    private let mismatch = L10n.tr("Passwords do not match")

    private func problem(_ confirm: String, editingConfirm: Bool = true, editingPassword: Bool = false) -> String? {
        PasswordConfirmation.problem(
            password: "Kx7-master", confirm: confirm, isEditingPassword: editingPassword, isEditingConfirm: editingConfirm)
    }

    func testPrefixWhileTypingIsNotAnError() {
        XCTAssertNil(problem(""))
        XCTAssertNil(problem("Kx7"))
        XCTAssertNil(problem("Kx7-master"))
    }

    func testWrongCharacterShowsImmediately() {
        XCTAssertEqual(problem("Kx8"), mismatch)
        XCTAssertEqual(problem("Kx7-master!"), mismatch, "Longer than the new password")
    }

    func testIncompleteAfterLeavingConfirmIsAnError() {
        XCTAssertEqual(problem("Kx7", editingConfirm: false), mismatch)
        XCTAssertNil(problem("Kx7-master", editingConfirm: false))
    }

    func testNoErrorWhileEditingNewPassword() {
        XCTAssertNil(problem("Kx8", editingConfirm: false, editingPassword: true))
    }
}

final class CoreErrorMappingTests: XCTestCase {
    /// Only InvalidPassword counts as a wrong password toward the wait; new errors must map to their own types.
    func testNewCoreErrorsMapToTheirOwnCases() {
        XCTAssertEqual(KakeyError.InvalidKey.vaultError, .invalidKey)
        XCTAssertEqual(KakeyError.CryptoFailure.vaultError, .cryptoFailure)
        XCTAssertEqual(KakeyError.CorruptVault.vaultError, .corruptVault)
        XCTAssertEqual(KakeyError.InvalidPassword.vaultError, .invalidPassword)
    }
}

final class UnlockThrottleTests: XCTestCase {
    func testNoLockoutBeforeThreshold() {
        XCTAssertNil(UnlockThrottle.lockoutDuration(afterConsecutiveFailures: 0))
        XCTAssertNil(UnlockThrottle.lockoutDuration(afterConsecutiveFailures: 4))
    }

    func testLockoutDoublesFromBaseDelay() {
        XCTAssertEqual(UnlockThrottle.lockoutDuration(afterConsecutiveFailures: 5), 30)
        XCTAssertEqual(UnlockThrottle.lockoutDuration(afterConsecutiveFailures: 6), 60)
        XCTAssertEqual(UnlockThrottle.lockoutDuration(afterConsecutiveFailures: 7), 120)
    }

    func testLockoutIsCappedAtMaxDelay() {
        XCTAssertEqual(UnlockThrottle.lockoutDuration(afterConsecutiveFailures: 9), 300)
        XCTAssertEqual(UnlockThrottle.lockoutDuration(afterConsecutiveFailures: 100), 300)
    }
}

final class AccountTests: XCTestCase {
    func testDeduplicationKeyIgnoresCaseAndWhitespace() {
        let a = Account.deduplicationKey(issuer: " GitHub ", username: "Alex", secret: "abcd", algorithm: .sha1, digits: 6, period: 30)
        let b = Account.deduplicationKey(issuer: "github", username: "alex ", secret: " ABCD ", algorithm: .sha1, digits: 6, period: 30)
        XCTAssertEqual(a, b)
    }

    func testDeduplicationKeyDistinguishesParameters() {
        let base = Account.deduplicationKey(issuer: "GitHub", username: "alex", secret: "ABCD", algorithm: .sha1, digits: 6, period: 30)
        XCTAssertNotEqual(
            base, Account.deduplicationKey(issuer: "GitHub", username: "alex", secret: "ABCD", algorithm: .sha1, digits: 8, period: 30))
        XCTAssertNotEqual(
            base, Account.deduplicationKey(issuer: "GitHub", username: "alex", secret: "ABCD", algorithm: .sha256, digits: 6, period: 30))
        XCTAssertNotEqual(
            base, Account.deduplicationKey(issuer: "GitHub", username: "other", secret: "ABCD", algorithm: .sha1, digits: 6, period: 30))
    }

    func testParsedOTPAuthSharesAccountKey() {
        let parsed = ParsedOTPAuth(isValid: true, issuer: "GitHub", account: "alex", secret: "ABCD")
        let account = Account(issuer: "GitHub", username: "alex", secret: "ABCD")
        XCTAssertEqual(parsed.deduplicationKey, account.deduplicationKey)
    }

    func testColorIsDeterministicPerIssuer() {
        XCTAssertEqual(Account.color(for: "GitHub"), Account.color(for: "GitHub"))
        XCTAssertEqual(Account.color(for: ""), Account.color(for: ""))
    }

    func testMonogram() {
        XCTAssertEqual(Account.monogram(for: "GitHub"), "GIT")
        XCTAssertEqual(Account.monogram(for: "Epic Games"), "EG")
        XCTAssertEqual(Account.monogram(for: "ab"), "AB")
    }

    func testRecentlyAddedWindow() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(
            Account(issuer: "New", username: "alex", secret: "ABCD", createdAt: now.addingTimeInterval(-29 * 60)).isRecentlyAdded(
                relativeTo: now))
        XCTAssertTrue(
            Account(issuer: "Boundary", username: "alex", secret: "ABCD", createdAt: now.addingTimeInterval(-30 * 60)).isRecentlyAdded(
                relativeTo: now))
        XCTAssertFalse(
            Account(issuer: "Old", username: "alex", secret: "ABCD", createdAt: now.addingTimeInterval(-30 * 60 - 1)).isRecentlyAdded(
                relativeTo: now))
        XCTAssertFalse(
            Account(issuer: "Future", username: "alex", secret: "ABCD", createdAt: now.addingTimeInterval(1)).isRecentlyAdded(
                relativeTo: now))
    }

    func testMatchesSearch() {
        let account = Account(issuer: "GitHub", username: "alex@example.com", secret: "ABCD")
        XCTAssertTrue(account.matchesSearch(""))
        XCTAssertTrue(account.matchesSearch("github"))
        XCTAssertTrue(account.matchesSearch("ghb"))
        XCTAssertTrue(account.matchesSearch("example"))
        XCTAssertFalse(account.matchesSearch("gitlab"))
    }
}

final class SettingsStorageTests: XCTestCase {
    func testAutoLockDelaySeconds() {
        XCTAssertEqual(AutoLockMode.allCases, [.oneMinute, .fiveMinutes, .thirtyMinutes])
        XCTAssertEqual(AutoLockMode.oneMinute.delaySeconds, 60)
        XCTAssertEqual(AutoLockMode.fiveMinutes.delaySeconds, 300)
        XCTAssertEqual(AutoLockMode.thirtyMinutes.delaySeconds, 1800)
    }

    func testMenuBarListScopeStorage() {
        XCTAssertEqual(MenuBarListScope(storedValue: "favorites"), .all, "Unrecognized values fall back to All, with no migration")
        XCTAssertEqual(MenuBarListScope(storedValue: nil), .all)
        XCTAssertEqual(MenuBarListScope(storedValue: "garbage"), .all)
        XCTAssertEqual(MenuBarListScope(storedValue: "category:not-a-uuid"), .all)
        let id = UUID()
        XCTAssertEqual(MenuBarListScope(storedValue: MenuBarListScope.category(id).rawValue), .category(id))
    }
}

final class BackupHistoryItemTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let item = BackupHistoryItem(
            date: Date(timeIntervalSince1970: 1_700_000_000), device: "Mac", size: "2 KB", sourceKey: "icloud.hist.auto", isFailure: true)
        let data = try JSONEncoder.kakey.encode([item])
        let decoded = try JSONDecoder.kakey.decode([BackupHistoryItem].self, from: data)
        XCTAssertEqual(decoded, [item])
        XCTAssertTrue(item.isWarning)
    }
}

final class CloudLocationCodingTests: XCTestCase {
    func testRoundTripKeepsAppFolder() throws {
        let location = CloudLocation(
            provider: .dropbox, host: "dropbox.com", username: "alice@example.com", isSecure: true, folder: "", isAppFolder: true)
        let decoded = try JSONDecoder().decode(CloudLocation.self, from: JSONEncoder().encode(location))
        XCTAssertEqual(decoded, location)
    }

    /// Google Drive keeps its app folder in My Drive, not under "Apps" as Dropbox and OneDrive do.
    func testAppFolderPathFollowsTheProvider() throws {
        let google = CloudLocation(
            provider: .googleDrive, host: "drive.google.com", username: "alice@gmail.com", isSecure: true, folder: "",
            isAppFolder: true)
        XCTAssertEqual(try JSONDecoder().decode(CloudLocation.self, from: JSONEncoder().encode(google)), google)
        XCTAssertEqual(SyncLocation.cloud(google).detail, L10n.format("%@ · My Drive › Kakey", "alice@gmail.com"))
        XCTAssertEqual(SyncLocation.cloud(google).fullPath, "Google Drive › \(L10n.tr("My Drive › Kakey"))")
        var oneDrive = google
        oneDrive.provider = .oneDrive
        XCTAssertEqual(SyncLocation.cloud(oneDrive).detail, L10n.format("%@ · Apps › Kakey", "alice@gmail.com"))
        XCTAssertEqual(CloudProvider(.googleDrive), .googleDrive)
        XCTAssertEqual(CloudProvider.googleDrive.core, .googleDrive)
        XCTAssertTrue(CloudProvider.googleDrive.usesOAuth)
    }

    /// `isAppFolder` is optional: a WebDAV / Nextcloud location without it decodes normally.
    func testMissingAppFolderReadsAsFalse() throws {
        let json = #"{"provider":"webDAV","host":"dav.example.com","username":"alice","isSecure":true,"folder":"Kakey"}"#
        let decoded = try JSONDecoder().decode(CloudLocation.self, from: Data(json.utf8))
        XCTAssertEqual(
            decoded,
            CloudLocation(provider: .webDAV, host: "dav.example.com", username: "alice", isSecure: true, folder: "Kakey"))
    }

    /// The missing-backup message names the selected location; for cloud storage only the service name, never the directory.
    func testMissingBackupMessageNamesTheLocation() {
        let webDAV = SyncLocation.cloud(
            CloudLocation(provider: .webDAV, host: "dav.example.com", username: "alice", isSecure: true, folder: "Backups/Kakey"))
        let message = SyncErrorText.message(for: VaultSyncError.missingRemoteVault, at: webDAV)
        XCTAssertEqual(message, L10n.format("No secure Kakey backup was found in %@.", "WebDAV"))
        XCTAssertFalse(message.contains("Backups"))
        XCTAssertEqual(
            SyncErrorText.message(for: VaultSyncError.missingRemoteVault, at: .iCloud(account: "a")),
            L10n.format("No secure Kakey backup was found in %@.", "iCloud"))
        XCTAssertEqual(
            SyncErrorText.message(for: VaultSyncError.missingRemoteVault, at: .folder(bookmark: Data(), name: "Kakey")),
            L10n.format("No secure Kakey backup was found in the “%@” folder.", "Kakey"))
    }
}

final class BackupHistoryDirectionTests: XCTestCase {
    func testDirectionRoundTripsAndIsOptional() throws {
        let item = BackupHistoryItem.record(
            date: Date(timeIntervalSince1970: 1_800_000_000), device: "Mac", bytes: 1_024, sourceKey: "icloud.hist.manual",
            direction: .download)
        let decoded = try JSONDecoder.kakey.decode([BackupHistoryItem].self, from: JSONEncoder.kakey.encode([item]))
        XCTAssertEqual(decoded, [item])
        XCTAssertEqual(item.title, L10n.tr("Downloaded"))

        var old = item
        old.direction = nil
        let json = try XCTUnwrap(String(data: JSONEncoder.kakey.encode([old]), encoding: .utf8))
        XCTAssertFalse(json.contains("direction"), "No field is written without a direction")
        let reread = try XCTUnwrap(try JSONDecoder.kakey.decode([BackupHistoryItem].self, from: Data(json.utf8)).first)
        XCTAssertEqual(reread.title, reread.statusText, "A record without a direction uses its status as the title")
        XCTAssertNil(reread.detail(thisDevice: "Mac"))
    }

    /// Second line: the trigger; adds "From X" when the data came from another device. Uploads, failures, and records from a device
    /// with this device's name omit the device.
    func testDetailNamesOtherDevicesOnly() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let auto = L10n.tr("icloud.hist.auto")
        let fromPhone = BackupHistoryItem.record(
            date: date, device: "iPhone", bytes: 1, sourceKey: "icloud.hist.auto", direction: .download)
        XCTAssertEqual(fromPhone.detail(thisDevice: "Mac"), "\(auto) · \(L10n.format("From %@", "iPhone"))")
        let own = BackupHistoryItem.record(date: date, device: "Mac", bytes: 1, sourceKey: "icloud.hist.auto", direction: .download)
        XCTAssertEqual(own.detail(thisDevice: "Mac"), auto)
        let upload = BackupHistoryItem.record(date: date, device: "Mac", bytes: 1, sourceKey: "icloud.hist.auto", direction: .upload)
        XCTAssertEqual(upload.title, L10n.tr("Uploaded"))
        XCTAssertEqual(upload.detail(thisDevice: "Mac"), auto)
        let failed = BackupHistoryItem.record(date: date, device: "Mac", bytes: nil, sourceKey: "icloud.hist.manual", isFailure: true)
        XCTAssertEqual(failed.title, failed.statusText)
        XCTAssertNil(failed.detail(thisDevice: "Mac"))
    }

    /// Records that captured a location lead the second line with its name (failures too), so they stay distinguishable after the
    /// location changes.
    func testDetailLeadsWithTheLocation() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let auto = L10n.tr("icloud.hist.auto")
        let upload = BackupHistoryItem.record(
            date: date, device: "Mac", bytes: 1, sourceKey: "icloud.hist.auto", direction: .upload, location: "OneDrive")
        XCTAssertEqual(upload.detail(thisDevice: "Mac"), "OneDrive · \(auto)")
        let failed = BackupHistoryItem.record(
            date: date, device: "Mac", bytes: nil, sourceKey: "icloud.hist.manual", isFailure: true, location: "Dropbox")
        XCTAssertEqual(failed.detail(thisDevice: "Mac"), "Dropbox")
        let decoded = try JSONDecoder.kakey.decode([BackupHistoryItem].self, from: JSONEncoder.kakey.encode([upload]))
        XCTAssertEqual(decoded.first?.location, "OneDrive")
    }
}

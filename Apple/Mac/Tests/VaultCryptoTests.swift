import XCTest

@testable import Kakey

final class VaultCryptoTests: XCTestCase {
    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Kakey-test-\(UUID().uuidString).json")
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func temporaryVaultURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Kakey-vault-test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("vault.json")
    }

    /// Import files larger than `ExternalFileLimits.maxBytes` are rejected as invalid without being read into memory.
    func testOversizedImportFileIsRejectedAsInvalid() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(count: ExternalFileLimits.maxBytes + 1).write(to: url)
        XCTAssertThrowsError(try ExternalAccountImportService.importAccounts(from: url, password: "x")) { error in
            XCTAssertEqual(error as? ExternalAccountImportError, .invalidFile)
        }
        XCTAssertThrowsError(try ExternalFileLimits.read(contentsOf: url)) { error in
            XCTAssertTrue(error is ExternalFileLimits.TooLarge)
        }
        try Data(count: ExternalFileLimits.maxBytes).write(to: url)
        XCTAssertEqual(try ExternalFileLimits.read(contentsOf: url).count, ExternalFileLimits.maxBytes, "Exactly the limit is OK")
    }

    func testExportImportRoundTrip() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let accounts = [
            Account(
                issuer: "GitHub", username: "alex", secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", algorithm: .sha256, digits: 8, period: 60),
            Account(issuer: "Example", username: "user", secret: "MZXW6YTBOI"),
        ]
        let categories = [
            AccountCategory(id: UUID(), name: "工作", accountIDs: [accounts[1].id, accounts[0].id]),
            AccountCategory(id: UUID(), name: "未导出", accountIDs: [UUID()]),
        ]
        try VaultPersistenceService.export(accounts: accounts, categories: categories, password: "Kx7-export-Qm2v", to: url)

        let exportFile = try jsonObject(at: url)
        XCTAssertEqual(exportFile["app"] as? String, "kakey")
        XCTAssertEqual(exportFile["version"] as? Int, 2)
        XCTAssertEqual(exportFile["kdf"] as? String, "Argon2id")
        XCTAssertEqual(exportFile["memoryKiB"] as? Int, 1024 * 64)
        XCTAssertEqual(exportFile["parallelism"] as? Int, 1)
        XCTAssertEqual(exportFile["keyLength"] as? Int, 32)
        XCTAssertEqual(exportFile["accountCount"] as? Int, 2)

        let imported = try ExternalAccountImportService.importAccounts(from: url, password: "Kx7-export-Qm2v")
        XCTAssertEqual(imported.accounts.map(\.issuer), accounts.map(\.issuer))
        XCTAssertEqual(imported.accounts.map(\.secret), accounts.map(\.secret))
        XCTAssertEqual(imported.accounts.map(\.algorithm), accounts.map(\.algorithm))
        XCTAssertEqual(imported.categories, [categories[0]], "Only categories of exported accounts are included; empty ones are not")
    }

    func testCategoriesPersistInVault() throws {
        let url = temporaryVaultURL()
        VaultPersistenceService.vaultURLOverride = url
        defer {
            VaultPersistenceService.vaultURLOverride = nil
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }

        let first = Account(issuer: "First", username: "user", secret: "MZXW6YTBOI")
        let second = Account(issuer: "Second", username: "user", secret: "GEZDGNBVGY3TQOJQ")
        let third = Account(issuer: "Third", username: "user", secret: "JBSWY3DPEHPK3PXP")
        var categories = try CategoryService.create([], name: "工作")
        categories = try CategoryService.add(second.id, to: categories[0].id, in: categories)
        categories = try CategoryService.add(first.id, to: categories[0].id, in: categories)
        categories = try CategoryService.create(categories, name: "Crypto")
        categories = try CategoryService.add(second.id, to: categories[1].id, in: categories)

        let key = try VaultPersistenceService.save(
            VaultContents(accounts: [first, second, third], categories: categories),
            password: "category-password"
        )

        XCTAssertEqual(try VaultPersistenceService.openCurrentVault(key: key).categories, categories)
        let unlocked = try VaultPersistenceService.unlock(password: "category-password")
        XCTAssertEqual(unlocked.contents.categories, categories)
        XCTAssertEqual(unlocked.contents.accounts.map(\.issuer), ["First", "Second", "Third"])
        XCTAssertEqual(categories.accounts(in: categories[0].id, from: unlocked.contents.accounts).map(\.issuer), ["Second", "First"])
        XCTAssertEqual(categories.containing(second.id).map(\.name), ["工作", "Crypto"])
    }

    func testCategoryRulesComeFromCore() throws {
        let categories = try CategoryService.create([], name: "  工作 ")
        XCTAssertEqual(categories.map(\.name), ["工作"])
        XCTAssertThrowsError(try CategoryService.create(categories, name: "工作")) { XCTAssertEqual($0 as? CategoryError, .duplicateName) }
        XCTAssertThrowsError(try CategoryService.create(categories, name: " ")) { XCTAssertEqual($0 as? CategoryError, .emptyName) }
        XCTAssertThrowsError(try CategoryService.create(categories, name: String(repeating: "长", count: CategoryService.maxNameLength + 1)))
        {
            XCTAssertEqual($0 as? CategoryError, .nameTooLong)
        }
        XCTAssertThrowsError(try CategoryService.rename(categories, id: UUID(), to: "x")) {
            XCTAssertEqual($0 as? CategoryError, .notFound)
        }
        let accountID = UUID()
        let added = try CategoryService.add(accountID, to: categories[0].id, in: categories)
        XCTAssertEqual(CategoryService.removing([accountID], from: added)[0].accountIDs, [])
        XCTAssertEqual(CategoryService.delete(added, id: categories[0].id), [])
    }

    func testImportWithWrongPasswordThrowsWithoutPartialData() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try VaultPersistenceService.export(
            accounts: [Account(issuer: "GitHub", username: "alex", secret: "MZXW6YTBOI")],
            categories: [],
            password: "correct-password",
            to: url
        )

        XCTAssertThrowsError(try ExternalAccountImportService.importAccounts(from: url, password: "wrong-password")) { error in
            XCTAssertEqual(error as? ExternalAccountImportError, .wrongPassword)
        }
    }

    /// Failures importing a Kakey export file use the same wording as Authenticator backups, never the vault unlock message
    /// "incorrect master password".
    func testBackupImportErrorsUseImportWording() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try VaultPersistenceService.export(
            accounts: [Account(issuer: "GitHub", username: "alex", secret: "MZXW6YTBOI")],
            categories: [],
            password: "correct-password",
            to: url
        )
        XCTAssertThrowsError(try ExternalAccountImportService.importAccounts(from: url, password: "wrong-password")) {
            XCTAssertEqual($0 as? ExternalAccountImportError, .wrongPassword)
        }
        XCTAssertThrowsError(try ExternalAccountImportService.importAccounts(from: url, password: "")) {
            XCTAssertEqual($0 as? ExternalAccountImportError, .passwordRequired)
        }

        var exportFile = try jsonObject(at: url)
        exportFile["kdf"] = "scrypt"
        try JSONSerialization.data(withJSONObject: exportFile).write(to: url, options: [.atomic])
        XCTAssertThrowsError(try ExternalAccountImportService.importAccounts(from: url, password: "correct-password")) {
            XCTAssertEqual($0 as? ExternalAccountImportError, .invalidFile)
        }

        let missing = url.deletingLastPathComponent().appendingPathComponent("Kakey-missing-\(UUID().uuidString).json")
        XCTAssertThrowsError(try ExternalAccountImportService.importAccounts(from: missing, password: "x")) {
            XCTAssertEqual($0 as? ExternalAccountImportError, .invalidFile)
        }
    }

    func testImportRejectsForeignEnvelope() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try Data(#"{"app":"other","kind":"x"}"#.utf8).write(to: url)
        XCTAssertThrowsError(try ExternalAccountImportService.importAccounts(from: url, password: "any"))
    }

    func testImportRejectsUnknownExportKDF() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try VaultPersistenceService.export(
            accounts: [Account(issuer: "GitHub", username: "alex", secret: "MZXW6YTBOI")],
            categories: [],
            password: "Kx7-export-Qm2v",
            to: url
        )

        var exportFile = try jsonObject(at: url)
        exportFile["kdf"] = "scrypt"
        try JSONSerialization.data(withJSONObject: exportFile).write(to: url, options: [.atomic])

        XCTAssertThrowsError(try ExternalAccountImportService.importAccounts(from: url, password: "Kx7-export-Qm2v"))
    }

    func testLastKnownGoodVaultCanRecoverAfterMainVaultCorruption() throws {
        let url = temporaryVaultURL()
        VaultPersistenceService.vaultURLOverride = url
        defer {
            VaultPersistenceService.vaultURLOverride = nil
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }

        let firstAccounts = [
            Account(issuer: "GitHub", username: "alex", secret: "MZXW6YTBOI")
        ]
        let secondAccounts = [
            Account(issuer: "GitHub", username: "alex", secret: "MZXW6YTBOI"),
            Account(issuer: "Example", username: "user", secret: "GEZDGNBVGY3TQOJQ"),
        ]

        let key = try VaultPersistenceService.createVault(password: "recover-password", accounts: firstAccounts)
        let envelope = try VaultPersistenceService.encryptedVaultEnvelope(from: Data(contentsOf: url))
        XCTAssertEqual(envelope.version, 2)
        XCTAssertEqual(envelope.kdf, "Argon2id")
        XCTAssertFalse(VaultPersistenceService.lastKnownGoodVaultExists)

        try VaultPersistenceService.save(VaultContents(accounts: secondAccounts, categories: []), key: key)
        XCTAssertTrue(VaultPersistenceService.lastKnownGoodVaultExists)

        try Data("not a valid vault".utf8).write(to: url, options: [.atomic])

        let restored = try VaultPersistenceService.restoreLastKnownGoodVault(password: "recover-password")
        XCTAssertEqual(restored.contents.accounts.map(\.issuer), ["GitHub"])

        let unlocked = try VaultPersistenceService.unlock(password: "recover-password")
        XCTAssertEqual(unlocked.contents.accounts.map(\.issuer), ["GitHub"])
    }
}

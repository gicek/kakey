import XCTest

@testable import Kakey

/// Compiled String Catalog: English source strings as keys, English plurals, positional placeholders. Does not change the current
/// L10n language.
final class LocalizationTests: XCTestCase {
    private func text(_ key: String, _ language: String, _ arguments: CVarArg...) throws -> String {
        let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"), "Missing \(language).lproj")
        let bundle = try XCTUnwrap(Bundle(path: path))
        return L10n.format(key, bundle: bundle, locale: Locale(identifier: language), arguments: arguments)
    }

    func testEnglishPluralsFollowCount() throws {
        XCTAssertEqual(try text("Imported %lld accounts", "en", 1), "Imported 1 account")
        XCTAssertEqual(try text("Imported %lld accounts", "en", 3), "Imported 3 accounts")
        XCTAssertEqual(
            try text("Imported %1$lld accounts, skipped %2$lld duplicates", "en", 1, 2),
            "Imported 1 account, skipped 2 duplicates"
        )
    }

    func testTranslationsAndPositionalArguments() throws {
        XCTAssertEqual(try text("Add Account", "zh-Hans", 0), "添加账户")
        XCTAssertEqual(try text("Add Account", "zh-Hant", 0), "加入帳號")
        XCTAssertEqual(try text("%1$lld of %2$lld selected", "zh-Hans", 2, 5), "已选 2 / 5")
        XCTAssertEqual(try text("%1$@ (%2$lld)", "zh-Hans", "工作", 4), "工作（4）")
        XCTAssertEqual(try text("%1$@ (%2$lld)", "en", "Work", 4), "Work (4)")
    }

    /// Core error codes keep semantic keys and are translated in all three languages.
    func testCoreErrorKeysAreTranslated() throws {
        XCTAssertEqual(try text("err.vault.corrupt", "en", 0), "Invalid vault file format")
        XCTAssertEqual(try text("err.vault.corrupt", "zh-Hans", 0), "保险库文件格式无效")
    }
}

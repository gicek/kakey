import Foundation
import XCTest

@testable import Kakey

/// Alfred workflow packaged at build time: the scripts live only inside the `.alfredworkflow`, and `build-alfred-workflow.py`
/// generates the result list and notification text in all three languages from the String Catalog.
final class AlfredWorkflowTests: XCTestCase {
    /// String Catalog keys used by the workflow (English source strings as keys; the scripts replace `%@` with `{}` / `%s`).
    private static let searchKeys = [
        "Kakey isn’t running",
        "Press Enter to open Kakey",
        "Kakey isn’t ready yet",
        "The vault hasn’t been unlocked since Kakey started",
        "Kakey automation access is off",
        "Press Enter to open System Settings and allow Alfred to control Kakey",
        "Third-party plugin interface is off",
        "Press Enter to open Kakey, then turn it on in Settings → Advanced",
        "No matching accounts",
        "No results for “%@”",
        "Type a service or account name to filter",
        "%@ · Press Enter to copy the code",
    ]
    private static let copiedMessageKey = "Code copied to clipboard: %@"
    private static let languages = ["en", "zh-Hans", "zh-Hant"]

    private func workflowURL() throws -> URL {
        try XCTUnwrap(Bundle.main.url(forResource: "Kakey", withExtension: "alfredworkflow"), "Missing Kakey.alfredworkflow")
    }

    private func entry(_ name: String, in workflow: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", workflow.path, name]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "unzip \(name)")
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    /// Raw template for the key in the compiled .lproj (keeps `%@`).
    private func template(_ key: String, _ language: String) throws -> String {
        let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"), "Missing \(language).lproj")
        let bundle = try XCTUnwrap(Bundle(path: path))
        let value = bundle.localizedString(forKey: key, value: "", table: nil)
        XCTAssertFalse(value.isEmpty, "Key \"\(key)\" has no text in \(language)")
        return value
    }

    func testScriptsShipOnlyInsideTheWorkflow() throws {
        _ = try workflowURL()
        XCTAssertNil(Bundle.main.url(forResource: "alfred-search", withExtension: "py"))
        XCTAssertNil(Bundle.main.url(forResource: "alfred-reveal", withExtension: "sh"))
        XCTAssertNil(Bundle.main.url(forResource: "search", withExtension: "py"))
    }

    func testSearchScriptCarriesCatalogTranslations() throws {
        let script = try entry("search.py", in: try workflowURL())
        XCTAssertFalse(script.contains("@@KAKEY_ALFRED_STRINGS@@"))
        XCTAssertFalse(script.contains("STRINGS = {}"))
        for language in Self.languages {
            for key in Self.searchKeys {
                let expected = try template(key, language).replacing("%@", with: "{}")
                XCTAssertTrue(script.contains("\"\(expected)\""), "\(language) is missing \"\(expected)\"")
            }
        }
    }

    func testRevealScriptCarriesCatalogTranslations() throws {
        let script = try entry("reveal.sh", in: try workflowURL())
        XCTAssertFalse(script.contains("@@KAKEY_ALFRED_COPIED_MESSAGE@@"))
        for language in Self.languages {
            let expected = try template(Self.copiedMessageKey, language).replacing("%@", with: "%s")
            let variable = "COPIED_MESSAGE_\(language.replacing("-", with: "_"))='\(expected)'"
            XCTAssertTrue(script.contains(variable), "\(language) is missing \"\(variable)\"")
        }
    }
}

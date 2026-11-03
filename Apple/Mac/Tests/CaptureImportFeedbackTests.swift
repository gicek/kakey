import XCTest

@testable import Kakey

/// Wording and tone of screenshot-scan results: the desktop toast, the menu bar footer, and results queued until unlock share one
/// source.
@MainActor
final class CaptureImportFeedbackTests: XCTestCase {
    func testAddedResultUsesSuccessTone() {
        let result = VaultStore.CaptureImportResult.added("GitHub")
        XCTAssertEqual(result.feedbackMessage, L10n.format("Added %@", "GitHub"))
        XCTAssertEqual(result.feedbackKind, .success)
    }

    func testDuplicateResultUsesErrorTone() {
        let result = VaultStore.CaptureImportResult.duplicate("GitHub")
        XCTAssertEqual(result.feedbackMessage, L10n.format("%@ already exists", "GitHub"))
        XCTAssertEqual(result.feedbackKind, .error)
    }
}

import XCTest

@testable import Kakey

final class AddAccountDropTests: XCTestCase {
    func testDroppedFilePathIsReplacedWithFileContents() {
        let url = URL(fileURLWithPath: "/Users/alex/Downloads/authenticator.txt")
        let fileText = """
            otpauth://totp/Example:one@example.com?secret=GEZDGNBVGY3TQOJQ
            otpauth://totp/Example:two@example.com?secret=GEZDGNBVGY3TQOJQ
            """

        let resolved = OTPAuthTextDropResolver.resolvedText(
            currentText: url.path,
            droppedFileURL: url,
            droppedFileText: fileText
        )

        XCTAssertFalse(resolved.contains(url.path))
        XCTAssertEqual(OTPAuthParser.parseLines(resolved).filter(\.isValid).count, 2)
    }

    func testFileURLReferenceFallbackExpandsToContents() {
        let url = URL(fileURLWithPath: "/Users/alex/Downloads/authenticator.txt")
        let fileText = "otpauth://totp/Example:one@example.com?secret=GEZDGNBVGY3TQOJQ"

        let resolved = OTPAuthTextDropResolver.resolvedText(currentText: url.absoluteString) { candidate in
            candidate == url ? fileText : nil
        }

        XCTAssertEqual(resolved, fileText)
        XCTAssertTrue(OTPAuthParser.parseLines(resolved).first?.isValid == true)
    }

    func testAppendedFileReferencesAreDroppedButOthersKept() {
        let appended = URL(fileURLWithPath: "/Users/alex/Downloads/authenticator.txt")
        let other = URL(fileURLWithPath: "/Users/alex/Downloads/other.txt")
        let text = """
            otpauth://totp/Example:one@example.com?secret=GEZDGNBVGY3TQOJQ
            \(appended.path)
            \(other.absoluteString)
            """

        let result = OTPAuthTextDropResolver.removingReferences(to: [appended], from: text)

        XCTAssertFalse(result.contains(appended.path))
        XCTAssertTrue(result.contains(other.absoluteString))
        XCTAssertEqual(result.components(separatedBy: "\n").count, 2)
    }
}

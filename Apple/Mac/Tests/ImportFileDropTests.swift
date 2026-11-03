import XCTest

@testable import Kakey

final class ImportFileDropTests: XCTestCase {
    func testFileURLDataResolvesToLocalFile() {
        let url = URL(fileURLWithPath: "/Users/alex/Downloads/authenticator.json")
        let data = Data(url.absoluteString.utf8)

        XCTAssertEqual(ImportFileDropResolver.fileURL(from: data as NSData), url)
    }

    func testPlainPathStringResolvesToLocalFile() {
        let url = URL(fileURLWithPath: "/Users/alex/Downloads/Kakey-export.json")

        XCTAssertEqual(ImportFileDropResolver.fileURL(from: url.path as NSString), url)
    }

    func testNSURLResolvesToLocalFile() {
        let url = URL(fileURLWithPath: "/Users/alex/Downloads/Kakey-export.json")

        XCTAssertEqual(ImportFileDropResolver.fileURL(from: url as NSURL), url)
    }

    func testNonFileURLIsRejected() {
        XCTAssertNil(ImportFileDropResolver.fileURL(fromDroppedText: "https://example.com/backup.json"))
    }
}

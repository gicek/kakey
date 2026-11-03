import XCTest

@testable import Kakey

final class TOTPServiceTests: XCTestCase {
    // RFC 6238 Appendix B test secret (Base32 of the ASCII digit sequence).
    private let sha1Secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    private let sha256Secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZA===="
    private let sha512Secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNA="

    private func account(secret: String, algorithm: TOTPAlgorithm, digits: Int = 8) -> Account {
        Account(issuer: "RFC", username: "test", secret: secret, algorithm: algorithm, digits: digits, period: 30)
    }

    func testRFC6238SHA1Vectors() {
        let account = account(secret: sha1Secret, algorithm: .sha1)
        XCTAssertEqual(TOTPService.code(for: account, date: Date(timeIntervalSince1970: 59)), "94287082")
        XCTAssertEqual(TOTPService.code(for: account, date: Date(timeIntervalSince1970: 1_111_111_109)), "07081804")
        XCTAssertEqual(TOTPService.code(for: account, date: Date(timeIntervalSince1970: 20_000_000_000)), "65353130")
    }

    func testRFC6238SHA256Vectors() {
        let account = account(secret: sha256Secret, algorithm: .sha256)
        XCTAssertEqual(TOTPService.code(for: account, date: Date(timeIntervalSince1970: 59)), "46119246")
        XCTAssertEqual(TOTPService.code(for: account, date: Date(timeIntervalSince1970: 1_111_111_109)), "68084774")
    }

    func testRFC6238SHA512Vectors() {
        let account = account(secret: sha512Secret, algorithm: .sha512)
        XCTAssertEqual(TOTPService.code(for: account, date: Date(timeIntervalSince1970: 59)), "90693936")
        XCTAssertEqual(TOTPService.code(for: account, date: Date(timeIntervalSince1970: 20_000_000_000)), "47863826")
    }

    func testSixDigitCodeIsZeroPadded() {
        let account = account(secret: sha1Secret, algorithm: .sha1, digits: 6)
        let code = TOTPService.code(for: account, date: Date(timeIntervalSince1970: 59))
        XCTAssertEqual(code.count, 6)
        XCTAssertEqual(code, "287082")
    }

    func testInvalidSecretProducesPlaceholder() {
        let account = account(secret: "not base32 !!", algorithm: .sha1, digits: 6)
        XCTAssertEqual(TOTPService.code(for: account, date: .now), String(repeating: "—", count: 6))
    }

    func testFormattedCodeSplitsInHalf() {
        let account = account(secret: sha1Secret, algorithm: .sha1, digits: 6)
        XCTAssertEqual(TOTPService.formattedCode(for: account, date: Date(timeIntervalSince1970: 59)), "287 082")
    }

    func testSecondsRemainingAndProgress() {
        let account = account(secret: sha1Secret, algorithm: .sha1)
        XCTAssertEqual(TOTPService.secondsRemaining(for: account, date: Date(timeIntervalSince1970: 0)), 30)
        XCTAssertEqual(TOTPService.secondsRemaining(for: account, date: Date(timeIntervalSince1970: 29)), 1)
        XCTAssertEqual(TOTPService.progress(for: account, date: Date(timeIntervalSince1970: 0)), 1.0)
    }

    func testIsValidSecret() {
        XCTAssertTrue(TOTPService.isValidSecret(sha1Secret))
        XCTAssertTrue(TOTPService.isValidSecret("gezd gnbv-gy3t qojq"))
        XCTAssertFalse(TOTPService.isValidSecret(""))
        XCTAssertFalse(TOTPService.isValidSecret("18"))
    }
}

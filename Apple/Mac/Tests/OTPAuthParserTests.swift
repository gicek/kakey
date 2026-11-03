import XCTest

@testable import Kakey

final class OTPAuthParserTests: XCTestCase {
    private let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

    func testParsesFullURI() {
        let parsed = OTPAuthParser.parse(
            "otpauth://totp/GitHub:alex@example.com?secret=\(secret)&issuer=GitHub&algorithm=SHA256&digits=8&period=60")
        XCTAssertTrue(parsed.isValid)
        XCTAssertEqual(parsed.issuer, "GitHub")
        XCTAssertEqual(parsed.account, "alex@example.com")
        XCTAssertEqual(parsed.algorithm, .sha256)
        XCTAssertEqual(parsed.digits, 8)
        XCTAssertEqual(parsed.period, 60)
    }

    func testParsesSloppyURIIntoCanonicalFields() {
        let parsed = OTPAuthParser.parse(
            " otpauth://1/GitHub%20Inc:alex%40example.com?secret=gez dgnbv-gy3tqojqgez dgnbvgy3tqojq%0A&issuer=GitHub%20Inc%0A&algorithm=sha256&digits=8&period=60 "
        )

        XCTAssertTrue(parsed.isValid)
        XCTAssertEqual(parsed.issuer, "GitHub Inc")
        XCTAssertEqual(parsed.account, "alex@example.com")
        XCTAssertEqual(parsed.secret, secret)
        XCTAssertEqual(parsed.algorithm, .sha256)
        XCTAssertEqual(parsed.digits, 8)
        XCTAssertEqual(parsed.period, 60)
    }

    func testBuildsCanonicalOTPAuthURLString() {
        let account = Account(
            issuer: " GitHub Inc ",
            username: "alex@example.com",
            secret: "gez dgnbv-gy3tqojqgez dgnbvgy3tqojq",
            algorithm: .sha256,
            digits: 8,
            period: 60
        )

        let uri = OTPAuthCanonicalizer.otpauthURLString(for: account)

        XCTAssertEqual(
            uri, "otpauth://totp/GitHub%20Inc:alex%40example.com?secret=\(secret)&issuer=GitHub%20Inc&algorithm=SHA256&digits=8&period=60")
        XCTAssertEqual(OTPAuthParser.parse(uri).secret, secret)
    }

    func testIssuerFallsBackToLabel() {
        let parsed = OTPAuthParser.parse("otpauth://totp/Example:user?secret=\(secret)")
        XCTAssertTrue(parsed.isValid)
        XCTAssertEqual(parsed.issuer, "Example")
        XCTAssertEqual(parsed.account, "user")
    }

    func testDefaultsToSHA1SixDigits30Seconds() {
        let parsed = OTPAuthParser.parse("otpauth://totp/Example:user?secret=\(secret)")
        XCTAssertEqual(parsed.algorithm, .sha1)
        XCTAssertEqual(parsed.digits, 6)
        XCTAssertEqual(parsed.period, 30)
    }

    func testRejectsMissingSecret() {
        XCTAssertFalse(OTPAuthParser.parse("otpauth://totp/Example:user").isValid)
    }

    func testRejectsInvalidBase32Secret() {
        XCTAssertFalse(OTPAuthParser.parse("otpauth://totp/Example:user?secret=189").isValid)
    }

    func testRejectsNonTOTPType() {
        XCTAssertFalse(OTPAuthParser.parse("otpauth://hotp/Example:user?secret=\(secret)").isValid)
    }

    func testRejectsUnsupportedDigits() {
        XCTAssertFalse(OTPAuthParser.parse("otpauth://totp/Example:user?secret=\(secret)&digits=7").isValid)
    }

    func testRejectsPlainText() {
        XCTAssertFalse(OTPAuthParser.parse("hello world").isValid)
    }

    func testParsesLabelWithPercentEncodedColon() {
        // Some QR codes encode the colon in the label as %3A; the account name must not keep the "issuer:" prefix.
        let parsed = OTPAuthParser.parse("otpauth://totp/Aliyun%3Aalexchen%40163.com?secret=\(secret)&issuer=Aliyun")
        XCTAssertTrue(parsed.isValid)
        XCTAssertEqual(parsed.issuer, "Aliyun")
        XCTAssertEqual(parsed.account, "alexchen@163.com")
    }

    func testParseLinesSplitsAndParsesEachLine() {
        let text = """
            otpauth://totp/A:a?secret=\(secret)
            not-a-uri
            otpauth://totp/B:b?secret=\(secret)
            """
        let parsed = OTPAuthParser.parseLines(text)
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed.filter(\.isValid).count, 2)
    }

    func testParsesGoogleAuthenticatorMigrationURI() {
        let uri = googleMigrationURI(
            secret: Data("12345678901234567890".utf8),
            name: "alex@example.com",
            issuer: "Google",
            algorithm: 2,
            digits: 2,
            batchSize: 3,
            batchIndex: 1,
            batchID: 42
        )

        let result = OTPAuthParser.parseScanResult(uri)
        XCTAssertTrue(result.isGoogleMigration)
        XCTAssertEqual(result.batchSize, 3)
        XCTAssertEqual(result.batchIndex, 1)
        XCTAssertEqual(result.batchID, 42)
        XCTAssertEqual(result.validAccounts.count, 1)
        XCTAssertEqual(result.validAccounts.first?.issuer, "Google")
        XCTAssertEqual(result.validAccounts.first?.account, "alex@example.com")
        XCTAssertEqual(result.validAccounts.first?.secret, secret)
        XCTAssertEqual(result.validAccounts.first?.algorithm, .sha256)
        XCTAssertEqual(result.validAccounts.first?.digits, 8)
        XCTAssertEqual(result.validAccounts.first?.period, 30)
    }

    private func googleMigrationURI(
        secret: Data,
        name: String,
        issuer: String,
        algorithm: UInt64,
        digits: UInt64,
        batchSize: UInt64,
        batchIndex: UInt64,
        batchID: UInt64
    ) -> String {
        let parameter =
            lengthDelimitedField(1, secret)
            + stringField(2, name)
            + stringField(3, issuer)
            + varintField(4, algorithm)
            + varintField(5, digits)
            + varintField(6, 2)
        let payload =
            lengthDelimitedField(1, parameter)
            + varintField(3, batchSize)
            + varintField(4, batchIndex)
            + varintField(5, batchID)
        let encoded =
            payload.base64EncodedString()
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return "otpauth-migration://offline?data=\(encoded)"
    }

    private func stringField(_ number: Int, _ value: String) -> Data {
        lengthDelimitedField(number, Data(value.utf8))
    }

    private func lengthDelimitedField(_ number: Int, _ value: Data) -> Data {
        var data = varintFieldKey(number, wireType: 2)
        data.append(varint(UInt64(value.count)))
        data.append(value)
        return data
    }

    private func varintField(_ number: Int, _ value: UInt64) -> Data {
        var data = varintFieldKey(number, wireType: 0)
        data.append(varint(value))
        return data
    }

    private func varintFieldKey(_ number: Int, wireType: UInt64) -> Data {
        varint((UInt64(number) << 3) | wireType)
    }

    private func varint(_ value: UInt64) -> Data {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 {
                byte |= 0x80
            }
            bytes.append(byte)
        } while value != 0
        return Data(bytes)
    }
}

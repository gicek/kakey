import XCTest

@testable import Kakey

final class AuthenticatorImportTests: XCTestCase {
    func testImportsAuthenticatorPlaintextJSON() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa": [
                "account": " alex%40example.com%0A ",
                "algorithm": "SHA256",
                "dataType": "OTPStorage",
                "digits": 8,
                "encrypted": false,
                "hash": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                "index": 0,
                "issuer": " GitHub%20Inc%0A ",
                "period": 60,
                "secret": "mzxw 6ytb-oi%0A",
                "type": "totp",
            ],
            "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb": [
                "account": "hex@example.com",
                "encrypted": false,
                "hash": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                "index": 1,
                "issuer": "Hex",
                "secret": "666f6f626172",
                "type": "hex",
            ],
            "cccccccc-cccc-4ccc-8ccc-cccccccccccc": [
                "account": "hotp@example.com",
                "encrypted": false,
                "hash": "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
                "index": 2,
                "issuer": "HOTP",
                "secret": "MZXW6YTBOI",
                "type": "hotp",
            ],
        ])

        let accounts = try ExternalAccountImportService.importAccounts(from: data, password: "").accounts

        XCTAssertEqual(accounts.count, 2)
        XCTAssertEqual(accounts[0].issuer, "GitHub Inc")
        XCTAssertEqual(accounts[0].username, "alex@example.com")
        XCTAssertEqual(accounts[0].secret, "MZXW6YTBOI")
        XCTAssertEqual(accounts[0].algorithm, .sha256)
        XCTAssertEqual(accounts[0].digits, 8)
        XCTAssertEqual(accounts[0].period, 60)
        XCTAssertEqual(accounts[1].issuer, "Hex")
        XCTAssertEqual(accounts[1].secret, "MZXW6YTBOI")
    }

    /// The v3 encrypted backup sample comes from golden (generated with Argon2id + CryptoJS).
    func testImportsAuthenticatorV3EncryptedJSON() throws {
        let sample = try Golden.sample("authenticator", list: "imports", name: "encrypted")
        let data = Data(try XCTUnwrap(sample["file"] as? String).utf8)

        let accounts = try ExternalAccountImportService.importAccounts(from: data, password: try XCTUnwrap(sample["password"] as? String))
            .accounts

        // Encrypted entries in the sample have no outer index and sort by entry hash: 99999999… (Second) before ffffffff… (Example).
        XCTAssertEqual(accounts.map(\.issuer), ["Second", "Example"])
        let example = accounts[1]
        XCTAssertEqual(example.username, "user@example.com")
        XCTAssertEqual(example.algorithm, .sha512)
        XCTAssertEqual(example.digits, 8)
        XCTAssertEqual(example.period, 45)
        XCTAssertEqual(example.secret, "MZXW6YTBOI")
    }

    func testAuthenticatorV3EncryptedJSONRequiresPassword() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee": [
                "data": "U2FsdGVkX18xMjM0NTY3OA==",
                "dataType": "EncOTPStorage",
                "index": 0,
                "keyId": "missing",
            ]
        ])

        XCTAssertThrowsError(try ExternalAccountImportService.importAccounts(from: data, password: "")) { error in
            XCTAssertEqual(error as? ExternalAccountImportError, .passwordRequired)
        }
    }

    /// The assertion that Argon2id runs only once per keyId lives in the core (unit tests in `authenticator.rs`).
    func testAuthenticatorV3WrongPasswordFails() throws {
        let sample = try Golden.sample("authenticator", list: "imports", name: "encrypted")
        let data = Data(try XCTUnwrap(sample["file"] as? String).utf8)

        XCTAssertThrowsError(try ExternalAccountImportService.importAccounts(from: data, password: "wrong-password")) { error in
            XCTAssertEqual(error as? ExternalAccountImportError, .wrongPassword)
        }
    }
}

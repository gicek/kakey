import Foundation

/// The result of parsing one scan or one line of text (a Google migration code expands into several accounts).
struct OTPAuthScanResult {
    var accounts: [ParsedOTPAuth]
    var batchIndex: Int?
    var batchSize: Int?
    var batchID: Int?
    var isGoogleMigration: Bool
    /// Identifies this code within a multi-QR migration batch; nil for non-migration codes or when the batch index is missing.
    var batchKey: String?

    var hasValidAccounts: Bool {
        accounts.contains { $0.isValid }
    }

    var validAccounts: [ParsedOTPAuth] {
        accounts.filter(\.isValid)
    }
}

/// Thin wrapper shared by Mac and iOS; otpauth and Google Authenticator migration code parsing lives in the Rust core
/// (`Core/crates/kakey-core/src/otpauth.rs`). Failure reasons are turned into text in the current language.
enum OTPAuthParser {
    static func parseLines(_ text: String) -> [ParsedOTPAuth] {
        coreParseOtpauthLines(text: text, placeholders: .current).map(ParsedOTPAuth.init)
    }

    static func parseScanResult(_ line: String) -> OTPAuthScanResult {
        let result = coreParseScanResult(line: line, placeholders: .current)
        return OTPAuthScanResult(
            accounts: result.accounts.map(ParsedOTPAuth.init),
            batchIndex: result.batchIndex.map { Int($0) },
            batchSize: result.batchSize.map { Int($0) },
            batchID: result.batchId.map { Int($0) },
            isGoogleMigration: result.isGoogleMigration,
            batchKey: result.batchKey
        )
    }

    static func parse(_ line: String) -> ParsedOTPAuth {
        ParsedOTPAuth(coreParseOtpauth(line: line, placeholders: .current))
    }
}

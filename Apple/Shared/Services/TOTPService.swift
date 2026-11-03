import Foundation

/// Thin wrapper shared by Mac and iOS; TOTP (RFC 6238) and Base32 are implemented in the Rust core
/// (`Core/crates/kakey-core/src/totp.rs`, `base32.rs`).
enum TOTPService {
    static func code(for account: Account, date: Date = .now) -> String {
        coreTotpCode(
            secret: account.secret,
            algorithm: account.algorithm.core,
            digits: UInt32(clamping: account.digits),
            period: UInt32(clamping: account.period),
            at: date
        )
    }

    static func formattedCode(for account: Account, date: Date = .now) -> String {
        formatted(code: code(for: account, date: date))
    }

    /// Splits the code in the middle (6 digits `123 456`, 8 digits `1234 5678`).
    static func formatted(code: String) -> String {
        coreTotpFormatted(code: code)
    }

    static func secondsRemaining(for account: Account, date: Date = .now) -> Int {
        Int(coreTotpSecondsRemaining(period: UInt32(clamping: account.period), at: date))
    }

    static func progress(for account: Account, date: Date = .now) -> Double {
        coreTotpProgress(period: UInt32(clamping: account.period), at: date)
    }

    static func isValidSecret(_ secret: String) -> Bool {
        coreIsValidSecret(secret: secret)
    }
}

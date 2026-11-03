import Foundation

/// Thin wrapper shared by Mac and iOS; the account field canonicalization rules live in the Rust core
/// (`Core/crates/kakey-core/src/canonical.rs`). Placeholder text (unknown service, no account) is passed to the core in the
/// current UI language; edited names go through core canonicalization via `VaultDocument.update`.
enum OTPAuthCanonicalizer {
    static func cleanText(_ value: String) -> String {
        coreCleanText(value: value)
    }

    static func standardizedSecret(_ value: String) -> String? {
        coreStandardizedSecret(value: value)
    }

    static func otpauthURLString(for account: Account) -> String {
        // Fails only for an invalid id, and in-app account ids are always UUIDs.
        (try? coreOtpauthUrl(account: account.core, placeholders: .current)) ?? ""
    }
}

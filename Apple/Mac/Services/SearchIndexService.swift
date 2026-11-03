import Foundation

/// Local, non-secret index that lets external automation (such as the Alfred workflow) filter accounts by name. It holds only
/// id / issuer / username, never secrets or codes, and lives only in `VaultStore` memory, never on disk. Hard Lock clears
/// `VaultStore.accounts` but not this index, so filtering still works while locked; `resetApplication()` clears it too.
/// Read through the `find accounts` AppleScript command in `Kakey.sdef`, which goes through the same macOS Automation TCC gate as
/// `copy code`: only apps the user has explicitly allowed to control Kakey can read it.
enum SearchIndexService {
    struct Entry: Codable {
        let id: UUID
        let issuer: String
        let username: String
    }

    static func entries(from accounts: [Account]) -> [Entry] {
        accounts.map { Entry(id: $0.id, issuer: $0.issuer, username: $0.username) }
    }

    /// Only for telling apart several accounts of the same service in the UI; never used for search matching. Emails keep the
    /// first 1-2 characters of the local part plus the full domain; all-digit values of 7+ digits keep the first 3 and last 2;
    /// anything else keeps the first 1-2 characters (rules live in the core `search.rs`).
    static func maskUsername(_ username: String) -> String {
        coreMaskUsername(username: username)
    }
}

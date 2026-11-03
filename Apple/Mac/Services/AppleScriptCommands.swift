import AppKit
import Foundation

/// Implements the `copy code` command declared in Kakey.sdef. The ground rule: whether or not the app is currently unlocked, every
/// call must make the user re-authenticate with Touch ID / the login password before a code is copied, so local malware cannot
/// silently read codes through an already authorized automation channel while the app happens to be unlocked. Accounts can only be
/// discovered through the non-secret list returned by `find accounts`; this command offers no enumeration or search and only looks
/// up an id the caller already knows.
///
/// `@objc(ClassName)` pins the Objective-C runtime name, which must match the `<cocoa class="...">` value in Kakey.sdef exactly;
/// otherwise Apple Event dispatch cannot find the implementing class.
///
/// `NSScriptCommand` executes synchronously by default, but re-authentication is asynchronous (LocalAuthentication, possibly the
/// password unlock UI), so the command is suspended with `suspendExecution()` / `resumeExecution(withResult:)` while the async work
/// completes; this is the asynchronous command pattern Cocoa Scripting officially supports.
///
/// The return value is the code text itself (an empty string on failure, cancellation or not found). See docs/SECURITY.md: the code
/// is written to the system pasteboard at the same moment it is returned, so the caller could read the same value from the pasteboard
/// immediately anyway. Also returning it through the same TCC-gated, re-authenticated channel adds no new exposure; callers use it
/// to show the code directly in a notification.
@objc(CopyCodeCommand)
@MainActor
final class CopyCodeCommand: NSScriptCommand, @unchecked Sendable {
    override func performDefaultImplementation() -> Any? {
        guard let idString = directParameter as? String,
            let accountID = UUID(uuidString: idString)
        else {
            return ""
        }

        suspendExecution()
        Task { @MainActor in
            let result = await Self.authorizeAndCopy(accountID: accountID)
            self.resumeExecution(withResult: result)
        }
        return nil
    }

    private static func authorizeAndCopy(accountID: UUID) async -> String {
        // When the "Enable third-party plugin interface" master switch (Settings > Advanced) is off, the whole automation channel,
        // including this command and not just find accounts, refuses.
        guard let store = VaultStore.shared, store.alfredIntegrationEnabled else { return "" }

        // If this process was cold-launched by this very command and the vault is locked: minimize the main window to the Dock
        // first, then prompt Touch ID, so the user never sees the full main window pop up. An instance that was already running
        // leaves its windows alone, since the user may be doing something else in the main window.
        if store.isLocked, AppLaunchInfo.wasJustLaunched {
            MainWindowController.shared.miniaturizeIfVisible()
        }

        switch await store.requestSecureCopy(accountID: accountID, reason: L10n.tr("copy this account’s code")) {
        case .copied(_, let code):
            return code
        case .needsPasswordUnlock:
            // The user chose the password in the Touch ID prompt: the request is already queued in requestSecureCopy. This only brings
            // the main window forward to show the password lock screen; it does not wait for the password to be entered.
            if let url = URL(string: "kakey://reveal?id=\(accountID.uuidString)") {
                NSWorkspace.shared.open(url)
            }
            return ""
        case .failed:
            return ""
        }
    }
}

/// Implements the `find accounts` command declared in Kakey.sdef, giving local automation (such as the Alfred workflow) offline
/// fuzzy search. The data lives only in `VaultStore` process memory (`VaultStore.searchIndexEntries`, not cleared by Hard Lock) and
/// can only be read through this `Kakey.sdef` Apple Event command, which goes through the same macOS Automation TCC gate as
/// `copy code`: only apps the user has explicitly allowed to control Kakey can call it. No Touch ID / password re-authentication is
/// required, because it returns only service names and masked account names (`SearchIndexService.maskUsername`), never secrets or
/// codes.
///
/// The "Enable third-party plugin interface" master switch (Settings > Advanced) is off by default. While off, `VaultStore` never
/// builds the in-memory cache (see `refreshSearchIndex`) and this returns `enabled:false`, so users who never turned the feature on
/// have none of this attack surface.
///
/// Matching runs here against the full (unmasked) issuer + username, using the same rules as the main window search (core
/// `search.rs`: case-, diacritic- and width-insensitive, substring or in-order fuzzy matching), and only matched results are masked
/// and returned. Callers (such as the Alfred workflow) neither need nor receive the unmasked username, and masking the display does
/// not hurt search quality.
///
/// Known trade-offs (accepted by the user, and only applicable while the switch is on):
/// 1. macOS Automation authorization stops at "can this app control Kakey", not "which script inside this app". Once the user has
///    approved Alfred as a whole, other workflows in Alfred (not the one Kakey exports) could in theory call this command too. Kakey
///    adds no authentication or session mechanism of its own and relies entirely on the TCC gate; see docs/SECURITY.md.
/// 2. Allowing search by username means "does it match" itself leaks a little of the unmasked content: repeated queries with
///    different fragments could in theory recover a few more middle characters than the masked display (which already shows the
///    domain and the first 1-2 characters). Since the masked display already reveals most of it, this marginal increase is
///    considered acceptable.
@objc(FindAccountsCommand)
@MainActor
final class FindAccountsCommand: NSScriptCommand, @unchecked Sendable {
    private struct MaskedEntry: Encodable {
        let id: String
        let issuer: String
        let username: String
    }

    private struct Response: Encodable {
        let enabled: Bool
        let ready: Bool
        let accounts: [MaskedEntry]
    }

    private static let disabledJSON = "{\"enabled\":false,\"ready\":false,\"accounts\":[]}"
    private static let notReadyJSON = "{\"enabled\":true,\"ready\":false,\"accounts\":[]}"

    /// `performDefaultImplementation` is inherited from the nonisolated `NSScriptCommand`, so it is not on the main actor even though
    /// the class is `@MainActor`. Cocoa Scripting dispatches Apple Event commands on the main thread, so this asserts main-actor
    /// isolation and reads `VaultStore` synchronously (unlike `copy code`, which waits for authentication, this command need not
    /// suspend).
    override func performDefaultImplementation() -> Any? {
        let query = (directParameter as? String) ?? ""
        return MainActor.assumeIsolated { Self.respond(query: query) }
    }

    private static func respond(query: String) -> String {
        guard let store = VaultStore.shared else { return Self.disabledJSON }

        switch store.searchIndexAvailability() {
        case .disabled:
            return Self.disabledJSON
        case .notReady:
            return Self.notReadyJSON
        case .ready(let entries):
            let masked = Self.filter(entries, query: query).map {
                MaskedEntry(id: $0.id.uuidString, issuer: $0.issuer, username: SearchIndexService.maskUsername($0.username))
            }
            guard let data = try? JSONEncoder().encode(Response(enabled: true, ready: true, accounts: masked)),
                let json = String(data: data, encoding: .utf8)
            else {
                return Self.notReadyJSON
            }
            return json
        }
    }

    /// Same rules as the main window search (core `coreMatchesSearch`); an empty query returns everything.
    private static func filter(_ entries: [SearchIndexService.Entry], query: String) -> [SearchIndexService.Entry] {
        entries.filter { coreMatchesSearch(issuer: $0.issuer, username: $0.username, query: query) }
    }
}

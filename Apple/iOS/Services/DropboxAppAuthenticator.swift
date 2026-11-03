import UIKit

/// Authorization through the official Dropbox iOS app. The protocol matches `DropboxMobileOAuthManager` in the official SwiftyDropbox
/// SDK (`dbapi-2://1/connect?k=…&state=oauth2code:…&extra_query_params=…`, with the app calling back to
/// `db-<app key>://1/connect?…`), but the SDK is not used: it exchanges the token and keeps the PKCE verifier itself, which breaks
/// the rule that only the core builds requests. The launch URL, callback validation, and token exchange all live in the core.
///
/// The callback arrives via URL scheme (`db-<app key>` is registered in `Info.plist`, generated from `cloud-keys.toml` at build
/// time) and `onOpenURL` passes it to `DropboxAppCallbacks`; only callbacks the core confirms belong to this sign-in are handed
/// back. Another app registering the same scheme still cannot get a token, because it has no verifier.
struct OfficialDropboxAppAuthenticator: DropboxAppAuthenticating {
    /// Schemes of the App Store and enterprise (EMM) apps; both must be listed in `LSApplicationQueriesSchemes` in `Info.plist`
    /// for `canOpenURL` to work.
    static let schemes = ["dbapi-2", "dbapi-8-emm"]

    @MainActor
    func authenticate(launchURL: (String) -> String?, accepts: @escaping @Sendable (URL) -> Bool) async throws -> URL? {
        let candidates = Self.schemes.compactMap { launchURL($0).flatMap(URL.init(string:)) }
        guard let url = candidates.first(where: UIApplication.shared.canOpenURL) else { return nil }
        return try await DropboxAppCallbacks.await(accepts: accepts) {
            UIApplication.shared.open(url) { opened in
                if !opened { DropboxAppCallbacks.cancel() }
            }
        }
    }
}

/// In-process callback relay: waits for at most one app authorization at a time and drops URLs that do not belong to it. If the
/// waiting task is cancelled (the user tapped Cancel or left the connection screen), the registration is withdrawn.
@MainActor
enum DropboxAppCallbacks {
    private static var pending: CheckedContinuation<URL, Error>?
    private static var accepts: (@Sendable (URL) -> Bool)?

    static func await(accepts: @escaping @Sendable (URL) -> Bool, open: () -> Void) async throws -> URL {
        cancel()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                self.accepts = accepts
                open()
            }
        } onCancel: {
            Task { @MainActor in cancel() }
        }
    }

    /// Hands back a URL received by `onOpenURL` and returns true if it belongs to the pending authorization.
    @discardableResult
    static func deliver(_ url: URL) -> Bool {
        guard let continuation = pending, accepts?(url) == true else { return false }
        pending = nil
        accepts = nil
        continuation.resume(returning: url)
        return true
    }

    /// The app cannot be opened or the task was cancelled: stops waiting (throws `CancellationError`, and the connection screen
    /// returns to the form).
    static func cancel() {
        let continuation = pending
        pending = nil
        accepts = nil
        continuation?.resume(throwing: CancellationError())
    }
}

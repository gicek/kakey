import AuthenticationServices
import Foundation

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Opens the provider's sign-in page and waits for the callback URL (OAuth, docs/TECHNICAL.md). Tests use a fake
/// that shows no UI.
protocol WebAuthenticating: Sendable {
    /// Throws `CancellationError` when the user cancels.
    @MainActor func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

/// Authorizes through the official Dropbox app (iOS): if installed, it is launched, and the redirect URL goes back to the
/// core for validation and token exchange. Returns nil when the app is missing or cannot be opened, so the caller falls back
/// to the system authentication session. A user cancellation also returns a redirect URL, which the core reports as denied.
protocol DropboxAppAuthenticating: Sendable {
    /// `launchURL` returns the launch URL for a scheme (`dbapi-2` / `dbapi-8-emm`); `accepts` decides whether a redirect URL
    /// belongs to this sign-in (the rules live in the core).
    @MainActor func authenticate(launchURL: (String) -> String?, accepts: @escaping @Sendable (URL) -> Bool) async throws -> URL?
}

/// System authentication session (`ASWebAuthenticationSession`). It is deliberately not ephemeral: reusing the sign-in state
/// of the default browser (if supported, otherwise Safari) spares the user from re-entering a password and two-factor code.
/// The authorization code does not travel in cookies; credentials come only from this session's PKCE exchange. The callback
/// is delivered only for this session's scheme, so other apps cannot intercept it; `state` and PKCE are validated in the core.
@MainActor
final class SystemWebAuthenticator: NSObject, WebAuthenticating, ASWebAuthenticationPresentationContextProviding {
    /// The session must be retained until it completes; otherwise it is released immediately and the callback never arrives.
    private var session: ASWebAuthenticationSession?

    nonisolated override init() {
        super.init()
    }

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        session?.cancel()
        defer { session = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let completion: ASWebAuthenticationSession.CompletionHandler = { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: error ?? CancellationError())
                }
            }
            let session: ASWebAuthenticationSession
            if #available(macOS 14.4, iOS 17.4, *) {
                session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme), completionHandler: completion)
            } else {
                session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme, completionHandler: completion)
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: CloudSyncError.service(.Internal))
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(macOS)
                NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor()
            #else
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows)
                    .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
            #endif
        }
    }
}

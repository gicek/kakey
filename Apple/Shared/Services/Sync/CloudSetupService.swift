import Foundation

/// One-off operations while connecting cloud storage, before the connection is saved: creating and verifying a WebDAV
/// connection, Nextcloud and OAuth sign-in, browsing and creating remote folders, and revoking on disconnect. The protocols
/// live in the core. The connection blob passes through here only in memory (`InMemoryCloudConnectionStore`) and reaches
/// the persistent `CloudConnectionStoring` only after the caller confirms. If a token is refreshed while browsing, the new
/// connection is written back to the same in-memory store, so the final result is always the latest.
struct CloudSetupService: Sendable {
    let executor: any HTTPExecuting
    let userAgent: String
    var authenticator: any WebAuthenticating = SystemWebAuthenticator()
    /// Authorizes Dropbox through its official app first (set on iOS; nil on Mac, where the app offers no authorization
    /// protocol).
    var dropboxApp: (any DropboxAppAuthenticating)?

    /// `Kakey/<version> (<platform>)`, which is also the name shown under Nextcloud's "Devices & sessions".
    static func userAgent(platform: String) -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "Kakey/\(version) (\(platform))"
    }

    /// Creates a WebDAV connection and lists the root once to confirm the URL and account work. `allowInsecureHTTP` is true
    /// only after the user confirmed plaintext HTTP; `trustedCertificate` is passed only after the user verified the server
    /// certificate fingerprint (docs/SECURITY.md). Throws `CloudCertificateError` if the system does not trust
    /// the certificate.
    func webDAVConnection(
        url: String, username: String, password: String, allowInsecureHTTP: Bool, trustedCertificate: Data? = nil
    ) async throws -> Data {
        let connection = try Self.wrapping {
            try coreCloudWebdavConnection(
                url: url, username: username, password: password, allowInsecureHttp: allowInsecureHTTP,
                trustedCertificate: trustedCertificate)
        }
        _ = try await entries(in: "", connections: InMemoryCloudConnectionStore(connection))
        return connection
    }

    /// OAuth sign-in (Dropbox, OneDrive, Google Drive): the system authentication session opens the sign-in page, and the callback goes
    /// to the core to validate `state` and exchange it for a token. Throws `CancellationError` if the user closes the page.
    /// Calls `onAuthorized` when the page returns and the token exchange starts (the UI switches to "connecting account").
    @MainActor
    func signIn(to provider: CloudProvider, access: CoreCloudAccess, onAuthorized: () -> Void = {}) async throws -> Data {
        let session = try Self.wrapping { try coreCloudBeginOauth(provider: provider.core, access: access) }
        // Try the official Dropbox app first: if installed, authorize there; the core validates the redirect's `state` and
        // exchanges it for a token.
        if provider == .dropbox, let dropboxApp,
            let callback = try await dropboxApp.authenticate(
                launchURL: { session.dropboxAppUrl(scheme: $0) },
                accepts: { session.acceptsDropboxAppCallback(callbackUrl: $0.absoluteString) })
        {
            onAuthorized()
            let operation = try Self.wrapping {
                try session.completeDropboxAppCallback(callbackUrl: callback.absoluteString, userAgent: userAgent)
            }
            guard case .connected(let connection) = try await runner(nil).drive(operation) else {
                throw CloudSyncError.service(.Internal)
            }
            return connection
        }
        guard let url = URL(string: session.url()) else { throw CloudSyncError.service(.Internal) }
        let callback = try await authenticator.authenticate(url: url, callbackScheme: session.callbackScheme())
        onAuthorized()
        let operation = try Self.wrapping { try session.complete(callbackUrl: callback.absoluteString, userAgent: userAgent) }
        guard case .connected(let connection) = try await runner(nil).drive(operation) else {
            throw CloudSyncError.service(.Internal)
        }
        return connection
    }

    /// `trustedCertificate` works as in `webDAVConnection`: the subsequent polls and the resulting connection all pin it.
    func beginNextcloudLogin(
        server: String, allowInsecureHTTP: Bool, trustedCertificate: Data? = nil
    ) async throws -> (loginURL: URL, login: CoreNextcloudLogin) {
        let operation = try Self.wrapping {
            try coreNextcloudBeginLogin(
                server: server, allowInsecureHttp: allowInsecureHTTP, trustedCertificate: trustedCertificate, userAgent: userAgent)
        }
        guard case .loginStarted(let loginURL, let login) = try await runner(nil).drive(operation), let url = URL(string: loginURL) else {
            throw CloudSyncError.service(.InvalidResponse)
        }
        return (url, login)
    }

    /// Returns nil while the user has not finished authorizing in the browser.
    func pollNextcloudLogin(_ login: CoreNextcloudLogin) async throws -> Data? {
        guard case .loginPolled(let connection) = try await runner(nil).drive(coreNextcloudPollLogin(login: login, userAgent: userAgent))
        else {
            throw CloudSyncError.service(.Internal)
        }
        return connection
    }

    /// The folder's direct children (files and folders), sorted by name.
    func entries(in path: String, connections: any CloudConnectionStoring) async throws -> [CoreCloudEntry] {
        let outcome = try await runner(connections).run { connection, userAgent in
            try coreCloudList(connection: connection, dir: path, userAgent: userAgent)
        }
        guard case .entries(let entries) = outcome else { throw CloudSyncError.service(.Internal) }
        return entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func createFolder(_ path: String, connections: any CloudConnectionStoring) async throws {
        _ = try await runner(connections).run { connection, userAgent in
            try coreCloudCreateFolder(connection: connection, folder: path, userAgent: userAgent)
        }
    }

    /// Best-effort revocation of the server-side authorization on disconnect; failure does not stop local credential removal.
    func revoke(_ connection: Data) async {
        _ = try? await runner(InMemoryCloudConnectionStore(connection)).run { connection, userAgent in
            try coreCloudRevoke(connection: connection, userAgent: userAgent)
        }
    }

    /// Location info for display (never includes the password).
    static func location(for connection: Data, folder: String) throws -> CloudLocation {
        let info = try wrapping { try coreCloudConnectionInfo(connectionBytes: connection) }
        return CloudLocation(
            provider: CloudProvider(info.provider), host: info.host, username: info.username, isSecure: info.isSecure, folder: folder,
            isAppFolder: info.access == .appFolder, isCertificatePinned: info.hasPinnedCertificate)
    }

    private func runner(_ connections: (any CloudConnectionStoring)?) -> CloudOperationRunner {
        CloudOperationRunner(connections: connections ?? InMemoryCloudConnectionStore(), executor: executor, userAgent: userAgent)
    }

    private static func wrapping<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as CoreCloudError {
            throw CloudSyncError.service(error)
        }
    }
}

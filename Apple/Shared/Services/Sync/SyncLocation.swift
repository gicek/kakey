import Foundation

/// The user's chosen backup location (see docs/TECHNICAL.md). Not sensitive, so it lives in settings; cloud storage
/// credentials are kept separately in `CloudConnectionStoring`. Only one location is active at a time
/// (docs/TECHNICAL.md).
enum SyncLocation: Codable, Equatable, Sendable {
    /// iCloud (CloudKit private database), with the iCloud account at link time (an opaque per-container user ID). If the
    /// device switches accounts, sync stops rather than writing data into the other account.
    case iCloud(account: String)
    /// A user-chosen folder: its bookmark (security-scoped on iOS) and display name.
    case folder(bookmark: Data, name: String)
    /// Cloud storage: the connection blob is in `CloudConnectionStoring`; this holds only display info and the remote folder.
    case cloud(CloudLocation)

    var title: String {
        switch self {
        case .iCloud: "iCloud"
        case .folder(_, let name): name
        case .cloud(let location): location.provider.displayName
        }
    }

    /// Second line: for iCloud, where the data is kept; for cloud storage, "account · host › folder" (or "account · Apps ›
    /// Kakey" / "account · My Drive › Kakey" for app-folder access).
    var detail: String? {
        switch self {
        case .iCloud: L10n.tr("Private to your Apple Account")
        case .folder: nil
        case .cloud(let location):
            if location.isAppFolder {
                location.provider == .googleDrive
                    ? L10n.format("%@ · My Drive › Kakey", location.username)
                    : L10n.format("%@ · Apps › Kakey", location.username)
            } else if location.folder.isEmpty {
                "\(location.username) · \(location.host)"
            } else {
                "\(location.username) · \(location.host) › \(location.folder)"
            }
        }
    }

    /// The cloud storage account (second line of the Mac status card); iCloud and folders have no account to show.
    var account: String? {
        guard case .cloud(let location) = self, !location.username.isEmpty else { return nil }
        return location.username
    }

    /// The full location (Mac status card tooltip): "OneDrive › Apps › Kakey", "host › folder", or the folder name; iCloud
    /// has no path.
    var fullPath: String {
        switch self {
        case .iCloud:
            return "iCloud"
        case .folder(_, let name):
            return name
        case .cloud(let location):
            if location.isAppFolder {
                return "\(location.provider.displayName) › \(location.provider.appFolderPath)"
            }
            return location.folder.isEmpty ? location.host : "\(location.host) › \(location.folder)"
        }
    }

    var systemImage: String {
        switch self {
        case .iCloud: "icloud"
        case .folder: "folder"
        case .cloud(let location): location.provider.systemImage
        }
    }

    /// Message when this location has no Kakey backup. For cloud storage it names only the service, not the folder; when the
    /// folder can be changed, the UI also offers "Choose Folder".
    var missingBackupMessage: String {
        switch self {
        case .iCloud: L10n.format("No secure Kakey backup was found in %@.", "iCloud")
        case .folder(_, let name): L10n.format("No secure Kakey backup was found in the “%@” folder.", name)
        case .cloud(let location): L10n.format("No secure Kakey backup was found in %@.", location.provider.displayName)
        }
    }

    /// A plaintext HTTP connection; the UI keeps showing "unencrypted connection" (docs/SECURITY.md).
    var isInsecure: Bool {
        if case .cloud(let location) = self { return !location.isSecure }
        return false
    }

    /// A user-confirmed certificate is pinned; the UI keeps showing "certificate not verified" (docs/SECURITY.md).
    var hasUnverifiedCertificate: Bool {
        if case .cloud(let location) = self { return location.isCertificatePinned }
        return false
    }

    var isCloud: Bool {
        if case .cloud = self { return true }
        return false
    }

    var isICloud: Bool {
        if case .iCloud = self { return true }
        return false
    }
}

struct CloudLocation: Codable, Equatable, Sendable {
    var provider: CloudProvider
    var host: String
    var username: String
    var isSecure: Bool
    /// Remote folder relative to the storage root, separated by `/`. Empty means the root (with app-folder access, that is
    /// "Apps › Kakey" or "My Drive › Kakey" itself).
    var folder: String
    /// Whether an OAuth provider is limited to the app folder (docs/TECHNICAL.md); false for WebDAV / Nextcloud.
    /// Defaults to false: it only matters for OAuth, and a missing key must not make a saved WebDAV / Nextcloud location
    /// unreadable.
    var isAppFolder: Bool = false
    /// Whether a server certificate the system does not trust was confirmed by the user and pinned
    /// (docs/SECURITY.md). Defaults to false, for the same reason as `isAppFolder`.
    var isCertificatePinned: Bool = false
}

extension CloudLocation {
    private enum CodingKeys: String, CodingKey {
        case provider, host, username, isSecure, folder, isAppFolder, isCertificatePinned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(CloudProvider.self, forKey: .provider)
        host = try container.decode(String.self, forKey: .host)
        username = try container.decode(String.self, forKey: .username)
        isSecure = try container.decode(Bool.self, forKey: .isSecure)
        folder = try container.decode(String.self, forKey: .folder)
        isAppFolder = try container.decodeIfPresent(Bool.self, forKey: .isAppFolder) ?? false
        isCertificatePinned = try container.decodeIfPresent(Bool.self, forKey: .isCertificatePinned) ?? false
    }
}

enum CloudProvider: String, Codable, CaseIterable, Sendable {
    case dropbox
    case oneDrive
    case googleDrive
    case nextcloud
    case webDAV

    var displayName: String {
        switch self {
        case .dropbox: "Dropbox"
        case .oneDrive: "OneDrive"
        case .googleDrive: "Google Drive"
        case .nextcloud: "Nextcloud"
        case .webDAV: "WebDAV"
        }
    }

    var systemImage: String {
        switch self {
        case .dropbox: "shippingbox"
        case .oneDrive: "cloud.circle"
        case .googleDrive: "triangle"
        case .nextcloud: "cloud"
        case .webDAV: "server.rack"
        }
    }

    /// Subtitle in the location list.
    var pickerSubtitle: String {
        switch self {
        case .dropbox: L10n.tr("Sign in with your Dropbox account")
        case .oneDrive: L10n.tr("Sign in with your Microsoft account")
        case .googleDrive: L10n.tr("Sign in with your Google account")
        case .nextcloud: L10n.tr("Sign in with your Nextcloud account")
        case .webDAV: L10n.tr("Your own server or NAS")
        }
    }

    /// Signs in with OAuth (system authentication session) instead of entering a server address.
    var usesOAuth: Bool {
        self == .dropbox || self == .oneDrive || self == .googleDrive
    }

    /// Where the app folder lives in this provider's UI: Dropbox and OneDrive give each app one under "Apps"; on Google Drive
    /// it is a Kakey folder in My Drive (docs/TECHNICAL.md).
    var appFolderPath: String {
        self == .googleDrive ? L10n.tr("My Drive › Kakey") : L10n.tr("Apps › Kakey")
    }

    var core: CoreCloudProvider {
        switch self {
        case .dropbox: .dropbox
        case .oneDrive: .oneDrive
        case .googleDrive: .googleDrive
        case .nextcloud: .nextcloud
        case .webDAV: .webDav
        }
    }

    init(_ provider: CoreCloudProvider) {
        switch provider {
        case .dropbox: self = .dropbox
        case .oneDrive: self = .oneDrive
        case .googleDrive: self = .googleDrive
        case .nextcloud: self = .nextcloud
        case .webDav: self = .webDAV
        }
    }

    /// Backends available in this build: OAuth providers appear only if a developer key was configured at build time
    /// (`cloud-keys.toml`); WebDAV and Nextcloud are always available.
    static var available: [CloudProvider] {
        let configured = Set(coreCloudOauthProviders().map { CloudProvider($0.provider) })
        return allCases.filter { !$0.usesOAuth || configured.contains($0) }
    }

    /// Whether full-drive access can be chosen (the matching key is configured).
    var fullAccessAvailable: Bool {
        coreCloudOauthProviders().first { CloudProvider($0.provider) == self }?.fullAccessAvailable ?? false
    }

    /// Whether the user can choose the backup folder: always for WebDAV / Nextcloud; for OAuth providers only if the build
    /// has the "any folder" key.
    var canChooseFolder: Bool {
        !usesOAuth || fullAccessAvailable
    }
}

extension SyncLocation {
    /// The form stored in settings; anything unreadable is treated as not configured (no legacy formats).
    static func decode(_ data: Data?) -> SyncLocation? {
        data.flatMap { try? JSONDecoder.kakey.decode(SyncLocation.self, from: $0) }
    }

    func encoded() -> Data? {
        try? JSONEncoder.kakey.encode(self)
    }
}

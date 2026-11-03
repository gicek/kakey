import Foundation

/// Non-sensitive iOS / iPadOS settings, stored as a single JSON value in the injected settings store (in-memory in tests).
/// Accounts, secrets, and the master password never live here.
struct MobilePreferences: Codable, Equatable {
    var appearance: AppearanceMode = .system
    var language: LanguageMode = .system
    var autoLock: AutoLockMode = .fiveMinutes
    var biometricsEnabled = false
    /// Backup location (sync folder bookmark, or cloud storage display info and directory); nil means sync is off. Cloud storage
    /// credentials are stored separately in the Keychain.
    var syncLocation: SyncLocation?
    var lastSyncLocalUpdatedAt: Date?
    /// Persisted remote version (`SyncMarks.encodedRemoteVersion`).
    var lastSyncRemoteVersion: String?
    var consecutiveUnlockFailures = 0
    var lockoutUntil: Date?

    private static let storageKey = "mobilePreferences.v1"

    init() {}

    private enum CodingKeys: String, CodingKey {
        case appearance, language, autoLock, biometricsEnabled, syncLocation
        case lastSyncLocalUpdatedAt, lastSyncRemoteVersion, consecutiveUnlockFailures, lockoutUntil
    }

    /// Decodes each field with `decodeIfPresent` and a default, so a new non-optional field or one unparseable value does not reset
    /// all settings.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appearance = (try? container.decodeIfPresent(AppearanceMode.self, forKey: .appearance)) ?? .system
        language = (try? container.decodeIfPresent(LanguageMode.self, forKey: .language)) ?? .system
        autoLock = (try? container.decodeIfPresent(AutoLockMode.self, forKey: .autoLock)) ?? .fiveMinutes
        biometricsEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .biometricsEnabled)) ?? false
        syncLocation = try? container.decodeIfPresent(SyncLocation.self, forKey: .syncLocation)
        lastSyncLocalUpdatedAt = try? container.decodeIfPresent(Date.self, forKey: .lastSyncLocalUpdatedAt)
        lastSyncRemoteVersion = try? container.decodeIfPresent(String.self, forKey: .lastSyncRemoteVersion)
        consecutiveUnlockFailures = (try? container.decodeIfPresent(Int.self, forKey: .consecutiveUnlockFailures)) ?? 0
        lockoutUntil = try? container.decodeIfPresent(Date.self, forKey: .lockoutUntil)
    }

    static func load(from settings: any SettingsStore) -> MobilePreferences {
        guard let data = settings.data(forKey: storageKey),
            let preferences = try? JSONDecoder.kakey.decode(MobilePreferences.self, from: data)
        else {
            return MobilePreferences()
        }
        return preferences
    }

    func save(to settings: any SettingsStore) {
        if let data = try? JSONEncoder.kakey.encode(self) {
            settings.set(data, forKey: Self.storageKey)
        }
    }

    static func remove(from settings: any SettingsStore) {
        settings.removeObject(forKey: storageKey)
    }
}

extension AppearanceMode: Codable {}
extension AutoLockMode: Codable {}
extension LanguageMode: Codable {}

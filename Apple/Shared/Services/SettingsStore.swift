import Foundation

/// Key-value storage for non-sensitive settings. The app uses `UserDefaults`; tests inject `InMemorySettingsStore` so they
/// never touch real preferences.
protocol SettingsStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension SettingsStore {
    func bool(forKey key: String) -> Bool {
        object(forKey: key) as? Bool ?? false
    }

    func string(forKey key: String) -> String? {
        object(forKey: key) as? String
    }

    func integer(forKey key: String) -> Int {
        object(forKey: key) as? Int ?? 0
    }

    func date(forKey key: String) -> Date? {
        object(forKey: key) as? Date
    }

    func data(forKey key: String) -> Data? {
        object(forKey: key) as? Data
    }

    func removeObjects(forKeys keys: [String]) {
        keys.forEach(removeObject(forKey:))
    }
}

extension UserDefaults: SettingsStore {}

/// In-memory implementation for tests and previews; contents are lost when the process exits.
final class InMemorySettingsStore: SettingsStore, @unchecked Sendable {
    private let values = Locked<[String: Any]>([:])

    init() {}

    func object(forKey key: String) -> Any? {
        values.withLock { $0[key] }
    }

    func set(_ value: Any?, forKey key: String) {
        values.withLock { $0[key] = value }
    }

    func removeObject(forKey key: String) {
        _ = values.withLock { $0.removeValue(forKey: key) }
    }

    var isEmpty: Bool {
        values.withLock { $0.isEmpty }
    }
}

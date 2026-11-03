import Foundation

/// Local persistence for backup history. The plaintext holds only time, device name, size and status key; never account data.
enum BackupHistoryStore {
    static let maxEntries = 50

    private static var url: URL {
        VaultPersistenceService.vaultDirectoryURL.appendingPathComponent("backup-history.json")
    }

    static func load() -> [BackupHistoryItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder.kakey.decode([BackupHistoryItem].self, from: data)) ?? []
    }

    static func save(_ items: [BackupHistoryItem]) {
        guard let data = try? JSONEncoder.kakey.encode(Array(items.prefix(maxEntries))) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Inserts a new record at the front, trims to the limit and saves. Shared by Mac and iOS.
    static func append(_ item: BackupHistoryItem, to history: inout [BackupHistoryItem]) {
        history.insert(item, at: 0)
        if history.count > maxEntries {
            history.removeLast(history.count - maxEntries)
        }
        save(history)
    }

    /// The size shown for a record, formatted the same on Mac and iOS (KB / MB); failed records have no data and show "—".
    static func sizeLabel(bytes: Int?) -> String {
        guard let bytes else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

extension BackupHistoryItem {
    static func record(
        date: Date, device: String, bytes: Int?, sourceKey: String, isFailure: Bool = false,
        direction: SyncDirection? = nil, location: String? = nil
    ) -> BackupHistoryItem {
        BackupHistoryItem(
            date: date,
            device: device,
            size: BackupHistoryStore.sizeLabel(bytes: bytes),
            sourceKey: sourceKey,
            isFailure: isFailure,
            direction: direction,
            location: location
        )
    }
}

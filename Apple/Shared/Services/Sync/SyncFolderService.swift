import Foundation

/// Bookmarks and resolution for the user-chosen sync folder. On iOS these are security-scoped bookmarks; the Mac app is not
/// sandboxed, so there the bookmark only tracks renames and moves. File IO, decisions and conflict handling live in the
/// shared `FolderSyncBackend`.
enum SyncFolderService {
    /// When the user picks a parent folder, the backup goes into this subfolder.
    static let defaultFolderName = "Kakey"

    static func bookmark(for url: URL) throws -> Data {
        try withAccess(to: url) { try url.bookmarkData() }
    }

    static func resolve(bookmark: Data) throws -> URL {
        var isStale = false
        return try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)
    }

    /// Uses the picked folder directly if it is the Kakey folder or already holds a vault; otherwise (e.g. the iCloud Drive
    /// root) uses `Kakey/` inside it, so every device finds the file in the same conventional place.
    static func vaultFolder(for picked: URL) -> URL {
        (try? withAccess(to: picked) {
            let fileManager = FileManager.default
            if picked.lastPathComponent == defaultFolderName
                || fileManager.fileExists(atPath: picked.appendingPathComponent(FolderSyncBackend.vaultFileName).path)
            {
                return picked
            }
            return picked.appendingPathComponent(defaultFolderName, isDirectory: true)
        }) ?? picked
    }

    private static func withAccess<T>(to url: URL, _ body: () throws -> T) throws -> T {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }
}

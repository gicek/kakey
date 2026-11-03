import Foundation

/// Size limit for external files (imported backups, vaults in a sync folder) before they are read into memory; larger files
/// are treated as invalid or corrupt instead of being loaded whole. Matches Android `FileLimits.MAX_EXTERNAL_FILE_BYTES`;
/// see docs/SECURITY.md.
enum ExternalFileLimits {
    static let maxBytes = 16 * 1024 * 1024

    struct TooLarge: Error {}

    /// Checks the size from file attributes before reading. Throws if the file is missing, unreadable or over the limit;
    /// callers map that to their own "invalid file" message.
    static func read(contentsOf url: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= Int64(maxBytes) else { throw TooLarge() }
        let data = try Data(contentsOf: url)
        guard data.count <= maxBytes else { throw TooLarge() }
        return data
    }
}

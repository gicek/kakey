import Foundation

/// Shared coding configuration for every JSON file written to disk (vault, Touch ID–protected key, iCloud backup metadata):
/// ISO-8601 dates, and `prettyPrinted` + `sortedKeys` so file contents are stable and diffable.
extension JSONEncoder {
    static var kakey: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var kakey: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

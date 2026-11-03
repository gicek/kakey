import Foundation

/// The single implementation of combining multi-QR Google Authenticator migration codes:
/// - Non-migration codes and single-code migrations complete immediately.
/// - Codes of one batch are collected by `batchKey`; a code with a different `batchID` (or batch size) discards what was
///   collected, since the user switched to another export.
/// - Once `batchSize` codes are collected the batch completes, with accounts concatenated in `batchKey` order. Scanning the
///   same code twice does not count twice.
struct MigrationBatchCollector: Sendable {
    enum Outcome: Sendable {
        case complete([ParsedOTPAuth])
        case partial(scanned: Int, total: Int)
    }

    private(set) var batchID: Int?
    private(set) var batchSize: Int?
    private var collected: [String: [ParsedOTPAuth]] = [:]

    init() {}

    /// Progress while collecting a multi-code migration; nil before it starts or for single codes.
    var progress: (scanned: Int, total: Int)? {
        guard let batchSize, batchSize > 1 else { return nil }
        return (collected.count, batchSize)
    }

    /// Whether a multi-code migration is in progress and still incomplete.
    var isAwaitingMoreCodes: Bool {
        guard let progress else { return false }
        return progress.scanned < progress.total
    }

    mutating func add(_ result: OTPAuthScanResult) -> Outcome {
        guard result.isGoogleMigration, let size = result.batchSize, size > 1, let key = result.batchKey else {
            return .complete(result.accounts)
        }
        if batchID != result.batchID || batchSize != size {
            batchID = result.batchID
            batchSize = size
            collected = [:]
        }
        collected[key] = result.accounts
        if collected.count >= size {
            return .complete(collected.keys.sorted().flatMap { collected[$0] ?? [] })
        }
        return .partial(scanned: collected.count, total: size)
    }

    mutating func reset() {
        self = MigrationBatchCollector()
    }
}

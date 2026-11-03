import Foundation

/// A lock-protected mutable value for global state shared across tasks, used instead of `nonisolated(unsafe)` statics.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        try lock.withLock { try body(&storage) }
    }
}

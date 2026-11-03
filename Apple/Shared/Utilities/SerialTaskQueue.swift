import Foundation

/// A queue of async operations started on the main actor and run serially in the order they were enqueued.
///
/// Vault saves and syncs go through it. Actors do not guarantee that tasks run in arrival order, so each task explicitly
/// awaits the previous one: a save always lands before the sync that follows it, and two saves never reorder. Changing
/// the master password calls `drain()` first to wait for all queued saves and syncs.
@MainActor
final class SerialTaskQueue {
    private var last: Task<Void, Never>?

    @discardableResult
    func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = last
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        last = task
        return task
    }

    /// Waits for every queued task to finish.
    func drain() async {
        await last?.value
    }
}

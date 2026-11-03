import Foundation

/// Wait state after repeated wrong master passwords, shared by Mac and iOS. The rules live in the core (`password.rs`):
/// from the 5th failure, 30 seconds, doubling, capped at 5 minutes. Only wrong passwords count; a successful unlock or
/// password change resets it. Mac keeps it in settings (can be turned off); iOS keeps it in preferences (always on).
struct UnlockLockoutState: Codable, Equatable, Sendable {
    var consecutiveFailures = 0
    var lockoutUntil: Date?

    static let cleared = UnlockLockoutState()
}

enum UnlockLockout {
    /// Seconds left to wait (rounded up, at least 1), or nil when not in a wait period.
    static func remainingSeconds(_ state: UnlockLockoutState, now: Date) -> Int? {
        guard let until = state.lockoutUntil, until > now else { return nil }
        return max(1, Int(until.timeIntervalSince(now).rounded(.up)))
    }

    static func registeringFailure(_ state: UnlockLockoutState, now: Date) -> UnlockLockoutState {
        var next = state
        next.consecutiveFailures += 1
        if let delay = UnlockThrottle.lockoutDuration(afterConsecutiveFailures: next.consecutiveFailures) {
            next.lockoutUntil = now.addingTimeInterval(delay)
        }
        return next
    }
}

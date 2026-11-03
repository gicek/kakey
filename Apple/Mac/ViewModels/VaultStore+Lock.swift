import AppKit

/// Locking, main window open / closed state, auto-lock and locking on system sleep.
///
/// Auto-lock counts from the last user activity: unlocking counts as activity, and every key press, click or scroll in the app
/// restarts the count; the vault locks after being idle for the chosen duration, regardless of whether a window / panel is open
/// (same on all platforms). Counting from the moment of unlock instead would lock the vault while it is being used.
/// The main window's open state only affects the Dock icon policy; the menu bar panel's open state is not reported.
extension VaultStore {
    // MARK: - Locking

    /// Hard Lock: clears accounts, categories and secrets; closes any open sheets (details and QR code hold copies of the account and
    /// must not stay above the lock screen); drops queued copy / import requests (they must not be fulfilled at an unrelated later
    /// unlock).
    /// Does nothing before onboarding is complete, since there is no vault to lock (otherwise the menu bar panel would show an unlock
    /// form that can never be unlocked).
    /// After any lock (manual, auto, sleep / screen lock) the lock screen does not prompt Touch ID automatically and waits for the
    /// user; only the first lock screen after launch prompts once.
    func lock() {
        guard hasCompletedOnboarding else { return }
        cancelScheduledAutoLock()
        lastActivityAt = nil
        syncDebounceTask?.cancel()
        document = VaultDocument()
        vaultKey = nil
        activeSheet = nil
        pendingCopyAccountIDAfterUnlock = nil
        pendingCaptureAccountsAfterPasswordUnlock = []
        pendingCaptureImportResult = nil
        pendingCopyResultIssuer = nil
        isLocked = true
        autoTouchIDSuppressed = true
    }

    func mainWindowDidOpen() {
        isMainWindowOpen = true
        applyDockIconPolicy()
    }

    func mainWindowDidClose() {
        isMainWindowOpen = false
        applyDockIconPolicy()
    }

    func prepareToOpenMainWindow() {
        isMainWindowOpen = true
        applyDockIconPolicy()
        system.activateApp()
    }

    func suspendMainWindowUnlockReveal(for delay: Duration = .milliseconds(350)) {
        isMainWindowUnlockRevealSuspended = true
        Task {
            try? await Task.sleep(for: delay)
            isMainWindowUnlockRevealSuspended = false
        }
    }

    // MARK: - Auto-lock

    /// The lock time is the last activity time plus the chosen duration. Call this on unlock, on settings changes, and whenever the
    /// schedule needs rechecking: if the time has passed, lock now; otherwise sleep until then and check again, sleeping on if there
    /// was activity in between and locking if not.
    func scheduleAutoLock() {
        cancelScheduledAutoLock()
        guard let remaining = autoLockRemaining() else { return }
        guard remaining > 0 else {
            lock()
            return
        }
        autoLockTask = Task { @MainActor [weak self] in
            var wait = remaining
            while wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let next = self?.autoLockRemaining() else { return }
                wait = next
            }
            self?.lock()
        }
    }

    /// Seconds left until auto-lock; nil when not unlocked.
    private func autoLockRemaining() -> TimeInterval? {
        guard hasCompletedOnboarding, !isLocked, let lastActivityAt else { return nil }
        return lastActivityAt.addingTimeInterval(autoLockMode.delaySeconds).timeIntervalSince(now())
    }

    /// The user did something in the app (key press, click or scroll in any window or the menu bar panel): auto-lock restarts from now.
    /// Only records the time without rebuilding the timer; when the timer wakes it rechecks against the latest time.
    func noteUserActivity() {
        guard !isLocked, lastActivityAt != nil else { return }
        lastActivityAt = now()
    }

    /// Observes key presses, mouse downs and scrolls received by this app (a local monitor that sees only events sent to Kakey and
    /// never reads their content) and treats them as activity that resets the auto-lock count.
    func observeUserActivity() {
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        userActivityMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.noteUserActivity() }
            return event
        }
    }

    func cancelScheduledAutoLock() {
        autoLockTask?.cancel()
        autoLockTask = nil
    }

    /// Locks immediately on system sleep, display sleep, screen lock (including Control-Command-Q), screen saver start or session
    /// switch. Screen lock and the screen saver are only available as distributed notifications (`com.apple.screenIsLocked`,
    /// `com.apple.screensaver.didstart`), which carry no content.
    func observeSystemSleep() {
        let workspace = NSWorkspace.shared.notificationCenter
        let workspaceNames: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ]
        let distributed = DistributedNotificationCenter.default()
        let distributedNames = [
            Notification.Name("com.apple.screenIsLocked"),
            Notification.Name("com.apple.screensaver.didstart"),
        ]
        let observe: (NotificationCenter, Notification.Name) -> NSObjectProtocol = { center, name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.lockForSystemSleep()
                }
            }
        }
        systemSleepObservers =
            workspaceNames.map { observe(workspace, $0) } + distributedNames.map { observe(distributed, $0) }
    }

    private func lockForSystemSleep() {
        guard hasCompletedOnboarding, !isLocked else { return }
        lock()
    }
}

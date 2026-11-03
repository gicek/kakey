import AppKit
import CoreGraphics

/// Finds, waits for and activates the System Settings main window, and computes where the guide card docks.
/// Windows are filtered by PID (the window owner name is localized with the system language and unreliable).
@MainActor
enum SystemSettingsWindow {
    nonisolated static let bundleID = "com.apple.systempreferences"

    /// Waits for the Settings window to appear and settle (two consecutive identical samples), up to 6 seconds, so the card does
    /// not dock to a mid-animation position.
    static func waitForStableFrame(sampleInterval: Duration) async -> CGRect? {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(6)
        let stabilizationBudget: Duration = .milliseconds(1200)

        var firstSeenAt: ContinuousClock.Instant?
        var lastFrame: CGRect?

        while clock.now < deadline, !Task.isCancelled {
            if let frame = frame() {
                if let lastFrame, frame.integral == lastFrame.integral {
                    return frame
                }
                if firstSeenAt == nil {
                    firstSeenAt = clock.now
                } else if let firstSeenAt, clock.now - firstSeenAt >= stabilizationBudget {
                    return frame
                }
                lastFrame = frame
            } else {
                firstSeenAt = nil
                lastFrame = nil
            }
            try? await Task.sleep(for: sampleInterval)
        }
        return lastFrame
    }

    /// The System Settings main window in AppKit screen coordinates; nil when it is not running or has no window.
    static func frame() -> CGRect? {
        guard
            let pid =
                NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .first?.processIdentifier
        else { return nil }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]] else {
            return nil
        }

        // Take the largest matching window so a transient popover does not win over the main window.
        var best: CGRect?
        for info in infoList {
            guard let ownerPID = info[kCGWindowOwnerPID] as? pid_t, ownerPID == pid,
                let layer = info[kCGWindowLayer] as? Int, layer == 0,
                let boundsDict = info[kCGWindowBounds] as? [String: CGFloat],
                let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                frame.width >= 300, frame.height >= 200
            else { continue }
            if best == nil || frame.width * frame.height > best!.width * best!.height {
                best = frame
            }
        }
        guard let cgFrame = best, let primary = NSScreen.screens.first else { return nil }

        // CG global coordinates (origin at the main screen's top left) -> AppKit screen coordinates (origin at its bottom left).
        return CGRect(
            x: cgFrame.minX,
            y: primary.frame.height - cgFrame.minY - cgFrame.height,
            width: cgFrame.width,
            height: cgFrame.height
        )
    }

    static func activate() {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first?
            .activate(from: .current, options: [])
    }

    /// Where the guide card docks: inside the Settings window's bottom-right corner with a fixed inset, pulled back on screen if
    /// it would overflow.
    static func dockedFrame(near settingsFrame: CGRect, size: CGSize) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(settingsFrame) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? settingsFrame

        let inset: CGFloat = 16
        let preferredX = settingsFrame.maxX - size.width - inset
        let preferredY = settingsFrame.minY + inset
        let x = min(max(preferredX, visible.minX + 8), visible.maxX - size.width - 8)
        let y = min(max(preferredY, visible.minY + 8), visible.maxY - size.height - 8)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

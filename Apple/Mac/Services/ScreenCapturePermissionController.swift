import AppKit
import CoreGraphics
import QuartzCore
import SwiftUI

/// Screen Recording permission guide. Before recognizing a QR code from the screen, a separate window lists the permission and
/// explains the privacy boundary. Clicking the permission row opens System Settings > Screen Recording, and a snapshot of the row
/// flies along a parabola to dock at the Settings window's bottom right, turning into a guide card with a draggable app icon
/// (dropping it on the permission list writes the TCC entry). Meanwhile the authorization status is polled, and capture continues
/// automatically once granted.
/// Shared by the add-account sheet, the menu bar panel and the global shortcut. The views are in `Views/PermissionGuide/`, Settings
/// window detection is in `SystemSettingsWindow`, and the flight animation and curves are in `PermissionGuideFlight`.
@MainActor
final class ScreenCapturePermissionController: NSObject {
    static let shared = ScreenCapturePermissionController()

    /// Polls the authorization status every 0.5 seconds (see docs/DESIGN.md); TCC posts no notification when authorization changes.
    private static let grantPollInterval: Duration = .milliseconds(500)
    /// After granting, shows "Done" for a moment before finishing, so the state change is noticeable.
    private static let grantedDisplayDuration: Duration = .milliseconds(700)
    /// Sampling interval for the System Settings window position (see `startSettingsTracking`).
    private static let settingsSampleInterval: Duration = .milliseconds(120)

    private var introPanel: NSPanel?
    private var guidePanel: NSPanel?
    private var replicant: FlightReplicantWindow?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var grantWatcher: Task<Void, Never>?
    private var guideFlow: Task<Void, Never>?
    private var settingsTracking: Task<Void, Never>?
    private var settingsTerminationObserver: NSObjectProtocol?
    private let model = ScreenCapturePermissionModel()
    private let guideModel = ScreenCaptureGuideModel()

    private weak var rowAnchorView: NSView?
    private weak var draggableView: DraggableAppIconView?

    // Snapshot for this session, needed by the reverse flight (guide card back to the permission row).
    private var sessionSourceSnapshot: NSImage?
    private var sessionTargetImage: NSImage?
    private var sessionTargetFrame: NSRect = .zero

    private override init() {}

    var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Returns immediately when already authorized; otherwise shows the permission window until the user grants access (true) or
    /// cancels (false).
    func ensurePermission() async -> Bool {
        if isGranted { return true }

        // A guide flow is already running: bring its window forward and treat this call as cancelled.
        guard continuation == nil else {
            introPanel?.makeKeyAndOrderFront(nil)
            return false
        }

        model.rowState = .idle
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.showIntroPanel()
        }
    }

    // MARK: - Permission window

    private func showIntroPanel() {
        let panel = introPanel ?? makeIntroPanel()
        introPanel = panel
        panel.contentView = NSHostingView(
            rootView: ScreenCapturePermissionView(
                model: model,
                onRequest: { [weak self] in self?.beginAuthorization() },
                onCancel: { [weak self] in self?.finish(granted: false) },
                onRowAnchorCreated: { [weak self] view in self?.rowAnchorView = view }
            )
        )
        panel.layoutIfNeeded()
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func beginAuthorization() {
        guard guideFlow == nil, model.rowState == .idle else { return }
        if isGranted {
            finish(granted: true)
            return
        }
        // Take the source snapshot while the row is still in its normal state; the flight starts from it as the stand-in.
        sessionSourceSnapshot = rowCardSnapshot()
        startGrantWatcher()
        guideFlow = Task { [weak self] in
            await self?.runGuideFlow()
            self?.guideFlow = nil
        }
    }

    /// The permission row's current position in screen coordinates (flight start / reverse flight end).
    private func rowScreenRect() -> CGRect? {
        guard let view = rowAnchorView, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    /// Snapshot of the permission row card, always rendered from the window holding the row anchor so overlapping windows are never
    /// captured by mistake.
    private func rowCardSnapshot() -> NSImage? {
        guard let view = rowAnchorView, let contentView = view.window?.contentView else { return nil }
        let rect = contentView.convert(view.bounds, from: view)
        guard rect.width > 1, rect.height > 1,
            let rep = contentView.bitmapImageRepForCachingDisplay(in: rect)
        else { return nil }
        contentView.cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - Guide flow: open Settings -> fly and dock -> drag

    private func runGuideFlow() async {
        ScreenCaptureQRCodeService.openScreenCapturePrivacySettings()
        guard let settingsFrame = await waitForSettingsWindow(),
            continuation != nil, !Task.isCancelled
        else { return }

        // The Settings window is in front; bring the app and the explanation window back so the flight's starting point is visible.
        NSApp.activate(ignoringOtherApps: true)
        introPanel?.orderFrontRegardless()

        guideModel.phase = .drag
        let guide = guidePanel ?? makeGuidePanel()
        guidePanel = guide
        let hostingView = NSHostingView(
            rootView: ScreenCaptureGuideView(
                model: guideModel,
                isStaticRender: false,
                onBack: { [weak self] in self?.returnFromGuide() },
                onDraggableCreated: { [weak self] view in
                    self?.draggableView = view
                    view.onDragEnded = { operation in
                        Task { @MainActor [weak self] in
                            self?.handleDragEnded(operation)
                        }
                    }
                }
            )
        )
        guide.contentView = hostingView
        guide.setContentSize(ScreenCaptureGuideView.contentSize)

        let targetFrame = dockedFrame(near: settingsFrame)
        sessionTargetFrame = targetFrame
        sessionTargetImage = renderGuideSnapshot()

        let sourceFrame = rowScreenRect() ?? targetFrame
        model.rowState = .pending

        await runFlight(
            from: sourceFrame,
            to: targetFrame,
            sourceImage: sessionSourceSnapshot,
            targetImage: sessionTargetImage,
            reversed: false
        )
        guard continuation != nil, !Task.isCancelled else { return }

        guide.setFrame(targetFrame, display: true)
        guide.orderFrontRegardless()
        replicant?.orderOut(nil)

        // Hand focus back to System Settings so the user can drag and drop directly; the guide card is a non-activating floating
        // panel and stays visible.
        activateSystemSettings()
        startSettingsTracking()
    }

    private func handleDragEnded(_ operation: NSDragOperation) {
        guard operation != [] else { return }
        // Dropped into the list: ask the user to turn on the switch in the list, and wait for the authorization poll to hit.
        guideModel.phase = .toggle
    }

    /// The guide card's back button: flies back to the permission row, which returns to its normal state mid-flight.
    private func returnFromGuide() {
        guard settingsTracking != nil || guidePanel?.isVisible == true else { return }
        stopSettingsTracking()
        let guide = guidePanel
        guideFlow = Task { [weak self] in
            guard let self else { return }
            guide?.orderOut(nil)
            let sourceFrame = self.rowScreenRect() ?? self.sessionTargetFrame
            await self.runFlight(
                from: sourceFrame,
                to: self.sessionTargetFrame,
                sourceImage: self.sessionSourceSnapshot,
                targetImage: self.sessionTargetImage,
                reversed: true
            )
            self.replicant?.orderOut(nil)
            self.guideFlow = nil
            NSApp.activate(ignoringOtherApps: true)
            self.introPanel?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - System Settings window detection and tracking

    /// Waits for the Settings window to appear and settle (two consecutive identical samples), up to 6 seconds, so the card does not
    /// dock to a mid-animation position.
    private func waitForSettingsWindow() async -> CGRect? {
        await SystemSettingsWindow.waitForStableFrame(sampleInterval: Self.settingsSampleInterval)
    }

    private func settingsWindowFrame() -> CGRect? {
        SystemSettingsWindow.frame()
    }

    /// Where the guide card docks: inside the Settings window's bottom-right corner with a fixed inset, pulled back on screen if it
    /// would overflow.
    private func dockedFrame(near settingsFrame: CGRect) -> NSRect {
        SystemSettingsWindow.dockedFrame(near: settingsFrame, size: ScreenCaptureGuideView.contentSize)
    }

    /// The guide card follows the System Settings window. Another process's window has no public move notification (AX observation
    /// requires Accessibility permission), so this one bounded sampling task runs while docked and stops when the window disappears
    /// or System Settings quits.
    private func startSettingsTracking() {
        stopSettingsTracking()
        settingsTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == SystemSettingsWindow.bundleID else { return }
            Task { @MainActor in self?.abortGuide() }
        }
        settingsTracking = Task { [weak self] in
            var missCount = 0
            var lastFrame: CGRect?
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.settingsSampleInterval)
                guard let self, self.continuation != nil, !Task.isCancelled else { return }
                if let frame = self.settingsWindowFrame() {
                    missCount = 0
                    if frame != lastFrame {
                        lastFrame = frame
                        let docked = self.dockedFrame(near: frame)
                        self.sessionTargetFrame = docked
                        self.guidePanel?.setFrame(docked, display: true, animate: false)
                    }
                } else {
                    // The Settings window disappeared (closed by the user): dismiss the guide card and let the permission row retry.
                    missCount += 1
                    if missCount >= 4 {
                        self.abortGuide()
                        return
                    }
                }
            }
        }
    }

    private func stopSettingsTracking() {
        settingsTracking?.cancel()
        settingsTracking = nil
        if let settingsTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(settingsTerminationObserver)
            self.settingsTerminationObserver = nil
        }
    }

    private func abortGuide() {
        stopSettingsTracking()
        guidePanel?.orderOut(nil)
        replicant?.orderOut(nil)
        model.rowState = .idle
        NSApp.activate(ignoringOtherApps: true)
        introPanel?.makeKeyAndOrderFront(nil)
    }

    private func activateSystemSettings() {
        SystemSettingsWindow.activate()
    }

    // MARK: - Flight animation (the stand-in window is advanced frame by frame by `PermissionGuideFlight`)

    private func runFlight(
        from sourceFrame: NSRect,
        to targetFrame: NSRect,
        sourceImage: NSImage?,
        targetImage: NSImage?,
        reversed: Bool
    ) async {
        let replicant = self.replicant ?? FlightReplicantWindow()
        self.replicant = replicant
        await PermissionGuideFlight.run(
            replicant: replicant,
            from: sourceFrame,
            to: targetFrame,
            sourceImage: sourceImage,
            targetImage: targetImage,
            reversed: reversed,
            onApex: { [model] in
                // When the reverse flight passes the apex, restore the permission row; the switch is hidden behind the stand-in.
                if reversed { model.rowState = .idle }
            }
        )
    }

    /// Static snapshot of the guide card (the flight stand-in's target image). ImageRenderer cannot render NSViewRepresentable, so the
    /// drag row uses a same-size pure SwiftUI substitute.
    private func renderGuideSnapshot() -> NSImage? {
        let renderer = ImageRenderer(
            content: ScreenCaptureGuideView(
                model: guideModel,
                isStaticRender: true,
                onBack: {},
                onDraggableCreated: { _ in }
            )
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        renderer.isOpaque = false
        renderer.proposedSize = ProposedViewSize(ScreenCaptureGuideView.contentSize)
        return renderer.nsImage
    }

    // MARK: - Authorization polling

    private func startGrantWatcher() {
        grantWatcher?.cancel()
        grantWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.grantPollInterval)
                guard let self, self.continuation != nil else { return }
                if self.isGranted {
                    self.stopSettingsTracking()
                    self.guidePanel?.orderOut(nil)
                    self.replicant?.orderOut(nil)
                    self.model.rowState = .granted
                    NSApp.activate(ignoringOtherApps: true)
                    self.introPanel?.makeKeyAndOrderFront(nil)
                    try? await Task.sleep(for: Self.grantedDisplayDuration)
                    self.finish(granted: true)
                    return
                }
            }
        }
    }

    private func finish(granted: Bool) {
        grantWatcher?.cancel()
        grantWatcher = nil
        guideFlow?.cancel()
        guideFlow = nil
        stopSettingsTracking()
        replicant?.orderOut(nil)
        guidePanel?.orderOut(nil)
        guidePanel?.contentView = nil
        if let introPanel {
            introPanel.orderOut(nil)
            introPanel.contentView = nil
        }
        sessionSourceSnapshot = nil
        sessionTargetImage = nil
        continuation?.resume(returning: granted)
        continuation = nil
    }

    // MARK: - Window construction

    private func makeIntroPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        return panel
    }

    private func makeGuidePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: ScreenCaptureGuideView.contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }
}

extension ScreenCapturePermissionController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        finish(granted: false)
    }
}

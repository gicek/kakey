import AppKit
import SwiftUI

/// The menu bar panel window. Borderless windows cannot become key by default; overriding that lets the search / password fields get
/// keyboard focus. `.nonactivatingPanel` lets it receive input without activating the whole app, like Spotlight, so opening the
/// panel does not take activation from the current frontmost app.
final class MenuBarPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Registers an arrow cursor rect for the whole panel; the I-beam rects registered by text fields (subviews) take precedence.
/// Tested on macOS 26.5: with the panel not activating the app, cursors from windows underneath (Safari / Chrome link hand, TextEdit
/// I-beam) do not leak through, empty space shows an arrow and the search field an I-beam, even without this rect; it is kept as a
/// fallback.
final class MenuBarPanelHostingView<Content: View>: NSHostingView<Content> {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }
}

/// Menu bar icon: left click opens the account panel; right click shows a standard `NSMenu` (the "Show Accounts" scope submenu and
/// "Quit").
@MainActor
final class MenuBarStatusItemController: NSObject {
    static let shared = MenuBarStatusItemController()

    private static let panelWidth: CGFloat = 310
    private static let menuBarGap: CGFloat = 5
    private static let screenEdgeMargin: CGFloat = 8
    private static let escapeKeyCode: UInt16 = 53

    private var statusItem: NSStatusItem?
    private var panel: MenuBarPanelWindow?
    private weak var store: VaultStore?
    private var openSettings: (() -> Void)?
    /// System interactions such as the Touch ID prompt or interactive screen capture take key window status from the panel; meanwhile
    /// "close on losing focus / clicking outside" is suspended, like an `NSPopover`'s semitransient behavior.
    private var dismissalSuspended = false
    /// The language revision and color scheme the current panel content was built for. Content is built once and stays alive; closing
    /// only calls `orderOut`. Creating a new NSHostingView on every open spends most of its time instantiating the whole SwiftUI view
    /// graph (about 130-150 ms in Release), so content is rebuilt only when the language or appearance changes.
    private var builtFor: (languageRevision: Int, colorScheme: ColorScheme)?
    private let presentation = MenuBarPanelPresentation()
    private var resignKeyObserver: NSObjectProtocol?
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?

    private override init() {
        super.init()
    }

    func configure(store: VaultStore, openSettings: @escaping () -> Void) {
        self.store = store
        self.openSettings = openSettings
        updateVisibility(isVisible: store.menuBarIconVisible)
        // Language / theme changes trigger configure again (as does every appearance of the main window). When the content is stale,
        // rebuild immediately if the panel is showing; otherwise prebuild it while idle so the first open does not build on the spot.
        guard contentIsStale else { return }
        if panel?.isVisible == true {
            rebuildPanelContent()
        } else {
            Task { @MainActor [weak self] in self?.prepareContentIfNeeded() }
        }
    }

    /// Only takes effect when `configure` has not really run yet (`store == nil`). Used by the fallback call in
    /// `KakeyAppDelegate.applicationDidFinishLaunching`, so it never overrides the normal configuration that
    /// `AppShortcutIntegrationView.onAppear` sets up with the SwiftUI environment.
    func configureIfNeeded(store: VaultStore, openSettings: @escaping () -> Void) {
        guard self.store == nil else { return }
        configure(store: store, openSettings: openSettings)
    }

    func updateVisibility(isVisible: Bool) {
        if isVisible {
            ensureStatusItem()
        } else {
            closePanel()
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
                self.statusItem = nil
            }
        }
    }

    func showPanel() {
        guard let store else { return }
        if !store.menuBarIconVisible {
            store.menuBarIconVisible = true
            updateVisibility(isVisible: true)
        }
        ensureStatusItem()
        guard let button = statusItem?.button else { return }

        if panel?.isVisible == true {
            closePanel()
            return
        }

        let panel = prepareContentIfNeeded()

        var height = panel.contentView?.fittingSize.height ?? 0
        if height < 100 {
            height = estimatedPanelHeight(for: store)
        }
        panel.setFrame(panelFrame(anchoredTo: button, height: height), display: true)

        dismissalSuspended = false
        presentation.isVisible = true
        button.highlight(true)
        panel.alphaValue = 0
        // Do not activate the app: the panel is a `.nonactivatingPanel` and receives input by becoming key itself. Calling
        // `NSApp.activate` here would, when Kakey is not frontmost, bring the main window forward too, switch the system menu bar and
        // wait for an extra app switch, behaving differently from when Kakey is already frontmost.
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.13
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        } completionHandler: {
            // The window is fully transparent when the fade-in starts, so recompute the shadow for the fully shown content.
            panel.invalidateShadow()
        }
        installDismissMonitors()
    }

    func closePanel() {
        removeDismissMonitors()
        dismissalSuspended = false
        statusItem?.button?.highlight(false)
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        presentation.isVisible = false
        // Content stays alive; the query, highlighted row, capture status and unlock form password are cleared on hide so the next
        // open starts fresh.
        NotificationCenter.default.post(name: .kakeyMenuBarPanelDidHide, object: nil)
    }

    /// Builds the panel window and content on demand (first time, or after the language / appearance changed) and returns the panel.
    @discardableResult
    private func prepareContentIfNeeded() -> MenuBarPanelWindow {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if contentIsStale {
            rebuildPanelContent()
        }
        return panel
    }

    private var contentIsStale: Bool {
        guard let store, let builtFor, panel?.contentView != nil else { return true }
        return builtFor.languageRevision != store.languageRevision || builtFor.colorScheme != store.resolvedColorScheme
    }

    func setPanelDismissalSuspended(_ suspended: Bool) {
        dismissalSuspended = suspended
    }

    @objc private func togglePanel(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusContextMenu()
            return
        }
        showPanel()
    }

    private func ensureStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Without an autosaveName, the position (including whether the system folded it into the hidden area beside the notch) is
        // saved under a generic key based on creation order ("NSStatusItem Preferred Position Item-0") that is not tied to Kakey,
        // so after the user drags the icon out of the hidden area, the system may fold it back on the next launch. A fixed string
        // keeps the position stably recorded for this app.
        item.autosaveName = "KakeyMenuBarItem"
        item.button?.image = KakeyAssets.menuBarIcon
        item.button?.target = self
        item.button?.action = #selector(togglePanel(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    // MARK: - Context menu

    /// Temporarily attaches the menu to the status item and simulates a click, so the system handles positioning, highlighting,
    /// keyboard navigation and dismissal; the menu is detached as soon as it closes, so the next left click still opens the panel.
    private func showStatusContextMenu() {
        guard let statusItem, let button = statusItem.button else { return }
        closePanel()
        statusItem.menu = makeStatusMenu()
        button.performClick(nil)
        statusItem.menu = nil
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        let scopeItem = NSMenuItem(title: L10n.tr("Show Accounts"), action: nil, keyEquivalent: "")
        scopeItem.submenu = makeScopeMenu()
        menu.addItem(scopeItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: L10n.tr("Quit"), action: #selector(quitFromStatusMenu(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    /// "All" plus each category (in sidebar order), with the current scope checked.
    private func makeScopeMenu() -> NSMenu {
        let menu = NSMenu()
        guard let store else { return menu }
        let current = store.menuBarCategory.map { MenuBarListScope.category($0.id) } ?? .all
        let options: [(scope: MenuBarListScope, title: String)] =
            [(.all, L10n.tr("All"))] + store.categories.map { (.category($0.id), $0.name) }
        for option in options {
            let item = NSMenuItem(title: option.title, action: #selector(selectScope(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.scope.rawValue
            item.state = option.scope == current ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func selectScope(_ sender: NSMenuItem) {
        guard let store, let rawValue = sender.representedObject as? String else { return }
        store.menuBarListScope = MenuBarListScope(storedValue: rawValue)
        if panel?.isVisible == true {
            rebuildPanelContent()
        }
    }

    @objc private func quitFromStatusMenu(_ sender: Any?) {
        AppTerminationController.terminate()
    }

    // MARK: - Panel

    private func makePanel() -> MenuBarPanelWindow {
        let panel = MenuBarPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 430),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }

    private func rebuildPanelContent() {
        guard let store, let panel else { return }

        let rootView = MenuBarPanelVisibilityGate(presentation: presentation) {
            MenuBarPanelChrome(onContentHeightChange: { [weak self] height in
                Task { @MainActor in
                    self?.panelContentHeightDidChange(height)
                }
            }) {
                MenuBarPanel(
                    // The content stays alive, so read the current callback when opening Settings (configure may have replaced it).
                    openSettingsOverride: { [weak self] in self?.openSettings?() },
                    closePanelOverride: { [weak self] in self?.closePanel() },
                    setPanelDismissalSuspended: { [weak self] suspended in
                        self?.setPanelDismissalSuspended(suspended)
                    }
                )
            }
        }
        .environmentObject(store)
        .environment(\.locale, L10n.locale)
        .id(store.languageRevision)
        .preferredColorScheme(store.resolvedColorScheme)

        let hostingView = MenuBarPanelHostingView(rootView: rootView)
        // The controller manages the panel size, so the hosting view must not resize the window itself.
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        builtFor = (store.languageRevision, store.resolvedColorScheme)
        panel.appearance = NSAppearance(named: store.resolvedColorScheme == .dark ? .darkAqua : .aqua)
    }

    /// Follows content height changes (lock / unlock, accounts added or removed, search filtering, the capture status line appearing)
    /// by resizing the window, keeping the top edge against the menu bar.
    private func panelContentHeightDidChange(_ height: CGFloat) {
        guard height > 0, let panel, panel.isVisible, let button = statusItem?.button else { return }
        let target = panelFrame(anchoredTo: button, height: height)
        guard abs(panel.frame.height - target.height) > 0.5 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    private func panelFrame(anchoredTo button: NSStatusBarButton, height: CGFloat) -> NSRect {
        let width = Self.panelWidth
        guard let buttonWindow = button.window else {
            return NSRect(x: 0, y: 0, width: width, height: height)
        }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var x = buttonFrame.midX - width / 2
        if let screen = buttonWindow.screen ?? NSScreen.main {
            let limit = screen.visibleFrame
            x = min(max(x, limit.minX + Self.screenEdgeMargin), limit.maxX - width - Self.screenEdgeMargin)
        }
        let top = buttonFrame.minY - Self.menuBarGap
        return NSRect(x: x.rounded(), y: (top - height).rounded(), width: width, height: height)
    }

    /// Fallback estimate before the first layout pass; normally fittingSize already gives the exact height.
    private func estimatedPanelHeight(for store: VaultStore) -> CGFloat {
        if store.isLocked {
            return 430
        }
        let visibleRows = min(max(store.menuBarAccounts.count, 5), 9)
        return 38 + 18 + 1 + CGFloat(visibleRows) * 44 + 1 + 42
    }

    private func installDismissMonitors() {
        guard let panel, resignKeyObserver == nil else { return }

        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.dismissalSuspended else { return }
                self.closePanel()
            }
        }

        // Close when clicking another app (including the desktop and menu bar), like an `NSPopover`'s transient behavior.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.dismissalSuspended else { return }
                self.closePanel()
            }
        }

        // Esc closes the panel, as with a popover.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, event.keyCode == Self.escapeKeyCode else { return event }
            let didClose = MainActor.assumeIsolated {
                guard event.window === self.panel, self.panel?.isVisible == true else { return false }
                self.closePanel()
                return true
            }
            return didClose ? nil : event
        }
    }

    private func removeDismissMonitors() {
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
            self.resignKeyObserver = nil
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }
}

extension Notification.Name {
    /// The menu bar panel just hid: the always-alive panel content clears its temporary state (query, capture status, uncommitted
    /// password).
    static let kakeyMenuBarPanelDidHide = Notification.Name("KakeyMenuBarPanelDidHide")
}

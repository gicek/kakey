import AppKit

/// The single entry point for the main window. `KakeyApp`'s `WindowEventsView` registers the window when it mounts, and opening
/// goes through SwiftUI's `openWindow` environment action. When an Apple Event cold-launches the app before SwiftUI has configured
/// the opener, the app reopens itself through `NSWorkspace`, which takes the system reopen path so `WindowGroup` creates its default
/// window.
@MainActor
final class MainWindowController {
    static let shared = MainWindowController()

    /// Scene id for `WindowGroup(id:)`.
    static let sceneID = "main"

    private(set) weak var window: NSWindow?
    private weak var store: VaultStore?
    private var openWindowAction: (() -> Void)?

    private init() {}

    func configure(store: VaultStore, openWindow: @escaping () -> Void) {
        self.store = store
        openWindowAction = openWindow
    }

    /// Only takes effect when nothing is configured yet; used by the fallback call in `applicationDidFinishLaunching`.
    func configureIfNeeded(store: VaultStore) {
        guard self.store == nil else { return }
        self.store = store
    }

    /// Only registers the window. Window chrome (the immersive title bar for onboarding and the lock screen) is declared by the
    /// SwiftUI views; see `immersiveWindowChrome()`.
    func attach(_ window: NSWindow?) {
        self.window = window
    }

    func isMainWindow(_ candidate: NSWindow?) -> Bool {
        guard let candidate, let window else { return false }
        return candidate === window
    }

    var isKey: Bool {
        window?.isKeyWindow ?? false
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    /// Opens and activates the main window: brings an existing window forward, otherwise lets the SwiftUI scene create one.
    func open() {
        store?.prepareToOpenMainWindow()
        if let window {
            window.makeKeyAndOrderFront(nil)
        } else if let openWindowAction {
            openWindowAction()
        } else {
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: .init())
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func makeKeyAndOrderFront() {
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    /// On an Alfred cold launch, minimizes the main window to the Dock before the Touch ID prompt; see `CopyCodeCommand`.
    func miniaturizeIfVisible() {
        guard let window, window.isVisible, !window.isMiniaturized else { return }
        window.miniaturize(nil)
    }
}

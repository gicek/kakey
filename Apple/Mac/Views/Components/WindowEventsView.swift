import AppKit
import SwiftUI

/// Hands the `NSWindow` hosting the SwiftUI content, and its key / close events, to the caller. If the window is already key on
/// mount, `onBecameKey` fires once more: the panel rebuilds its content each time it opens and SwiftUI may mount after the window
/// became key; without the replay, focus and the automatic Touch ID prompt would never fire for that whole cycle.
struct WindowEventsView: NSViewRepresentable {
    var onAttach: (NSWindow?) -> Void = { _ in }
    var onBecameKey: (NSWindow) -> Void = { _ in }
    var onResignedKey: (NSWindow) -> Void = { _ in }
    var onWillClose: (NSWindow) -> Void = { _ in }

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.handlers = self
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.handlers = self
        nsView.attachIfNeeded()
    }

    /// Registers notifications with selectors: the system unregisters them when the object is freed, so the nonisolated deinit never
    /// touches main-actor state.
    final class ObserverView: NSView {
        var handlers = WindowEventsView()
        private weak var observedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachIfNeeded()
        }

        func attachIfNeeded() {
            guard observedWindow !== window else { return }
            NotificationCenter.default.removeObserver(self)
            observedWindow = window
            handlers.onAttach(window)
            guard let window else { return }

            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(windowDidBecomeKey(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
            center.addObserver(self, selector: #selector(windowDidResignKey(_:)), name: NSWindow.didResignKeyNotification, object: window)
            center.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: window)
            if window.isKeyWindow {
                handlers.onBecameKey(window)
            }
        }

        @objc private func windowDidBecomeKey(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            handlers.onBecameKey(window)
        }

        @objc private func windowDidResignKey(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            handlers.onResignedKey(window)
        }

        @objc private func windowWillClose(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            handlers.onWillClose(window)
        }
    }
}

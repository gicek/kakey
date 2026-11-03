import KeyboardShortcuts

/// The global shortcut listener must outlive every SwiftUI window: a `.task` attached to a window's content view is cancelled
/// when that window closes, which would break the shortcut once the main window is closed. This singleton listens for the
/// app's lifetime and starts only once.
@MainActor
final class AppShortcutListener {
    static let shared = AppShortcutListener()

    private var onOpenMenuBar: (() -> Void)?
    private var onOpenMainWindow: (() -> Void)?
    private var onCaptureQRCode: (() async -> Void)?
    private var isListening = false

    private init() {}

    func configure(
        onOpenMenuBar: @escaping () -> Void,
        onOpenMainWindow: @escaping () -> Void,
        onCaptureQRCode: @escaping () async -> Void
    ) {
        self.onOpenMenuBar = onOpenMenuBar
        self.onOpenMainWindow = onOpenMainWindow
        self.onCaptureQRCode = onCaptureQRCode
        startListeningIfNeeded()
    }

    private func startListeningIfNeeded() {
        guard !isListening else { return }
        isListening = true

        Task {
            for await _ in KeyboardShortcuts.events(.keyUp, for: .openMenuBar) {
                onOpenMenuBar?()
            }
        }
        Task {
            for await _ in KeyboardShortcuts.events(.keyUp, for: .openMainWindow) {
                onOpenMainWindow?()
            }
        }
        Task {
            for await _ in KeyboardShortcuts.events(.keyUp, for: .captureQRCode) {
                await onCaptureQRCode?()
            }
        }
    }
}

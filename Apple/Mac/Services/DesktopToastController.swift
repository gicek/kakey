import AppKit
import SwiftUI

@MainActor
final class DesktopToastController {
    static let shared = DesktopToastController()

    enum Kind {
        case info
        case success
        case error

        var systemImage: String {
            switch self {
            case .info: "info.circle.fill"
            case .success: "checkmark.circle.fill"
            case .error: "exclamationmark.triangle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .info: .blue
            case .success: .green
            case .error: .red
            }
        }
    }

    /// How long the toast stays visible (a user-facing pacing choice, not a timing workaround).
    private static let displayDuration: Duration = .seconds(2.6)

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(_ message: String, kind: Kind) {
        dismissTask?.cancel()

        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: DesktopToastView(message: message, kind: kind))
        position(panel)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }

        dismissTask = Task {
            try? await Task.sleep(for: Self.displayDuration)
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    private func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 58),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }

    private func position(_ panel: NSPanel) {
        let screen = targetScreen()
        let visibleFrame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.maxY - size.height - 44
        )
        panel.setFrameOrigin(origin)
    }

    private func targetScreen() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

private struct DesktopToastView: View {
    var message: String
    var kind: DesktopToastController.Kind

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(kind.tint)
                .frame(width: 22, height: 22)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 15)
        .frame(width: 430, height: 58, alignment: .center)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

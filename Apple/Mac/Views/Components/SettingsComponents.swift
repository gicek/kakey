import AppKit
import SwiftUI

/// Components for the Settings window, in the style of System Settings / Mail settings: a translucent sidebar on the left and
/// untitled grouped forms on the right.
enum SettingsMetrics {
    /// Window content size, shared by `PreferencesView`'s ideal size and `SettingsWindowChrome` when it shrinks the window.
    static let windowSize = CGSize(width: 760, height: 520)
    static let sidebarWidth: CGFloat = 196
    /// Height at the top of the sidebar list reserved for the traffic lights (transparent title bar, content extends to the top).
    static let sidebarTopInset: CGFloat = 52
    static let sidebarRowHeight: CGFloat = 34
    static let sidebarRowRadius: CGFloat = 8
    static let pageInset: CGFloat = 22
    static let pageTopInset: CGFloat = 40
    static let groupSpacing: CGFloat = 22
    static let groupRadius: CGFloat = 14
    static let rowInset: CGFloat = 18
    static let rowHeight: CGFloat = 50
    static let rowHeightWithDescription: CGFloat = 60
}

/// Makes the Settings window's title bar transparent with content extending to the top, so the sidebar can hold the traffic lights
/// like System Settings. SwiftUI's `Settings` scene ignores `windowStyle(.hiddenTitleBar)` and configures the window again after
/// mounting, so the change is deferred one pass on mount and applied again whenever the window becomes key. The hosting view adds
/// the title bar height (safe area) to the root view's ideal height when sizing the window, so a direct `setContentSize` gets
/// undone; instead the title bar height is reported to `PreferencesView`, which subtracts it from its ideal height so the window
/// SwiftUI computes is exactly `windowSize`.
struct SettingsWindowChrome: View {
    @Binding var titlebarInset: CGFloat

    var body: some View {
        WindowEventsView(
            onAttach: { window in
                guard let window else { return }
                Task { @MainActor in apply(to: window) }
            },
            onBecameKey: { window in apply(to: window) }
        )
        .frame(width: 0, height: 0)
    }

    @MainActor
    private func apply(to window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbar = nil
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        let inset = window.frame.height - window.contentLayoutRect.height
        if inset >= 0, inset != titlebarInset {
            titlebarInset = inset
            return
        }
        // SwiftUI does not shrink the window by itself after the ideal height decreases, so shrink it once here (the fitting size
        // already equals windowSize, so it will not be pushed back), keeping the window's top edge in place.
        let target = SettingsMetrics.windowSize
        guard window.contentView?.frame.size != target else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: target))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true)
    }
}

/// Sidebar background for windows: the system sidebar material (shows the desktop through, adapts to light / dark, grays out with
/// the system when the window loses focus). Shared by the Settings window and first-run onboarding so both sidebars look the same.
/// SwiftUI's `.bar` looks too white in the Settings window and does not match System Settings.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// A sidebar row: icon + title, with a gray rounded background when selected; the text color does not change.
struct SettingsSidebarRow: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 22, alignment: .center)
                Text(title)
                    .font(.system(size: 13, weight: .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: SettingsMetrics.sidebarRowHeight)
            .contentShape(RoundedRectangle(cornerRadius: SettingsMetrics.sidebarRowRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .background(
            RoundedRectangle(cornerRadius: SettingsMetrics.sidebarRowRadius, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.09) : Color.clear)
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A group of settings rows: large corner radius, filled background, inset dividers between rows, no header.
struct SettingsSection<Content: View>: View {
    var tint: Color = .primary.opacity(0.05)
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint, in: RoundedRectangle(cornerRadius: SettingsMetrics.groupRadius, style: .continuous))
    }
}

/// A divider whose ends align with the row content instead of touching the group's edges.
struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, SettingsMetrics.rowInset)
    }
}

/// A settings row: title on the left (optionally with a one-line description), control on the right sized to its content; pass
/// `controlWidth` when a column needs a uniform width (shortcut recorders).
struct SettingsRow<Control: View>: View {
    let title: String
    var description: String? = nil
    var controlWidth: CGFloat? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                if let description {
                    Text(description)
                        .font(.system(size: 11.5, design: description.contains("/") ? .monospaced : .default))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 20)
            control
                .frame(width: controlWidth, alignment: .trailing)
                .fixedSize(horizontal: controlWidth == nil, vertical: false)
        }
        .padding(.horizontal, SettingsMetrics.rowInset)
        .frame(minHeight: description == nil ? SettingsMetrics.rowHeight : SettingsMetrics.rowHeightWithDescription)
    }
}

/// An inline error under its row (login item, Alfred export failures), in small red text.
struct SettingsInlineError: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(.red)
            .padding(.horizontal, SettingsMetrics.rowInset)
            .padding(.bottom, 10)
    }
}

import SwiftUI

/// Chrome container for the menu bar panel: background, corner radius and stroke, and reports the content height to the window
/// controller. This is the only implementation of the panel background; see `KakeyPanelBackground` (Liquid Glass on macOS 26,
/// menu material on older versions).
struct MenuBarPanelChrome<Content: View>: View {
    private let onContentHeightChange: @Sendable (CGFloat) -> Void
    private let content: Content
    private let cornerRadius = KakeyPanelStyle.cornerRadius

    init(
        onContentHeightChange: @escaping @Sendable (CGFloat) -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.onContentHeightChange = onContentHeightChange
        self.content = content()
    }

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: MenuBarPanelContentHeightKey.self, value: proxy.size.height)
                }
            )
            .onPreferenceChange(MenuBarPanelContentHeightKey.self, perform: onContentHeightChange)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(KakeyPanelBackground(cornerRadius: cornerRadius))
            .overlay {
                if !KakeyPanelStyle.drawsOwnEdge(reduceTransparency: reduceTransparency) {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
                }
            }
    }
}

/// Whether the menu bar panel is showing. The panel content stays alive, so hiding it pauses the code countdown through this.
@MainActor
@Observable
final class MenuBarPanelPresentation {
    var isVisible = false
}

/// Sets `codeCountdownPaused` from panel visibility. Only this layer observes visibility, so toggling it does not affect the rest of
/// the content.
struct MenuBarPanelVisibilityGate<Content: View>: View {
    let presentation: MenuBarPanelPresentation
    @ViewBuilder let content: Content

    var body: some View {
        content.environment(\.codeCountdownPaused, !presentation.isVisible)
    }
}

private struct MenuBarPanelContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

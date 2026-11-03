import SwiftUI

enum K {
    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 8
    }

    enum Control {
        static let circularButtonSize: CGFloat = 38
    }
}

/// App-wide button style. `size: .large` is for the bottom buttons of full-page forms such as onboarding: taller, heavier text,
/// and an accent-colored shadow on the primary button.
struct PressableButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var prominence: Prominence = .standard
    var size: Size = .regular

    enum Prominence {
        case standard
        case primary
        case icon
        case danger
        /// A secondary action drawn as accent-colored text with no border.
        case link
    }

    enum Size {
        case regular
        case large
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size == .large ? 13.5 : 13, weight: fontWeight))
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(minWidth: size == .large && prominence == .primary ? 132 : nil)
            .frame(height: size == .large ? 36 : 30)
            .frame(width: prominence == .icon ? 30 : nil)
            .background(background(configuration.isPressed), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                if prominence == .standard || prominence == .danger {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.separator.opacity(isEnabled ? 0.55 : 0.28))
                }
            }
            .shadow(
                color: shadowColor(configuration.isPressed), radius: configuration.isPressed ? 3 : 8, x: 0,
                y: configuration.isPressed ? 1 : 4
            )
            .scaleEffect(isEnabled && configuration.isPressed ? (size == .large ? 0.98 : 0.96) : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isEnabled)
    }

    private var fontWeight: Font.Weight {
        size == .large && prominence != .link ? .semibold : .medium
    }

    private var cornerRadius: CGFloat {
        size == .large ? K.Radius.medium : K.Radius.small
    }

    private var horizontalPadding: CGFloat {
        switch prominence {
        case .icon: 0
        case .link: 10
        default: size == .large ? 18 : 13
        }
    }

    private var foreground: AnyShapeStyle {
        if !isEnabled {
            return AnyShapeStyle(Color.secondary.opacity(0.72))
        }

        switch prominence {
        case .primary:
            return AnyShapeStyle(.white)
        case .danger:
            return AnyShapeStyle(.red)
        case .link:
            return AnyShapeStyle(Color.accentColor)
        default:
            return AnyShapeStyle(.primary)
        }
    }

    private func background(_ pressed: Bool) -> AnyShapeStyle {
        if !isEnabled {
            switch prominence {
            case .primary:
                return AnyShapeStyle(Color.secondary.opacity(size == .large ? 0.28 : 0.20))
            case .icon, .link:
                return AnyShapeStyle(Color.primary.opacity(0.001))
            default:
                return AnyShapeStyle(Color.secondary.opacity(0.06))
            }
        }

        switch prominence {
        case .primary:
            return AnyShapeStyle(Color.accentColor.opacity(pressed ? 0.82 : 1))
        case .icon:
            return AnyShapeStyle(Color.primary.opacity(pressed ? 0.10 : 0.001))
        case .link:
            return AnyShapeStyle(Color.accentColor.opacity(pressed ? 0.10 : 0.001))
        default:
            return AnyShapeStyle(Color.secondary.opacity(pressed ? 0.16 : 0.09))
        }
    }

    /// Only the large primary button has a shadow. A shadow on the button itself does not break the text cursor the way it does
    /// for input fields (see `kakeyInputChrome`).
    private func shadowColor(_ pressed: Bool) -> Color {
        guard isEnabled, size == .large, prominence == .primary else { return .clear }
        return Color.accentColor.opacity(pressed ? 0.10 : 0.22)
    }
}

struct SidebarButtonStyle: ButtonStyle {
    var isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .sidebarRowChrome(isActive: isActive, isPressed: configuration.isPressed)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    /// Sidebar row chrome, shared by button rows (`SidebarButtonStyle`) and reorderable category rows (not Buttons; clicks are
    /// dispatched by gesture).
    func sidebarRowChrome(isActive: Bool, isPressed: Bool = false) -> some View {
        font(.system(size: 13, weight: .medium))
            .foregroundStyle(isActive ? .white : .primary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isActive ? Color.accentColor : Color.primary.opacity(isPressed ? 0.08 : 0.001),
                in: RoundedRectangle(cornerRadius: K.Radius.small, style: .continuous)
            )
    }
}

/// Background and search field chrome for floating panels (the menu bar panel). macOS version checks live only here so `#available`
/// does not spread across the code. macOS 26 uses the system Liquid Glass (`NSGlassEffectView`); 14-25 keep the menu material plus a
/// little window background color; with Reduce Transparency on, always an opaque window background.
enum KakeyPanelStyle {
    static var usesSystemGlass: Bool {
        if #available(macOS 26, *) { true } else { false }
    }

    /// Panel corner radius: the glass panel matches the system's popover panels and is a bit larger; the material panel keeps the
    /// original value.
    static var cornerRadius: CGFloat { usesSystemGlass ? 18 : 13 }

    /// Glass has its own edge highlight, so no extra stroke; the material and opaque backgrounds keep a thin stroke.
    static func drawsOwnEdge(reduceTransparency: Bool) -> Bool { usesSystemGlass && !reduceTransparency }
}

/// Panel background: glass, material or opaque, as chosen by `KakeyPanelStyle`.
struct KakeyPanelBackground: View {
    var cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        } else if #available(macOS 26, *) {
            ZStack {
                // Glass is composited by the system, so the window's own pixels are almost fully transparent and a borderless
                // window cannot compute a shadow. An invisible shape underneath makes the window shadow follow the corner radius.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.04))
                SystemGlassBackground(cornerRadius: cornerRadius)
            }
        } else {
            ZStack {
                VisualEffectView(material: .menu)
                Color(nsColor: .windowBackgroundColor).opacity(0.15)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

}

@available(macOS 26, *)
private struct SystemGlassBackground: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .regular
        apply(to: view)
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        apply(to: view)
    }

    /// Clips the layer to the same corner radius. Otherwise the glass leaves semi-transparent pixels across the whole rectangle,
    /// the borderless window's shadow follows the rectangle, and square edges show at the corners.
    private func apply(to view: NSGlassEffectView) {
        view.cornerRadius = cornerRadius
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

extension View {
    // The shadow can only go on the background shape, never wrap the content: applying .shadow to the whole subtree pushes the
    // embedded NSTextField into an offscreen compositing group, and the mouse cursor (I-beam / arrow) hit area breaks or shifts.
    func kakeyInputChrome(cornerRadius: CGFloat = K.Radius.medium) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .shadow(color: .black.opacity(0.035), radius: 3, x: 0, y: 1)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.72), lineWidth: 1)
            }
    }

    /// Panel search field: a capsule with a system-accent focus ring outside it (same on every version). On macOS 26 the fill is
    /// translucent and blends with the glass panel; on older versions and with Reduce Transparency it is an opaque text background.
    func kakeySearchFieldChrome(isFocused: Bool) -> some View {
        modifier(KakeySearchFieldChrome(isFocused: isFocused))
    }

    func kakeyCapsuleInputChrome() -> some View {
        self
            .background(
                Capsule()
                    .fill(Color(nsColor: .textBackgroundColor))
                    .shadow(color: .black.opacity(0.035), radius: 3, x: 0, y: 1)
            )
            .overlay {
                Capsule()
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.78), lineWidth: 1)
            }
    }
}

private struct KakeySearchFieldChrome: ViewModifier {
    var isFocused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var fillOpacity: Double {
        KakeyPanelStyle.usesSystemGlass && !reduceTransparency ? 0.55 : 1
    }

    func body(content: Content) -> some View {
        content
            .background(
                Capsule()
                    .fill(Color(nsColor: .textBackgroundColor).opacity(fillOpacity))
                    .shadow(color: .black.opacity(0.035), radius: 3, x: 0, y: 1)
            )
            .overlay {
                Capsule()
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(isFocused ? 0 : 0.6), lineWidth: 1)
            }
            .background {
                // The focus ring is drawn outside the capsule so it does not overlap the text.
                Capsule()
                    .strokeBorder(Color.accentColor.opacity(isFocused ? 0.55 : 0), lineWidth: 3)
                    .padding(-2.5)
            }
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

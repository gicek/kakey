import AppKit
import SwiftUI

/// Phase of the docked guide card: asking to drag into the list, or, after dropping, asking to turn on the switch.
@MainActor
final class ScreenCaptureGuideModel: ObservableObject {
    enum Phase {
        case drag  // Asks the user to drag into the list
        case toggle  // Dropped: asks the user to turn on the switch
    }

    @Published var phase: Phase = .drag
}

/// The guide card docked at the bottom right of the System Settings window: arrow and hint, the app icon row that can be dragged into
/// the permission list, and a back button.
struct ScreenCaptureGuideView: View {
    @ObservedObject var model: ScreenCaptureGuideModel
    /// `ImageRenderer` cannot render NSViewRepresentable, so the flight stand-in's target snapshot uses a same-size pure SwiftUI
    /// substitute.
    let isStaticRender: Bool
    var onBack: () -> Void
    var onDraggableCreated: (DraggableAppIconView) -> Void

    static let contentSize = CGSize(width: 500, height: 130)
    static let cardCornerRadius: CGFloat = 22

    @State private var arrowScale: CGFloat
    @State private var arrowOffsetY: CGFloat
    @State private var arrowOpacity: CGFloat

    init(
        model: ScreenCaptureGuideModel,
        isStaticRender: Bool,
        onBack: @escaping () -> Void,
        onDraggableCreated: @escaping (DraggableAppIconView) -> Void
    ) {
        self.model = model
        self.isStaticRender = isStaticRender
        self.onBack = onBack
        self.onDraggableCreated = onDraggableCreated
        // Static snapshots use the final pose directly; live rendering runs the spring from the pre-entrance pose.
        _arrowScale = State(initialValue: isStaticRender ? 1.0 : 0.2)
        _arrowOffsetY = State(initialValue: isStaticRender ? 0 : 18)
        _arrowOpacity = State(initialValue: isStaticRender ? 1 : 0)
    }

    private var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Kakey"
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.tint)
                        .shadow(color: Color.accentColor.opacity(0.45), radius: 6, y: 2)
                        .frame(width: 28, height: 28)
                        .scaleEffect(arrowScale)
                        .offset(y: arrowOffsetY)
                        .opacity(arrowOpacity)
                    Text(caption)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .opacity(arrowOpacity)
                    Spacer(minLength: 0)
                }
                draggableRow
                    .frame(height: 44)
            }
            .padding(.vertical, 14)
            .padding(.leading, 52)
            .padding(.trailing, 18)
            .frame(
                width: Self.contentSize.width,
                height: Self.contentSize.height,
                alignment: .topLeading
            )
            .background(
                RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )

            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(L10n.tr("Back"))
            .accessibilityLabel(L10n.tr("Back"))
            .padding(.leading, 10)
            .padding(.top, (Self.contentSize.height - 32) / 2)
        }
        .onAppear(perform: playEntranceAnimation)
    }

    private var caption: String {
        switch model.phase {
        case .drag:
            L10n.format("Drag %@ to the list above to allow Screen Recording", appName)
        case .toggle:
            L10n.format("Turn on %@ in the list above", appName)
        }
    }

    @ViewBuilder
    private var draggableRow: some View {
        let pill = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if isStaticRender {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
                Text(appName)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary.opacity(0.5), in: pill)
            .overlay(pill.strokeBorder(.separator.opacity(0.6)))
        } else {
            DraggableAppIconRepresentable(onCreated: onDraggableCreated)
                .background(.quaternary.opacity(0.5), in: pill)
                .overlay(pill.strokeBorder(.separator.opacity(0.6)))
        }
    }

    private func playEntranceAnimation() {
        guard !isStaticRender else { return }
        withAnimation(.interpolatingSpring(mass: 1, stiffness: 200, damping: 11, initialVelocity: 18)) {
            arrowScale = 1.0
            arrowOffsetY = 0
            arrowOpacity = 1
        }
    }
}

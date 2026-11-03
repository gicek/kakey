import AppKit
import SwiftUI

/// Current pose of the flight stand-in: crossfade progress between the two snapshots, blur, corner radius, shadow and size.
@MainActor
final class FlightReplicantModel: ObservableObject {
    @Published var sourceImage: NSImage?
    @Published var targetImage: NSImage?
    @Published var progress: CGFloat = 0
    @Published var blurRadius: CGFloat = 0
    @Published var cornerRadius: CGFloat = 12
    @Published var shadowOpacity: CGFloat = 0
    @Published var contentSize: CGSize = .zero
}

private struct FlightReplicantContentView: View {
    @ObservedObject var model: FlightReplicantModel

    var body: some View {
        ZStack {
            // Both snapshots stretch to fill the stand-in rectangle, so the row grows smoothly into the card size without gaps.
            if let source = model.sourceImage {
                Image(nsImage: source)
                    .resizable()
                    .interpolation(.high)
                    .opacity(1 - model.progress)
            }
            if let target = model.targetImage {
                Image(nsImage: target)
                    .resizable()
                    .interpolation(.high)
                    .opacity(model.progress)
            }
        }
        .frame(width: model.contentSize.width, height: model.contentSize.height)
        .clipShape(RoundedRectangle(cornerRadius: model.cornerRadius, style: .continuous))
        .compositingGroup()
        .blur(radius: model.blurRadius)
        .shadow(color: .black.opacity(0.18 * model.shadowOpacity), radius: 2)
        .shadow(color: .black.opacity(0.22 * model.shadowOpacity), radius: 15, y: -6)
        .shadow(color: .black.opacity(0.14 * model.shadowOpacity), radius: 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Flight stand-in window: a snapshot of the permission row flies along a parabola to the Settings window, crossfading mid-air into
/// a snapshot of the guide card.
@MainActor
final class FlightReplicantWindow: NSPanel {
    /// Padding around the content so the shadow and blur glow are not clipped by the window edge.
    static let chromeInset: CGFloat = 40

    let model = FlightReplicantModel()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true

        let hostingView = NSHostingView(rootView: FlightReplicantContentView(model: model))
        hostingView.autoresizingMask = [.width, .height]
        contentView = hostingView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func apply(
        frame contentFrame: NSRect,
        cornerRadius: CGFloat,
        progress: CGFloat,
        shadowOpacity: CGFloat,
        blurRadius: CGFloat
    ) {
        let inset = Self.chromeInset
        setFrame(contentFrame.insetBy(dx: -inset, dy: -inset), display: false)

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.cornerRadius = cornerRadius
            model.progress = progress
            model.shadowOpacity = shadowOpacity
            model.blurRadius = blurRadius
            model.contentSize = contentFrame.size
        }
    }
}

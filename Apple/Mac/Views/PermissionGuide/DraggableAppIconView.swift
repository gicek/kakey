import AppKit
import SwiftUI

/// The draggable app icon row (a real drag source; dropping it on the System Settings permission list writes the TCC entry).
@MainActor
final class DraggableAppIconView: NSView, NSDraggingSource {
    private let dragThreshold: CGFloat = 3
    private var mouseDownEvent: NSEvent?
    private var hasStartedDrag = false

    private let iconView = NSImageView()
    private let nameLabel: NSTextField

    var onDragEnded: ((NSDragOperation) -> Void)?

    override init(frame frameRect: NSRect) {
        let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Kakey"
        nameLabel = NSTextField(labelWithString: appName)
        super.init(frame: frameRect)

        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path)
        icon.size = NSSize(width: 32, height: 32)
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        hasStartedDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, !hasStartedDrag else {
            super.mouseDragged(with: event)
            return
        }
        let distance = hypot(
            event.locationInWindow.x - down.locationInWindow.x,
            event.locationInWindow.y - down.locationInWindow.y
        )
        guard distance >= dragThreshold else { return }
        hasStartedDrag = true
        startDrag(with: down)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
        hasStartedDrag = false
        super.mouseUp(with: event)
    }

    private func startDrag(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: rowSnapshot() ?? iconView.image)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    /// The drag preview is a snapshot of the whole row (icon + app name), matching what the card shows.
    private func rowSnapshot() -> NSImage? {
        guard bounds.width > 1, bounds.height > 1,
            let rep = bitmapImageRepForCachingDisplay(in: bounds)
        else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    nonisolated func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation { .copy }

    nonisolated func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        Task { @MainActor in
            self.mouseDownEvent = nil
            self.hasStartedDrag = false
            self.onDragEnded?(operation)
        }
    }
}

struct DraggableAppIconRepresentable: NSViewRepresentable {
    let onCreated: (DraggableAppIconView) -> Void

    func makeNSView(context: Context) -> DraggableAppIconView {
        let view = DraggableAppIconView(frame: NSRect(x: 0, y: 0, width: 430, height: 44))
        onCreated(view)
        return view
    }

    func updateNSView(_ nsView: DraggableAppIconView, context: Context) {}
}

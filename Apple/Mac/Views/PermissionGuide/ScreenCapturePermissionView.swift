import AppKit
import SwiftUI

/// State of the permission explanation window: the permission row shows "Open System Settings", a dashed placeholder while guiding,
/// or "Done".
@MainActor
final class ScreenCapturePermissionModel: ObservableObject {
    enum RowState {
        case idle  // Shows the "Open System Settings" button
        case pending  // Flying / guiding: dashed placeholder "Finish in System Settings"
        case granted  // Done
    }

    @Published var rowState: RowState = .idle
}

/// Permission explanation window: title, permission row (icon, purpose, button) and privacy note.
struct ScreenCapturePermissionView: View {
    @ObservedObject var model: ScreenCapturePermissionModel
    var onRequest: () -> Void
    var onCancel: () -> Void
    /// Anchor view of the permission row: the controller uses it to compute the flight's starting point in screen coordinates.
    var onRowAnchorCreated: (NSView) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("Kakey Needs Permission"))
                        .font(.system(size: 15, weight: .semibold))
                    Text(L10n.tr("Allow the permission below in System Settings. Kakey uses it only as described here."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            permissionRow
                .background(RowAnchorReader(onCreated: onRowAnchorCreated))

            VStack(alignment: .leading, spacing: 12) {
                bulletRow(
                    systemImage: "hand.tap",
                    textKey: "Captures the screen once, only when you start a scan — never in the background")
                bulletRow(
                    systemImage: "lock.shield",
                    textKey: "The capture is read on this Mac and discarded right away — never saved or uploaded")
                bulletRow(systemImage: "gearshape", textKey: "Turn it off anytime in System Settings → Privacy & Security")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack {
                Button(L10n.tr("Cancel")) { onCancel() }
                    .buttonStyle(PressableButtonStyle())
                Spacer()
            }
        }
        .padding(20)
        .padding(.top, 6)
        .frame(width: 470)
    }

    /// While guiding, only the row content is hidden and a dashed placeholder overlays it; the row height stays the same so the window
    /// does not jump.
    private var permissionRow: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let isPending = model.rowState == .pending
        return HStack(spacing: 12) {
            Image(systemName: "rectangle.dashed.badge.record")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("Screen Recording"))
                    .font(.system(size: 13, weight: .semibold))
                Text(L10n.tr("Needed to read QR codes on your screen"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Group {
                if model.rowState == .granted {
                    Label(L10n.tr("Allowed"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.green)
                } else {
                    Button(L10n.tr("Open System Settings")) { onRequest() }
                        .buttonStyle(PressableButtonStyle(prominence: .primary))
                }
            }
            // The button and "Done" are laid out at full width; when space is short, the description on the left wraps instead of the
            // button truncating.
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 64)
        .opacity(isPending ? 0 : 1)
        .background(isPending ? AnyShapeStyle(.clear) : AnyShapeStyle(.quaternary.opacity(0.35)), in: shape)
        .overlay {
            if isPending {
                Text(L10n.tr("Complete in System Settings"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(shape.stroke(.separator, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            } else {
                shape.strokeBorder(.separator.opacity(0.6))
            }
        }
    }

    private func bulletRow(systemImage: String, textKey: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 18)
            Text(L10n.tr(textKey))
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Transparent anchor view: exposes the permission row's position in the window so the controller can convert it to screen
/// coordinates.
private struct RowAnchorReader: NSViewRepresentable {
    let onCreated: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        onCreated(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

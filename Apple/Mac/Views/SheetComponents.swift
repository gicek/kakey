import AppKit
import SwiftUI

func sheetHeader<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
    ZStack(alignment: .trailing) {
        HStack {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Spacer()
        }
        .padding(.leading, 24)
        .padding(.trailing, 16)

        trailing()
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .frame(height: 56)
    .background(.bar)
}
extension View {
    /// Ends editing when clicking empty space in a sheet's content (on macOS, SwiftUI does not resign focus on such clicks), so
    /// "validate after leaving the field" also fires there. Attached to the background, so controls' own clicks are unaffected.
    func resignsFocusOnBackgroundClick() -> some View {
        background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
    }

    func labeled(_ label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            self
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .frame(height: 36)
                .kakeyInputChrome(cornerRadius: 7)
        }
    }
}
extension Text {
    func sectionLabel() -> some View {
        self
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

struct FloatingSheetCloseButton: NSViewRepresentable {
    var action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let closeTitle = L10n.tr("Close")
        let button = NSButton(
            image: closeImage(accessibilityDescription: closeTitle),
            target: context.coordinator,
            action: #selector(Coordinator.close)
        )
        button.bezelStyle = .circular
        button.isBordered = true
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.controlSize = .regular
        button.setButtonType(.momentaryPushIn)
        button.toolTip = closeTitle
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: K.Control.circularButtonSize),
            button.heightAnchor.constraint(equalToConstant: K.Control.circularButtonSize),
        ])
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        let closeTitle = L10n.tr("Close")
        button.image = closeImage(accessibilityDescription: closeTitle)
        button.toolTip = closeTitle
    }

    private func closeImage(accessibilityDescription: String) -> NSImage {
        let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: accessibilityDescription) ?? NSImage()
        return image.withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) ?? image
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func close() {
            action()
        }
    }
}

import AppKit
import SwiftUI

/// A system pop-up button (`NSPopUpButton`) that fills the available width.
/// SwiftUI's `Picker(.menu)` sizes to its content and centers itself; filling the column requires bridging `NSPopUpButton`.
struct FullWidthPopUpPicker<Value: Hashable>: NSViewRepresentable {
    var options: [(value: Value, title: String)]
    @Binding var selection: Value

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.didSelect(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let titles = options.map(\.title)
        if button.itemTitles != titles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        }
        if let index = options.firstIndex(where: { $0.value == selection }) {
            button.selectItem(at: index)
        }
    }

    final class Coordinator: NSObject {
        var parent: FullWidthPopUpPicker

        init(_ parent: FullWidthPopUpPicker) {
            self.parent = parent
        }

        @MainActor @objc func didSelect(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard parent.options.indices.contains(index) else { return }
            parent.selection = parent.options[index].value
        }
    }
}

import AppKit
import SwiftUI

/// Main window content: title bar toolbar (lock, view switcher, search field, add) and the list / cards / empty states.
struct MainContentView: View {
    @EnvironmentObject private var store: VaultStore

    var body: some View {
        VStack(spacing: 0) {
            if store.accounts.isEmpty {
                EmptyVaultStateView()
            } else if store.filteredAccounts.isEmpty {
                if case .category(let id) = store.selectedSection, store.searchText.isEmpty, let category = store.category(id) {
                    // An empty category is not "no search results": explain how to add accounts to it.
                    EmptyStateView(
                        title: L10n.format("No accounts in “%@” yet", category.name),
                        systemImage: "folder",
                        message: L10n.tr("In the main window, right-click an account and choose Add to.")
                    )
                } else {
                    EmptyStateView(title: L10n.tr("No matching accounts"))
                }
            } else if store.usesCardView {
                AccountCardGrid()
            } else {
                AccountList()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.lock()
                } label: {
                    Label(L10n.tr("Lock"), systemImage: "lock")
                }
                .help(L10n.tr("Lock"))
            }
            ToolbarItem(placement: .primaryAction) { viewModePicker }
            ToolbarItem(placement: .primaryAction) { searchField }
            ToolbarItem(placement: .primaryAction) {
                // Add and search are the two most used entry points, so they sit together; add uses the prominent style.
                Button {
                    store.activeSheet = .addAccount
                } label: {
                    Label(L10n.tr("Add"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .help(L10n.tr("Add"))
            }
        }
        .onAppear { focusSearchField() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            focusSearchField()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard MainWindowController.shared.isMainWindow(notification.object as? NSWindow) else { return }
            focusSearchField()
        }
        .onChange(of: store.activeSheet?.id) { _, sheetID in
            if sheetID == nil {
                focusSearchField()
            }
        }
        .onChange(of: store.isLocked) { _, isLocked in
            if !isLocked {
                focusSearchField()
            }
        }
    }

    /// Search only needs a few characters of a service or account name, so it has a fixed width in the title bar; Return copies the
    /// first result.
    private var searchField: some View {
        ToolbarSearchField(
            text: $store.searchText,
            placeholder: L10n.tr("Search accounts or sites"),
            onSubmit: copyFirstResult
        )
        .frame(width: 240)
    }

    private var viewModePicker: some View {
        Picker(L10n.tr("View"), selection: $store.usesCardView) {
            Image(systemName: "list.bullet")
                .accessibilityLabel(L10n.tr("List"))
                .tag(false)
            Image(systemName: "square.grid.2x2")
                .accessibilityLabel(L10n.tr("Cards"))
                .tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help(L10n.tr("View"))
    }

    private func copyFirstResult() {
        guard let first = store.filteredAccounts.first else { return }
        store.copyCode(for: first)
    }

    /// Defers the focus request until after the current update: in the same pass as a sheet dismissal or the window becoming key, the
    /// toolbar field cannot become first responder yet.
    private func focusSearchField() {
        guard !store.isLocked, store.activeSheet == nil else { return }

        Task { @MainActor in
            guard !store.isLocked, store.activeSheet == nil, MainWindowController.shared.isKey else { return }
            NotificationCenter.default.post(name: .kakeyFocusMainSearch, object: nil)
        }
    }
}

extension Notification.Name {
    /// Asks to focus the main window search field; when `object` is `true` (Cmd-F), also selects the existing text.
    static let kakeyFocusMainSearch = Notification.Name("KakeyFocusMainSearchField")
}

/// Native search field in the title bar. SwiftUI `@FocusState` cannot reach fields in the toolbar and toolbar content updates at
/// unreliable times, so focus requests come through a notification that makes it first responder directly. Esc to clear is built
/// into NSSearchField.
private struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        // The clear button and Esc only send the action, not controlTextDidChange.
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchFieldChanged(_:))
        field.placeholderString = placeholder
        field.stringValue = text
        field.sendsSearchStringImmediately = true
        field.focusRingType = .exterior
        context.coordinator.field = field
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.focusField(_:)),
            name: .kakeyFocusMainSearch,
            object: nil
        )
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = placeholder
    }

    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ToolbarSearchField
        weak var field: NSSearchField?

        init(_ parent: ToolbarSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        @objc func focusField(_ notification: Notification) {
            guard let field, let window = field.window else { return }
            if field.currentEditor() == nil {
                window.makeFirstResponder(field)
            } else if notification.object as? Bool == true {
                field.selectText(nil)
            }
        }

        @objc func searchFieldChanged(_ field: NSSearchField) {
            if parent.text != field.stringValue {
                parent.text = field.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.onSubmit()
            return true
        }
    }
}

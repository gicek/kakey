import AppKit
import SwiftUI

/// The category name being edited in place in the sidebar: a new category or a rename.
enum CategoryNameEditing: Equatable {
    case new
    case rename(AccountCategory.ID)
}

/// The sidebar's "Categories" section: a header (with a New button), category rows (context menu Rename / Delete, drag to reorder)
/// and the inline editor. New categories can also be created from the sidebar's empty-area context menu; deleting a category
/// deletes only the category, and its accounts stay in "All".
struct CategorySidebarSection: View {
    @EnvironmentObject private var store: VaultStore
    @Binding var editing: CategoryNameEditing?
    @State private var pendingDelete: AccountCategory?
    @StateObject private var reorder = ReorderSession<AccountCategory.ID>(animation: .snappy(duration: 0.16))

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(L10n.tr("Categories"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    editing = .new
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.tr("New Category"))
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .padding(.top, 18)
            .contextMenu { newCategoryMenuItem }

            // Category rows form their own block as the reorder container: dropping inside it commits; dropping on the header, "All"
            // or outside the sidebar reverts.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(reorder.displayOrder(of: store.categories)) { category in
                    if editing == .rename(category.id) {
                        CategoryNameField(initialName: category.name, editing: $editing) { name in
                            try store.renameCategory(category.id, to: name)
                        }
                    } else {
                        row(category)
                    }
                }
            }
            .reorderContainer(session: reorder) { id in
                if let category = store.category(id) {
                    CategoryDragPreview(category: category, isActive: store.selectedSection == .category(id))
                }
            }

            if editing == .new {
                CategoryNameField(initialName: "", editing: $editing) { name in
                    store.selectedSection = .category(try store.createCategory(named: name).id)
                }
            }
        }
        .confirmationDialog(
            L10n.format("Delete the category “%@”?", pendingDelete?.name ?? ""),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { category in
            Button(L10n.tr("Delete Category"), role: .destructive) {
                store.deleteCategory(category.id)
            }
            Button(L10n.tr("Cancel"), role: .cancel) {}
        } message: { category in
            Text(L10n.format("The %lld accounts in it won’t be deleted and stay in All.", category.accountIDs.count))
        }
    }

    @ViewBuilder
    var newCategoryMenuItem: some View {
        Button(L10n.tr("New Category")) {
            editing = .new
        }
    }

    /// Category rows are not Buttons: a Button fires another tap when released after a drag, so clicks are dispatched by gesture.
    /// Looks the same as "All".
    private func row(_ category: AccountCategory) -> some View {
        CategoryRowLabel(category: category)
            .sidebarRowChrome(isActive: store.selectedSection == .category(category.id))
            .contentShape(Rectangle())
            .onTapGesture { store.selectedSection = .category(category.id) }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { store.selectedSection = .category(category.id) }
            .opacity(reorder.draggedID == category.id ? 0.4 : 1)
            .animation(.snappy(duration: 0.16), value: reorder.draggedID == category.id)
            .contextMenu {
                Button(L10n.tr("Rename")) {
                    editing = .rename(category.id)
                }
                Button(L10n.tr("Delete Category"), role: .destructive) {
                    pendingDelete = category
                }
                Divider()
                newCategoryMenuItem
            }
            .reorderItem(category.id, session: reorder) { start in
                reorder.beginDrag(category.id, at: start, order: store.categories.map(\.id)) { store.reorderCategories($0) }
            }
    }
}

private struct CategoryRowLabel: View {
    var category: AccountCategory

    var body: some View {
        HStack(spacing: 0) {
            SidebarRowLabel(title: category.name, image: "folder")
            Spacer(minLength: 6)
            Text("\(category.accountIDs.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The stand-in that follows the pointer when dragging a category: same look as the row, with an opaque background to cover other
/// rows.
private struct CategoryDragPreview: View {
    var category: AccountCategory
    var isActive: Bool

    var body: some View {
        CategoryRowLabel(category: category)
            .sidebarRowChrome(isActive: isActive)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: K.Radius.small, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }
}

/// Edits a category name in place: focused automatically, Return confirms, Esc cancels. Clicking outside the field or moving focus
/// away also finishes (like renaming in Finder): an empty name discards, otherwise it saves; an invalid name stays in editing with
/// the reason shown below.
private struct CategoryNameField: View {
    var initialName: String
    @Binding var editing: CategoryNameEditing?
    var commit: (String) throws -> Void
    @State private var name = ""
    @State private var error: String?
    @State private var fieldFrame: CGRect = .zero
    @State private var outsideClicks = OutsideClickMonitor()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 17, weight: .regular))
                    .frame(width: 24, alignment: .center)
                    .foregroundStyle(.secondary)
                TextField(L10n.tr("Category name"), text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .focused($focused)
                    .onSubmit(submit)
                    .onExitCommand { editing = nil }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { fieldFrame = proxy.frame(in: .global) }
                        .onChange(of: proxy.frame(in: .global)) { _, frame in fieldFrame = frame }
                }
            }
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: K.Radius.small, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: K.Radius.small, style: .continuous)
                    .strokeBorder(error == nil ? Color.accentColor.opacity(0.6) : Color.red.opacity(0.7), lineWidth: 1)
            }
            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            name = initialName
            outsideClicks.start(isInside: { fieldFrame.contains($0) }, onOutside: finishEditing)
            // The field was just inserted into the sidebar; changing `@FocusState` in the same pass is ignored, so defer it.
            Task { @MainActor in focused = true }
        }
        .onDisappear { outsideClicks.stop() }
        .onChange(of: focused) { _, isFocused in
            if !isFocused, editing != nil {
                finishEditing()
            }
        }
        .onChange(of: name) { _, _ in error = nil }
    }

    /// Click outside or focus lost: an empty name discards, anything else behaves like Return.
    private func finishEditing() {
        guard editing != nil else { return }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            editing = nil
        } else {
            submit()
        }
    }

    private func submit() {
        do {
            try commit(name)
            editing = nil
        } catch {
            self.error = error.localizedDescription
            focused = true
        }
    }
}

/// Watches mouse-down events in this window while editing: in SwiftUI, clicking empty space does not take focus from the field, so
/// the click location has to be checked by hand. Events pass through as usual, so clicking another category or account still works.
@MainActor
private final class OutsideClickMonitor {
    private var monitor: Any?

    /// `isInside` takes SwiftUI global coordinates (origin at the window content area's top left).
    func start(isInside: @escaping (CGPoint) -> Bool, onOutside: @escaping () -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated {
                if let contentView = event.window?.contentView {
                    let location = event.locationInWindow
                    let point = CGPoint(x: location.x, y: contentView.bounds.height - location.y)
                    if !isInside(point) {
                        Task { @MainActor in onOutside() }
                    }
                }
            }
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

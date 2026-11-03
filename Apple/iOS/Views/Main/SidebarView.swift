import SwiftUI

/// iPad sidebar: All plus each category (long-press to rename or delete, drag to reorder, "new" at the end), with Settings and Lock
/// at the bottom.
struct SidebarView: View {
    @Environment(MobileVaultStore.self) private var store
    @Environment(AddFlowController.self) private var flow
    @State private var namePrompt: CategoryNamePrompt?
    @State private var pendingDeletion: AccountCategory?

    var body: some View {
        @Bindable var store = store
        List(selection: Binding<VaultSection?>(get: { store.section }, set: { store.section = $0 ?? .all })) {
            Section {
                sectionRow(L10n.tr("All"), systemImage: "tray.full", count: store.accounts.count)
                    .tag(VaultSection.all)
            }
            Section(L10n.tr("Categories")) {
                ForEach(store.categories) { category in
                    sectionRow(category.name, systemImage: "folder", count: category.accountIDs.count)
                        .tag(VaultSection.category(category.id))
                        .contextMenu {
                            Button {
                                namePrompt = .rename(category)
                            } label: {
                                Label(L10n.tr("Rename"), systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                pendingDeletion = category
                            } label: {
                                Label(L10n.tr("Delete Category"), systemImage: "trash")
                            }
                        }
                }
                .onMove { store.moveCategories(fromOffsets: $0, toOffset: $1) }
                Button {
                    namePrompt = .new(addingAccount: nil)
                } label: {
                    Label(L10n.tr("New Category"), systemImage: "plus")
                }
            }
        }
        .navigationTitle(Text(verbatim: "Kakey"))
        .categoryNamePrompt($namePrompt)
        .categoryDeleteConfirmation($pendingDeletion)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    flow.present(.settings)
                } label: {
                    Label(L10n.tr("Settings"), systemImage: "gearshape")
                }
                Spacer()
                Button {
                    store.lock()
                } label: {
                    Label(L10n.tr("Lock Now"), systemImage: "lock")
                }
            }
        }
    }

    private func sectionRow(_ title: String, systemImage: String, count: Int) -> some View {
        Label {
            HStack {
                Text(title).lineLimit(1)
                Spacer()
                Text(verbatim: "\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

import SwiftUI

/// Category name input: create (optionally adding an account to it right away) or rename. An invalid name shows the reason in a
/// toast and closes the field.
enum CategoryNamePrompt: Identifiable, Equatable {
    case new(addingAccount: Account.ID?)
    case rename(AccountCategory)

    var id: String {
        switch self {
        case .new(let account): "new-\(account?.uuidString ?? "")"
        case .rename(let category): "rename-\(category.id.uuidString)"
        }
    }
}

extension View {
    /// Attaches a category name input; it appears when `prompt` becomes non-nil.
    func categoryNamePrompt(_ prompt: Binding<CategoryNamePrompt?>) -> some View {
        modifier(CategoryNamePromptModifier(prompt: prompt))
    }
}

private struct CategoryNamePromptModifier: ViewModifier {
    @Environment(MobileVaultStore.self) private var store
    @Binding var prompt: CategoryNamePrompt?
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert(
                title,
                isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }),
                presenting: prompt
            ) { prompt in
                TextField(L10n.tr("Category name"), text: $name)
                Button(prompt.isNew ? L10n.tr("Create") : L10n.tr("Done")) { commit(prompt) }
                Button(L10n.tr("Cancel"), role: .cancel) {}
            }
            .onChange(of: prompt) { _, prompt in
                if case .rename(let category) = prompt { name = category.name } else { name = "" }
            }
    }

    private var title: String {
        if case .rename = prompt { return L10n.tr("Rename") }
        return L10n.tr("New Category")
    }

    private func commit(_ prompt: CategoryNamePrompt) {
        do {
            switch prompt {
            case .new(let accountID):
                let category = try store.createCategory(named: name)
                if let accountID { store.toggleAccount(accountID, in: category.id) }
            case .rename(let category):
                try store.renameCategory(category.id, to: name)
            }
        } catch {
            store.showToast(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, systemImage: "exclamationmark.triangle")
        }
    }
}

private extension CategoryNamePrompt {
    var isNew: Bool {
        if case .new = self { return true }
        return false
    }
}

/// "Add to ›" in the account's long-press menu: categories the account belongs to are checked and tapping toggles them; "New
/// Category…" at the end creates one and adds the account to it. Inside a category there is also "Remove from "X"".
struct AccountCategoryMenuItems: View {
    @Environment(MobileVaultStore.self) private var store
    var account: Account
    @Binding var namePrompt: CategoryNamePrompt?

    var body: some View {
        Menu {
            ForEach(store.categories) { category in
                Toggle(
                    category.name,
                    isOn: Binding(
                        get: { store.isAccount(account.id, in: category.id) },
                        set: { _ in store.toggleAccount(account.id, in: category.id) }
                    ))
            }
            if !store.categories.isEmpty {
                Divider()
            }
            Button {
                namePrompt = .new(addingAccount: account.id)
            } label: {
                Label(L10n.tr("New Category"), systemImage: "folder.badge.plus")
            }
        } label: {
            Label(L10n.tr("Add to"), systemImage: "folder.badge.plus")
        }
        if let category = store.sectionCategory {
            Button {
                store.toggleAccount(account.id, in: category.id)
            } label: {
                Label(L10n.format("Remove from “%@”", category.name), systemImage: "folder.badge.minus")
            }
        }
    }
}

/// Category management (reached on iPhone from the section menu): create, tap to rename, swipe left to delete, drag to reorder in
/// edit mode.
struct CategoryManagerView: View {
    @Environment(MobileVaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var namePrompt: CategoryNamePrompt?
    @State private var pendingDeletion: AccountCategory?
    /// Not the system `EditButton`: its Edit / Done labels follow the system language, not the in-app language.
    @State private var editMode: EditMode = .inactive

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.categories) { category in
                        Button {
                            namePrompt = .rename(category)
                        } label: {
                            LabeledContent {
                                Text(verbatim: "\(category.accountIDs.count)").monospacedDigit()
                            } label: {
                                Label(category.name, systemImage: "folder")
                            }
                        }
                        .foregroundStyle(.primary)
                        .swipeActions {
                            Button(role: .destructive) {
                                pendingDeletion = category
                            } label: {
                                Label(L10n.tr("Delete Category"), systemImage: "trash")
                            }
                        }
                    }
                    .onMove { store.moveCategories(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    Text(
                        L10n.tr(
                            store.categories.isEmpty
                                ? "Create a category, then long-press an account and choose Add to."
                                : "Tap a category to rename it, swipe left to delete, or tap Edit to reorder. Deleting a category keeps its accounts."
                        ))
                }
                // "New" lives in the list with a text label: the iOS 26 bottom toolbar shows icons only, which is unclear here
                Section {
                    Button {
                        namePrompt = .new(addingAccount: nil)
                    } label: {
                        Label(L10n.tr("New Category"), systemImage: "folder.badge.plus")
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle(L10n.tr("Manage Categories"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("Done")) { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if !store.categories.isEmpty {
                        Button(editMode.isEditing ? L10n.tr("Done") : L10n.tr("Edit")) {
                            withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                        }
                    }
                }
            }
            .categoryNamePrompt($namePrompt)
            .categoryDeleteConfirmation($pendingDeletion)
        }
    }
}

extension View {
    /// Confirmation before deleting a category: only the category is deleted, and the message says its accounts are kept.
    func categoryDeleteConfirmation(_ category: Binding<AccountCategory?>) -> some View {
        modifier(CategoryDeleteConfirmation(category: category))
    }
}

private struct CategoryDeleteConfirmation: ViewModifier {
    @Environment(MobileVaultStore.self) private var store
    @Binding var category: AccountCategory?

    func body(content: Content) -> some View {
        content.alert(
            L10n.format("Delete the category “%@”?", category?.name ?? ""),
            isPresented: Binding(get: { category != nil }, set: { if !$0 { category = nil } }),
            presenting: category
        ) { category in
            Button(L10n.tr("Delete Category"), role: .destructive) { store.deleteCategory(category.id) }
            Button(L10n.tr("Cancel"), role: .cancel) {}
        } message: { category in
            Text(L10n.format("The %lld accounts in it won’t be deleted and stay in All.", category.accountIDs.count))
        }
    }
}

/// Categories on the detail screen: multiple selection; checking adds the account, unchecking removes it.
struct AccountCategoryPicker: View {
    @Environment(MobileVaultStore.self) private var store
    var account: Account
    @State private var namePrompt: CategoryNamePrompt?

    var body: some View {
        List {
            Section {
                ForEach(store.categories) { category in
                    Button {
                        store.toggleAccount(account.id, in: category.id)
                    } label: {
                        HStack {
                            Label(category.name, systemImage: "folder")
                            Spacer()
                            if store.isAccount(account.id, in: category.id) {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
            Section {
                Button {
                    namePrompt = .new(addingAccount: account.id)
                } label: {
                    Label(L10n.tr("New Category"), systemImage: "folder.badge.plus")
                }
            }
        }
        .navigationTitle(L10n.tr("Categories"))
        .navigationBarTitleDisplayMode(.inline)
        .categoryNamePrompt($namePrompt)
    }
}

import SwiftUI

struct AccountListView: View {
    enum Layout {
        /// iPhone: single-column system list, swipe left to delete, drag to reorder after Edit.
        case list
        /// iPad: card grid, long-press and drag to reorder.
        case grid
    }

    @Environment(MobileVaultStore.self) private var store
    @Environment(AddFlowController.self) private var flow
    /// Decided by MainView from the window's horizontalSizeClass; inside a split view every column reports compact, so the list
    /// can't read it itself.
    var layout: Layout
    var onShowDetail: (Account.ID) -> Void
    @State private var pendingDeletion: Account?
    @State private var namePrompt: CategoryNamePrompt?
    @State private var showsCategoryManager = false
    @State private var editMode: EditMode = .inactive
    /// iPad card drag reordering: see `GridReorder`.
    @State private var reorder = GridReorder()
    @State private var gridWidth: CGFloat = 0

    /// Three columns when the card area is wide enough (iPad landscape), otherwise two; about 260 pt per card fits the name and an
    /// 8-digit code.
    private var gridColumnCount: Int {
        gridWidth >= 820 ? 3 : 2
    }

    var body: some View {
        @Bindable var store = store
        content
            .navigationTitle(layout == .grid ? sectionTitle : "Kakey")
            .navigationBarTitleDisplayMode(layout == .grid ? .automatic : .inline)
            .toolbar { toolbar }
            .modifier(SystemSearch(isEnabled: layout == .list))
            .overlay { emptyState }
            .background { keyboardShortcuts }
            .categoryNamePrompt($namePrompt)
            .sheet(isPresented: $showsCategoryManager) { CategoryManagerView() }
            #if DEBUG
                .task {
                    if DemoVault.isRequested, UserDefaults.standard.string(forKey: "KakeyDemoScreen") == "categories" {
                        showsCategoryManager = true
                    }
                }
            #endif
            .onChange(of: store.accounts.isEmpty) { _, isEmpty in
                if isEmpty { editMode = .inactive }
            }
            .alert(
                pendingDeletion.map { L10n.format("Delete “%@”?", $0.issuer) } ?? "",
                isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
            ) {
                Button(L10n.tr("Delete"), role: .destructive) {
                    if let account = pendingDeletion { store.delete(account) }
                    pendingDeletion = nil
                }
                Button(L10n.tr("Cancel"), role: .cancel) {}
            } message: {
                Text(L10n.tr("This can’t be undone. Make sure you can still sign in to this service another way."))
            }
    }

    private var sectionTitle: String {
        store.sectionCategory?.name ?? L10n.tr("All")
    }

    private var canReorder: Bool {
        store.searchText.isEmpty
    }

    @ViewBuilder
    private var content: some View {
        let accounts = store.visibleAccounts
        switch layout {
        case .list:
            List {
                ForEach(accounts) { account in
                    AccountRow(account: account)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingDeletion = account
                            } label: {
                                Label(L10n.tr("Delete"), systemImage: "trash")
                            }
                        }
                        .contextMenu { menuItems(account) }
                }
                .onMove(perform: canReorder ? { store.move(fromOffsets: $0, toOffset: $1) } : nil)
            }
            .listStyle(.plain)
            .environment(\.editMode, $editMode)
        case .grid:
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: gridColumnCount), spacing: 16) {
                    // The in-drag preview order lives only in GridReorder's memory and is saved in one go on release
                    ForEach(reorder.ordered(accounts)) { account in
                        gridCell(account)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                // The whole grid (including gaps between cards and the empty space below) is a single drop target, so releasing
                // anywhere ends the drag
                .frame(minHeight: reorder.viewportHeight, alignment: .top)
                .coordinateSpace(.named(GridReorder.space))
                .onDrop(
                    of: [GridReorder.contentType], delegate: GridReorderDropDelegate(reorder: reorder, store: store, isEnabled: canReorder))
            }
            .onGeometryChange(for: CGSize.self) {
                $0.size
            } action: {
                reorder.viewportHeight = $0.height
                gridWidth = $0.width
            }
        }
    }

    private func gridCell(_ account: Account) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return AccountRow(account: account, style: .card)
            .padding(16)
            .background(.background.secondary, in: shape)
            .contentShape(.contextMenuPreview, shape)
            .contentShape(.dragPreview, shape)
            .contextMenu { menuItems(account) }
            // Leave a faded placeholder in place; the dragged card follows the finger and the others move aside live
            .opacity(reorder.isFaded(account.id) ? 0.25 : 1)
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(GridReorder.space))
            } action: {
                reorder.frames[account.id] = $0
            }
            // Cards scrolled off screen in a lazy grid stop updating their frames; drop stale ones so swaps never target the wrong
            // card
            .onDisappear { reorder.frames[account.id] = nil }
            .onDrag { reorder.begin(account.id) }
    }

    /// Long-press menu: copy, details (the only entry point), categories, delete.
    @ViewBuilder
    private func menuItems(_ account: Account) -> some View {
        Button {
            store.copyCode(for: account)
        } label: {
            Label(L10n.tr("Copy Code"), systemImage: "doc.on.doc")
        }
        Button {
            onShowDetail(account.id)
        } label: {
            Label(L10n.tr("Account Details"), systemImage: "info.circle")
        }
        AccountCategoryMenuItems(account: account, namePrompt: $namePrompt)
        Divider()
        Button(role: .destructive) {
            pendingDeletion = account
        } label: {
            Label(L10n.tr("Delete"), systemImage: "trash")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        switch layout {
        case .list:
            if editMode.isEditing {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.tr("Done")) { withAnimation { editMode = .inactive } }
                        .fontWeight(.semibold)
                }
            }
            if !store.accounts.isEmpty {
                // iPhone: the section menu (All + each category) sits in the middle of the navigation bar, with category management
                // at the end
                ToolbarItem(placement: .principal) { sectionMenu }
            }
            // Add and More share one group on the trailing side: plus on the left, More on the right
            ToolbarItemGroup(placement: .topBarTrailing) {
                AddMenu()
                Menu {
                    Button {
                        flow.present(.settings)
                    } label: {
                        Label(L10n.tr("Settings"), systemImage: "gearshape")
                    }
                    Button {
                        store.lock()
                    } label: {
                        Label(L10n.tr("Lock Now"), systemImage: "lock")
                    }
                    if !store.accounts.isEmpty {
                        Button {
                            withAnimation { editMode = .active }
                        } label: {
                            Label(L10n.tr("Edit"), systemImage: "arrow.up.arrow.down")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .accessibilityLabel(L10n.tr("More"))
                }
            }
        case .grid:
            // Custom search field: system searchable is pinned to the right of the button group on iPad; here the field goes on
            // the left and "+" / "⋯" on the right
            ToolbarItem(placement: .topBarTrailing) {
                @Bindable var store = store
                ToolbarSearchField(text: $store.searchText)
            }
            if #available(iOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                AddMenu()
                // Settings and Lock stay reachable when the sidebar is collapsed in portrait
                Menu {
                    Button {
                        flow.present(.settings)
                    } label: {
                        Label(L10n.tr("Settings"), systemImage: "gearshape")
                    }
                    Button {
                        store.lock()
                    } label: {
                        Label(L10n.tr("Lock Now"), systemImage: "lock")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .accessibilityLabel(L10n.tr("More"))
                }
            }
        }
    }

    private var sectionMenu: some View {
        Menu {
            Picker(L10n.tr("Section"), selection: Binding(get: { store.section }, set: { store.section = $0 })) {
                Label(L10n.tr("All"), systemImage: "tray.full").tag(VaultSection.all)
                ForEach(store.categories) { category in
                    Label(category.name, systemImage: "folder").tag(VaultSection.category(category.id))
                }
            }
            Divider()
            Button {
                showsCategoryManager = true
            } label: {
                Label(L10n.tr("Manage"), systemImage: "folder.badge.gearshape")
            }
        } label: {
            HStack(spacing: 4) {
                Text(sectionTitle).font(.headline).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
            }
            .foregroundStyle(.primary)
        }
        .accessibilityLabel(L10n.tr("Section"))
    }

    /// Hardware keyboard shortcuts: ⌘N manual add, ⌘, Settings, ⌘L lock. The buttons are invisible and only register shortcuts;
    /// they also work when the sidebar is collapsed.
    private var keyboardShortcuts: some View {
        ZStack {
            Button(L10n.tr("Enter Setup Key")) { flow.present(.manual) }
                .keyboardShortcut("n", modifiers: .command)
            Button(L10n.tr("Settings")) { flow.present(.settings) }
                .keyboardShortcut(",", modifiers: .command)
            Button(L10n.tr("Lock Now")) { store.lock() }
                .keyboardShortcut("l", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.accounts.isEmpty {
            ContentUnavailableView {
                Label(L10n.tr("No 2FA accounts yet"), systemImage: "shield.lefthalf.filled")
            } description: {
                Text(L10n.tr("Scan the QR code from a service or enter its setup key. Codes are encrypted on this device."))
            } actions: {
                Button {
                    flow.present(.scanner)
                } label: {
                    Label(L10n.tr("Scan QR Code"), systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    flow.present(.manual)
                } label: {
                    Text(L10n.tr("Enter Setup Key"))
                }
            }
        } else if store.visibleAccounts.isEmpty {
            if !store.searchText.isEmpty {
                // Not `ContentUnavailableView.search`: its system text follows the system language
                ContentUnavailableView(L10n.tr("No matching accounts"), systemImage: "magnifyingglass")
            } else {
                ContentUnavailableView(
                    L10n.format("No accounts in “%@” yet", sectionTitle),
                    systemImage: "folder",
                    description: Text(L10n.tr("Long-press an account and choose Add to."))
                )
            }
        }
    }
}

/// iPhone uses the system search bar; iPad uses `ToolbarSearchField` in the toolbar.
private struct SystemSearch: ViewModifier {
    @Environment(MobileVaultStore.self) private var store
    var isEnabled: Bool

    func body(content: Content) -> some View {
        @Bindable var store = store
        if isEnabled {
            content.searchable(text: $store.searchText, prompt: L10n.tr("Search services or accounts"))
        } else {
            content
        }
    }
}

/// iPad toolbar search field: magnifying glass, text field, and a clear button when there is text; ⌘F focuses it.
private struct ToolbarSearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L10n.tr("Search services or accounts"), text: $text)
                .focused($isFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("Clear Search"))
            }
            Button(L10n.tr("Search")) { isFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .frame(width: 260)
    }
}

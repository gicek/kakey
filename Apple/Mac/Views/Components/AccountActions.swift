import SwiftUI

/// Context menu actions that need the list container to present a confirmation: deleting an account and creating a category for
/// an account. The list / card containers each host one confirmation and one text prompt instead of one per account.
@MainActor
final class AccountActionRequest: ObservableObject {
    @Published var deleting: Account?
    @Published var creatingCategoryFor: Account?
}

struct AccountIssuerTitle: View {
    var account: Account
    var fontSize: CGFloat

    var body: some View {
        Text(account.issuer)
            .font(.system(size: fontSize, weight: .semibold))
            .lineLimit(1)
    }
}

extension VaultStore {
    /// A row / card starts dragging: opens a session with the section's full order; dropping inside the drop zone saves it in one go.
    func beginAccountReorder(_ account: Account, in session: ReorderSession<Account.ID>, at start: CGPoint) {
        session.beginDrag(account.id, at: start, order: currentAccountOrderIDsForReorder()) { [weak self] order in
            self?.applyAccountOrder(order)
        }
    }

    /// Click on a row / card: runs the hover button under the pointer if any, otherwise copies the code.
    fileprivate func handleAccountTap(_ account: Account, on action: AccountHoverAction?) {
        switch action {
        case .detail: activeSheet = .detail(account)
        case nil: copyCode(for: account)
        }
    }
}

/// Context menu for managing accounts, shared by list and cards.
///
/// The `store` that rows / cards get is a plain reference that does not observe changes: a row / card redraws only when its own
/// inputs change, so copying, hovering and other state on any one account does not redraw the whole screen. Categories and
/// checkmarks in the menu come from `categories`, passed by value, so rows / cards update when categories change.
private struct AccountManagementActions: ViewModifier {
    var account: Account
    var categories: [AccountCategory]
    var sectionCategory: AccountCategory?
    let store: VaultStore
    let actionRequest: AccountActionRequest

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button {
                    store.copyCode(for: account)
                } label: {
                    Label(L10n.tr("Copy code"), systemImage: "doc.on.doc")
                }
                Menu {
                    ForEach(categories) { category in
                        Toggle(
                            category.name,
                            isOn: Binding(
                                get: { category.accountIDs.contains(account.id) },
                                set: { _ in store.toggleAccount(account.id, in: category.id) }
                            )
                        )
                    }
                    if !categories.isEmpty {
                        Divider()
                    }
                    Button(L10n.tr("New Category")) {
                        actionRequest.creatingCategoryFor = account
                    }
                } label: {
                    Label(L10n.tr("Add to"), systemImage: "folder.badge.plus")
                }
                if let sectionCategory {
                    Button {
                        store.removeAccount(account.id, from: sectionCategory.id)
                    } label: {
                        Label(L10n.format("Remove from “%@”", sectionCategory.name), systemImage: "folder.badge.minus")
                    }
                }
                Divider()
                Button {
                    store.activeSheet = .detail(account)
                } label: {
                    Label(L10n.tr("Details"), systemImage: "info.circle")
                }
                Button {
                    Task { await store.presentQRCode(for: account) }
                } label: {
                    Label(L10n.tr("Show QR Code"), systemImage: "qrcode")
                }
                Divider()
                Button(role: .destructive) {
                    actionRequest.deleting = account
                } label: {
                    Label(L10n.tr("Delete"), systemImage: "trash")
                }
            }
    }
}

/// Delete confirmation and the "New Category…" prompt (the originating account is added to the new category).
private struct AccountActionPrompts: ViewModifier {
    @ObservedObject var request: AccountActionRequest
    let store: VaultStore
    @State private var newCategoryName = ""
    @State private var newCategoryError: String?

    /// An invalid name must present the same alert again. SwiftUI accepts a new presentation only after the previous dismissal
    /// animation ends and offers no completion callback, so a short delay is the only option.
    private static let alertRepresentDelay: Duration = .milliseconds(200)

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                L10n.format("Delete “%@”?", request.deleting?.issuer ?? ""),
                isPresented: Binding(
                    get: { request.deleting != nil },
                    set: { if !$0 { request.deleting = nil } }
                ),
                titleVisibility: .visible,
                presenting: request.deleting
            ) { account in
                Button(L10n.tr("Delete"), role: .destructive) {
                    store.delete(account)
                }
                Button(L10n.tr("Cancel"), role: .cancel) {}
            }
            .alert(
                L10n.tr("New Category"),
                isPresented: Binding(
                    get: { request.creatingCategoryFor != nil },
                    set: { if !$0 { request.creatingCategoryFor = nil } }
                ),
                presenting: request.creatingCategoryFor
            ) { account in
                TextField(L10n.tr("Category name"), text: $newCategoryName)
                Button(L10n.tr("Create")) {
                    createCategory(for: account)
                }
                Button(L10n.tr("Cancel"), role: .cancel) {
                    newCategoryName = ""
                }
            } message: { account in
                Text(newCategoryError ?? L10n.format("The new category will include “%@”.", account.issuer))
            }
    }

    /// For an invalid name, presents the prompt again, keeping the entered name and explaining why.
    private func createCategory(for account: Account) {
        do {
            let category = try store.createCategory(named: newCategoryName)
            store.addAccount(account.id, to: category.id)
            newCategoryName = ""
            newCategoryError = nil
        } catch {
            newCategoryError = error.localizedDescription
            Task { @MainActor in
                try? await Task.sleep(for: Self.alertRepresentDelay)
                request.creatingCategoryFor = account
            }
        }
    }
}

extension View {
    func accountManagementActions(
        for account: Account,
        categories: [AccountCategory],
        sectionCategory: AccountCategory?,
        store: VaultStore,
        actionRequest: AccountActionRequest
    ) -> some View {
        modifier(
            AccountManagementActions(
                account: account,
                categories: categories,
                sectionCategory: sectionCategory,
                store: store,
                actionRequest: actionRequest
            ))
    }

    func accountActionPrompts(_ request: AccountActionRequest, store: VaultStore) -> some View {
        modifier(AccountActionPrompts(request: request, store: store))
    }

    /// Click dispatch for a row / card: copies the code or performs the hover button's action; exposed to accessibility as a button.
    func accountTapTarget(for account: Account, store: VaultStore) -> some View {
        modifier(AccountTapTarget(account: account, store: store))
    }
}

private enum AccountHoverAction: Hashable {
    case detail

    static let coordinateSpace = "AccountHoverActionSpace"

    /// Which hover button the click location falls on (each frame padded by 4 pt).
    static func hit(_ location: CGPoint, in frames: [AccountHoverAction: CGRect]) -> AccountHoverAction? {
        frames.first { $0.value.insetBy(dx: -4, dy: -4).contains(location) }?.key
    }
}

private struct AccountHoverActionFrameKey: PreferenceKey {
    static let defaultValue: [AccountHoverAction: CGRect] = [:]

    static func reduce(value: inout [AccountHoverAction: CGRect], nextValue: () -> [AccountHoverAction: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The outer view carries click-to-copy and drag-to-reorder, so on macOS the inner Button, onTapGesture, highPriorityGesture and
/// even onHover receive no events. Hover buttons therefore only report their frames, and clicks are dispatched here by location.
private struct AccountTapTarget: ViewModifier {
    var account: Account
    let store: VaultStore
    @State private var actionFrames: [AccountHoverAction: CGRect] = [:]

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: AccountHoverAction.coordinateSpace)
            .onPreferenceChange(AccountHoverActionFrameKey.self) { actionFrames = $0 }
            .onTapGesture(coordinateSpace: .named(AccountHoverAction.coordinateSpace)) { location in
                store.handleAccountTap(account, on: AccountHoverAction.hit(location, in: actionFrames))
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(verbatim: "\(account.issuer), \(account.username)"))
            .accessibilityHint(L10n.tr("Copy code"))
            .accessibilityAction { store.handleAccountTap(account, on: nil) }
            .accessibilityAction(named: L10n.tr("Details")) { store.handleAccountTap(account, on: .detail) }
    }
}

/// The details button that appears on hover; category, delete and other management actions are in the context menu.
/// The button has no padding so its icon lines up with the right edge of the countdown ring in cards.
struct AccountHoverActions: View {
    var account: Account
    let store: VaultStore

    var body: some View {
        HoverIconButton(systemImage: "info.circle", help: L10n.tr("Details"))
            .reportingFrame(as: .detail)
            .accessibilityAction { store.handleAccountTap(account, on: .detail) }
    }
}

/// Hover button appearance; clicks are dispatched by location in `AccountTapTarget`.
private struct HoverIconButton: View {
    var systemImage: String
    var help: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(.secondary)
            .help(help)
            .accessibilityElement()
            .accessibilityLabel(help)
            .accessibilityAddTraits(.isButton)
    }
}

private extension View {
    func reportingFrame(as action: AccountHoverAction) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: AccountHoverActionFrameKey.self,
                    value: [action: proxy.frame(in: .named(AccountHoverAction.coordinateSpace))]
                )
            }
        }
    }
}

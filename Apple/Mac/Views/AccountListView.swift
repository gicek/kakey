import SwiftUI

/// List view: each row has a badge, name, code and ring; click to copy, a details button on hover, drag to reorder.
struct AccountList: View {
    @EnvironmentObject private var store: VaultStore
    @StateObject private var reorder = ReorderSession<Account.ID>()
    @StateObject private var actionRequest = AccountActionRequest()

    private var sectionCategory: AccountCategory? {
        guard case .category(let id) = store.selectedSection else { return nil }
        return store.category(id)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(reorder.displayOrder(of: store.filteredAccounts)) { account in
                        AccountRow(
                            account: account,
                            categories: store.categories,
                            sectionCategory: sectionCategory,
                            isCopied: store.copiedAccountID == account.id,
                            isDragging: reorder.draggedID == account.id,
                            isDropTarget: reorder.dropTargetID == account.id,
                            store: store,
                            actionRequest: actionRequest
                        )
                        .equatable()
                        .id(account.id)
                        .reorderItem(account.id, session: reorder) { start in
                            store.beginAccountReorder(account, in: reorder, at: start)
                        }
                        Divider()
                            .padding(.leading, 62)
                    }
                }
                .padding(.vertical, 4)
            }
            .reorderContainer(
                session: reorder,
                autoScroll: ReorderAutoScroll(proxy: proxy, step: 2) { reorder.displayOrder(of: store.filteredAccounts).map(\.id) }
            ) { id in
                if let account = store.document.account(id) {
                    AccountDragPreview(account: account, style: .row, frozenAt: reorder.startedAt)
                }
            }
        }
        .accountActionPrompts(actionRequest, store: store)
    }
}

private struct AccountRow: View, Equatable {
    var account: Account
    var categories: [AccountCategory]
    var sectionCategory: AccountCategory?
    var isCopied: Bool
    var isDragging: Bool
    var isDropTarget: Bool
    let store: VaultStore
    let actionRequest: AccountActionRequest
    @State private var isHovered = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.account == rhs.account && lhs.categories == rhs.categories && lhs.sectionCategory == rhs.sectionCategory
            && lhs.isCopied == rhs.isCopied && lhs.isDragging == rhs.isDragging && lhs.isDropTarget == rhs.isDropTarget
    }

    var body: some View {
        HStack(spacing: 12) {
            LogoBadge(account: account, showsRecentIndicator: account.isRecentlyAdded(relativeTo: Date()))
            VStack(alignment: .leading, spacing: 2) {
                AccountIssuerTitle(account: account, fontSize: 13.5)
                Text(account.username)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            CodeWithCountdown(account: account, isCopied: isCopied, layout: .listRow)
            // The details icon sits right of the countdown. Its space is always reserved and it shows only on hover, so the code
            // and ring do not shift sideways.
            AccountHoverActions(account: account, store: store)
                .opacity(isHovered ? 1 : 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(rowFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isDropTarget ? Color.accentColor.opacity(0.42) : Color.clear, lineWidth: 1)
        }
        .opacity(isDragging ? 0 : 1)
        .padding(.horizontal, 8)
        .animation(.snappy(duration: 0.18), value: isDragging)
        .animation(.snappy(duration: 0.18), value: isDropTarget)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accountTapTarget(for: account, store: store)
        .accountManagementActions(
            for: account,
            categories: categories,
            sectionCategory: sectionCategory,
            store: store,
            actionRequest: actionRequest
        )
    }

    private var rowFill: Color {
        if isDropTarget { return Color.accentColor.opacity(0.08) }
        return isHovered ? Color.primary.opacity(0.04) : .clear
    }
}

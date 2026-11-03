import SwiftUI

/// Card view: adaptive column count (cards at least 210 pt wide), countdown ring and code on one row; click to copy, drag to reorder.
struct AccountCardGrid: View {
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                    ForEach(reorder.displayOrder(of: store.filteredAccounts)) { account in
                        AccountCard(
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
                    }
                }
                .padding(16)
            }
            .reorderContainer(
                session: reorder,
                autoScroll: ReorderAutoScroll(proxy: proxy, step: 3) { reorder.displayOrder(of: store.filteredAccounts).map(\.id) }
            ) { id in
                if let account = store.document.account(id) {
                    AccountDragPreview(account: account, style: .card, frozenAt: reorder.startedAt)
                }
            }
        }
        .accountActionPrompts(actionRequest, store: store)
    }
}

private struct AccountCard: View, Equatable {
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                LogoBadge(account: account, size: 30, showsRecentIndicator: account.isRecentlyAdded(relativeTo: Date()))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        AccountIssuerTitle(account: account, fontSize: 13.5)
                        Spacer(minLength: 0)
                        if isHovered {
                            AccountHoverActions(account: account, store: store)
                        }
                    }
                    Text(account.username)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(height: 30)
            CodeWithCountdown(account: account, isCopied: isCopied, layout: .card)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(isHovered && !isDropTarget ? 0.03 : 0))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isDropTarget ? Color.accentColor.opacity(0.58) : Color(nsColor: .separatorColor).opacity(isHovered ? 0.9 : 0.5),
                    lineWidth: isDropTarget ? 1.4 : 1
                )
        }
        .opacity(isDragging ? 0 : 1)
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
}

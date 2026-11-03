import SwiftUI

/// The stand-in that follows the pointer while reordering: renders the code statically as of the session start, without a
/// timeline. Its size comes from `reorderContainer`, using the dragged row / card's actual frame; the session draws it itself
/// rather than using a system drag image.
struct AccountDragPreview: View {
    enum Style {
        case row
        case card
    }

    var account: Account
    var style: Style
    var frozenAt: Date

    var body: some View {
        Group {
            switch style {
            case .row:
                rowPreview
            case .card:
                cardPreview
            }
        }
        .allowsHitTesting(false)
    }

    private var rowPreview: some View {
        HStack(spacing: 12) {
            LogoBadge(account: account, showsRecentIndicator: account.isRecentlyAdded(relativeTo: frozenAt))
            VStack(alignment: .leading, spacing: 2) {
                AccountIssuerTitle(account: account, fontSize: 13.5)
                Text(account.username)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            CodeWithCountdown(account: account, isCopied: false, layout: .listRow, frozenAt: frozenAt)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        // Rows have an 8 pt inset on each side; the stand-in keeps it so its background lines up with the original row.
        .padding(.horizontal, 8)
    }

    private var cardPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                LogoBadge(account: account, size: 30, showsRecentIndicator: account.isRecentlyAdded(relativeTo: frozenAt))
                VStack(alignment: .leading, spacing: 2) {
                    AccountIssuerTitle(account: account, fontSize: 13.5)
                    Text(account.username)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 30)
            CodeWithCountdown(account: account, isCopied: false, layout: .card, frozenAt: frozenAt)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5))
        }
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

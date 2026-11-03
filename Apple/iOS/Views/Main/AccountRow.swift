import SwiftUI

/// Account row shared by the iPhone list and the iPad cards: service badge, name, verification code, and countdown; tapping anywhere
/// copies the code. Cards are only half the screen wide, so the name and code sit on separate lines and the code never squeezes
/// out the name.
struct AccountRow: View {
    enum Style {
        case row
        case card
    }

    @Environment(MobileVaultStore.self) private var store
    var account: Account
    var style: Style = .row

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = TOTPService.secondsRemaining(for: account, date: context.date)
            let code = CodeText(code: TOTPService.code(for: account, date: context.date), urgent: remaining <= 5)
            let ring = CountdownRing(progress: TOTPService.progress(for: account, date: context.date), secondsRemaining: remaining)
            Group {
                switch style {
                case .row:
                    HStack(spacing: 12) {
                        MonogramBadge(issuer: account.issuer, size: 42)
                        names.layoutPriority(-1)
                        Spacer(minLength: 8)
                        code
                        ring
                    }
                    .padding(.vertical, 6)
                case .card:
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            MonogramBadge(issuer: account.issuer, size: 40)
                            names
                            Spacer(minLength: 0)
                        }
                        HStack {
                            code
                            Spacer(minLength: 8)
                            ring
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { store.copyCode(for: account) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { store.copyCode(for: account) }
            .accessibilityHint(L10n.format("Copy code for %@", account.issuer))
        }
    }

    private var names: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(account.issuer).font(.headline).lineLimit(1)
            Text(account.username).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

import SwiftUI

/// Empty states for the menu bar panel: onboarding not finished, no accounts yet, selected category empty, no search results.
struct MenuBarSetupState: View {
    var openMainWindow: () -> Void

    var body: some View {
        VStack(spacing: 13) {
            Image(nsImage: KakeyAssets.appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 58, height: 58)

            VStack(spacing: 5) {
                Text(L10n.tr("Get started with Kakey"))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(L10n.tr("Create a vault or restore a backup in the main window."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 220)
            }

            Button(L10n.tr("Open Main Window"), action: openMainWindow)
                // Neutral gray button: it is the only action in the panel and does not need the accent color to stand out.
                .buttonStyle(.bordered)
                .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MenuBarEmptyVaultState: View {
    var body: some View {
        VStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: 58, height: 58)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 1)
                    .frame(width: 58, height: 58)
                Image(systemName: "lock.shield")
                    .font(.system(size: 26, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 5) {
                Text(L10n.tr("No 2FA accounts yet"))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(L10n.tr("After you add accounts, your codes will appear here securely."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 220)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MenuBarEmptyCategoryState: View {
    var name: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.secondary)
            Text(L10n.format("No accounts in “%@” yet", name))
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(L10n.tr("In the main window, right-click an account and choose Add to."))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MenuBarEmptySearchState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 25, weight: .light))
            Text(L10n.tr("No matching accounts"))
                .font(.system(size: 12))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

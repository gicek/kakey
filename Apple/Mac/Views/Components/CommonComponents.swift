import SwiftUI

struct LogoBadge: View {
    var account: Account
    var size: CGFloat = 34
    var showsRecentIndicator = false

    private var indicatorSize: CGFloat {
        min(8, max(5.5, size * 0.22))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text(account.monogram)
                .font(.system(size: size > 38 ? 17 : 12, weight: .semibold))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.58)
                .lineLimit(1)
                .frame(width: size, height: size)
                .background(account.color, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))

            if showsRecentIndicator {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: indicatorSize, height: indicatorSize)
                    .overlay {
                        Circle()
                            .strokeBorder(.white, lineWidth: 1.5)
                    }
                    .offset(x: -1, y: -1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct CodeRing: View {
    var progress: Double
    var isLow: Bool
    var size: CGFloat = 28

    // Deliberately no implicit animation: a per-second trim animation makes every ring redraw continuously at the display refresh
    // rate, and N rings in a list pushed idle CPU to 40%+. A discrete step each second is enough.
    var body: some View {
        ZStack {
            Circle()
                .stroke(.separator.opacity(0.7), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(isLow ? .red : Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .accessibilityLabel(L10n.tr("Code countdown"))
    }
}

/// Strength meter with one line of text below. When `problem` is non-nil, that line becomes a red rule hint (too short, too easy to
/// guess), so the error stays with the field instead of adding a separate block that pushes the content below.
struct StrengthMeter: View {
    var strength: PasswordStrength
    var problem: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 3) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(index < strength.rawValue ? color : Color.secondary.opacity(0.18))
                        .frame(height: 4)
                }
            }
            Text(problem ?? strength.label)
                .font(.system(size: 11))
                .foregroundStyle(problem == nil ? labelColor : .red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var color: Color {
        switch strength {
        case .empty: .secondary.opacity(0.18)
        case .weak: .red
        case .fair, .good: .orange
        case .strong: .green
        }
    }

    private var labelColor: Color {
        switch strength {
        case .weak: .red
        case .fair, .good: .orange
        case .strong: .green
        default: .secondary
        }
    }
}

struct EmptyStateView: View {
    var title: String
    var systemImage: String = "magnifyingglass"
    var message: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .light))
            Text(title)
                .font(.system(size: 13))
            if let message {
                Text(message)
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyVaultStateView: View {
    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: 78, height: 78)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 1)
                    .frame(width: 78, height: 78)
                Image(systemName: "lock.shield")
                    .font(.system(size: 34, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 7) {
                Text(L10n.tr("No 2FA accounts yet"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(L10n.tr("After you add accounts, your codes are encrypted on this Mac and shown only after unlock."))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 360)
            }
        }
        .padding(.bottom, 42)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Whether the confirmation matches (shared by creating a vault in onboarding and setting a separate master password).
/// No message while the new password is being edited, or while the confirmation is still a prefix of the new password (not done
/// typing); one wrong character shows the message immediately, and so does an incomplete confirmation after leaving the field.
/// Callers make sure the new password itself is valid first.
enum PasswordConfirmation {
    static func problem(password: String, confirm: String, isEditingPassword: Bool, isEditingConfirm: Bool) -> String? {
        guard !isEditingPassword, !password.isEmpty, !confirm.isEmpty, password != confirm else { return nil }
        if isEditingConfirm, password.hasPrefix(confirm) { return nil }
        return L10n.tr("Passwords do not match")
    }
}

/// One red validation line under a field (such as passwords not matching). It reserves its line height even when empty, so content
/// below does not jump as it appears and disappears.
struct FieldMessage: View {
    var text: String?

    var body: some View {
        Text(text ?? " ")
            .font(.system(size: 11))
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .opacity(text == nil ? 0 : 1)
            .accessibilityHidden(text == nil)
    }
}

/// One inline notice with an icon (error, warning, info), shared by onboarding, change master password, backup and cloud connection.
struct InlineNotice: View {
    var text: String
    var systemImage: String
    var tint: Color
    /// Optional trailing button (for example "Choose Folder" when no backup was found).
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        // The trailing button is taller than the text, so the row is centered vertically.
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 16, height: 16)
                    .padding(.top, 1)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(PressableButtonStyle(prominence: .link))
                    .fixedSize()
            }
        }
        .padding(12)
        .background(tint.opacity(0.085), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// The eye button that shows / hides secret text, shared by password and secret fields. `isRevealed` only drives the icon and help
/// text; the toggle action comes from the caller (revealing a secret in account details requires authentication first).
struct RevealSecretButton: View {
    var isRevealed: Bool
    var showTitle = L10n.tr("Show")
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isRevealed ? "eye.slash" : "eye")
        }
        .buttonStyle(PressableButtonStyle(prominence: .icon))
        .help(title)
        .accessibilityLabel(title)
    }

    private var title: String {
        isRevealed ? L10n.tr("Hide") : showTitle
    }
}

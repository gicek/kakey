import SwiftUI

/// Onboarding task panel: back arrow above the title, title, description, content and the bottom button row.
/// The top of the panel (the back arrow) aligns with the sidebar graphic, and the button row sits level with the security points at
/// the bottom of the sidebar.
struct OnboardingTaskPanel<Content: View, Footer: View>: View {
    var title: String
    var description: String
    var onBack: () -> Void
    var isBackDisabled = false
    @ViewBuilder var footer: () -> Footer
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                OnboardingBackButton(action: onBack)
                    .disabled(isBackDisabled)
                    // The arrow itself aligns with the title's left edge; the hover background extends outward.
                    .padding(.leading, -9)
                    .padding(.bottom, 2)

                Text(title)
                    .font(.system(size: 27, weight: .semibold))
                Text(description)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 24)

            // Scrolls only when the content does not fit (larger system text, longer translations); the button row stays visible.
            // 4 pt on each side leaves room for the fields' focus ring so the scroll view does not clip it.
            // The scroll view takes clicks first, so the outer "click empty space to end editing" never sees them: the content
            // fills at least the visible height, and the handler is attached again behind it.
            GeometryReader { proxy in
                ScrollView(.vertical) {
                    content()
                        .padding(.horizontal, 4)
                        .padding(.bottom, 4)
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
                        .resignsFocusOnBackgroundClick()
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .padding(.horizontal, -4)

            footer()
                .padding(.top, 18)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Back arrow above the task panel title: a circular background on hover, darker when pressed.
private struct OnboardingBackButton: View {
    var action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.left")
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(BackButtonStyle(isHovered: isHovered && isEnabled))
        .onHover { isHovered = $0 }
        .help(L10n.tr("Back"))
        .accessibilityLabel(L10n.tr("Back"))
    }

    private struct BackButtonStyle: ButtonStyle {
        var isHovered: Bool
        @Environment(\.isEnabled) private var isEnabled

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.secondary.opacity(0.6)))
                .background(
                    Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : isHovered ? 0.08 : 0))
                )
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// Onboarding bottom button row: primary button on the right.
struct OnboardingActionRow<Leading: View, Primary: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var primary: () -> Primary

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            leading()
            Spacer(minLength: 20)
            primary()
        }
        .frame(minHeight: 42)
    }
}

/// A note left of the bottom buttons about the consequences of forgetting the master password. Shared by every place that sets a new
/// master password (creating a vault, restoring from an export file with a separate master password). It sits next to the button so
/// it is seen right before clicking, without taking a block of its own.
struct OnboardingForgetPasswordNote: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.orange)
            Text(L10n.tr("If you forget your master password, this device and your backups can’t be decrypted."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension OnboardingActionRow where Leading == EmptyView {
    init(@ViewBuilder primary: @escaping () -> Primary) {
        self.init(leading: { EmptyView() }, primary: primary)
    }
}

/// Toggle card for enabling Touch ID. When Touch ID is unavailable it shows as off and disabled, but does not rewrite
/// `store.touchIDEnabled` (every unlock path checks "enabled && available", so keeping the preference is enough). Availability is
/// re-checked when the app becomes active, so it also recovers while this page is showing.
struct OnboardingTouchIDToggle: View {
    @EnvironmentObject private var store: VaultStore

    private var isTouchIDAvailable: Bool { store.biometricsAvailable }

    var body: some View {
        Toggle(isOn: isTouchIDAvailable ? $store.touchIDEnabled : .constant(false)) {
            HStack(alignment: .top, spacing: 13) {
                // The icon frame matches the "Backup found" card's size and padding, so the icons of the two cards line up.
                Image(systemName: "touchid")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.pink)
                    .frame(width: 38, height: 38)
                    .background(Color.pink.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("Unlock with Touch ID"))
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(
                        isTouchIDAvailable
                            ? L10n.tr("You can always unlock with your master password.")
                            : L10n.tr("Touch ID is unavailable or not enrolled on this Mac.")
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                }
            }
            // Fill the available width to align with the password field above, instead of shrinking with the description length.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .disabled(!isTouchIDAvailable)
        .opacity(isTouchIDAvailable ? 1 : 0.55)
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45))
        }
    }
}

/// The two choice cards on the welcome page. `isSelected` highlights the recommended default; the parent decides when to drop it.
struct OnboardingChoiceCard: View {
    var icon: String
    var title: String
    var subtitle: String
    var tint: Color
    var isSelected: Bool
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 10)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: isSelected ? 1.4 : 1)
            }
            .shadow(color: shadowColor, radius: isHovered ? 14 : 8, x: 0, y: isHovered ? 7 : 4)
            .scaleEffect(isHovered ? 1.01 : 1)
            .animation(.easeOut(duration: 0.14), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var borderColor: Color {
        if isSelected {
            return Color.accentColor.opacity(isHovered ? 0.78 : 0.55)
        }
        return isHovered ? tint.opacity(0.48) : Color(nsColor: .separatorColor).opacity(0.42)
    }

    private var shadowColor: Color {
        if isSelected {
            return Color.accentColor.opacity(isHovered ? 0.14 : 0.08)
        }
        return .black.opacity(isHovered ? 0.10 : 0.045)
    }
}

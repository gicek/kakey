import SwiftUI

enum OnboardingStep {
    case welcome
    case create
    case restore
}

/// First run: brand and security points on the left; on the right the welcome page (new user / returning user) -> set a master
/// password or restore from a backup location.
struct OnboardingView: View {
    @State private var step: OnboardingStep = .welcome
    /// Cloud storage connections authorized during first-run restore; memory only, released with onboarding.
    @State private var restoreConnections = RestoreCloudConnections()
    @State private var didInteractWithWelcomeChoices = false

    var body: some View {
        HStack(spacing: 0) {
            onboardingSidebar
            Divider()
            onboardingContent
        }
        // Clicking the sidebar, title or empty space on the right also ends editing, triggering "validate after leaving the field".
        .resignsFocusOnBackgroundClick()
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var onboardingSidebar: some View {
        ZStack {
            SidebarMaterial()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    OnboardingVaultGraphic()

                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: "Kakey")
                            .font(.system(size: 25, weight: .semibold))
                        Text(L10n.tr("Secure, modern 2FA that stays in sync across all your devices."))
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 50)

                Spacer()

                // Security points: one per line with aligned icons, rather than packed into one paragraph.
                VStack(alignment: .leading, spacing: 11) {
                    securityPoint("hand.raised", L10n.tr("Built for privacy and security"))
                    securityPoint("key", L10n.tr("Your password is never saved"))
                    securityPoint("lock.shield", L10n.tr("End-to-end encrypted storage"))
                }
                .padding(.bottom, 28)
            }
            .padding(.horizontal, 28)
        }
        .frame(width: 292)
    }

    private func securityPoint(_ systemImage: String, _ text: String) -> some View {
        Label {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.accentColor)
                // Fixed icon frame: tall symbols such as the key do not make their line taller, so all three lines are evenly spaced.
                .frame(width: 18, height: 14)
        }
        .labelStyle(SecurityPointLabelStyle())
    }

    /// The welcome page is centered vertically in the content area; the create and restore steps align their top with the sidebar
    /// graphic (both at 50) and their bottom with the sidebar's security points.
    /// Page changes are not animated; otherwise the content would slide between centered and top-aligned.
    private var onboardingContent: some View {
        Group {
            switch step {
            case .welcome:
                welcomeStep
            case .create:
                OnboardingCreateStep(onBack: { step = .welcome })
            case .restore:
                OnboardingRestoreStep(connections: restoreConnections, onBack: { step = .welcome })
            }
        }
        .frame(width: 520)
        .padding(.top, step == .welcome ? 24 : 50)
        .padding(.bottom, step == .welcome ? 24 : 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: step == .welcome ? .center : .top)
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("Protect your 2FA with Kakey"))
                    .font(.system(size: 30, weight: .semibold))
                Text(L10n.tr("End-to-end encrypted, effortless to use, and ready on every device you own."))
                    .font(.system(size: 14.5))
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                OnboardingChoiceCard(
                    icon: "plus.circle.fill",
                    title: L10n.tr("Start fresh"),
                    subtitle: L10n.tr("Set a master password to get started."),
                    tint: .accentColor,
                    isSelected: !didInteractWithWelcomeChoices
                ) {
                    step = .create
                }
                .onHover(perform: noteWelcomeChoiceHover)

                OnboardingChoiceCard(
                    icon: "icloud.and.arrow.down.fill",
                    title: L10n.tr("Restore a backup"),
                    subtitle: L10n.tr("From iCloud, a folder or a cloud service."),
                    tint: .green,
                    isSelected: false
                ) {
                    step = .restore
                }
                .onHover(perform: noteWelcomeChoiceHover)
            }
        }
    }

    /// "Start Fresh" is highlighted as recommended by default; the highlight goes away once the pointer touches either card.
    private func noteWelcomeChoiceHover(_ isHovered: Bool) {
        if isHovered {
            didInteractWithWelcomeChoices = true
        }
    }
}

/// A security point line: fixed-size icon and text centered vertically, with fixed spacing.
private struct SecurityPointLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 9) {
            configuration.icon
            configuration.title
        }
    }
}

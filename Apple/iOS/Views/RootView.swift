import SwiftUI

struct RootView: View {
    @Environment(MobileVaultStore.self) private var store

    var body: some View {
        ZStack {
            switch store.phase {
            case .onboarding:
                OnboardingView()
                    .transition(.opacity)
            case .locked:
                LockView()
                    .transition(.opacity)
            case .unlocked:
                MainView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.phase)
        .overlay(alignment: .bottom) { ToastHost() }
    }
}

/// Privacy cover shown in the app switcher and in the background; `PrivacyCoverController` hosts it in a separate high-level window.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            BrandMark(size: 96)
        }
        .ignoresSafeArea()
    }
}

/// Toast at the bottom that dismisses itself after 1.6 seconds.
private struct ToastHost: View {
    @Environment(MobileVaultStore.self) private var store

    var body: some View {
        if let toast = store.toast {
            Label(toast.message, systemImage: toast.systemImage)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
                .task(id: toast.id) {
                    try? await Task.sleep(for: .seconds(1.6))
                    withAnimation { if store.toast?.id == toast.id { store.toast = nil } }
                }
                .accessibilityAddTraits(.isStaticText)
        }
    }
}

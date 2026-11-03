import SwiftUI

/// Main window root view: hosts the sheets; content switches between onboarding, locked and unlocked.
struct RootView: View {
    @EnvironmentObject private var store: VaultStore

    var body: some View {
        MainWindowView()
            .sheet(item: $store.activeSheet) { sheet in
                switch sheet {
                case .onboarding:
                    EmptyView()
                case .addAccount:
                    AddAccountView()
                        .frame(width: 620)
                case .detail(let account):
                    AccountDetailView(account: account)
                        .frame(width: 540)
                case .accountQRCode(let account):
                    AccountQRCodeView(account: account)
                        .frame(width: 420)
                case .backupSync:
                    BackupSyncView()
                        .frame(width: 640)
                case .exportImport:
                    ExportImportView()
                        .frame(width: 660)
                case .changePassword:
                    ChangePasswordView()
                        .frame(width: 460)
                }
            }
    }
}

struct MainWindowView: View {
    @EnvironmentObject private var store: VaultStore

    var body: some View {
        Group {
            if !store.hasCompletedOnboarding {
                OnboardingView()
                    .immersiveWindowChrome()
                    .transition(.opacity)
            } else if store.showsMainWindowLockScreen {
                LockOverlay()
                    .immersiveWindowChrome()
            } else {
                unlockedContent
            }
        }
        .animation(.easeOut(duration: 0.18), value: store.isLocked)
        .animation(.easeOut(duration: 0.18), value: store.isMainWindowUnlockRevealSuspended)
    }

    private var unlockedContent: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
        } detail: {
            MainContentView()
        }
        .transition(.opacity)
    }
}

extension View {
    /// Immersive main window pages (onboarding, lock screen): no title, a transparent title bar without a separator, and traffic
    /// lights floating over the content. Declared only with SwiftUI toolbar modifiers, so they are undone when the view goes away and
    /// the unlocked NavigationSplitView gets the standard title bar back; the window is not changed from AppKit (SwiftUI would revert
    /// it on update). Extending the content under the title bar is done at the `KakeyApp` root, which ignores the safe area based on
    /// `showsImmersiveMainWindow`.
    func immersiveWindowChrome() -> some View {
        modifier(ImmersiveWindowChrome())
    }
}

private struct ImmersiveWindowChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .toolbar(removing: .title)
                .toolbarBackground(.hidden, for: .windowToolbar)
        } else {
            // macOS 14 has no `toolbar(removing: .title)`: an empty navigation title is not shown either, and the scene title comes
            // back when the view goes away.
            content
                .navigationTitle("")
                .toolbarBackground(.hidden, for: .windowToolbar)
        }
    }
}

import SwiftUI

@main
struct KakeyMobileApp: App {
    @UIApplicationDelegateAdaptor(KakeyMobileAppDelegate.self) private var appDelegate
    @State private var store: MobileVaultStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
            DemoVault.prepareIfRequested()
        #endif
        let store = MobileVaultStore.makeForApp()
        _store = State(initialValue: store)
        KakeyMobileAppDelegate.store = store
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .preferredColorScheme(store.preferences.appearance.colorScheme)
                .environment(\.locale, L10n.locale)
                // Changing the UI language rebuilds the whole view tree so every L10n.tr is evaluated again
                .id(store.preferences.language)
                // Callback from the official Dropbox app after authorization (`db-<app key>://1/connect`)
                .onOpenURL { DropboxAppCallbacks.deliver($0) }
                // Any touch or key press in the window counts as activity and restarts the auto-lock timer
                .background(UserActivityObserver { store.noteUserActivity() })
                // Lock immediately when the device locks (only sent when a device passcode is set) instead of waiting for idle
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) {
                    _ in store.lock()
                }
                #if DEBUG
                    .task { await DemoVault.unlockIfRequested(store) }
                #endif
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            // Re-check auto-lock on returning to the foreground: the process is suspended in the background, so a lock that came
            // due must be applied here
            if newPhase == .active, oldPhase == .background || oldPhase == .inactive {
                store.willEnterForeground()
            }
            updatePrivacyCover()
        }
        .onChange(of: store.phase) { updatePrivacyCover() }
    }

    /// When unlocked, entering the app switcher (inactive) or background covers all content (including sheets) with a separate
    /// window. The lock screen has nothing sensitive and is not covered, which avoids flicker during the Face ID prompt.
    private func updatePrivacyCover() {
        PrivacyCoverController.shared.setCovered(scenePhase != .active && store.phase == .unlocked)
    }
}

/// Handles only silent pushes for the iCloud backup: wakes the app to sync when another device changed the backup (see
/// docs/SECURITY.md).
final class KakeyMobileAppDelegate: NSObject, UIApplicationDelegate {
    @MainActor static weak var store: MobileVaultStore?

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async
        -> UIBackgroundFetchResult
    {
        guard ICloudVault.isVaultChange(userInfo), let store = Self.store else { return .noData }
        return await store.iCloudBackupDidChange() ? .newData : .noData
    }
}

/// Attaches a listen-only gesture recognizer to the window: it calls back when a touch begins or a hardware key is pressed, then
/// immediately fails, so it never cancels or delays touches and never competes with other gestures. Sheets and popover menus share
/// the window and are covered too; the system keyboard is in its own window and is not seen.
private struct UserActivityObserver: UIViewRepresentable {
    let onActivity: @MainActor () -> Void

    func makeUIView(context: Context) -> HostView {
        HostView(onActivity: onActivity)
    }

    func updateUIView(_ view: HostView, context: Context) {
        view.recognizer.onActivity = onActivity
    }

    final class HostView: UIView {
        let recognizer: ActivityRecognizer

        init(onActivity: @escaping @MainActor () -> Void) {
            recognizer = ActivityRecognizer(onActivity: onActivity)
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            recognizer.view?.removeGestureRecognizer(recognizer)
            newWindow?.addGestureRecognizer(recognizer)
        }
    }

    final class ActivityRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
        var onActivity: @MainActor () -> Void

        init(onActivity: @escaping @MainActor () -> Void) {
            self.onActivity = onActivity
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            delegate = self
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            onActivity()
            state = .failed
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            onActivity()
            state = .failed
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer)
            -> Bool
        {
            true
        }
    }
}

extension AppearanceMode {
    var colorScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }
}

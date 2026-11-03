import SwiftUI

@MainActor
enum KakeyAssets {
    /// Loaded once and cached; view bodies read it often and must not decode it every time.
    static let appIcon: NSImage = {
        if let icon = NSImage(named: "AppIcon") {
            return icon
        }

        return NSImage(systemSymbolName: "lock.shield", accessibilityDescription: "Kakey")
            ?? NSImage(size: NSSize(width: 128, height: 128))
    }()

    static let menuBarIcon: NSImage = {
        let pointSize = NSSize(width: 18, height: 18)

        let image =
            NSImage(named: "Kakey-menubar-template")
            ?? NSImage(systemSymbolName: "lock.shield", accessibilityDescription: "Kakey")
            ?? NSImage(size: pointSize)
        image.isTemplate = true
        image.size = pointSize
        return image
    }()
}

enum KakeySingleInstance {
    static func activateExistingInstanceIfNeeded() -> Bool {
        let currentProcessID = ProcessInfo.processInfo.processIdentifier

        if let bundleIdentifier = Bundle.main.bundleIdentifier,
            let existingApp =
                NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleIdentifier)
                .first(where: { $0.processIdentifier != currentProcessID && !$0.isTerminated })
        {
            existingApp.activate(options: [.activateAllWindows])
            return true
        }

        guard let currentExecutableURL = Bundle.main.executableURL?.standardizedFileURL else {
            return false
        }

        if let existingApp = NSWorkspace.shared.runningApplications.first(where: { app in
            app.processIdentifier != currentProcessID
                && !app.isTerminated
                && app.executableURL?.standardizedFileURL == currentExecutableURL
        }) {
            existingApp.activate(options: [.activateAllWindows])
            return true
        }

        return false
    }
}

@MainActor
enum AppTerminationController {
    static func terminate(_ application: NSApplication = .shared) {
        NotificationCenter.default.post(name: .kakeyWillTerminate, object: nil)
        _ = dismissAttachedSheets(in: application)
        // Terminate on the next run loop pass: SwiftUI dismisses the sheet when it commits this pass.
        RunLoop.main.perform {
            MainActor.assumeIsolated {
                application.terminate(nil)
            }
        }
    }

    static func prepareForTermination(_ application: NSApplication = .shared) {
        _ = dismissAttachedSheets(in: application)
    }

    static func dismissAttachedSheets(in application: NSApplication) -> Bool {
        var dismissedSheets = false
        application.stopModal(withCode: .cancel)
        for window in application.windows {
            while let sheet = window.attachedSheet {
                dismissedSheets = true
                window.endSheet(sheet, returnCode: .cancel)
                sheet.close()
            }
            if window.isSheet {
                dismissedSheets = true
                window.sheetParent?.endSheet(window, returnCode: .cancel)
                window.close()
            }
        }
        return dismissedSheets
    }
}

extension Notification.Name {
    static let kakeyWillTerminate = Notification.Name("kakeyWillTerminate")
}

/// Records when the process launched so `CopyCodeCommand` can tell whether this launch was a cold launch triggered by Alfred's
/// `copy code`. If so, the main window is minimized to the Dock before the Touch ID prompt, so the user never sees the full main
/// window pop up; an instance that was already running leaves its main window as is and does not disturb what the user is doing.
/// Uptime is used rather than the event type because the Apple Event of a custom Cocoa Scripting command is delivered only after
/// the app finishes launching and registers its scripting handlers, when `applicationDidFinishLaunching` can no longer tell what
/// triggered the launch.
@MainActor
enum AppLaunchInfo {
    private static var launchUptime: TimeInterval?

    static func markLaunched() {
        if launchUptime == nil {
            launchUptime = ProcessInfo.processInfo.systemUptime
        }
    }

    static var wasJustLaunched: Bool {
        guard let launchUptime else { return false }
        return ProcessInfo.processInfo.systemUptime - launchUptime < 3
    }

    /// "Launch to menu bar only" must close more than the one window SwiftUI's WindowGroup creates by default during a cold launch:
    /// AppKit separately restores the windows open at the last quit from the `NSWindow Frame main-AppWindow-1` autosave record,
    /// through an entirely different creation path, so blocking only the first `onOpen` is not enough. Instead it uses a time window:
    /// every `onOpen` within 3 seconds of launch is closed (the same threshold as `wasJustLaunched`, consistent with the Alfred
    /// cold-launch fallback), and only later manual reopening of the main window goes through.
    static func shouldSuppressWindowOpen(launchMinimized: Bool) -> Bool {
        launchMinimized && wasJustLaunched
    }
}

final class KakeyAppDelegate: NSObject, NSApplicationDelegate {
    private var isDuplicateInstance = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        isDuplicateInstance = KakeySingleInstance.activateExistingInstanceIfNeeded()
        if isDuplicateInstance {
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isDuplicateInstance else { return }
        AppLaunchInfo.markLaunched()
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleQuitAppleEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEQuitApplication)
        )
        NSApp.applicationIconImage = KakeyAssets.appIcon
        // Launching to the menu bar only: do not force regular / activate; keep the policy `VaultStore` already computed from
        // dockIconMode (the main window has never opened), so the app does not steal focus or show a Dock icon.
        if !VaultStore.isLaunchMinimized(in: UserDefaults.standard) {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        // Fallback: on a cold launch by an Apple Event (such as Alfred's copy code command), SwiftUI's WindowGroup does not create the
        // default window as in a normal launch, so `AppShortcutIntegrationView.onAppear` never fires and the menu bar icon never
        // appears. Configure once here directly with `VaultStore.shared`. `configureIfNeeded` only takes effect when configure has not
        // really run yet, so the normal launch path is unaffected (onAppear has already configured it with the SwiftUI environment's
        // openWindow / openSettings).
        // The test host installs no menu bar icon.
        if !AppEnvironment.isTestHost, let store = VaultStore.shared {
            MainWindowController.shared.configureIfNeeded(store: store)
            MenuBarStatusItemController.shared.configureIfNeeded(
                store: store,
                openSettings: {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            )
        }
    }

    @MainActor
    @objc private func handleQuitAppleEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        AppTerminationController.terminate()
    }

    /// Silent push for iCloud backups: another device changed the backup, so hand it to the store to sync (see docs/SECURITY.md).
    @MainActor
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        guard ICloudVault.isVaultChange(userInfo) else { return }
        VaultStore.shared?.iCloudBackupDidChange()
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppTerminationController.prepareForTermination(sender)
        return .terminateNow
    }
}

@main
struct KakeyApp: App {
    @NSApplicationDelegateAdaptor(KakeyAppDelegate.self) private var appDelegate
    @StateObject private var store = VaultStore.makeForApp()

    init() {
        // The launch time must be recorded here (before the `@StateObject` VaultStore is constructed) rather than in
        // `applicationDidFinishLaunching`: both WindowGroup's default window and the windows AppKit restores from the autosave record
        // may trigger `onOpen` before that.
        AppLaunchInfo.markLaunched()
        // Probe Touch ID availability for the first time at launch so the lazy initialization does not drift to after a lid close /
        // wake from sleep; afterwards `VaultStore` re-checks in the background only when the app becomes active.
        _ = BiometricCapability.current
    }

    var body: some Scene {
        WindowGroup("Kakey", id: MainWindowController.sceneID) {
            RootView()
                .environmentObject(store)
                .environment(\.locale, L10n.locale)
                .id(store.languageRevision)
                .preferredColorScheme(store.resolvedColorScheme)
                .frame(minWidth: 880, minHeight: 620)
                // Onboarding and the lock screen extend under the title bar (traffic lights float over the content); this must be
                // outside the frame modifier, it has no effect inside the view.
                .ignoresSafeArea(edges: store.showsImmersiveMainWindow ? .all : [])
                .background(
                    ZStack {
                        WindowEventsView(
                            onAttach: { window in
                                MainWindowController.shared.attach(window)
                                guard let window else { return }
                                if AppLaunchInfo.shouldSuppressWindowOpen(launchMinimized: store.launchMinimized) {
                                    window.close()
                                } else {
                                    store.mainWindowDidOpen()
                                }
                            },
                            onBecameKey: { window in
                                // When restoring the window frame from the last quit (`NSWindow Frame main-AppWindow-1` autosave),
                                // AppKit actually orders the window front / makes it key later than the `close()` called synchronously
                                // on mount, and that final step undoes the earlier close(), making the window visible again. Close it
                                // once more when it really becomes key, until the launch grace period (`wasJustLaunched`) ends.
                                if AppLaunchInfo.shouldSuppressWindowOpen(launchMinimized: store.launchMinimized) {
                                    window.close()
                                }
                            },
                            onWillClose: { _ in store.mainWindowDidClose() }
                        )
                        .frame(width: 0, height: 0)
                        AppShortcutIntegrationView()
                            .environmentObject(store)
                            .frame(width: 0, height: 0)
                    }
                )
                .onReceive(NotificationCenter.default.publisher(for: .kakeyWillTerminate)) { _ in
                    store.activeSheet = nil
                }
        }
        .defaultSize(width: 980, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.tr("Add Account")) {
                    store.activeSheet = .addAccount
                }
                .keyboardShortcut("n", modifiers: [.command])
                Divider()
                Button(L10n.tr("Export / Import")) {
                    store.activeSheet = .exportImport
                }
                .disabled(store.isLocked || !store.hasCompletedOnboarding)
                Button(L10n.tr("Backup & Sync")) {
                    store.activeSheet = .backupSync
                }
                .disabled(store.isLocked || !store.hasCompletedOnboarding)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button(L10n.tr("Find")) {
                    MainWindowController.shared.makeKeyAndOrderFront()
                    NotificationCenter.default.post(name: .kakeyFocusMainSearch, object: true)
                }
                .keyboardShortcut("f", modifiers: [.command])
                .disabled(store.isLocked || !store.hasCompletedOnboarding)
            }
            CommandGroup(replacing: .appTermination) {
                Button(L10n.tr("Quit")) {
                    AppTerminationController.terminate()
                }
                .keyboardShortcut("q", modifiers: [.command])
            }
        }

        Settings {
            PreferencesView()
                .environmentObject(store)
                .environment(\.locale, L10n.locale)
                .id(store.languageRevision)
                .preferredColorScheme(store.resolvedColorScheme)
                .background(
                    AppShortcutIntegrationView()
                        .environmentObject(store)
                        .frame(width: 0, height: 0)
                )
        }
    }
}

private struct AppShortcutIntegrationView: View {
    @EnvironmentObject private var store: VaultStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .onAppear {
                configureMenuBarIntegration()
                configureShortcutListening()
            }
            .onChange(of: store.menuBarIconVisible) { _, isVisible in
                MenuBarStatusItemController.shared.updateVisibility(isVisible: isVisible)
            }
            .onChange(of: store.languageRevision) { _, _ in configureMenuBarIntegration() }
            .onChange(of: store.resolvedColorScheme) { _, _ in configureMenuBarIntegration() }
            .onOpenURL { url in
                handleIncomingURL(url)
            }
    }

    /// Handles `kakey://reveal?id=<uuid>`: carries only an account id, never secrets or passwords, and never triggers a copy itself.
    /// The URL is opened only when the user switches to the password in `CopyCodeCommand`'s Touch ID prompt, to bring the main window
    /// forward with the password lock screen. The matching copy request is already queued in `VaultStore.requestSecureCopy`; after a
    /// successful password unlock the lock screen consumes `pendingCopyResultIssuer` and shows a toast.
    /// There is deliberately no "copy directly if unlocked" shortcut here; otherwise any process could bypass the AppleScript TCC
    /// authorization and per-request re-authentication with `open "kakey://reveal?id=..."`.
    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == "kakey", url.host == "reveal",
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.queryItems?.first(where: { $0.name == "id" })?.value != nil
        else {
            return
        }

        openMainWindowAction()
    }

    private func openMainWindowAction() {
        MainWindowController.shared.open()
    }

    private func openMenuBarAction() {
        MenuBarStatusItemController.shared.showPanel()
    }

    private func captureQRCodeAction() async {
        do {
            let result = try await store.captureQRCodeFromScreen(
                authorizeIfLocked: true,
                onLockedQRCodeRecognized: {
                    DesktopToastController.shared.show(
                        L10n.tr("QR code recognized. Unlock first."),
                        kind: .info
                    )
                }
            )
            DesktopToastController.shared.show(result.feedbackMessage, kind: result.feedbackKind)
        } catch QRScanError.cancelled {
            // Esc or closing the permission guide is the user's own action: show nothing.
        } catch {
            if store.lastTouchIDErrorWasUserFallback {
                openMainWindowAction()
                return
            }

            NSSound.beep()
            DesktopToastController.shared.show(error.localizedDescription, kind: .error)
        }
    }

    private func configureMenuBarIntegration() {
        MainWindowController.shared.configure(store: store) {
            openWindow(id: MainWindowController.sceneID)
        }
        // The test host installs no menu bar icon.
        guard !AppEnvironment.isTestHost else { return }
        MenuBarStatusItemController.shared.configure(
            store: store,
            openSettings: {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
        )
    }

    private func configureShortcutListening() {
        AppShortcutListener.shared.configure(
            onOpenMenuBar: openMenuBarAction,
            onOpenMainWindow: openMainWindowAction,
            onCaptureQRCode: captureQRCodeAction
        )
    }
}

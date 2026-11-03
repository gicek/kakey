import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

/// AppKit / system capabilities used by `VaultStore`. Injected so unit tests can use a no-op implementation that never touches the
/// Dock, login items, shortcuts or appearance.
@MainActor
protocol MacSystemIntegration: AnyObject {
    func setDockIconVisible(_ visible: Bool)
    var isLaunchAtLoginEnabled: Bool { get }
    func setLaunchAtLogin(_ enabled: Bool) throws
    func resetGlobalShortcuts()
    func applyAppearance(_ scheme: ColorScheme)
    func systemColorScheme() -> ColorScheme
    func activateApp()
    func beep()
    var deviceName: String { get }
    /// Registers for remote notifications (change notifications for iCloud backups).
    func registerForRemoteNotifications()
}

@MainActor
final class AppKitSystemIntegration: MacSystemIntegration {
    init() {}

    func setDockIconVisible(_ visible: Bool) {
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
    }

    var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    func resetGlobalShortcuts() {
        KeyboardShortcuts.reset(.openMenuBar, .openMainWindow, .captureQRCode)
    }

    func applyAppearance(_ scheme: ColorScheme) {
        // Write the appearance explicitly for light, dark and system alike so switching in Settings takes effect immediately.
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        for window in NSApp.windows {
            // Status bar item windows use the system's vibrant appearance (VibrantLight / VibrantDark). Overriding it with the
            // in-app theme strips the template icon's vibrancy and renders it as flat opaque black or white. Reset to nil to hand
            // it back to the system (NSApp.appearance does not affect status bar windows).
            if window.className.contains("NSStatusBarWindow") {
                window.appearance = nil
                window.contentView?.appearance = nil
                continue
            }
            window.appearance = appearance
            window.contentView?.appearance = appearance
            window.contentView?.needsDisplay = true
            window.viewsNeedDisplay = true
        }
    }

    /// Reads the actual system appearance, unaffected by the current `NSApp.appearance` override.
    func systemColorScheme() -> ColorScheme {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? .dark : .light
    }

    func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }

    func beep() {
        NSSound.beep()
    }

    var deviceName: String {
        SystemDeviceService.computerName
    }

    func registerForRemoteNotifications() {
        NSApp.registerForRemoteNotifications()
    }
}

import AppKit
import KeyboardShortcuts
import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject private var store: VaultStore
    @State private var showResetConfirm = false
    @State private var showChangePassword = false
    @State private var alfredExportError: String?
    /// Title bar height reported by `SettingsWindowChrome`; window size = root view ideal height + this inset (see that type's docs).
    @State private var titlebarInset: CGFloat = 0

    private var isTouchIDAvailable: Bool { store.biometricsAvailable }

    private var storageLocationText: String {
        store.vaultFileURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            + " " + L10n.tr("(encrypted)")
    }

    private var appearanceSelection: Binding<String> {
        Binding {
            store.appearanceMode.rawValue
        } set: { value in
            store.appearanceMode = AppearanceMode(rawValue: value) ?? .system
        }
    }

    private var languageSelection: Binding<String> {
        Binding {
            store.languageMode.rawValue
        } set: { value in
            store.languageMode = LanguageMode(rawValue: value) ?? .system
        }
    }

    private var dockIconSelection: Binding<String> {
        Binding {
            store.dockIconMode.rawValue
        } set: { value in
            store.dockIconMode = DockIconMode(rawValue: value) ?? .mainWindowOnly
        }
    }

    /// Shows "All" when the selected category no longer exists.
    private var menuBarListScopeSelection: Binding<String> {
        Binding {
            (store.menuBarCategory.map { MenuBarListScope.category($0.id) } ?? .all).rawValue
        } set: { value in
            store.menuBarListScope = MenuBarListScope(storedValue: value)
        }
    }

    private var menuBarListScopeOptions: [(value: String, title: String)] {
        [(MenuBarListScope.all.rawValue, L10n.tr("All"))]
            + store.categories.map { (MenuBarListScope.category($0.id).rawValue, $0.name) }
    }

    private var autoLockSelection: Binding<String> {
        Binding {
            store.autoLockMode.rawValue
        } set: { value in
            store.autoLockMode = AutoLockMode(rawValue: value) ?? .fiveMinutes
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
                .frame(width: SettingsMetrics.sidebarWidth)
            Divider()
            settingsPage {
                switch store.selectedSettingsPanel {
                case .general:
                    general
                case .security:
                    // Security and advanced settings cannot be changed while locked: someone with brief access to a locked Mac must
                    // not be able to turn off the failure delay or auto-lock, or reset the app.
                    if store.isLocked { lockedPlaceholder } else { security }
                case .shortcuts:
                    shortcuts
                case .advanced:
                    if store.isLocked { lockedPlaceholder } else { advanced }
                }
            }
        }
        .frame(width: SettingsMetrics.windowSize.width)
        .frame(
            minHeight: SettingsMetrics.windowSize.height - titlebarInset,
            idealHeight: SettingsMetrics.windowSize.height - titlebarInset,
            maxHeight: .infinity
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .background(SettingsWindowChrome(titlebarInset: $titlebarInset))
        .ignoresSafeArea()
        .sheet(isPresented: $showChangePassword) {
            ChangePasswordView()
                .frame(width: 460)
        }
    }

    private var lockedPlaceholder: some View {
        SettingsSection {
            Label(L10n.tr("Unlock Kakey to change these settings"), systemImage: "lock")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.horizontal, SettingsMetrics.rowInset)
                .frame(minHeight: SettingsMetrics.rowHeight)
        }
    }

    /// The sidebar holds the traffic lights: the list starts below them, with no app icon or title; the current page has a gray
    /// highlight.
    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            sidebarRow(.general, image: "gearshape")
            sidebarRow(.security, image: "lock")
            sidebarRow(.shortcuts, image: "keyboard")
            sidebarRow(.advanced, image: "slider.horizontal.3")
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, SettingsMetrics.sidebarTopInset)
        .background(SidebarMaterial())
    }

    private func sidebarRow(_ panel: SettingsPanel, image: String) -> some View {
        SettingsSidebarRow(
            title: panel.localizedTitle,
            systemImage: image,
            isSelected: store.selectedSettingsPanel == panel
        ) {
            store.selectedSettingsPanel = panel
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            SettingsSection {
                settingPicker(
                    L10n.tr("Appearance"),
                    selection: appearanceSelection,
                    options: AppearanceMode.allCases.map { ($0.rawValue, $0.localizedTitle) }
                )
                SettingsDivider()
                settingPicker(
                    L10n.tr("Language"),
                    selection: languageSelection,
                    options: LanguageMode.allCases.map { ($0.rawValue, $0.pickerTitle) }
                )
            }
            SettingsSection {
                settingToggle(
                    L10n.tr("Launch at Login"),
                    L10n.tr("Open Kakey automatically when you log in"),
                    isOn: $store.launchAtLoginEnabled
                )
                if let launchError = store.launchAtLoginError {
                    SettingsInlineError(message: launchError)
                }
                SettingsDivider()
                settingToggle(
                    L10n.tr("Background Launch Only"),
                    L10n.tr("Don’t open the main window at launch; run only in the menu bar"),
                    isOn: $store.launchMinimized
                )
            }
            SettingsSection {
                settingToggle(
                    L10n.tr("Menu Bar Icon"),
                    L10n.tr("Show a menu bar icon for quick code access"),
                    isOn: $store.menuBarIconVisible
                )
                SettingsDivider()
                // This setting has no effect while the menu bar icon is hidden, so it is disabled.
                settingPicker(
                    L10n.tr("Menu Bar Accounts"),
                    selection: menuBarListScopeSelection,
                    options: menuBarListScopeOptions
                )
                .disabled(!store.menuBarIconVisible)
                .opacity(store.menuBarIconVisible ? 1 : 0.5)
                SettingsDivider()
                settingPicker(
                    L10n.tr("Dock Icon"),
                    selection: dockIconSelection,
                    options: DockIconMode.allCases.map { ($0.rawValue, $0.localizedTitle) }
                )
            }
        }
    }

    private var security: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            SettingsSection {
                settingToggle(
                    L10n.tr("Unlock with Touch ID"),
                    isTouchIDAvailable
                        ? L10n.tr("Fall back to master password if it fails or is unavailable")
                        : L10n.tr("Touch ID is unavailable or not enrolled on this Mac"),
                    isOn: Binding(
                        get: { store.touchIDEnabled && isTouchIDAvailable },
                        set: { store.touchIDEnabled = $0 }
                    )
                )
                .disabled(!isTouchIDAvailable)
                SettingsDivider()
                // Turning it off requires Touch ID or the system password on the spot (handled by the store), so it is not bound
                // directly.
                settingToggle(
                    L10n.tr("Delay After Failed Attempts"),
                    L10n.tr("After 5 wrong master password attempts, wait times increase"),
                    isOn: Binding(
                        get: { store.lockoutDelayEnabled },
                        set: { enabled in Task { await store.setLockoutDelayEnabled(enabled) } }
                    )
                )
            }
            SettingsSection {
                settingPicker(
                    L10n.tr("Auto-Lock"),
                    description: L10n.tr(
                        "Locks after the selected time without activity or in the background, and immediately when the device locks"),
                    selection: autoLockSelection,
                    options: AutoLockMode.allCases.map { ($0.rawValue, $0.localizedTitle) }
                )
                SettingsDivider()
                SettingsRow(
                    title: L10n.tr("Change Master Password"),
                    description: L10n.tr("Re-encrypt local account data")
                ) {
                    Button(L10n.tr("Change")) { showChangePassword = true }
                        .buttonStyle(PressableButtonStyle())
                }
            }
        }
    }

    private var shortcuts: some View {
        SettingsSection {
            SettingsRow(
                title: L10n.tr("Open Menu Bar"),
                description: L10n.tr("Open the menu bar code panel"),
                controlWidth: 150
            ) {
                KeyboardShortcuts.Recorder(for: .openMenuBar)
            }
            SettingsDivider()
            SettingsRow(
                title: L10n.tr("Open Main App"),
                description: L10n.tr("Bring up the Kakey main window"),
                controlWidth: 150
            ) {
                KeyboardShortcuts.Recorder(for: .openMainWindow)
            }
            SettingsDivider()
            SettingsRow(
                title: L10n.tr("Capture QR Code"),
                description: L10n.tr("Select an on-screen QR code and import the account"),
                controlWidth: 150
            ) {
                KeyboardShortcuts.Recorder(for: .captureQRCode)
            }
        }
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            SettingsSection {
                settingToggle(
                    L10n.tr("Enable Third-Party Plugin Interface"),
                    L10n.tr("When on, third-party tools can securely and quickly look up accounts"),
                    isOn: $store.alfredIntegrationEnabled
                )
                SettingsDivider()
                SettingsRow(
                    title: L10n.tr("Install Alfred Workflow"),
                    description: L10n.tr("Import the Alfred workflow to search accounts and copy codes with a keyword")
                ) {
                    Button(L10n.tr("Install to Alfred")) {
                        exportAlfredWorkflow()
                    }
                    .buttonStyle(PressableButtonStyle())
                }
                if let alfredExportError {
                    SettingsInlineError(message: alfredExportError)
                }
            }
            SettingsSection {
                SettingsRow(title: L10n.tr("Local Data Location"), description: storageLocationText) {
                    Button(L10n.tr("Open Location")) {
                        openStorageLocation()
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
            SettingsSection(tint: .red.opacity(0.07)) {
                SettingsRow(
                    title: L10n.tr("Reset App"),
                    description: L10n.tr("Erases local data; iCloud backups aren't affected")
                ) {
                    Button(L10n.tr("Reset")) { showResetConfirm = true }
                        .buttonStyle(PressableButtonStyle(prominence: .danger))
                }
            }
            .confirmationDialog(
                L10n.tr("Reset Kakey?"),
                isPresented: $showResetConfirm,
                titleVisibility: .visible
            ) {
                Button(L10n.tr("Erase Local Data"), role: .destructive) {
                    // Requires Touch ID or the system password on the spot even when unlocked (handled by the store).
                    Task { await store.resetApplicationAfterAuthentication() }
                }
                Button(L10n.tr("Cancel"), role: .cancel) {}
            } message: {
                Text(L10n.tr("Erases local data; iCloud backups aren't affected"))
            }
        }
    }

    /// Right-side content area: no page title, groups fill the width, with uniform margins on all sides.
    private func settingsPage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsMetrics.pageInset)
            .padding(.top, SettingsMetrics.pageTopInset)
            .padding(.bottom, SettingsMetrics.pageInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func settingToggle(_ title: String, _ description: String, isOn: Binding<Bool>) -> some View {
        SettingsRow(title: title, description: description) {
            Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden()
        }
    }

    /// Pop-up menus size to their content, at most 240 pt wide (category names can be long and are truncated).
    private func settingPicker(
        _ title: String,
        description: String? = nil,
        selection: Binding<String>,
        options: [(value: String, title: String)]
    ) -> some View {
        SettingsRow(title: title, description: description) {
            Picker(title, selection: selection) {
                ForEach(options, id: \.value) { option in
                    Text(option.title).tag(option.value)
                }
            }
            .labelsHidden()
            .font(.system(size: 13))
            .frame(maxWidth: 240)
        }
    }

    private func openStorageLocation() {
        let directoryURL = store.vaultDirectoryURL
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: store.vaultFileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([store.vaultFileURL])
        } else {
            NSWorkspace.shared.open(directoryURL)
        }
    }

    private func exportAlfredWorkflow() {
        do {
            try AlfredWorkflowExporter.exportAndOpen()
            alfredExportError = nil
        } catch {
            alfredExportError = error.localizedDescription
        }
    }
}

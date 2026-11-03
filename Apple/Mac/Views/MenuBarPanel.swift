import AppKit
import SwiftUI

/// Menu bar panel: search field, account list, screen capture status line and bottom bar. When locked, the list is blurred and the
/// shared unlock form covers it. Before onboarding is complete it shows only a prompt to finish setup in the main window, without
/// search, capture or locking.
struct MenuBarPanel: View {
    @EnvironmentObject private var store: VaultStore
    @Environment(\.openSettings) private var openSettings
    var openSettingsOverride: (() -> Void)?
    var closePanelOverride: (() -> Void)?
    var setPanelDismissalSuspended: ((Bool) -> Void)?
    @State private var query = ""
    /// Row highlighted by both the arrow keys and mouse hover; Return copies it (or the first row when none is highlighted).
    @State private var selectedID: Account.ID?
    /// The list scrolls along only when the arrow keys change the highlight. Mouse hover also changes `selectedID`, and while
    /// scrolling the pointer keeps entering new rows; following with `scrollTo` would fight the gesture for scrolling and break the
    /// elastic bounce at both ends.
    @State private var keyboardScrollTarget: Account.ID?
    /// Hover highlighting follows only pointer movement (kept out of view observation; see `ListHoverTracker`).
    @State private var hoverTracker = ListHoverTracker()
    @State private var captureBusy = false
    @State private var captureStatus: (message: String, style: CaptureStatusStyle)?
    @State private var panelWindow: NSWindow?
    @State private var isPanelKey = false
    @State private var captureStatusTask: Task<Void, Never>?
    /// Incremented on hide; the list scrolls back to the top in response.
    @State private var scrollToTopRequest = 0
    @FocusState private var searchFieldFocused: Bool
    private let rowHeight: CGFloat = 44
    /// After the capture button is clicked, the status line shows for a moment before the screen is handed to the system selection.
    private static let captureHintLeadTime: Duration = .milliseconds(650)
    /// How long a success message stays; failures and duplicates stay longer.
    private static let captureSuccessStatusDuration: Duration = .seconds(2.5)
    private static let captureFailureStatusDuration: Duration = .seconds(5)

    var menuBarSourceAccounts: [Account] {
        store.menuBarAccounts
    }

    var rows: [Account] {
        menuBarSourceAccounts
            .filter { $0.matchesSearch(query) }
    }

    private func listHeight(rowCount: Int) -> CGFloat {
        if !store.hasCompletedOnboarding || menuBarSourceAccounts.isEmpty {
            return 250
        }
        return CGFloat(min(max(rowCount, 5), 9)) * rowHeight
    }

    var body: some View {
        // Filter only once per update (every account goes through a core search match); reading `rows` per row would filter
        // "row count + 3" times per update.
        let rows = rows
        ZStack {
            VStack(spacing: 0) {
                if store.hasCompletedOnboarding {
                    searchField
                    Divider()
                }
                list(rows)
                    .frame(height: listHeight(rowCount: rows.count))
                Divider()
                if let captureStatus {
                    Label(captureStatus.message, systemImage: captureStatus.style.systemImage)
                        .font(.system(size: 11.5))
                        .foregroundStyle(captureStatus.style.color)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                    Divider()
                }
                footer
            }
            .frame(width: 310)
            .blur(radius: store.isLocked ? 4 : 0)
            .opacity(store.isLocked ? 0.55 : 1)
            if store.isLocked {
                UnlockForm(
                    style: .panel,
                    isHostKey: isPanelKey,
                    onBiometricPromptActive: { setPanelDismissalSuspended?($0) },
                    makeHostKey: { panelWindow?.makeKey() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
            }
        }
        .frame(height: store.isLocked ? 430 : nil, alignment: .top)
        .background(
            WindowEventsView(
                onAttach: { window in
                    panelWindow = window
                    hoverTracker.observeScrolling(in: window) {
                        // Scrolling started: clear highlights that came from hovering (they return when the mouse moves); keep a
                        // keyboard selection.
                        if hoverTracker.selectionFromHover {
                            selectedID = nil
                            hoverTracker.selectionFromHover = false
                        }
                    }
                },
                onBecameKey: { _ in
                    isPanelKey = true
                    focusSearchFieldIfUnlocked()
                },
                onResignedKey: { _ in
                    isPanelKey = false
                    clearSearchField()
                }
            )
            .frame(width: 0, height: 0)
        )
        .onAppear { focusSearchFieldIfUnlocked() }
        .onReceive(NotificationCenter.default.publisher(for: .kakeyMenuBarPanelDidHide)) { _ in
            resetForNextPresentation()
        }
        .onChange(of: store.isLocked) { _, isLocked in
            if !isLocked {
                focusSearchFieldIfUnlocked()
            }
        }
    }

    /// The content stays alive, so on hide, temporary state is reset and the next opening looks like a fresh one.
    private func resetForNextPresentation() {
        query = ""
        selectedID = nil
        captureStatusTask?.cancel()
        captureStatusTask = nil
        captureStatus = nil
        scrollToTopRequest += 1
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L10n.tr("Search accounts"), text: $query)
                .textFieldStyle(.plain)
                .focused($searchFieldFocused)
                .onSubmit(copySelectedRow)
                .onKeyPress(.downArrow) {
                    moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveSelection(by: -1)
                    return .handled
                }
                .onChange(of: query) { _, newValue in
                    // After typing a query, highlight the first result by default so Return copies it.
                    selectedID = newValue.isEmpty ? nil : rows.first?.id
                }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .kakeySearchFieldChrome(isFocused: searchFieldFocused)
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func list(_ rows: [Account]) -> some View {
        if !store.hasCompletedOnboarding {
            MenuBarSetupState(openMainWindow: openMainWindow)
        } else if menuBarSourceAccounts.isEmpty {
            if let category = store.menuBarCategory, !store.accounts.isEmpty {
                MenuBarEmptyCategoryState(name: category.name)
            } else {
                MenuBarEmptyVaultState()
            }
        } else if rows.isEmpty {
            MenuBarEmptySearchState()
        } else {
            let lastRowID = rows.last?.id
            ScrollViewReader { proxy in
                ScrollView {
                    // Build views only for visible rows: a plain VStack keeps every row in the view graph, so every scrolling frame
                    // would update every row's position, which is especially heavy during the bounce at both ends.
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { account in
                            MenuBarAccountRow(
                                account: account,
                                isCopied: store.copiedAccountID == account.id,
                                isHighlighted: selectedID == account.id,
                                showsDivider: account.id != lastRowID,
                                height: rowHeight
                            ) {
                                store.copyCode(for: account)
                            }
                            .id(account.id)
                        }
                    }
                    // Hover highlighting uses one continuous hover over the whole list and computes the row from the pointer's height
                    // (rows have a fixed height), instead of an `.onHover` per row: per-row hover tracking adds a pass over every
                    // row's position on each scrolling frame. It updates only when the pointer actually moves; while scrolling,
                    // decelerating or bouncing, content slides under a still pointer without changing the highlight (as in Finder and
                    // other system lists), otherwise the whole list would recompute for every row passing under the pointer.
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard hoverTracker.pointerMoved() else { return }
                            let index = Int(location.y / rowHeight)
                            let hoveredID = rows.indices.contains(index) ? rows[index].id : nil
                            if selectedID != hoveredID {
                                selectedID = hoveredID
                                hoverTracker.selectionFromHover = hoveredID != nil
                            }
                        case .ended:
                            if hoverTracker.selectionFromHover {
                                selectedID = nil
                                hoverTracker.selectionFromHover = false
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .onChange(of: keyboardScrollTarget) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                    // Clear after use, so selecting the same row again by key (after the mouse scrolled it away) scrolls back to it.
                    keyboardScrollTarget = nil
                }
                .onChange(of: scrollToTopRequest) { _, _ in
                    if let first = rows.first?.id {
                        proxy.scrollTo(first, anchor: .top)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if store.hasCompletedOnboarding {
                Button {
                    captureQRCodeFromScreen()
                } label: {
                    Group {
                        if captureBusy {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "qrcode.viewfinder")
                        }
                    }
                    .modifier(MenuBarFooterHover())
                }
                .disabled(captureBusy)
                .help(L10n.tr("Add account via screenshot"))
                .accessibilityLabel(L10n.tr("Add account via screenshot"))
            }
            Spacer()
            Menu {
                // No "Lock" when already locked; before onboarding is complete there is no vault to lock.
                if store.hasCompletedOnboarding && !store.isLocked {
                    Button {
                        lockMenuBarPanel()
                    } label: {
                        Label(L10n.tr("Lock"), systemImage: "lock")
                    }
                }
                Button {
                    openMainWindow()
                } label: {
                    Label(L10n.tr("Main Window"), systemImage: "macwindow")
                }
                Button {
                    showSettingsWindow()
                } label: {
                    Label(L10n.tr("Settings"), systemImage: "gearshape")
                }
                Divider()
                Button {
                    AppTerminationController.terminate()
                } label: {
                    Label(L10n.tr("Quit"), systemImage: "power")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .modifier(MenuBarFooterHover())
            .help(L10n.tr("Menu"))
            .accessibilityLabel(L10n.tr("Menu"))
        }
        .buttonStyle(.plain)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        // The scope menu is overlaid in the center of the bottom bar, independent of the side buttons' widths.
        .overlay {
            if store.hasCompletedOnboarding && !store.categories.isEmpty {
                scopeMenu
            }
        }
    }

    /// Scope switcher in the bottom bar: shows whether "All" or a category is being viewed and switches on click (the same setting as
    /// Settings and the menu bar icon's context menu).
    private var scopeMenu: some View {
        Menu {
            Toggle(
                L10n.tr("All"),
                isOn: Binding(
                    get: { store.menuBarCategory == nil },
                    set: { _ in store.menuBarListScope = .all }
                ))
            Divider()
            ForEach(store.categories) { category in
                Toggle(
                    category.name,
                    isOn: Binding(
                        get: { store.menuBarCategory?.id == category.id },
                        set: { _ in store.menuBarListScope = .category(category.id) }
                    ))
            }
        } label: {
            HStack(spacing: 4) {
                Text(store.menuBarCategory?.name ?? L10n.tr("All"))
                    .lineLimit(1)
                    .frame(maxWidth: 150)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .modifier(MenuBarFooterHover(width: nil))
        .help(L10n.tr("Menu Bar Accounts"))
        .accessibilityLabel(L10n.tr("Menu Bar Accounts"))
    }

    private func moveSelection(by offset: Int) {
        guard !rows.isEmpty else { return }
        let current = selectedID.flatMap { id in rows.firstIndex { $0.id == id } }
        let next = current.map { min(max($0 + offset, 0), rows.count - 1) } ?? (offset > 0 ? 0 : rows.count - 1)
        selectedID = rows[next].id
        hoverTracker.selectionFromHover = false
        keyboardScrollTarget = rows[next].id
    }

    private func copySelectedRow() {
        guard let account = rows.first(where: { $0.id == selectedID }) ?? rows.first else { return }
        store.copyCode(for: account)
    }

    /// Defers the focus request until after the current update (changing `@FocusState` right as the panel becomes key or the unlock
    /// form unmounts is ignored).
    private func focusSearchFieldIfUnlocked() {
        guard store.hasCompletedOnboarding, !store.isLocked else { return }
        Task { @MainActor in
            guard store.hasCompletedOnboarding, !store.isLocked else { return }
            searchFieldFocused = true
        }
    }

    private func captureQRCodeFromScreen() {
        guard !captureBusy else { return }
        captureBusy = true
        setCaptureStatus(L10n.tr("Capture a QR code on screen"), style: .hint, clearAfter: nil)
        // During interactive capture, clicks land on the system capture layer, so suspend "click outside to close" to keep the panel
        // from disappearing while selecting.
        setPanelDismissalSuspended?(true)

        Task {
            try? await Task.sleep(for: Self.captureHintLeadTime)

            do {
                let result = try await store.captureQRCodeFromScreen()
                let style = CaptureStatusStyle(kind: result.feedbackKind)
                setCaptureStatus(
                    result.feedbackMessage,
                    style: style,
                    clearAfter: style == .success ? Self.captureSuccessStatusDuration : Self.captureFailureStatusDuration
                )
            } catch QRScanError.cancelled {
                // Esc or closing the permission guide is the user's own action: show nothing.
                setCaptureStatus(nil, style: .hint, clearAfter: nil)
            } catch {
                setCaptureStatus(error.localizedDescription, style: .error, clearAfter: Self.captureFailureStatusDuration)
            }

            captureBusy = false
            setPanelDismissalSuspended?(false)
        }
    }

    private func setCaptureStatus(_ message: String?, style: CaptureStatusStyle, clearAfter: Duration?) {
        captureStatusTask?.cancel()
        captureStatus = message.map { ($0, style) }
        guard let clearAfter else { return }
        captureStatusTask = Task {
            try? await Task.sleep(for: clearAfter)
            guard !Task.isCancelled else { return }
            captureStatus = nil
        }
    }

    private func showSettingsWindow() {
        hideMenuBarPanel()
        // The panel must resign key first for the Settings window to come to the front, so open it on the next pass.
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let openSettingsOverride {
                openSettingsOverride()
            } else {
                openSettings()
            }
        }
    }

    private func openMainWindow() {
        hideMenuBarPanel()
        Task { @MainActor in
            MainWindowController.shared.open()
        }
    }

    private func hideMenuBarPanel() {
        clearSearchField()
        if let closePanelOverride {
            closePanelOverride()
        } else {
            panelWindow?.orderOut(nil)
        }
    }

    /// On losing key, only clears the query and leaves focus in the search field: if focus were removed, AppKit would walk the whole
    /// view tree to find the first focusable control the next time the panel shows (tens of milliseconds with many accounts), only
    /// for focus to move back to the search field.
    private func clearSearchField() {
        query = ""
        selectedID = nil
    }

    private func lockMenuBarPanel() {
        store.lock()
        hideMenuBarPanel()
    }
}

/// A menu bar panel row: click to copy, "Copied" replaces the code in place; the highlight comes from keyboard selection or hover.
private struct MenuBarAccountRow: View {
    var account: Account
    var isCopied: Bool
    var isHighlighted: Bool
    var showsDivider: Bool
    var height: CGFloat
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                LogoBadge(account: account, size: 26, showsRecentIndicator: account.isRecentlyAdded(relativeTo: Date()))
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.issuer)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(account.username)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                CodeWithCountdown(account: account, isCopied: isCopied, layout: .menuBarRow)
            }
            .padding(.horizontal, 8)
            .frame(height: height)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHighlighted ? Color.accentColor.opacity(0.16) : Color.clear)
                    .padding(.vertical, 2)
            }
            .overlay(alignment: .bottom) {
                if showsDivider && !isHighlighted {
                    Divider().padding(.horizontal, 8)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "\(account.issuer), \(account.username)"))
        .accessibilityHint(L10n.tr("Copy code"))
    }
}

/// Hover tracking state for the panel list. A plain reference type kept out of view observation: scroll and hover callbacks arrive
/// every frame, and writing to it does not trigger recomputation.
@MainActor
final class ListHoverTracker {
    /// Whether the current highlight came from mouse hover (only that kind is cleared when scrolling starts).
    var selectionFromHover = false
    private var lastPointer: NSPoint?
    private var monitor: Any?
    private weak var window: NSWindow?

    /// Whether the pointer's screen position changed since last time. Hover callbacks also fire when content scrolls under a still
    /// pointer; this tells the two apart.
    func pointerMoved() -> Bool {
        let pointer = NSEvent.mouseLocation
        defer { lastPointer = pointer }
        return pointer != lastPointer
    }

    /// Called once when a scroll sent to this window starts from rest (once per gesture).
    func observeScrolling(in window: NSWindow?, onBegin: @escaping @MainActor () -> Void) {
        guard window !== self.window else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        self.window = window
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.window else { return }
                if event.phase == .began || (event.phase == [] && event.momentumPhase == []) {
                    onBegin()
                }
            }
            return event
        }
    }
}

/// Hover appearance for bottom bar icon buttons: a larger hit area, a light background on hover, and the cursor reset to an arrow
/// (hovering a button while the search field is focused can leave an I-beam cursor behind).
private struct MenuBarFooterHover: ViewModifier {
    /// Icon buttons are a fixed 28 pt square; `nil` uses the content width plus horizontal padding (the scope menu in the middle).
    var width: CGFloat? = 28
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, width == nil ? 8 : 0)
            .frame(width: width, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.1 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    NSCursor.arrow.set()
                }
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

/// The capture status line's three tones: waiting for selection uses the secondary color; results reuse the toast's success /
/// failure tones.
private enum CaptureStatusStyle: Equatable {
    case hint
    case success
    case error

    init(kind: DesktopToastController.Kind) {
        switch kind {
        case .info: self = .hint
        case .success: self = .success
        case .error: self = .error
        }
    }

    var systemImage: String {
        switch self {
        case .hint: "crop"
        case .success: "checkmark.circle"
        case .error: "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch self {
        case .hint: .secondary
        case .success: .green
        case .error: .red
        }
    }
}

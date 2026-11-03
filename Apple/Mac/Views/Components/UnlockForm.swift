import SwiftUI

/// Unlock form: app icon (with an optional Touch ID button on its corner), title and description, password field and one error line.
/// The main window lock screen (`LockOverlay`) and the menu bar panel share this logic; only size, Touch ID reason and host hooks
/// differ. Results queued while locked (recognition / copy) are delivered after a successful unlock.
struct UnlockForm: View {
    enum Style {
        case window
        case panel
    }

    var style: Style
    /// After a menu bar Touch ID unlock, the main window briefly keeps the lock screen look: no input and no Touch ID prompt.
    var isPassive = false
    /// Whether the host window is key: becoming key focuses the password field and (after a natural lock) prompts Touch ID once.
    var isHostKey: Bool
    /// Tells the host while the Touch ID system prompt is up (the panel suspends "click outside to close" meanwhile).
    var onBiometricPromptActive: (Bool) -> Void = { _ in }
    /// Makes the host window key before focusing the password field (a borderless panel needs an explicit `makeKey`).
    var makeHostKey: () -> Void = {}

    @EnvironmentObject private var store: VaultStore
    @State private var password = ""
    @State private var revealPassword = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var busy = false
    @State private var isTouchIDHovered = false
    @State private var didAutoRequestTouchID = false
    @FocusState private var passwordFieldFocused: Bool

    private var showsTouchID: Bool {
        !isPassive && store.touchIDEnabled && store.biometricsAvailable
    }

    var body: some View {
        VStack(spacing: style.spacing) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: KakeyAssets.appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: style.iconSize, height: style.iconSize)
                    .shadow(color: .black.opacity(0.22), radius: style.iconShadowRadius, x: 0, y: style.iconShadowRadius / 2)
                if showsTouchID {
                    touchIDButton
                }
            }

            VStack(spacing: 4) {
                Text(L10n.tr("Kakey is locked"))
                    .font(.system(size: style.titleSize, weight: .semibold))
                Text(
                    L10n.tr(showsTouchID ? "Use Touch ID or enter your master password to unlock" : "Enter your master password to unlock")
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: style.textMaxWidth)
            }

            // The description already says to enter the master password, so no placeholder; show / hide on the right, as in onboarding.
            HStack(spacing: 0) {
                passwordField
                    .accessibilityLabel(L10n.tr("Password"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .multilineTextAlignment(.center)
                    .focused($passwordFieldFocused)
                    .romanInputOnly(focused: passwordFieldFocused, revealed: revealPassword)
                    .onSubmit(unlockWithPassword)
                RevealSecretButton(isRevealed: revealPassword) { revealPassword.toggle() }
            }
            // Leading space as wide as the button keeps the text centered in the capsule.
            .padding(.leading, 30)
            .padding(.trailing, 2)
            .frame(width: style.fieldWidth, height: 34)
            .kakeyCapsuleInputChrome()
            .disabled(isPassive)
            // Toggling show / hide swaps the field, so focus is brought back.
            .onChange(of: revealPassword) { _, _ in focusPasswordField() }

            Text(showError ? errorMessage : " ")
                .font(.system(size: 11.5))
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .frame(maxWidth: style.textMaxWidth)

            // The main file is corrupt and a last-known-good snapshot exists: offer recovery (using the master password entered above).
            if style == .window, !isPassive, store.lastKnownGoodRestoreAvailable {
                Button(L10n.tr("Restore Last Good Copy"), action: restoreLastKnownGood)
                    .buttonStyle(.link)
                    .disabled(password.isEmpty || busy)
                    .help(L10n.tr("The vault file is damaged. Restore the last good copy?"))
            }
        }
        .onAppear(perform: hostActivated)
        // The menu bar panel content stays alive: on hide, clear any half-typed password and error rather than leaving them in the
        // hidden panel.
        .onReceive(NotificationCenter.default.publisher(for: .kakeyMenuBarPanelDidHide)) { _ in
            guard style == .panel, !busy else { return }
            password = ""
            revealPassword = false
            showError = false
        }
        .onChange(of: isHostKey) { _, isKey in
            if isKey {
                hostActivated()
            }
        }
    }

    @ViewBuilder
    private var passwordField: some View {
        if revealPassword {
            TextField("", text: $password)
        } else {
            SecureField("", text: $password)
        }
    }

    private var touchIDButton: some View {
        Button(action: unlockWithTouchID) {
            Image(systemName: "touchid")
                .font(.system(size: style.touchIDIconSize, weight: style == .window ? .medium : .regular))
                .foregroundStyle(.pink)
                .frame(width: style.touchIDSize, height: style.touchIDSize)
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: Circle())
        .overlay(Circle().strokeBorder(.separator.opacity(0.5)))
        .shadow(color: .black.opacity(isTouchIDHovered ? 0.18 : 0.10), radius: isTouchIDHovered ? 14 : 8, x: 0, y: 4)
        .scaleEffect(isTouchIDHovered ? 1.08 : 1)
        .animation(.easeOut(duration: 0.16), value: isTouchIDHovered)
        .onHover { isTouchIDHovered = $0 }
        .help(L10n.tr("Unlock with Touch ID"))
        .accessibilityLabel(L10n.tr("Unlock with Touch ID"))
        .offset(x: style.touchIDOffset, y: style.touchIDOffset)
        .disabled(busy)
    }

    /// The host became key: focus the password field. Touch ID is prompted automatically only on the lock screen after launch.
    /// After a lock while running (manual, auto, sleep / screen lock) or after the user cancelled the prompt
    /// (`autoTouchIDSuppressed`), it stays quiet and only keeps the password field focused.
    private func hostActivated() {
        guard !isPassive, isHostKey else { return }
        focusPasswordField()
        guard showsTouchID, store.isLocked, !store.autoTouchIDSuppressed, !didAutoRequestTouchID, !busy else { return }
        didAutoRequestTouchID = true
        unlockWithTouchID()
    }

    private func unlockWithTouchID() {
        guard !isPassive, !busy else { return }
        didAutoRequestTouchID = true
        guard store.touchIDEnabled else {
            errorMessage = L10n.tr("Touch ID is turned off in Settings")
            showError = true
            focusPasswordField()
            return
        }

        busy = true
        showError = false
        onBiometricPromptActive(true)
        if style == .panel {
            // The main window keeps the lock screen look and reveals the accounts after a short delay, to avoid a flash (see
            // docs/DESIGN.md).
            store.suspendMainWindowUnlockReveal()
        }
        Task {
            if await store.unlockWithTouchID(reason: L10n.tr(style.touchIDReasonKey)) {
                password = ""
                errorMessage = ""
                UnlockFeedback.showPendingResults(from: store)
            } else {
                errorMessage = store.vaultError ?? L10n.tr("Enter your master password to unlock first")
                showError = true
                focusPasswordField()
            }
            onBiometricPromptActive(false)
            busy = false
        }
    }

    /// An empty password is not blocked here: the core treats it as a wrong password and shows the same message.
    private func unlockWithPassword() {
        guard !isPassive, !busy else { return }
        busy = true
        Task {
            if await store.unlock(password: password) {
                showError = false
                errorMessage = ""
                password = ""
                UnlockFeedback.showPendingResults(from: store)
            } else {
                errorMessage = store.vaultError ?? L10n.tr("Unable to unlock")
                showError = true
                focusPasswordField()
            }
            busy = false
        }
    }

    private func restoreLastKnownGood() {
        guard !isPassive, !busy else { return }
        busy = true
        Task {
            if await store.restoreLastKnownGoodVault(password: password) {
                showError = false
                password = ""
            } else {
                errorMessage = store.vaultError ?? L10n.tr("Unable to unlock")
                showError = true
                focusPasswordField()
            }
            busy = false
        }
    }

    /// Defers the focus request until after the current update: changing `@FocusState` in the same pass as a body update or a system
    /// prompt dismissal is ignored.
    private func focusPasswordField() {
        guard !isPassive else { return }
        makeHostKey()
        Task { @MainActor in
            guard store.isLocked else { return }
            passwordFieldFocused = true
        }
    }
}

private extension UnlockForm.Style {
    var spacing: CGFloat { self == .window ? 16 : 12 }
    var iconSize: CGFloat { self == .window ? 112 : 70 }
    var iconShadowRadius: CGFloat { self == .window ? 14 : 8 }
    var touchIDSize: CGFloat { self == .window ? 56 : 34 }
    var touchIDIconSize: CGFloat { self == .window ? 30 : 18 }
    var touchIDOffset: CGFloat { self == .window ? 12 : 8 }
    var titleSize: CGFloat { self == .window ? 20 : 14 }
    var fieldWidth: CGFloat { self == .window ? 220 : 210 }
    var textMaxWidth: CGFloat { self == .window ? 280 : 230 }
    var touchIDReasonKey: String { self == .window ? "unlock Kakey" : "unlock Kakey menu bar codes" }
}

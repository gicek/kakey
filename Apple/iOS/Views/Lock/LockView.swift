import SwiftUI

/// Lock screen: unlock with the master password or biometrics. Biometrics are prompted automatically only once, on the lock screen
/// after launch; after any lock (manual or automatic) it stays on the password field. The suppression flag lives in the store.
struct LockView: View {
    @Environment(MobileVaultStore.self) private var store
    @State private var password = ""
    @State private var confirmRestore = false
    @FocusState private var passwordFocused: Bool

    private var canUseBiometrics: Bool {
        store.preferences.biometricsEnabled && store.biometricKeyAvailable
    }

    private var canSubmit: Bool {
        !password.isEmpty && !store.isWorking && store.lockoutRemaining == nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 40)
                VStack(spacing: 14) {
                    BrandMark(size: 96)
                    Text(L10n.tr("Kakey is locked"))
                        .font(.title2.bold())
                    Text(
                        canUseBiometrics
                            ? L10n.format("Use %@ or enter your master password", store.biometrics.displayName)
                            : L10n.tr("Enter your master password to unlock")
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }

                VStack(spacing: 14) {
                    SecureField(L10n.tr("Enter password"), text: $password)
                        .keyboardType(.asciiCapable)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($passwordFocused)
                        .onSubmit(unlock)
                        .padding(.horizontal, 16)
                        .frame(height: 50)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .disabled(store.lockoutRemaining != nil)

                    Button(action: unlock) {
                        ZStack {
                            Text(L10n.tr("Unlock")).opacity(store.isWorking ? 0 : 1)
                            if store.isWorking { ProgressView().tint(.white) }
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 14))
                    .disabled(!canSubmit)

                    if canUseBiometrics {
                        Button {
                            Task { await store.unlockWithBiometrics() }
                        } label: {
                            Label(L10n.format("Unlock with %@", store.biometrics.displayName), systemImage: store.biometrics.symbolName)
                                .font(.subheadline.weight(.medium))
                        }
                        .padding(.top, 4)
                        .disabled(store.isWorking)
                    }

                    if store.lastKnownGoodRestoreAvailable {
                        Button(L10n.tr("Restore Last Good Copy")) { confirmRestore = true }
                            .font(.subheadline.weight(.medium))
                            .disabled(!canSubmit)
                    }

                    LockMessage()
                }
                .frame(maxWidth: 380)
                Spacer(minLength: 40)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: password) { store.clearUnlockError() }
        .alert(L10n.tr("The vault file is damaged. Restore the last good copy?"), isPresented: $confirmRestore) {
            Button(L10n.tr("Restore Last Good Copy")) { restore() }
            Button(L10n.tr("Cancel"), role: .cancel) {}
        }
        .task {
            if store.shouldAutoPromptBiometrics {
                await store.autoPromptBiometricsIfNeeded()
            } else {
                passwordFocused = true
            }
        }
    }

    /// Rejects a second submission while one is in progress (Return and the button share this path).
    private func unlock() {
        guard canSubmit else { return }
        Task {
            await store.unlock(password: password)
            if store.phase == .unlocked { password = "" }
        }
    }

    private func restore() {
        guard canSubmit else { return }
        Task {
            await store.restoreLastKnownGoodVault(password: password)
            if store.phase == .unlocked { password = "" }
        }
    }
}

/// Error message and the countdown after repeated wrong attempts.
private struct LockMessage: View {
    @Environment(MobileVaultStore.self) private var store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            if let remaining = store.lockoutRemaining {
                Text(L10n.format("Too many attempts. Try again in %lld seconds", Int(remaining.rounded(.up))))
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else if let error = store.unlockError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

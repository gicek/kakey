import SwiftUI

/// Change master password: the same password fields (with show / hide), strength meter and inline hints as onboarding.
struct ChangePasswordView: View {
    @EnvironmentObject private var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var next = ""
    @State private var confirm = ""
    @State private var revealCurrent = false
    @State private var revealNext = false
    @State private var revealConfirm = false
    @State private var errorMessage = ""
    @State private var confirmingFairPassword = false
    @State private var isUpdatingBackup = false
    @State private var backupNotUpdated = false
    @FocusState private var nextFocused: Bool

    private var strength: PasswordStrength { PasswordStrength.evaluate(next) }
    private var mismatch: Bool { !confirm.isEmpty && next != confirm }
    /// Length and strength problems appear only after leaving the new password field, not while typing.
    private var nextProblem: String? { nextFocused ? nil : PasswordPolicy.problem(for: next) }
    private var canSubmit: Bool { !current.isEmpty && PasswordPolicy.isAcceptableMasterPassword(next) && next == confirm }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader(L10n.tr("Change Master Password"))
            VStack(alignment: .leading, spacing: 14) {
                LabeledSecureField(label: L10n.tr("Current Master Password"), text: $current, reveal: $revealCurrent)
                if !errorMessage.isEmpty {
                    InlineNotice(text: errorMessage, systemImage: "exclamationmark.triangle", tint: .red)
                }
                LabeledSecureField(
                    label: L10n.tr("New Password"), text: $next, reveal: $revealNext, focused: $nextFocused, onSubmit: submitIfReady
                )
                .newPasswordInput($next)
                StrengthMeter(strength: strength)
                    .padding(.bottom, 2)
                if let nextProblem {
                    InlineNotice(text: nextProblem, systemImage: "exclamationmark.circle", tint: .red)
                }
                LabeledSecureField(label: L10n.tr("Confirm New Password"), text: $confirm, reveal: $revealConfirm, onSubmit: submitIfReady)
                    .newPasswordInput($confirm)
                if mismatch {
                    InlineNotice(text: L10n.tr("New passwords do not match"), systemImage: "exclamationmark.circle", tint: .red)
                }
                InlineNotice(
                    text: store.syncLocation == nil
                        ? L10n.tr("After changing, your vault is re-encrypted with the new password.")
                        : L10n.tr("After changing, your vault is re-encrypted with the new password and your backup is updated."),
                    systemImage: "exclamationmark.circle",
                    tint: .orange
                )
            }
            .padding(22)
            .resignsFocusOnBackgroundClick()
            Divider()
            HStack {
                Spacer()
                Button(L10n.tr("Cancel")) { dismiss() }.buttonStyle(PressableButtonStyle())
                Button(action: submit) {
                    HStack(spacing: 6) {
                        if isUpdatingBackup { ProgressView().controlSize(.small) }
                        Text(isUpdatingBackup ? L10n.tr("Updating Backup") : L10n.tr("Change Password"))
                    }
                }
                .buttonStyle(PressableButtonStyle(prominence: .primary))
                .disabled(!canSubmit || store.isWorking || isUpdatingBackup)
            }
            .padding(14)
            .background(.bar)
        }
        .onChange(of: current) { _, _ in errorMessage = "" }
        .fairPasswordConfirmation(isPresented: $confirmingFairPassword, onConfirm: changePassword)
        .alert(L10n.tr("Backup not updated"), isPresented: $backupNotUpdated) {
            Button(L10n.tr("OK")) { dismiss() }
        } message: {
            Text(
                L10n.tr(
                    "Your new password is in use, but the backup wasn’t updated and is still encrypted with the old password. Back up again later, or delete the old backup."
                ))
        }
    }

    private func submitIfReady() {
        guard canSubmit, !store.isWorking, !isUpdatingBackup else { return }
        submit()
    }

    private func submit() {
        if strength == .fair {
            confirmingFairPassword = true
        } else {
            changePassword()
        }
    }

    private func changePassword() {
        Task {
            if await store.changeMasterPassword(currentPassword: current, newPassword: next) {
                // With backups on: wait for the sync after the password change and warn if the backup was not updated (it would
                // still hold the vault encrypted with the old password).
                isUpdatingBackup = true
                let updated = await store.backupUpdatedAfterPasswordChange()
                isUpdatingBackup = false
                if updated { dismiss() } else { backupNotUpdated = true }
            } else {
                errorMessage = store.vaultError ?? L10n.tr("Unable to change master password")
            }
        }
    }
}

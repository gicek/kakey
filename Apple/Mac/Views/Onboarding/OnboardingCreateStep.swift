import SwiftUI

/// New user: set the master password (strength meter and hints), optionally enable Touch ID, create the vault.
struct OnboardingCreateStep: View {
    var onBack: () -> Void

    @EnvironmentObject private var store: VaultStore
    @State private var password = ""
    @State private var confirm = ""
    @State private var revealPassword = false
    @State private var revealConfirm = false
    @State private var errorMessage = ""
    @State private var confirmingFairPassword = false
    @FocusState private var passwordFocused: Bool
    @FocusState private var confirmFocused: Bool

    private var strength: PasswordStrength { PasswordStrength.evaluate(password) }

    /// Validated only after leaving the password field, not while typing: length and strength (weak passwords are rejected) appear
    /// under the strength meter.
    private var passwordProblem: String? {
        guard !passwordFocused else { return nil }
        return PasswordPolicy.problem(for: password)
    }
    /// Once the new password is valid, checks that the confirmation matches; shown under the confirmation field.
    /// Checked while typing: no message while the confirmation is still a prefix of the new password, but as soon as one character is
    /// wrong (so it can never match) the message appears, without waiting for the field to lose focus.
    private var mismatchProblem: String? {
        PasswordConfirmation.problem(
            password: password, confirm: confirm, isEditingPassword: passwordFocused, isEditingConfirm: confirmFocused)
    }
    private var canSubmit: Bool { PasswordPolicy.isAcceptableMasterPassword(password) && password == confirm }

    var body: some View {
        OnboardingTaskPanel(
            title: L10n.tr("Set master password"),
            description: L10n.tr("Your master password encrypts your 2FA on this Mac and in every backup. Pick one you won’t forget."),
            onBack: onBack,
            footer: {
                OnboardingActionRow {
                    OnboardingForgetPasswordNote()
                } primary: {
                    Button(action: submit) {
                        Text(L10n.tr("Create Vault"))
                    }
                    .buttonStyle(PressableButtonStyle(prominence: .primary, size: .large))
                    .disabled(!canSubmit || store.isWorking)
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 14) {
                LabeledSecureField(
                    label: L10n.tr("New Password"),
                    text: $password,
                    reveal: $revealPassword,
                    focused: $passwordFocused,
                    onSubmit: submitIfReady
                )
                .newPasswordInput($password)
                StrengthMeter(strength: strength, problem: passwordProblem)
                    .padding(.bottom, 2)
                VStack(alignment: .leading, spacing: 6) {
                    LabeledSecureField(
                        label: L10n.tr("Confirm Password"),
                        text: $confirm,
                        reveal: $revealConfirm,
                        focused: $confirmFocused,
                        onSubmit: submitIfReady
                    )
                    .newPasswordInput($confirm)
                    FieldMessage(text: mismatchProblem)
                }
                // Creation failures (disk writes, ...) are rare, so they still use a full notice block.
                if !errorMessage.isEmpty {
                    InlineNotice(text: errorMessage, systemImage: "exclamationmark.circle", tint: .red)
                }

                OnboardingTouchIDToggle()
            }
        }
        .onChange(of: password) { _, _ in errorMessage = "" }
        .onChange(of: confirm) { _, _ in errorMessage = "" }
        .fairPasswordConfirmation(isPresented: $confirmingFairPassword, onConfirm: createVault)
    }

    /// Return: the field ends editing first to trigger validation (see `LabeledSecureField`); when both fields are valid it acts like
    /// clicking "Create Vault".
    private func submitIfReady() {
        guard canSubmit, !store.isWorking else { return }
        submit()
    }

    /// A "fair" password asks for confirmation first and creates the vault only after the user agrees; the button is disabled for
    /// weak passwords, so they never get here.
    private func submit() {
        if strength == .fair {
            confirmingFairPassword = true
        } else {
            createVault()
        }
    }

    private func createVault() {
        Task {
            if !(await store.createVault(masterPassword: password)) {
                errorMessage = store.vaultError ?? L10n.tr("Unable to create encrypted vault")
            }
        }
    }
}

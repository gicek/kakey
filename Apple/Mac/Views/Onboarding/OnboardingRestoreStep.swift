import SwiftUI

/// Returning user: first choose where the backup is and fetch the encrypted backup (kept only in memory,
/// `store.pendingOnboardingRestore`), then unlock it with the original master password (iCloud, folders and cloud storage are
/// available). A Kakey export file can also be chosen (`store.pendingOnboardingExport`): after entering the export password a new
/// vault is created. "Use as master password" is checked by default and uses the export password; unchecking it sets a separate
/// master password.
struct OnboardingRestoreStep: View {
    /// Cloud storage connections authorized during this onboarding: choosing the same service again does not require signing in again.
    var connections: RestoreCloudConnections
    var onBack: () -> Void

    @EnvironmentObject private var store: VaultStore
    @State private var restorePassword = ""
    @State private var revealRestorePassword = false
    /// Export file: the export password is the master password by default; the new password fields appear only when unchecked.
    @State private var useExportPasswordAsMaster = true
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var revealNewPassword = false
    @State private var revealConfirmPassword = false
    @State private var confirmingFairPassword = false
    @FocusState private var newPasswordFocused: Bool
    @FocusState private var confirmPasswordFocused: Bool
    @State private var errorMessage = ""
    @State private var cloudSetup: CloudSetupModel?
    /// When cloud storage has no backup and the service allows changing the folder, remembers the location and connection so the
    /// notice can offer "Choose Folder".
    @State private var missingCloudBackup: (location: CloudLocation, connection: Data)?
    @FocusState private var passwordFocused: Bool

    private var hasBackup: Bool { store.pendingOnboardingRestore != nil || store.pendingOnboardingExport != nil }
    /// The page cannot be left while finding or fetching a backup: completing the fetch rewrites the vault's in-memory state.
    private var isFetching: Bool { store.isFetchingOnboardingRestore }

    var body: some View {
        OnboardingTaskPanel(
            title: L10n.tr("Restore a backup"),
            description: L10n.tr("Choose where your backup is, then unlock it with your master password."),
            onBack: onBack,
            isBackDisabled: isFetching,
            footer: {
                // Nothing to unlock while choosing a location, so no button; "Unlock and Continue" appears once a backup is found.
                if hasBackup {
                    OnboardingActionRow {
                        // Restoring from an export file with a separate master password warns about forgetting it, as when creating
                        // a vault.
                        if isExport, !useExportPasswordAsMaster {
                            OnboardingForgetPasswordNote()
                        }
                    } primary: {
                        Button(action: unlock) {
                            HStack(spacing: 8) {
                                // Unlocking (Argon2) is the slowest step on this page, so its progress is drawn on the button; fetch
                                // progress is shown below the list above.
                                if store.isWorking {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(L10n.tr("Unlock & Continue"))
                            }
                        }
                        .buttonStyle(PressableButtonStyle(prominence: .primary, size: .large))
                        .disabled(!canUnlock)
                    }
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 14) {
                if hasBackup {
                    backupFoundPanel(detail: backupSource)

                    VStack(alignment: .leading, spacing: 6) {
                        LabeledSecureField(
                            label: isExport ? L10n.tr("Export Password") : L10n.tr("Existing Master Password"),
                            text: $restorePassword,
                            reveal: $revealRestorePassword,
                            focused: $passwordFocused,
                            onSubmit: unlock
                        )
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))

                    if isExport {
                        masterPasswordFields
                    }

                    OnboardingTouchIDToggle()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    SyncLocationPicker(
                        current: nil, iCloudAvailable: store.iCloud != nil, acceptsExportFile: true, columns: 2, onChoose: choose
                    )
                    .disabled(isFetching)
                    if isFetching {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(L10n.tr("Looking for a Kakey backup")).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }

                if !errorMessage.isEmpty {
                    errorNotice
                }
            }
        }
        // Give focus to the password field once a backup is found. `@FocusState` must change after the current update; changing it
        // in the same pass is ignored.
        .onChange(of: hasBackup) { _, found in
            if found { Task { @MainActor in passwordFocused = true } }
        }
        .fairPasswordConfirmation(isPresented: $confirmingFairPassword, onConfirm: performUnlock)
        .sheet(item: $cloudSetup) { model in
            VStack(spacing: 0) {
                sheetHeader(model.title)
                CloudSetupView(model: model, finishTitle: L10n.tr("Restore from This Folder"), onBack: { cloudSetup = nil }) { result in
                    // Restore happens in onboarding's own status panel, so just close the connection sheet.
                    cloudSetup = nil
                    restore(from: .cloud(result.location), connection: result.connection)
                    return nil
                }
            }
            .frame(width: 560)
        }
    }

    @ViewBuilder
    private var errorNotice: some View {
        if missingCloudBackup != nil {
            InlineNotice(
                text: errorMessage, systemImage: "exclamationmark.triangle", tint: .red, actionTitle: L10n.tr("Choose Folder")
            ) { chooseAnotherCloudFolder() }
        } else {
            InlineNotice(text: errorMessage, systemImage: "exclamationmark.triangle", tint: .red)
        }
    }

    private func backupFoundPanel(detail: String) -> some View {
        HStack(alignment: .center, spacing: 13) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 38, height: 38)
                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.tr("Backup found"))
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            // Lets the user pick again after choosing the wrong location or forgetting this backup's password; without it the only way
            // out after finding a backup would be quitting the app.
            Button(L10n.tr("Change Location"), action: changeLocation)
                .buttonStyle(PressableButtonStyle())
                .disabled(store.isWorking)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45))
        }
    }

    private var isExport: Bool { store.pendingOnboardingExport != nil }

    /// Master password for an export file. "Use as master password" is checked by default and uses the export password, keeping the
    /// page simple; unchecking it shows new password and confirmation fields with the same rules as creating a vault. It must fit
    /// the smallest window, so the two fields sit side by side, the strength meter goes under the new password, and each field shows
    /// its own validation message.
    private var masterPasswordFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(L10n.tr("Use as Master Password"), isOn: $useExportPasswordAsMaster.animation(.easeInOut(duration: 0.2)))
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
            if !useExportPasswordAsMaster {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledSecureField(
                                label: L10n.tr("Master Password"),
                                text: $newPassword,
                                reveal: $revealNewPassword,
                                focused: $newPasswordFocused,
                                onSubmit: unlock
                            )
                            .newPasswordInput($newPassword)
                            StrengthMeter(strength: PasswordStrength.evaluate(newPassword), problem: newPasswordProblem)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledSecureField(
                                label: L10n.tr("Confirm Password"),
                                text: $confirmPassword,
                                reveal: $revealConfirmPassword,
                                focused: $confirmPasswordFocused,
                                onSubmit: unlock
                            )
                            .newPasswordInput($confirmPassword)
                            // Same line as the text under the strength meter on the left: skip the meter's height (4 pt bar + 5 pt
                            // spacing).
                            FieldMessage(text: mismatchProblem)
                                .padding(.top, 9)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// Validation when setting a separate master password, same as creating a vault: length and strength after leaving the new
    /// password field (under the strength meter), and the match while typing (under the confirmation field; rules in
    /// `PasswordConfirmation`).
    private var newPasswordProblem: String? {
        guard !useExportPasswordAsMaster, !newPasswordFocused else { return nil }
        return PasswordPolicy.problem(for: newPassword)
    }
    private var mismatchProblem: String? {
        guard !useExportPasswordAsMaster, newPasswordProblem == nil else { return nil }
        return PasswordConfirmation.problem(
            password: newPassword, confirm: confirmPassword, isEditingPassword: newPasswordFocused, isEditingConfirm: confirmPasswordFocused
        )
    }

    /// The master password the new vault will actually use.
    private var masterPassword: String { useExportPasswordAsMaster ? restorePassword : newPassword }

    /// Under "Backup found" only the source is shown, never the account, host or path: the service name for iCloud and cloud
    /// storage, the kind for folders and export files.
    private var backupSource: String {
        if isExport { return L10n.tr("From an exported file") }
        switch store.pendingOnboardingRestore?.location {
        case .folder: return L10n.tr("From a backup folder")
        case let location?: return L10n.format("From %@", location.title)
        case nil: return ""
        }
    }

    /// A backup has been fetched, no unlock is in progress, and a password is entered. Shared by the button's enabled state and
    /// Return to submit.
    private var canUnlock: Bool {
        guard hasBackup, !store.isWorking, !restorePassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard isExport, !useExportPasswordAsMaster else { return true }
        return PasswordPolicy.isAcceptableMasterPassword(newPassword) && newPassword == confirmPassword
    }

    private func choose(_ choice: SyncLocationChoice) {
        missingCloudBackup = nil
        switch choice {
        case .iCloud:
            fetch { await store.prepareOnboardingRestoreFromICloud() }
        case .folder(let url):
            do {
                restore(from: try store.syncLocation(forFolder: url))
            } catch {
                errorMessage = SyncErrorText.message(for: error)
            }
        case .exportFile(let url):
            fetch { store.prepareOnboardingExport(from: url) }
        case .cloud(let provider):
            let model = CloudSetupModel(provider: provider, purpose: .restore, service: store.cloudSetup) { NSWorkspace.shared.open($0) }
            // Already authorized services skip sign-in; a dedicated app folder searches for the backup directly without opening the
            // connection sheet.
            switch connections.prepare(model) {
            case .restore(let location, let connection):
                restore(from: .cloud(location), connection: connection)
            case .open(let resume):
                // Show the connection sheet first, then list folders inside it, so a slow network does not delay the sheet.
                model.perform {
                    cloudSetup = model
                    if let resume { await model.resume(with: resume.location, connection: resume.connection) }
                }
            }
        }
    }

    private func restore(from location: SyncLocation, connection: Data? = nil) {
        var missing: (location: CloudLocation, connection: Data)?
        if case .cloud(let cloud) = location, let connection {
            connections.remember(cloud, connection: connection)
            if cloud.provider.canChooseFolder { missing = (cloud, connection) }
        }
        fetch(missing: missing) {
            let outcome = await store.prepareOnboardingRestore(from: location, connection: connection)
            // If the fetch refreshed the token, the connection remembered for this onboarding is replaced with the latest one (reused
            // when the same service is chosen again after "Change Location").
            if outcome == .found, case .cloud(let cloud) = location, let latest = store.pendingOnboardingRestore?.connection {
                connections.remember(cloud, connection: latest)
            }
            return outcome
        }
    }

    /// Finds the backup and shows the result; when nothing is found and this cloud storage allows changing the folder (`missing`),
    /// the notice offers "Choose Folder".
    private func fetch(
        missing: (location: CloudLocation, connection: Data)? = nil, _ operation: @escaping () async -> OnboardingRestoreOutcome
    ) {
        errorMessage = ""
        missingCloudBackup = nil
        Task {
            let outcome = await operation()
            if outcome != .found {
                errorMessage = store.vaultError ?? L10n.tr("Unable to restore from backup")
            }
            if outcome == .notFound, let missing { missingCloudBackup = missing }
        }
    }

    /// Reopens the connection sheet to pick another folder: a user-chosen folder goes straight back to folder selection; if only the
    /// app folder was authorized, it switches to "Any Folder" and signs in again.
    private func chooseAnotherCloudFolder() {
        guard let missing = missingCloudBackup else { return }
        let model = CloudSetupModel(provider: missing.location.provider, purpose: .restore, service: store.cloudSetup) {
            NSWorkspace.shared.open($0)
        }
        errorMessage = ""
        missingCloudBackup = nil
        Task {
            connections.track(model)
            await model.chooseAnotherFolder(after: missing.location, connection: missing.connection)
            cloudSetup = model
        }
    }

    private func changeLocation() {
        restorePassword = ""
        newPassword = ""
        confirmPassword = ""
        useExportPasswordAsMaster = true
        errorMessage = ""
        store.discardOnboardingRestore()
    }

    private func unlock() {
        guard canUnlock else { return }
        // A "fair" master password for the new vault asks for confirmation first (same as creating a vault); weak passwords are
        // stopped by the rules.
        if isExport, PasswordStrength.evaluate(masterPassword) == .fair {
            confirmingFairPassword = true
        } else {
            performUnlock()
        }
    }

    private func performUnlock() {
        errorMessage = ""
        Task {
            let restored =
                isExport
                ? await store.completeExportOnboarding(password: restorePassword, masterPassword: masterPassword)
                : await store.completeRestoredOnboarding(password: restorePassword)
            if restored {
                restorePassword = ""
                newPassword = ""
                confirmPassword = ""
            } else {
                errorMessage = store.vaultError ?? L10n.tr("Unable to unlock")
            }
        }
    }
}

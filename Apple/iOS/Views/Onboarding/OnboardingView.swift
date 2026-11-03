import SwiftUI

/// First run: create a new vault, or restore from a backup location (iCloud, a folder, or cloud storage).
struct OnboardingView: View {
    private enum Step: Hashable {
        case create
        case restore
    }

    @State private var path: [Step] = []
    /// Cloud storage connections authorized during first-run restore; memory only, released with onboarding
    @State private var restoreConnections = RestoreCloudConnections()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 16) {
                        BrandMark(size: 112)
                        Text(L10n.tr("Protect your 2FA with Kakey"))
                            .font(.largeTitle.bold())
                            .multilineTextAlignment(.center)
                        Text(L10n.tr("End-to-end encrypted, effortless to use, and ready on every device you own."))
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 40)

                    VStack(spacing: 12) {
                        ChoiceCard(
                            systemImage: "sparkles",
                            title: L10n.tr("Start fresh"),
                            detail: L10n.tr("Set a master password to get started.")
                        ) { path.append(.create) }
                        ChoiceCard(
                            systemImage: "icloud.and.arrow.down",
                            title: L10n.tr("Restore a backup"),
                            detail: L10n.tr("From iCloud, a folder or a cloud service.")
                        ) { path.append(.restore) }
                    }
                }
                .padding(24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .create: CreateVaultView()
                case .restore: RestoreView(connections: restoreConnections)
                }
            }
        }
    }
}

private struct ChoiceCard: View {
    var systemImage: String
    var title: String
    var detail: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(18)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Sets the master password and creates the vault.
struct CreateVaultView: View {
    @Environment(MobileVaultStore.self) private var store
    @State private var password = ""
    @State private var confirmation = ""
    /// On by default when the device supports it; capability is probed once when the store starts.
    @State private var enableBiometrics = false
    @FocusState private var focused: Field?

    private enum Field { case password, confirmation }

    private var mismatch: Bool { !confirmation.isEmpty && password != confirmation }
    /// Shows length and strength problems only after leaving the password field (weak passwords are not allowed), never while
    /// typing.
    private var passwordProblem: String? { focused == .password ? nil : PasswordPolicy.problem(for: password) }
    @State private var confirmingFairPassword = false
    private var canCreate: Bool { PasswordPolicy.isAcceptableMasterPassword(password) && password == confirmation && !store.isWorking }

    var body: some View {
        Form {
            Section {
                Label {
                    Text(L10n.tr("Your master password encrypts your 2FA on this device and in every backup. Pick one you won’t forget."))
                } icon: {
                    Image(systemName: "lock.shield").foregroundStyle(.tint)
                }
                .padding(.vertical, 4)
            }
            Section {
                SecureField(L10n.tr("Enter a password"), text: $password)
                    .keyboardType(.asciiCapable)
                    .textContentType(.newPassword)
                    .newPasswordInput($password)
                    .focused($focused, equals: .password)
                    .submitLabel(.next)
                    .onSubmit { focused = .confirmation }
                SecureField(L10n.tr("Enter again"), text: $confirmation)
                    .keyboardType(.asciiCapable)
                    .textContentType(.newPassword)
                    .newPasswordInput($confirmation)
                    .focused($focused, equals: .confirmation)
                    .submitLabel(.done)
                    .onSubmit(submit)
            } header: {
                Text(L10n.tr("New Password"))
            } footer: {
                VStack(alignment: .leading, spacing: 10) {
                    PasswordStrengthBar(password: password)
                    if let passwordProblem {
                        Text(passwordProblem).foregroundStyle(.red)
                    }
                    if mismatch {
                        Text(L10n.tr("Passwords do not match")).foregroundStyle(.red)
                    }
                    // Why creation failed (disk write, etc.); cleared when the password changes
                    if let error = store.unlockError {
                        Text(error).foregroundStyle(.red)
                    }
                }
                .padding(.top, 6)
            }

            if store.biometrics.isAvailable {
                Section {
                    Toggle(isOn: $enableBiometrics) {
                        Label(L10n.format("Unlock with %@", store.biometrics.displayName), systemImage: store.biometrics.symbolName)
                    }
                } footer: {
                    Text(
                        L10n.tr("You can always unlock with your master password."))
                }
            }

            Section {
                Button(action: submit) {
                    HStack {
                        Spacer()
                        if store.isWorking { ProgressView() } else { Text(L10n.tr("Create Vault")).bold() }
                        Spacer()
                    }
                }
                .disabled(!canCreate)
            } footer: {
                Text(
                    L10n.tr(
                        "Your master password is never uploaded and can’t be recovered. If you forget it, this device and your backups can’t be decrypted."
                    ))
            }
        }
        .navigationTitle(L10n.tr("Set master password"))
        .navigationBarTitleDisplayMode(.inline)
        .fairPasswordConfirmation(isPresented: $confirmingFairPassword, onConfirm: create)
        .onAppear {
            enableBiometrics = store.biometrics.isAvailable
            focused = .password
        }
        .onChange(of: password) { store.unlockError = nil }
        .onChange(of: confirmation) { store.unlockError = nil }
    }

    /// "Fair" strength asks for confirmation before creating; weak passwords cannot be submitted.
    private func submit() {
        guard canCreate else { return }
        if PasswordStrength.evaluate(password) == .fair {
            confirmingFairPassword = true
        } else {
            create()
        }
    }

    private func create() {
        guard canCreate else { return }
        Task { _ = await store.createVault(password: password, enableBiometrics: enableBiometrics) }
    }
}

/// Fetches the encrypted vault from a backup (folder, WebDAV, or Nextcloud); on success, goes to the lock screen to unlock with the
/// original master password. A Kakey export file can also be chosen (same as the Mac): the next page asks for the export password
/// and, once it decrypts, creates a new vault with a separately set master password.
struct RestoreView: View {
    @Environment(MobileVaultStore.self) private var store
    @Environment(\.openURL) private var openURL
    /// Cloud storage connections authorized during this onboarding: choosing the same service again needs no new sign-in.
    var connections: RestoreCloudConnections
    @State private var error: String?
    @State private var cloudSetup: CloudSetupModel?
    /// When cloud storage had no backup and the service can switch folders, remembers the location and connection so the message
    /// below offers "Choose Folder" (same as the Mac).
    @State private var missingCloudBackup: (location: CloudLocation, connection: Data)?

    var body: some View {
        Form {
            Section {
                Label {
                    Text(
                        L10n.tr("Choose where your backup is, then unlock it with your master password."))
                } icon: {
                    Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
                }
                .padding(.vertical, 4)
            }
            locationSections
        }
        .navigationTitle(L10n.tr("Restore a backup"))
        .navigationBarTitleDisplayMode(.inline)
        // A found backup or chosen export file opens the next page; going back returns to the location list to pick another source
        // or to the welcome page to create a vault, so the page has no "Change Location"
        .navigationDestination(
            isPresented: Binding(
                get: { store.pendingOnboardingRestore != nil || store.pendingOnboardingExport != nil },
                set: { if !$0 { store.discardOnboardingRestore() } })
        ) {
            if let export = store.pendingOnboardingExport {
                RestoreUnlockView(source: .export(fileName: export.fileName))
            } else if let pending = store.pendingOnboardingRestore {
                RestoreUnlockView(source: .backup(pending.location))
            }
        }
        .cloudSetupSheet($cloudSetup, finishTitle: L10n.tr("Restore")) { result in
            // Restore runs inside onboarding and shows errors there: just close the connection screen
            cloudSetup = nil
            Task { await restoreCloud(result.location, connection: result.connection) }
            return nil
        }
    }

    @ViewBuilder
    private var locationSections: some View {
        resultSection
        SyncLocationOptionsSection(current: nil, iCloudAvailable: store.iCloud != nil) {
            missingCloudBackup = nil
            Task { error = await store.restoreFromICloud() }
        } onFolder: { url in
            missingCloudBackup = nil
            Task { error = await store.restore(from: url) }
        } onCloud: { provider in
            missingCloudBackup = nil
            let model = CloudSetupModel(provider: provider, purpose: .restore, service: store.cloudSetup) { openURL($0) }
            // Already authorized: no new sign-in; app folders search for the backup directly without opening the connection screen
            switch connections.prepare(model) {
            case .restore(let location, let connection):
                Task { await restoreCloud(location, connection: connection) }
            case .open(let resume):
                // Present the connection screen first and list folders inside it, so folder selection happens in the same pass
                // without the form flashing first
                model.perform {
                    cloudSetup = model
                    if let resume { await model.resume(with: resume.location, connection: resume.connection) }
                }
            }
        } onExportFile: { url in
            missingCloudBackup = nil
            error = store.prepareExportRestore(from: url)
        }
        .disabled(store.isWorking)
    }

    /// Search progress and failure result, below the description and above the location list so they are the first thing seen on
    /// returning to this page. A failure is a Label with an orange warning icon (bold title, reason in secondary color), followed by
    /// a "Choose Folder" row when the folder can be changed.
    @ViewBuilder
    private var resultSection: some View {
        if store.isWorking {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(L10n.tr("Looking for a Kakey backup")).foregroundStyle(.secondary)
                }
            }
        } else if let error {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.restoreMissedBackup ? L10n.tr("No Backup Found") : L10n.tr("Unable to restore from backup"))
                            .font(.headline)
                        Text(error).font(.subheadline).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .padding(.vertical, 2)
                if missingCloudBackup != nil {
                    Button(action: chooseAnotherCloudFolder) {
                        Label(L10n.tr("Choose Folder"), systemImage: "folder")
                    }
                }
            }
        }
    }

    /// Restores with this cloud storage connection: remembers the authorization; when no backup was found and the service can
    /// switch folders, the message below offers "Choose Folder".
    private func restoreCloud(_ location: CloudLocation, connection: Data) async {
        connections.remember(location, connection: connection)
        error = await store.restore(from: .cloud(location), connection: connection)
        // If fetching refreshed the token, replace the remembered connection with the latest one (reused when the same service is
        // chosen again after going back)
        if error == nil, let latest = store.pendingOnboardingRestore?.connection {
            connections.remember(location, connection: latest)
        }
        if error != nil, store.restoreMissedBackup, location.provider.canChooseFolder {
            missingCloudBackup = (location, connection)
        }
    }

    /// Reopens the connection screen to pick another folder: a custom folder goes straight back to folder selection; with only the
    /// app folder authorized, "Any Folder" is preselected for a new sign-in.
    private func chooseAnotherCloudFolder() {
        guard let missing = missingCloudBackup else { return }
        let model = CloudSetupModel(provider: missing.location.provider, purpose: .restore, service: store.cloudSetup) { openURL($0) }
        error = nil
        missingCloudBackup = nil
        Task {
            connections.track(model)
            await model.chooseAnotherFolder(after: missing.location, connection: missing.connection)
            cloudSetup = model
        }
    }
}

/// Second page of first-run restore: the backup found or the chosen Kakey export file. Shows the description, source, password,
/// biometrics switch, continue button, and failure reason. A backup is written to disk only after it decrypts with its original
/// master password; an export file, once decrypted, creates a new vault with a separately set master password (or the export
/// password when that option is on). Going back returns to the location list (`store.discardOnboardingRestore()`), so a user who
/// cannot remember the password can pick another source or return to the welcome page to create a vault.
private struct RestoreUnlockView: View {
    enum Source {
        case backup(SyncLocation)
        case export(fileName: String)
    }

    @Environment(MobileVaultStore.self) private var store
    var source: Source
    @State private var password = ""
    @State private var enableBiometrics = false
    @State private var error: String?
    /// Export file: the export password is used as the master password by default; turning this off reveals new password fields
    @State private var useExportPasswordAsMaster = true
    @State private var newPassword = ""
    @State private var confirmation = ""
    @State private var confirmingFairPassword = false
    @FocusState private var focused: Field?

    private enum Field { case password, newPassword, confirmation }

    private var isExport: Bool {
        if case .export = source { return true }
        return false
    }

    /// The master password the new vault will actually use (only meaningful for export files).
    private var masterPassword: String { useExportPasswordAsMaster ? password : newPassword }

    private var canSubmit: Bool {
        guard !password.isEmpty, !store.isWorking else { return false }
        guard isExport, !useExportPasswordAsMaster else { return true }
        return PasswordPolicy.isAcceptableMasterPassword(newPassword) && newPassword == confirmation
    }

    var body: some View {
        Form {
            // No description: the title is already in the navigation bar, so content starts with the source
            Section { sourceLabel }
            Section {
                // No placeholder: the section header already says what the password is for
                SecureField(String(), text: $password)
                    .accessibilityLabel(passwordTitle)
                    .textContentType(.password)
                    .focused($focused, equals: .password)
                    .submitLabel(isExport && !useExportPasswordAsMaster ? .next : .done)
                    .onSubmit { if isExport && !useExportPasswordAsMaster { focused = .newPassword } else { submit() } }
                    .onChange(of: password) { error = nil }
            } header: {
                Text(passwordTitle)
            }
            if isExport { masterPasswordSections }
            if store.biometrics.isAvailable {
                Section {
                    Toggle(isOn: $enableBiometrics) {
                        Label(L10n.format("Unlock with %@", store.biometrics.displayName), systemImage: store.biometrics.symbolName)
                    }
                }
            }
            Section {
                Button(action: submit) {
                    HStack {
                        Spacer()
                        if store.isWorking { ProgressView() } else { Text(L10n.tr("Unlock & Continue")).bold() }
                        Spacer()
                    }
                }
                .disabled(!canSubmit)
            } footer: {
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(L10n.tr("Restore a backup"))
        .navigationBarTitleDisplayMode(.inline)
        // Cannot go back while unlocking / creating the vault
        .navigationBarBackButtonHidden(store.isWorking)
        .fairPasswordConfirmation(isPresented: $confirmingFairPassword, onConfirm: perform)
        .onAppear {
            enableBiometrics = store.biometrics.isAvailable
            focused = .password
        }
    }

    /// Master password for an export file: "Use as master password" is on by default and uses the export password, keeping the page
    /// simple; turning it off reveals new password and confirmation fields with the same rules as creating a vault.
    @ViewBuilder
    private var masterPasswordSections: some View {
        Section {
            Toggle(L10n.tr("Use as Master Password"), isOn: $useExportPasswordAsMaster.animation())
                .onChange(of: useExportPasswordAsMaster) { error = nil }
        }
        if !useExportPasswordAsMaster {
            newPasswordSection
        }
    }

    private var newPasswordSection: some View {
        Section {
            SecureField(L10n.tr("Enter a password"), text: $newPassword)
                .keyboardType(.asciiCapable)
                .textContentType(.newPassword)
                .newPasswordInput($newPassword)
                .focused($focused, equals: .newPassword)
                .submitLabel(.next)
                .onSubmit { focused = .confirmation }
            SecureField(L10n.tr("Enter again"), text: $confirmation)
                .keyboardType(.asciiCapable)
                .textContentType(.newPassword)
                .newPasswordInput($confirmation)
                .focused($focused, equals: .confirmation)
                .submitLabel(.done)
                .onSubmit(submit)
        } header: {
            Text(L10n.tr("Master Password"))
        } footer: {
            VStack(alignment: .leading, spacing: 10) {
                PasswordStrengthBar(password: newPassword)
                // Shows length and strength problems only after leaving the new password field, never while typing (same as
                // creating a vault)
                if focused != .newPassword, let problem = PasswordPolicy.problem(for: newPassword) {
                    Text(problem).foregroundStyle(.red)
                }
                if !confirmation.isEmpty, newPassword != confirmation {
                    Text(L10n.tr("Passwords do not match")).foregroundStyle(.red)
                }
            }
            .padding(.top, 6)
        }
        .onChange(of: newPassword) { error = nil }
        .onChange(of: confirmation) { error = nil }
    }

    private var passwordTitle: String {
        switch source {
        case .backup: L10n.tr("Existing Master Password")
        case .export: L10n.tr("Export Password")
        }
    }

    /// Below "Backup found" only the source is shown, never the account, host, or path (same as the Mac): the service name for iCloud
    /// and cloud storage, the kind for folders.
    @ViewBuilder
    private var sourceLabel: some View {
        switch source {
        case .backup(let location):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("Backup found"))
                    Text(Self.origin(of: location)).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            }
        case .export(let fileName):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("From an exported file"))
                    Text(fileName).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                }
            } icon: {
                Image(systemName: "doc.badge.arrow.up").foregroundStyle(.tint)
            }
        }
    }

    private static func origin(of location: SyncLocation) -> String {
        if case .folder = location { return L10n.tr("From a backup folder") }
        return L10n.format("From %@", location.title)
    }

    private func submit() {
        guard canSubmit else { return }
        // Confirm first when the new vault's master password is "Fair" strength (same as creating a vault); weak passwords are
        // blocked by the rules
        if isExport, PasswordStrength.evaluate(masterPassword) == .fair {
            confirmingFairPassword = true
        } else {
            perform()
        }
    }

    private func perform() {
        error = nil
        Task {
            switch source {
            case .backup: error = await store.completeOnboardingRestore(password: password, enableBiometrics: enableBiometrics)
            case .export:
                error = await store.completeExportRestore(
                    password: password, masterPassword: masterPassword, enableBiometrics: enableBiometrics)
            }
        }
    }
}

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(MobileVaultStore.self) private var store
    @Environment(AddFlowController.self) private var flow
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section {
                    if store.biometrics.isAvailable {
                        Toggle(
                            isOn: Binding(
                                get: { store.preferences.biometricsEnabled },
                                set: { enabled in Task { await store.setBiometricsEnabled(enabled) } }
                            )
                        ) {
                            Label(L10n.format("Unlock with %@", store.biometrics.displayName), systemImage: store.biometrics.symbolName)
                        }
                    }
                    Picker(selection: $store.preferences.autoLock) {
                        ForEach(AutoLockMode.allCases) { Text($0.localizedTitle).tag($0) }
                    } label: {
                        Label(L10n.tr("Auto-Lock"), systemImage: "lock.rotation")
                    }
                    NavigationLink {
                        ChangePasswordView()
                    } label: {
                        Label(L10n.tr("Change Master Password"), systemImage: "key.horizontal")
                    }
                } header: {
                    Text(L10n.tr("Security"))
                } footer: {
                    Text(
                        L10n.tr(
                            "Locks after the selected time without activity or in the background, and immediately when the device locks"))
                }

                Section {
                    NavigationLink {
                        SyncSettingsView()
                    } label: {
                        LabeledContent {
                            Text(syncSummary).foregroundStyle(.secondary)
                        } label: {
                            Label(L10n.tr("Sync & Backup"), systemImage: "arrow.triangle.2.circlepath.icloud")
                        }
                    }
                    NavigationLink {
                        ExportBackupView()
                    } label: {
                        Label(L10n.tr("Export Encrypted Backup"), systemImage: "square.and.arrow.up")
                    }
                    Button {
                        // Two system presentations cannot be shown at once: present the file picker after Settings is dismissed (the sheet's onDismiss)
                        flow.presentsFileImporterAfterSheetDismiss = true
                        dismiss()
                    } label: {
                        Label(L10n.tr("Import Backup File"), systemImage: "square.and.arrow.down")
                    }
                } header: {
                    Text(L10n.tr("Data"))
                }

                Section(L10n.tr("Appearance")) {
                    Picker(selection: $store.preferences.appearance) {
                        ForEach(AppearanceMode.allCases) { Text($0.localizedTitle).tag($0) }
                    } label: {
                        Label(L10n.tr("Appearance"), systemImage: "circle.lefthalf.filled")
                    }
                    Picker(selection: $store.preferences.language) {
                        ForEach(LanguageMode.allCases) { Text($0.pickerTitle).tag($0) }
                    } label: {
                        Label(L10n.tr("Language"), systemImage: "globe")
                    }
                }

                Section {
                    LabeledContent(L10n.tr("Version"), value: Self.version)
                    Button(role: .destructive) {
                        confirmReset = true
                    } label: {
                        Label(L10n.tr("Reset App"), systemImage: "arrow.counterclockwise")
                    }
                } footer: {
                    Text(L10n.tr("Erases the vault and settings on this device. Your backup isn’t affected."))
                }
            }
            .navigationTitle(L10n.tr("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("Done")) { dismiss() }
                }
            }
            .alert(L10n.tr("Reset Kakey?"), isPresented: $confirmReset) {
                Button(L10n.tr("Erase Local Data"), role: .destructive) {
                    // Verify identity on the spot before wiping; on cancel or failure, stay in Settings
                    Task {
                        if await store.resetApplicationAfterAuthentication() { dismiss() }
                    }
                }
                Button(L10n.tr("Cancel"), role: .cancel) {}
            } message: {
                Text(L10n.tr("Erases the vault and settings on this device. Your backup isn’t affected."))
            }
        }
    }

    private var syncSummary: String {
        switch store.syncStatus {
        case .notConfigured: L10n.tr("Off")
        case .idle: store.syncFolderName ?? L10n.tr("On")
        case .running: L10n.tr("Syncing")
        case .conflict: L10n.tr("Sync Conflict")
        case .unreadable: L10n.tr("Backup Can’t Be Opened")
        case .failed: L10n.tr("Sync Failed")
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build)) · Core \(coreVersion())"
    }
}

struct ChangePasswordView: View {
    @Environment(MobileVaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var confirmation = ""
    @State private var error: String?
    @State private var confirmingFairPassword = false
    @State private var isUpdatingBackup = false
    @State private var backupNotUpdated = false
    @FocusState private var newFocused: Bool

    /// Shows length and strength problems only after leaving the new password field (weak passwords are not allowed).
    private var newProblem: String? { newFocused ? nil : PasswordPolicy.problem(for: new) }
    private var canSubmit: Bool {
        !current.isEmpty && PasswordPolicy.isAcceptableMasterPassword(new) && new == confirmation && !store.isWorking
            && !isUpdatingBackup
    }

    var body: some View {
        Form {
            Section(L10n.tr("Current Master Password")) {
                SecureField(L10n.tr("Enter current password"), text: $current).textContentType(.password).keyboardType(.asciiCapable)
            }
            Section {
                SecureField(L10n.tr("At least 8 characters"), text: $new).textContentType(.newPassword).keyboardType(.asciiCapable)
                    .newPasswordInput($new)
                    .focused($newFocused)
                SecureField(L10n.tr("Re-enter new password"), text: $confirmation).textContentType(.newPassword).keyboardType(.asciiCapable)
                    .newPasswordInput($confirmation)
            } header: {
                Text(L10n.tr("New Password"))
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    PasswordStrengthBar(password: new)
                    if let newProblem {
                        Text(newProblem).foregroundStyle(.red)
                    }
                    if !confirmation.isEmpty && new != confirmation {
                        Text(L10n.tr("New passwords do not match")).foregroundStyle(.red)
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                    Text(
                        L10n.tr(
                            "The vault on this device is re-encrypted with the new password. If sync is on, your backup is updated too."
                        ))
                }
                .padding(.top, 6)
            }
            Section {
                Button {
                    if PasswordStrength.evaluate(new) == .fair {
                        confirmingFairPassword = true
                    } else {
                        changePassword()
                    }
                } label: {
                    HStack {
                        Spacer()
                        if store.isWorking || isUpdatingBackup { ProgressView() } else { Text(L10n.tr("Change Password")).bold() }
                        Spacer()
                    }
                }
                .disabled(!canSubmit)
            }
        }
        .navigationTitle(L10n.tr("Change Master Password"))
        .navigationBarTitleDisplayMode(.inline)
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

    private func changePassword() {
        Task {
            error = await store.changePassword(current: current, new: new)
            guard error == nil else { return }
            // With a backup set up: sync right away and warn if the backup was not updated (it still holds the vault encrypted with
            // the old password)
            isUpdatingBackup = true
            let updated = await store.backupUpdatedAfterPasswordChange()
            isUpdatingBackup = false
            if updated {
                store.showToast(L10n.tr("Master password changed"), systemImage: "checkmark.circle.fill")
                dismiss()
            } else {
                backupNotUpdated = true
            }
        }
    }
}

/// Encrypted export: encrypted with a separate export password, then saved to Files or sent to another device via the share sheet.
struct ExportBackupView: View {
    @Environment(MobileVaultStore.self) private var store
    @State private var password = ""
    @State private var confirmation = ""
    @State private var exported: ExportedBackup?
    @State private var error: String?
    @State private var isExporting = false
    @State private var confirmingFairPassword = false
    @FocusState private var passwordFocused: Bool

    /// Shows length and strength problems only after leaving the password field. Export passwords follow the master password rules;
    /// weak passwords cannot export.
    private var passwordProblem: String? { passwordFocused ? nil : PasswordPolicy.problem(for: password) }
    private var canExport: Bool { PasswordPolicy.isAcceptableExportPassword(password) && password == confirmation && !isExporting }

    var body: some View {
        Form {
            Section {
                SecureField(L10n.tr("At least 8 characters"), text: $password).textContentType(.newPassword).keyboardType(.asciiCapable)
                    .newPasswordInput($password)
                    .focused($passwordFocused)
                SecureField(L10n.tr("Enter again"), text: $confirmation).textContentType(.newPassword).keyboardType(.asciiCapable)
                    .newPasswordInput($confirmation)
            } header: {
                Text(L10n.tr("Export Password"))
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    PasswordStrengthBar(password: password)
                    if let passwordProblem {
                        Text(passwordProblem).foregroundStyle(.red)
                    }
                    if !confirmation.isEmpty && password != confirmation {
                        Text(L10n.tr("Passwords do not match")).foregroundStyle(.red)
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                    Text(L10n.tr("The backup is encrypted with this separate password. You’ll need it to import on another device."))
                }
                .padding(.top, 6)
            }
            Section {
                Button {
                    // "Fair" strength first confirms that the export file might be cracked; the button is disabled for weak passwords
                    if PasswordStrength.evaluate(password) == .fair {
                        confirmingFairPassword = true
                    } else {
                        export()
                    }
                } label: {
                    HStack {
                        Spacer()
                        if isExporting { ProgressView() } else { Text(L10n.tr("Export")).bold() }
                        Spacer()
                    }
                }
                .disabled(!canExport)
            }
        }
        .navigationTitle(L10n.tr("Export Encrypted Backup"))
        .navigationBarTitleDisplayMode(.inline)
        .fairPasswordConfirmation(isPresented: $confirmingFairPassword, onConfirm: export)
        .fileExporter(
            isPresented: Binding(get: { exported != nil }, set: { if !$0 { exported = nil } }),
            document: exported,
            contentType: .json,
            defaultFilename: "Kakey-\(Date.now.formatted(.iso8601.year().month().day()))"
        ) { result in
            if case .success = result {
                store.showToast(L10n.tr("Encrypted backup exported"), systemImage: "checkmark.circle.fill")
                password = ""
                confirmation = ""
            }
        }
    }

    private func export() {
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                exported = ExportedBackup(data: try await store.exportBackup(password: password))
                error = nil
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

struct ExportedBackup: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Sync and backup (location can be a folder, WebDAV, or Nextcloud): current location and status, Sync Now, change location;
/// choosing which copy to keep on conflict; sync history below and Stop Syncing at the bottom.
struct SyncSettingsView: View {
    @Environment(MobileVaultStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var isChoosingLocation = false
    @State private var cloudSetup: CloudSetupModel?
    @State private var confirmingStop = false
    @State private var linkError: String?
    @State private var conflictReview: ConflictReview?
    @State private var isLoadingReview = false
    @State private var reviewError: String?
    @State private var stopError: String?
    /// "Restore from Backup" when the backup cannot be decrypted asks for that backup's master password first; this device is
    /// replaced only after it decrypts
    @State private var isEnteringRestorePassword = false
    @State private var restorePassword = ""
    @State private var restoreError: String?
    @State private var isRestoringBackup = false

    var body: some View {
        Form {
            Section {
                if let location = store.syncLocation {
                    LabeledContent {
                        Text(location.detail ?? "").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    } label: {
                        Label {
                            Text(location.title)
                        } icon: {
                            SyncLocationIcon(kind: location.iconKind, size: 30)
                        }
                    }
                    if location.isInsecure {
                        Label(L10n.tr("Unencrypted connection"), systemImage: "lock.open.fill").foregroundStyle(.orange)
                    }
                    if location.hasUnverifiedCertificate {
                        Label(L10n.tr("Certificate not verified"), systemImage: "exclamationmark.shield.fill").foregroundStyle(.orange)
                    }
                } else {
                    LabeledContent(L10n.tr("Location")) {
                        Text(L10n.tr("Off")).foregroundStyle(.secondary)
                    }
                }
                statusRow
                Button {
                    isChoosingLocation = true
                } label: {
                    Label(store.syncLocation == nil ? L10n.tr("Set Up") : L10n.tr("Change Location"), systemImage: "arrow.left.arrow.right")
                }
                .disabled(store.syncStatus == .running)
                if store.syncStatus != .notConfigured, store.syncStatus != .unreadable {
                    Button {
                        Task { await store.sync() }
                    } label: {
                        Label(L10n.tr("Back Up Now"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(store.syncStatus == .running)
                }
            } footer: {
                Text(L10n.tr("Backups are end-to-end encrypted with your master password; only you can open them."))
            }

            if store.syncStatus == .unreadable {
                Section {
                    Button {
                        restorePassword = ""
                        isEnteringRestorePassword = true
                    } label: {
                        HStack {
                            Label(L10n.tr("Restore from Backup"), systemImage: "arrow.down.circle")
                            if isRestoringBackup {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isRestoringBackup)
                } header: {
                    Text(L10n.tr("Backup Can’t Be Opened"))
                } footer: {
                    if let restoreError {
                        Text(restoreError).foregroundStyle(.red)
                    } else {
                        Text(
                            (VaultSyncError.unreadableRemote.errorDescription ?? "") + " "
                                + L10n.tr(
                                    "To use that backup, restore from it and unlock with its master password. This replaces the vault on this device."
                                )
                        )
                    }
                }
            }

            if store.syncStatus == .conflict {
                Section {
                    Button {
                        openConflict()
                    } label: {
                        HStack {
                            Label(L10n.tr("Resolve Conflict"), systemImage: "arrow.triangle.merge")
                            if isLoadingReview {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isLoadingReview)
                } header: {
                    Text(L10n.tr("Sync Conflict Detected"))
                } footer: {
                    Text(
                        reviewError
                            ?? L10n.tr(
                                "This device and the backup both changed. Compare the accounts on each side, then keep one copy or merge both."
                            ))
                }
            }

            Section(L10n.tr("Backup History")) {
                if store.syncHistory.isEmpty {
                    Text(L10n.tr("No backup history yet")).foregroundStyle(.secondary)
                } else {
                    ForEach(store.syncHistory) { item in
                        // Same layout as the Mac: direction icon, result and trigger (naming the other device when it came from one),
                        // time and size on the right
                        HStack(spacing: 12) {
                            Image(systemName: item.systemImage)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(item.isWarning ? Color.orange : Color.secondary)
                                .frame(width: 28, height: 28)
                                .background((item.isWarning ? Color.orange : Color.secondary).opacity(0.12), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).foregroundStyle(item.isWarning ? Color.orange : Color.primary)
                                if let detail = item.detail(thisDevice: DeviceInfo.name) {
                                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(item.date.formatted(Date.FormatStyle(locale: L10n.locale).month(.abbreviated).day().hour().minute()))
                                Text(item.size).foregroundStyle(.tertiary)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        }
                    }
                }
            }

            if store.syncStatus != .notConfigured {
                Section {
                    Button(role: .destructive) {
                        confirmingStop = true
                    } label: {
                        Text(L10n.tr("Stop Syncing"))
                    }
                } footer: {
                    Text(L10n.tr("The backup already stored there is kept."))
                }
            }
        }
        .navigationTitle(L10n.tr("Sync & Backup"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(stopTitle, isPresented: $confirmingStop) {
            if store.syncLocation?.isICloud == true {
                Button(L10n.tr("Turn Off and Keep Backup")) { store.stopSync() }
                Button(L10n.tr("Turn Off and Delete iCloud Backup"), role: .destructive) {
                    Task { stopError = await store.stopSyncDeletingICloudBackup() }
                }
            } else {
                Button(L10n.tr("Stop Syncing"), role: .destructive) { store.stopSync() }
            }
            Button(L10n.tr("Cancel"), role: .cancel) {}
        } message: {
            if store.syncLocation?.isICloud == true {
                Text(
                    L10n.tr(
                        "Deleting removes the encrypted backup from iCloud for all your devices. Devices that still use iCloud backup upload their copy again."
                    ))
            }
        }
        .alert(L10n.tr("Restore from Backup"), isPresented: $isEnteringRestorePassword) {
            SecureField(L10n.tr("Existing Master Password"), text: $restorePassword)
                .textContentType(.password)
            Button(L10n.tr("Cancel"), role: .cancel) {}
            Button(L10n.tr("Restore"), action: restoreBackup).disabled(restorePassword.isEmpty)
        } message: {
            Text(
                L10n.tr("To use that backup, restore from it and unlock with its master password. This replaces the vault on this device.")
            )
        }
        .alert(
            L10n.tr("Couldn’t Delete the iCloud Backup"),
            isPresented: Binding(get: { stopError != nil }, set: { if !$0 { stopError = nil } })
        ) {
        } message: {
            Text(stopError ?? "")
        }
        .navigationDestination(item: $conflictReview) { review in
            ConflictResolutionScreen(review: review) { choice, preferRemote in
                Task {
                    switch choice {
                    case .merge: await store.mergeWithBackup(review, preferRemote: preferRemote)
                    case .keepLocal: await store.resolveConflictKeepingLocal()
                    case .useBackup: await store.resolveConflictUsingRemote()
                    }
                }
            }
        }
        .sheet(isPresented: $isChoosingLocation, onDismiss: { linkError = nil }) {
            NavigationStack {
                Form {
                    SyncLocationOptionsSection(current: store.syncLocation, iCloudAvailable: store.iCloud != nil) {
                        Task {
                            linkError = await store.linkICloud()
                            if linkError == nil { isChoosingLocation = false }
                        }
                    } onFolder: { url in
                        Task {
                            linkError = await store.configureSync(folder: url)
                            if linkError == nil { isChoosingLocation = false }
                        }
                    } onCloud: { provider in
                        cloudSetup = CloudSetupModel(provider: provider, service: store.cloudSetup) { openURL($0) }
                    }
                    if let linkError {
                        Section {
                            Label(linkError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        }
                    }
                }
                .navigationTitle(L10n.tr("Choose Location"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.tr("Cancel")) { isChoosingLocation = false }
                    }
                }
                .cloudSetupSheet($cloudSetup, finishTitle: L10n.tr("Use This Folder")) { result in
                    if let error = await store.configureSync(.cloud(result.location), connection: result.connection) { return error }
                    isChoosingLocation = false
                    cloudSetup = nil
                    return nil
                }
            }
        }
    }

    private func openConflict() {
        isLoadingReview = true
        reviewError = nil
        Task {
            switch await store.loadConflictReview() {
            case .success(let review): conflictReview = review
            case .failure(let failure): reviewError = failure.message
            }
            isLoadingReview = false
        }
    }

    /// Decrypts the backup with the entered password, then replaces this device. On a wrong password nothing changes here and
    /// the reason appears in the section footer.
    private func restoreBackup() {
        let password = restorePassword
        restorePassword = ""
        restoreError = nil
        isRestoringBackup = true
        Task {
            restoreError = await store.restoreUnreadableBackup(password: password)
            isRestoringBackup = false
        }
    }

    private var stopTitle: String {
        if case .cloud(let location) = store.syncLocation {
            return L10n.format("Turn off backup and sign out of %@?", location.provider.displayName)
        }
        return L10n.tr("Turn off backup?")
    }

    @ViewBuilder
    private var statusRow: some View {
        switch store.syncStatus {
        case .notConfigured:
            EmptyView()
        case .idle:
            Label(L10n.tr("On"), systemImage: "checkmark.icloud").foregroundStyle(.green)
        case .running:
            HStack {
                ProgressView()
                Text(L10n.tr("Syncing"))
            }
        case .conflict:
            Label(L10n.tr("Sync Conflict"), systemImage: "exclamationmark.icloud").foregroundStyle(.orange)
        case .unreadable:
            Label(L10n.tr("Backup Can’t Be Opened"), systemImage: "lock.trianglebadge.exclamationmark").foregroundStyle(.red)
        case .failed(let message):
            Label(message, systemImage: "xmark.icloud").foregroundStyle(.red)
        }
    }
}

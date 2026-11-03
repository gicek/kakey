import SwiftUI

/// A section listing backup locations (see docs/TECHNICAL.md): iCloud (CloudKit), the cloud storage available in this build, and
/// finally "Other Folder" (the system file picker; iCloud Drive and cloud drive app folders both work). Only "Other Folder" has a
/// description; the rest show just a name (same as the Mac). Shared by "change location" in Sync & Backup and by first-run restore.
/// When the build lacks the iCloud capability, the iCloud row is disabled with the reason.
struct SyncLocationOptionsSection: View {
    var current: SyncLocation?
    var iCloudAvailable: Bool
    var onICloud: () -> Void
    var onFolder: (URL) -> Void
    var onCloud: (CloudProvider) -> Void
    /// Passed only for first-run restore: adds a "Kakey Export File" row below "Other Folder"; each opens a picker limited to folders
    /// or to `.json` files respectively.
    var onExportFile: ((URL) -> Void)? = nil

    /// With two `fileImporter`s on one view only the last one works, so a single picker is used and its allowed types depend on
    /// which row was tapped.
    private enum Picking { case folder, exportFile }
    @State private var isPicking = false
    @State private var picking = Picking.folder

    var body: some View {
        Section {
            Button(action: onICloud) {
                row(
                    "iCloud", subtitle: iCloudAvailable ? nil : L10n.tr("Not available in this build of Kakey"),
                    icon: .iCloud, isCurrent: current?.isICloud == true, isEnabled: iCloudAvailable)
            }
            .disabled(!iCloudAvailable)
            ForEach(CloudProvider.available, id: \.self) { provider in
                Button {
                    onCloud(provider)
                } label: {
                    row(provider.displayName, icon: .provider(provider), isCurrent: isCurrent(provider))
                }
            }
            Button {
                picking = .folder
                isPicking = true
            } label: {
                row(
                    L10n.tr("Other Folder"), subtitle: L10n.tr("iCloud Drive or a folder synced by another app"), icon: .folder,
                    isCurrent: isCurrentFolder)
            }
            if onExportFile != nil {
                Button {
                    picking = .exportFile
                    isPicking = true
                } label: {
                    row(L10n.tr("Kakey Exported File"), icon: .exportFile, isCurrent: false)
                }
            }
        } footer: {
            Text(L10n.tr("Only the encrypted vault leaves this device. To sync with Android, use a cloud service or a synced folder."))
        }
        .fileImporter(isPresented: $isPicking, allowedContentTypes: picking == .exportFile ? [.json] : [.folder]) { result in
            guard case .success(let url) = result else { return }
            if picking == .exportFile {
                onExportFile?(url)
            } else {
                onFolder(url)
            }
        }
    }

    private var isCurrentFolder: Bool {
        if case .folder = current { return true }
        return false
    }

    private func isCurrent(_ provider: CloudProvider) -> Bool {
        if case .cloud(let location) = current { return location.provider == provider }
        return false
    }

    /// Title and icon use a fixed `Color.primary`: `.primary` inside a button label resolves to the accent color.
    private func row(
        _ title: String, subtitle: String? = nil, icon: SyncLocationIcon.Kind, isCurrent: Bool, isEnabled: Bool = true
    ) -> some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(Color.secondary)
                    }
                }
            } icon: {
                SyncLocationIcon(kind: icon, size: 30, tint: isEnabled ? Color.primary : Color.secondary)
            }
            Spacer()
            if isCurrent {
                Image(systemName: "checkmark").foregroundStyle(.tint)
            }
        }
    }
}

/// Connect cloud storage: steps and networking live in the shared `CloudSetupModel`; this only draws the iOS form.
/// The result goes to `onFinish`: an error message returned keeps this screen and shows it, nil lets the caller leave; while
/// waiting, this screen shows "Checking backup".
struct CloudSetupScreen: View {
    @Bindable var model: CloudSetupModel
    var finishTitle: String
    var onFinish: (CloudSetupModel.Result) async -> String?

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var isNamingFolder = false
    @State private var newFolderName = ""

    var body: some View {
        Form {
            switch model.step {
            case .form: form
            case .waitingForBrowser(let url): waiting(url)
            case .chooseFolder: folderBrowser
            }
            if let message = model.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        // Presented as a sheet and dismissed by swiping down (there is no Cancel); after returning from the browser (token exchange,
        // backup check) swipe-to-dismiss is disabled
        .interactiveDismissDisabled(model.phase.map { $0 > .signingIn } ?? false)
        .toolbar { toolbar }
        .overlay {
            if model.step == .chooseFolder, model.currentFolderHasOnlyBackup {
                ContentUnavailableView {
                    Label {
                        Text(L10n.tr("Backup found"))
                    } icon: {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                }
                // Display only: does not block taps on rows above such as Back
                .allowsHitTesting(false)
            }
        }
        // Confirmations always use a centered alert: on iOS 26 confirmationDialog becomes a popover pointing at empty form space
        // and has no Cancel button
        .alert(
            L10n.tr("Unencrypted connection"),
            isPresented: Binding(get: { model.needsInsecureConfirmation }, set: { if !$0 { model.declineInsecure() } })
        ) {
            Button(L10n.tr("Use Unencrypted Connection"), role: .destructive) { model.perform { await model.confirmInsecure() } }
            Button(L10n.tr("Cancel"), role: .cancel) { model.declineInsecure() }
        } message: {
            Text(L10n.tr("Your password is sent over HTTP in plain text. Only continue on a network you trust."))
        }
        // Certificate not trusted by the system (docs/SECURITY.md): after checking the fingerprint, trust only this
        // certificate
        .alert(
            L10n.tr("The server’s certificate can’t be verified"),
            isPresented: Binding(get: { model.untrustedCertificate != nil }, set: { if !$0 { model.declineCertificate() } }),
            presenting: model.untrustedCertificate
        ) { fingerprint in
            Button(L10n.tr("Trust This Certificate"), role: .destructive) { model.perform { await model.confirmCertificate(fingerprint) } }
            Button(L10n.tr("Cancel"), role: .cancel) { model.declineCertificate() }
        } message: { fingerprint in
            Text(
                L10n.tr(
                    "Continue only if this fingerprint matches the one your server shows. Kakey will trust only this certificate."
                )
                    + "\n\n" + L10n.tr("SHA-256 fingerprint") + "\n" + CloudSetupModel.formattedFingerprint(fingerprint))
        }
        .alert(L10n.tr("New Folder"), isPresented: $isNamingFolder) {
            TextField(L10n.tr("New folder name"), text: $newFolderName)
            Button(L10n.tr("Cancel"), role: .cancel) { newFolderName = "" }
            Button(L10n.tr("Create")) {
                let name = newFolderName
                newFolderName = ""
                model.perform { await model.createFolder(named: name) }
            }
        }
        // Check once right after returning from browser authorization instead of waiting for the next poll
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.checkSignInNow() }
        }
        .onDisappear { model.cancel() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            switch model.step {
            case .form:
                // OAuth progress is drawn in the three-step guide; the toolbar only disables the button
                if model.isWorking, !model.provider.usesOAuth {
                    ProgressView()
                } else {
                    Button(model.submitTitle) {
                        model.perform {
                            if let result = await model.submit() { _ = await model.complete(result, using: onFinish) }
                        }
                    }
                    .disabled(!model.canSubmit || model.isWorking)
                }
            case .waitingForBrowser:
                ProgressView()
            case .chooseFolder:
                Button(finishTitle) {
                    if let result = try? model.finish() { model.perform { _ = await model.complete(result, using: onFinish) } }
                }
                .disabled(model.isWorking || !model.canFinish)
            }
        }
    }

    @ViewBuilder
    private var form: some View {
        if model.provider.usesOAuth {
            oauthForm
        } else {
            serverForm
        }
    }

    /// OAuth (same structure as the Mac): pairing graphic, then access scope, then the three-step guide. After tapping Sign In, the
    /// three-step guide shows progress.
    @ViewBuilder
    private var oauthForm: some View {
        pairingHeader
        Section {
            if model.offersFullAccess {
                Picker(selection: $model.access) {
                    ForEach([CoreCloudAccess.appFolder, .full], id: \.self) { access in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(CloudSetupModel.accessTitle(access))
                            Text(model.accessDetail(access)).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(access)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } else {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(CloudSetupModel.accessTitle(.appFolder))
                        Text(model.accessDetail(.appFolder)).font(.footnote).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "lock.shield.fill").foregroundStyle(.tint)
                }
            }
        }
        .disabled(model.isWorking)
        Section {
            ForEach(Array(model.connectSteps.enumerated()), id: \.offset) { index, text in
                ConnectStepRow(index: index, text: text, state: CloudSetupModel.ConnectStepState(step: index, phase: model.phase))
            }
        }
        .animation(.snappy(duration: 0.22), value: model.phase)
    }

    private var pairingHeader: some View {
        Section {
            CloudPairingHeader(provider: model.provider, headline: model.headline, note: model.storedNote)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
    }

    /// WebDAV / Nextcloud (same structure as OAuth): pairing graphic, then the form. The address section has a header, the address
    /// field has no placeholder, and the format is described in the section footer.
    @ViewBuilder
    private var serverForm: some View {
        pairingHeader
        Section {
            // The placeholder hints that the scheme can be omitted: a bare IP gets http://, a domain gets https://
            TextField("", text: $model.address, prompt: Text(verbatim: "https://"))
                .accessibilityLabel(L10n.tr("Server Address"))
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: model.address) { model.addressDidChange() }
        } header: {
            Text(L10n.tr("Server Address"))
        } footer: {
            Text(model.addressHint)
        }
        .disabled(model.isWorking)
        if model.provider == .webDAV {
            Section {
                TextField(L10n.tr("Username"), text: $model.username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(L10n.tr("Password"), text: $model.password)
                    .keyboardType(.asciiCapable)
                    .textContentType(.password)
            } header: {
                Text(L10n.tr("Account"))
            }
            .disabled(model.isWorking)
        }
    }

    private func waiting(_ url: URL) -> some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                Text(model.isCheckingSignIn ? L10n.tr("Finishing sign-in") : L10n.tr("Waiting for you to grant access in the browser"))
            }
            Button(L10n.tr("Open Browser Again")) { openURL(url) }
                .disabled(model.isCheckingSignIn)
        } footer: {
            Text(L10n.tr("Sign in to Nextcloud in the browser window that opened and allow Kakey. Kakey continues automatically."))
        }
    }

    @ViewBuilder
    private var folderBrowser: some View {
        // The suggested directory is created when needed and is used only for backup; restore is read-only
        if model.purpose == .backup {
            Section {
                Button {
                    model.perform {
                        if let result = try? await model.useDefaultFolder() { _ = await model.complete(result, using: onFinish) }
                    }
                } label: {
                    Label(L10n.format("Use “%@” Folder", CloudSetupModel.defaultFolder), systemImage: "star")
                }
                .disabled(model.isWorking)
            }
        }
        Section {
            // The first row is always "up one level" (same as Android): accent color when available to set it apart from the
            // black subdirectories; gray and disabled at the root
            Button {
                model.perform { await model.goUp() }
            } label: {
                Label(L10n.tr("Parent Directory"), systemImage: "arrow.turn.left.up")
                    .foregroundStyle(model.canGoUp ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .disabled(!model.canGoUp)
            // The backup file itself is also listed before the subdirectories (not tappable); when it is the only item it shows in
            // the middle of the page instead (see the overlay in body)
            if model.currentFolderHasBackup, !model.currentFolderHasOnlyBackup {
                Label {
                    Text(L10n.tr("Kakey backup"))
                } icon: {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                }
            } else if !model.currentFolderHasBackup, model.folders.isEmpty {
                // On the first listing (just signed in, or opened with an existing authorization) the list is still empty: show
                // loading instead of "No folders"
                if model.isWorking {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(L10n.tr("Loading folders")).foregroundStyle(.secondary)
                    }
                } else {
                    Text(L10n.tr("No folders")).foregroundStyle(.secondary)
                }
            }
            ForEach(model.folders, id: \.path) { entry in
                Button {
                    model.perform { await model.open(entry) }
                } label: {
                    Label(entry.name, systemImage: "folder").foregroundStyle(.primary)
                }
                .tint(.primary)
            }
            if model.purpose == .backup {
                Button {
                    isNamingFolder = true
                } label: {
                    Label(L10n.tr("New Folder"), systemImage: "folder.badge.plus")
                }
            }
        } header: {
            // Small path text that wraps when long; at a fixed trailing position a spinner while loading, otherwise refresh (no
            // pull-to-refresh: pulling down dismisses the sheet)
            HStack(spacing: 12) {
                Text(model.currentFolderTitle)
                    .font(.footnote)
                    .textCase(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    if model.isWorking {
                        ProgressView()
                    } else {
                        Button {
                            model.perform { await model.refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .tint(.primary)
                        .accessibilityLabel(L10n.tr("Refresh"))
                    }
                }
                .frame(width: 28, height: 28)
            }
        } footer: {
            if let hint = model.folderHint, !model.isWorking {
                Text(hint)
            }
        }
        .disabled(model.isWorking)
    }
}

extension View {
    /// The connect cloud storage screen is always a sheet; closing it or finishing sets `model` to nil.
    func cloudSetupSheet(
        _ model: Binding<CloudSetupModel?>, finishTitle: String, onFinish: @escaping (CloudSetupModel.Result) async -> String?
    ) -> some View {
        sheet(item: model) { setup in
            NavigationStack {
                CloudSetupScreen(model: setup, finishTitle: finishTitle, onFinish: onFinish)
            }
        }
    }
}

// MARK: - OAuth connection screen components

/// Pairing graphic for Kakey and the provider: a locked link between the two icons (only the encrypted vault is transferred), with
/// the sign-in method and a note that only ciphertext is stored below.
private struct CloudPairingHeader: View {
    var provider: CloudProvider
    var headline: String
    var note: String

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                BrandMark(size: 52)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                HStack(spacing: 4) {
                    Capsule().fill(.quaternary).frame(width: 14, height: 2)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color(.tertiarySystemFill), in: Circle())
                    Capsule().fill(.quaternary).frame(width: 14, height: 2)
                }
                SyncLocationIcon(kind: .provider(provider), size: 52, plate: AnyShapeStyle(Color(.secondarySystemGroupedBackground)))
            }
            .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(headline).font(.headline)
                Text(note).font(.subheadline).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

/// One row of the three-step guide: numbered before sign-in; once started, done steps are checked, the current one spins and is
/// bold, and pending ones are dimmed.
private struct ConnectStepRow: View {
    var index: Int
    var text: String
    var state: CloudSetupModel.ConnectStepState

    var body: some View {
        HStack(spacing: 12) {
            marker
                .frame(width: 24, height: 24)
                .id(state)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            Text(text)
                .fontWeight(state == .active ? .semibold : .regular)
                .foregroundStyle(state == .pending ? .tertiary : state == .upcoming ? .secondary : .primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(state == .done ? L10n.tr("Done") : state == .active ? L10n.tr("In Progress") : "")
    }

    @ViewBuilder
    private var marker: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.tint)
        case .active:
            ProgressView()
        case .upcoming, .pending:
            Text("\(index + 1)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(.tertiary, lineWidth: 1))
        }
    }
}

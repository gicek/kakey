import SwiftUI

/// Connect cloud storage: fill in (for OAuth, choose the access scope) -> sign in -> choose the remote folder. Steps and networking
/// live in the shared `CloudSetupModel`; this view only draws the UI, with each step's actions in the bottom bar. On completion the
/// connection blob and location go to `onFinish`, and the caller decides whether to enable backups or run first-run restore. If it
/// returns an error message, this page stays and shows it; if it returns nil, the caller leaves the page. Meanwhile the page shows
/// "Checking backup".
struct CloudSetupView: View {
    @Bindable var model: CloudSetupModel
    var finishTitle: String
    var onBack: () -> Void
    var onFinish: (CloudSetupModel.Result) async -> String?

    @State private var newFolderName = ""
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // The outer stack does not scroll: all content has a fixed maximum, and only the folder list scrolls inside its own frame.
            VStack(alignment: .leading, spacing: 14) {
                switch model.step {
                case .form: form
                case .waitingForBrowser: waiting
                case .chooseFolder: folderBrowser
                }
                if let message = model.errorMessage {
                    InlineNotice(text: message, systemImage: "exclamationmark.triangle", tint: .red)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, minHeight: 300, alignment: .top)
            Divider()
            footer
        }
        // Check once immediately on returning from browser authorization, without waiting for the next poll.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.checkSignInNow()
        }
        .onDisappear { model.cancel() }
    }

    // MARK: - Fill in

    @ViewBuilder
    private var form: some View {
        if model.provider.usesOAuth {
            oauthForm
        } else {
            serverForm
        }
    }

    /// OAuth: pairing graphic (Kakey <-> provider) -> access scope -> three-step explanation. After "Sign In" the three steps become
    /// the progress, so the token exchange, folder listing and backup check after the browser returns are all visible. The access
    /// scope is selectable only when a full-access key is configured.
    private var oauthForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            CloudPairingHeader(provider: model.provider, headline: model.headline, note: model.storedNote)
            if model.offersFullAccess {
                VStack(spacing: 8) {
                    accessRow(.appFolder)
                    accessRow(.full)
                }
                .disabled(model.phase != nil)
            } else {
                accessPromise
            }
            ConnectStepList(steps: model.connectSteps, phase: model.phase)
        }
    }

    /// With only the dedicated app folder this is not a choice but a promise of what Kakey can see.
    private var accessPromise: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 17))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(CloudSetupModel.accessTitle(.appFolder)).font(.system(size: 13, weight: .semibold))
                Text(model.accessDetail(.appFolder))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.18)))
    }

    private func accessRow(_ access: CoreCloudAccess) -> some View {
        Button {
            model.access = access
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.access == access ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(model.access == access ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(CloudSetupModel.accessTitle(access)).font(.system(size: 13, weight: .semibold))
                    Text(model.accessDetail(access))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .contentShape(Rectangle())
            .background(
                model.access == access ? AnyShapeStyle(Color.accentColor.opacity(0.07)) : AnyShapeStyle(.quaternary.opacity(0.3)),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(model.access == access ? Color.accentColor.opacity(0.35) : .clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.access == access ? .isSelected : [])
    }

    /// WebDAV / Nextcloud, with the same structure as OAuth: pairing graphic -> form. Every field has a title, so no placeholders;
    /// the address format is described below the address field.
    private var serverForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            CloudPairingHeader(provider: model.provider, headline: model.headline, note: model.storedNote)
            VStack(alignment: .leading, spacing: 6) {
                // The placeholder hints that the scheme can be omitted: a bare IP gets http://, a domain gets https://.
                TextField("", text: $model.address, prompt: Text(verbatim: "https://"))
                    .accessibilityLabel(L10n.tr("Server Address"))
                    .labeled(L10n.tr("Server Address"))
                    .onChange(of: model.address) { model.addressDidChange() }
                Text(model.addressHint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.provider == .webDAV {
                HStack(spacing: 12) {
                    TextField("", text: $model.username)
                        .accessibilityLabel(L10n.tr("Username"))
                        .labeled(L10n.tr("Username"))
                    SecureField("", text: $model.password)
                        .focused($passwordFocused)
                        .romanInputOnly(focused: passwordFocused, revealed: false)
                        .accessibilityLabel(L10n.tr("Password"))
                        .labeled(L10n.tr("Password"))
                }
            }
            if model.needsInsecureConfirmation {
                insecureConfirmation
            }
            if let fingerprint = model.untrustedCertificate {
                certificateConfirmation(fingerprint)
            }
        }
        .disabled(model.isWorking)
    }

    /// Certificate not trusted by the system (docs/SECURITY.md): shows the fingerprint for the user to verify; once
    /// confirmed, only this one certificate is trusted.
    private func certificateConfirmation(_ fingerprint: Data) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.tr("The server’s certificate can’t be verified"), systemImage: "exclamationmark.shield.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.orange)
            Text(
                L10n.tr(
                    "Continue only if this fingerprint matches the one your server shows. Kakey will trust only this certificate."
                )
            )
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.tr("SHA-256 fingerprint"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(CloudSetupModel.formattedFingerprint(fingerprint))
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Spacer()
                Button(L10n.tr("Cancel")) { model.declineCertificate() }
                    .buttonStyle(PressableButtonStyle())
                Button(L10n.tr("Trust This Certificate")) { model.perform { await model.confirmCertificate(fingerprint) } }
                    .buttonStyle(PressableButtonStyle())
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.32)))
    }

    private var insecureConfirmation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.tr("Unencrypted connection"), systemImage: "lock.open.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.orange)
            Text(L10n.tr("Your password is sent over HTTP in plain text. Only continue on a network you trust."))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer()
                Button(L10n.tr("Cancel")) { model.declineInsecure() }
                    .buttonStyle(PressableButtonStyle())
                Button(L10n.tr("Use Unencrypted Connection")) { model.perform { await model.confirmInsecure() } }
                    .buttonStyle(PressableButtonStyle())
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.32)))
    }

    // MARK: - Browser sign-in

    /// "Reopen Browser" is on the right of the bottom bar, in the same place as other steps' primary buttons.
    private var waiting: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(model.isCheckingSignIn ? L10n.tr("Finishing sign-in") : L10n.tr("Waiting for you to grant access in the browser"))
                    .font(.system(size: 13, weight: .semibold))
            }
            Text(L10n.tr("Sign in to Nextcloud in the browser window that opened and allow Kakey. Kakey continues automatically."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Choose folder

    private var folderBrowser: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    model.perform { await model.goUp() }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(!model.canGoUp || model.isWorking)
                .help(L10n.tr("Back"))
                Label(model.currentFolderTitle, systemImage: "folder")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                // Same slot: a spinner while loading, otherwise a refresh button, so the row does not jump when switching.
                Group {
                    if model.isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            model.perform { await model.refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(PressableButtonStyle(prominence: .icon))
                        .help(L10n.tr("Refresh"))
                        .accessibilityLabel(L10n.tr("Refresh"))
                    }
                }
                .frame(width: 30, height: 30)
            }
            ScrollView {
                folderRows
            }
            // Fixed height: about 7 rows (32 pt row + 1 pt divider), more scroll inside the frame, so the sheet does not grow or shrink
            // with the folder count when navigating.
            .frame(height: Self.folderListHeight)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
            // Only backups have a hint, and it always takes two lines: while loading or without a hint it is just hidden, so the sheet
            // height stays the same when switching folders (the English hint wraps to two lines).
            if model.purpose == .backup {
                Label(model.folderHint ?? " ", systemImage: "info.circle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                    .opacity(model.folderHint == nil || model.isWorking ? 0 : 1)
            }
            // Restore is read-only: no creating folders.
            if model.purpose == .backup {
                HStack(spacing: 8) {
                    TextField(L10n.tr("New folder name"), text: $newFolderName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(createFolder)
                    Button(L10n.tr("New Folder"), action: createFolder)
                        .buttonStyle(PressableButtonStyle())
                        .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty || model.isWorking)
                }
            }
        }
    }

    private static let folderListHeight: CGFloat = 240

    /// Number of list rows: when the folder contains a backup, the first row is the backup itself, followed by subfolders.
    private var listRowCount: Int {
        model.folders.count + (model.currentFolderHasBackup ? 1 : 0)
    }

    @ViewBuilder
    private var folderRows: some View {
        if model.currentFolderHasOnlyBackup {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.green)
                Text(L10n.tr("Backup found"))
                    .font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity, minHeight: Self.folderListHeight)
            .accessibilityElement(children: .combine)
        } else {
            folderList
        }
    }

    private var folderList: some View {
        VStack(spacing: 0) {
            // The backup file itself is also listed before the subfolders (not clickable).
            if model.currentFolderHasBackup {
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text(L10n.tr("Kakey backup")).lineLimit(1)
                    Spacer()
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 12)
                .frame(height: 32)
                .accessibilityElement(children: .combine)
                if !model.folders.isEmpty { Divider().padding(.leading, 12) }
            }
            if listRowCount == 0 {
                // The first listing starts empty: show loading instead of "No folders".
                Group {
                    if model.isWorking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(L10n.tr("Loading folders"))
                        }
                    } else {
                        Text(L10n.tr("No folders"))
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: Self.folderListHeight)
            } else {
                ForEach(model.folders, id: \.path) { entry in
                    Button {
                        model.perform { await model.open(entry) }
                    } label: {
                        HStack {
                            Image(systemName: "folder").foregroundStyle(Color.accentColor)
                            Text(entry.name).lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        }
                        .font(.system(size: 12.5))
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if entry.path != model.folders.last?.path { Divider().padding(.leading, 12) }
                }
            }
        }
    }

    private func complete(_ result: CloudSetupModel.Result) async {
        _ = await model.complete(result, using: onFinish)
    }

    private func createFolder() {
        let name = newFolderName
        newFolderName = ""
        model.perform { await model.createFolder(named: name) }
    }

    // MARK: - Bottom bar

    private var footer: some View {
        HStack(spacing: 10) {
            // While choosing a folder, the bottom left only has "Cancel" (closes the whole connection sheet): there is already a "go
            // up" control above the folders, and another "Back" would be confusing.
            // Other steps have "Back": the form returns to the location list, and waiting for the browser returns to the form.
            Button(model.step == .chooseFolder ? L10n.tr("Cancel") : L10n.tr("Back")) {
                switch model.step {
                case .form, .chooseFolder: onBack()
                case .waitingForBrowser: model.backToForm()
                }
            }
            .buttonStyle(PressableButtonStyle())
            .keyboardShortcut(.cancelAction)
            // After the browser returns (token exchange, backup check) the page cannot be left midway; while the sign-in page is still
            // open, its own cancel button ends it.
            .disabled(model.phase.map { $0 > .signingIn } ?? false)
            Spacer()
            switch model.step {
            case .form:
                Button {
                    model.perform {
                        if let result = await model.submit() { await complete(result) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        // OAuth progress is drawn in the three-step list, so the button does not spin.
                        if model.isWorking, !model.provider.usesOAuth { ProgressView().controlSize(.small) }
                        Text(model.submitTitle)
                    }
                }
                .buttonStyle(PressableButtonStyle(prominence: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSubmit || model.needsInsecureConfirmation || model.untrustedCertificate != nil || model.isWorking)
            case .waitingForBrowser(let url):
                Button(L10n.tr("Open Browser Again")) { NSWorkspace.shared.open(url) }
                    .buttonStyle(PressableButtonStyle())
                    .disabled(model.isCheckingSignIn)
            case .chooseFolder:
                // The recommended folder is created when needed; backups only.
                if model.purpose == .backup {
                    Button(L10n.format("Use “%@” Folder", CloudSetupModel.defaultFolder)) {
                        model.perform {
                            if let result = try? await model.useDefaultFolder() { await complete(result) }
                        }
                    }
                    .buttonStyle(PressableButtonStyle())
                    .disabled(model.isWorking)
                }
                Button(finishTitle) {
                    if let result = try? model.finish() { model.perform { await complete(result) } }
                }
                .buttonStyle(PressableButtonStyle(prominence: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(model.isWorking || !model.canFinish)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(.bar)
    }
}

// MARK: - OAuth connection page components

/// Pairing graphic for Kakey and the provider: a locked connector between the two icons (only the encrypted vault is transferred).
/// The graphic is decorative; VoiceOver reads only the text on the right.
private struct CloudPairingHeader: View {
    var provider: CloudProvider
    var headline: String
    var note: String

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 50, height: 50)
                link
                SyncLocationIcon(kind: .provider(provider), size: 42)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline).font(.system(size: 13.5, weight: .semibold))
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var link: some View {
        HStack(spacing: 4) {
            Capsule().fill(.quaternary).frame(width: 12, height: 2)
            Image(systemName: "lock.fill")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 19, height: 19)
                .background(.quaternary.opacity(0.7), in: Circle())
            Capsule().fill(.quaternary).frame(width: 12, height: 2)
        }
    }
}

/// The three-step explanation, which becomes progress once sign-in starts: done steps get a checkmark, the current one spins and is
/// bold, and upcoming ones are dimmed. Before sign-in they are all numbered explanations.
private struct ConnectStepList: View {
    var steps: [String]
    var phase: CloudSetupModel.ConnectPhase?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, text in
                let state = CloudSetupModel.ConnectStepState(step: index, phase: phase)
                HStack(spacing: 10) {
                    marker(index: index, state: state)
                        .frame(width: 20, height: 20)
                        .id(state)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                    Text(text)
                        .font(.system(size: 12.5, weight: state == .active ? .semibold : .regular))
                        .foregroundStyle(state == .pending ? .tertiary : state == .upcoming ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(accessibilityValue(state))
            }
        }
        .animation(.snappy(duration: 0.22), value: phase)
    }

    @ViewBuilder
    private func marker(index: Int, state: CloudSetupModel.ConnectStepState) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color.accentColor)
        case .active:
            ProgressView().controlSize(.small)
        case .upcoming, .pending:
            Text("\(index + 1)")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(.tertiary, lineWidth: 1))
        }
    }

    private func accessibilityValue(_ state: CloudSetupModel.ConnectStepState) -> String {
        switch state {
        case .done: L10n.tr("Done")
        case .active: L10n.tr("In Progress")
        case .upcoming, .pending: ""
        }
    }
}

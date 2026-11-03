import SwiftUI

/// Account detail (presented as a system sheet): large verification code, name editing, categories, parameters, and the
/// re-authenticated "Show Secret" and "Export QR Code" actions.
struct AccountDetailView: View {
    @Environment(MobileVaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    var accountID: Account.ID

    @State private var isEditing = false
    @State private var draftIssuer = ""
    @State private var draftUsername = ""
    @State private var revealedSecret: String?
    @State private var qrImage: UIImage?
    @State private var confirmDelete = false
    @State private var authError: String?
    #if DEBUG
        @State private var showsDemoCategoryPicker = false
    #endif

    var body: some View {
        if let account = store.account(id: accountID) {
            content(account)
        } else {
            ContentUnavailableView(L10n.tr("Select an account to see details"), systemImage: "person.badge.key")
        }
    }

    private func categorySummary(_ account: Account) -> String {
        let names = store.categories.containing(account.id).map(\.name)
        return names.isEmpty ? L10n.tr("None") : names.joined(separator: L10n.tr(", "))
    }

    private func content(_ account: Account) -> some View {
        form(account)
            #if DEBUG
                .navigationDestination(isPresented: $showsDemoCategoryPicker) { AccountCategoryPicker(account: account) }
                .task {
                    guard DemoVault.isRequested, UserDefaults.standard.string(forKey: "KakeyDemoScreen") == "detail-categories" else {
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(600))
                    showsDemoCategoryPicker = true
                }
            #endif
    }

    private func form(_ account: Account) -> some View {
        Form {
            Section {
                codeCard(account)
                    .listRowInsets(EdgeInsets(top: 20, leading: 16, bottom: 20, trailing: 16))
            }

            Section {
                if isEditing {
                    TextField(L10n.tr("Service Name"), text: $draftIssuer)
                    TextField(L10n.tr("Account name or email"), text: $draftUsername)
                        .textInputAutocapitalization(.never)
                } else {
                    LabeledContent(L10n.tr("Service Name"), value: account.issuer)
                    LabeledContent(L10n.tr("Account / Email"), value: account.username)
                }
                NavigationLink {
                    AccountCategoryPicker(account: account)
                } label: {
                    LabeledContent(L10n.tr("Categories")) {
                        Text(categorySummary(account)).lineLimit(1)
                    }
                }
            }

            Section(L10n.tr("Options")) {
                LabeledContent(
                    L10n.tr("Algorithm"),
                    value: L10n.format("%1$@ · %2$lld digits · %3$lld sec", account.algorithm.rawValue, account.digits, account.period))
                LabeledContent(L10n.tr("Added via"), value: AccountProvenance.localizedTitle(for: account.addedBy))
                LabeledContent(
                    L10n.tr("Date Added"),
                    value: account.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale)))
            }

            Section {
                if let revealedSecret {
                    HStack {
                        Text(revealedSecret)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            store.copySensitive(revealedSecret)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .accessibilityLabel(L10n.tr("Copy"))
                    }
                    Button(L10n.tr("Hide")) { self.revealedSecret = nil }
                } else {
                    Button {
                        reveal(account)
                    } label: {
                        Label(L10n.tr("Show Secret"), systemImage: "key")
                    }
                }
                Button {
                    showQRCode(account)
                } label: {
                    Label(L10n.tr("Export QR Code"), systemImage: "qrcode")
                }
            } header: {
                Text(L10n.tr("Secret"))
            } footer: {
                if let authError {
                    Text(authError).foregroundStyle(.red)
                } else {
                    Text(L10n.tr("Revealing the secret or QR code requires verifying your identity."))
                }
            }

            Section {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label(L10n.tr("Delete This Account"), systemImage: "trash")
                }
            }
        }
        .navigationTitle(account.issuer)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Presented as a system sheet: close at top leading; closing while editing discards the changes
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel(L10n.tr("Close"))
            }
            ToolbarItem(placement: .primaryAction) {
                Button(isEditing ? L10n.tr("Done") : L10n.tr("Edit")) {
                    if isEditing {
                        var updated = account
                        updated.issuer = draftIssuer
                        updated.username = draftUsername
                        store.update(updated)
                    } else {
                        draftIssuer = account.issuer
                        draftUsername = account.username
                    }
                    isEditing.toggle()
                }
            }
        }
        .alert(L10n.format("Delete “%@”?", account.issuer), isPresented: $confirmDelete) {
            Button(L10n.tr("Delete"), role: .destructive) {
                store.delete(account)
                dismiss()
            }
            Button(L10n.tr("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("This can’t be undone. Make sure you can still sign in to this service another way."))
        }
        .sheet(item: Binding(get: { qrImage.map(IdentifiedImage.init) }, set: { qrImage = $0?.image })) { item in
            QRCodeSheet(image: item.image, account: account)
        }
        .onChange(of: accountID) {
            revealedSecret = nil
            isEditing = false
            authError = nil
        }
        .onDisappear { revealedSecret = nil }
        // Hide the secret and QR code when entering the app switcher or background so snapshots never contain them
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                revealedSecret = nil
                qrImage = nil
            }
        }
    }

    private func codeCard(_ account: Account) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let code = TOTPService.code(for: account, date: context.date)
            let remaining = TOTPService.secondsRemaining(for: account, date: context.date)
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    MonogramBadge(issuer: account.issuer, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.issuer).font(.title3.bold())
                        Text(account.username).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Button {
                    store.copyCode(for: account)
                } label: {
                    VStack(spacing: 10) {
                        CodeText(code: code, urgent: remaining <= 5, font: CodeFont.font(size: 44, relativeTo: .largeTitle))
                        HStack(spacing: 8) {
                            CountdownRing(
                                progress: TOTPService.progress(for: account, date: context.date), secondsRemaining: remaining, size: 18)
                            Text(L10n.format("Refreshes in %llds", remaining)).font(.footnote).foregroundStyle(.secondary)
                            Text(verbatim: "·").foregroundStyle(.tertiary)
                            Label(L10n.tr("Copy"), systemImage: "doc.on.doc").font(.footnote).foregroundStyle(.tint)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.format("Copy code for %@", account.issuer))
            }
        }
    }

    private func reveal(_ account: Account) {
        Task {
            do {
                try await BiometricService.authenticateOwner(reason: L10n.tr("Reveal the account secret"))
                authError = nil
                revealedSecret = account.secret
            } catch {
                if !BiometricService.isCancellation(error) { authError = BiometricService.message(for: error) }
            }
        }
    }

    private func showQRCode(_ account: Account) {
        Task {
            do {
                try await BiometricService.authenticateOwner(reason: L10n.tr("Show the account QR code"))
                authError = nil
                qrImage = QRCodeImage.make(from: OTPAuthCanonicalizer.otpauthURLString(for: account))
            } catch {
                if !BiometricService.isCancellation(error) { authError = BiometricService.message(for: error) }
            }
        }
    }
}

private struct IdentifiedImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Single-account QR code export, scannable on another device or in another authenticator.
private struct QRCodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    var image: UIImage
    var account: Account

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280)
                    .padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                VStack(spacing: 4) {
                    Text(account.issuer).font(.headline)
                    Text(account.username).font(.subheadline).foregroundStyle(.secondary)
                }
                Text(L10n.tr("Anyone who scans this code can generate your codes. Scan it only on devices you trust."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .navigationTitle(L10n.tr("Export QR Code"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Flow state shared by every way to add accounts: scan, photo library, paste, manual entry, backup file import, and drop.
/// Recognized results go to a confirmation screen first; once confirmed they are inserted through core deduplication.
@MainActor
@Observable
final class AddFlowController {
    enum Sheet: Identifiable {
        case scanner
        case manual
        case review([ParsedOTPAuth])
        case settings

        var id: String {
            switch self {
            case .scanner: "scanner"
            case .manual: "manual"
            case .review(let items): "review-\(items.map(\.id))"
            case .settings: "settings"
            }
        }
    }

    var sheet: Sheet?
    var isImportingFile = false
    var isPickingPhoto = false
    var photoItem: PhotosPickerItem?
    /// A backup file that needs a password to import (Kakey encrypted export, Authenticator v3 encrypted backup).
    var pendingBackup: Data?
    var backupPassword = ""
    var alertMessage: String?
    /// "Import Backup File" in Settings: the file picker appears after the Settings sheet is dismissed (two system presentations
    /// cannot be shown at once).
    var presentsFileImporterAfterSheetDismiss = false

    func present(_ sheet: Sheet) {
        self.sheet = sheet
    }

    func pasteFromClipboard() {
        let parsed = OTPAuthParser.parseLines(Clipboard.text ?? "")
        guard !parsed.isEmpty else {
            alertMessage = L10n.tr("The clipboard doesn’t contain an otpauth or migration link.")
            return
        }
        sheet = .review(parsed)
    }

    func handlePhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        photoItem = nil
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                alertMessage = L10n.tr("No QR code found")
                return
            }
            await review(payloads: await QRImageDecoder.payloads(in: data))
        }
    }

    func handleDrop(_ providers: [NSItemProvider]) {
        Task {
            var payloads: [String] = []
            for provider in providers {
                if provider.canLoadObject(ofClass: UIImage.self), let image = await provider.loadImage() {
                    payloads += await QRImageDecoder.payloads(in: image)
                } else if let text = await provider.loadText() {
                    payloads.append(text)
                }
            }
            await review(payloads: payloads)
        }
    }

    private func review(payloads: [String]) async {
        let parsed = payloads.flatMap { OTPAuthParser.parseLines($0) }
        guard parsed.contains(where: \.isValid) else {
            alertMessage = L10n.tr("No QR code found")
            return
        }
        sheet = .review(parsed)
    }

    /// Cleanup after a sheet is dismissed: if Settings requested an import, present the file picker now.
    func sheetDidDismiss() {
        guard presentsFileImporterAfterSheetDismiss else { return }
        presentsFileImporterAfterSheetDismiss = false
        isImportingFile = true
    }

    /// The store comes from the environment via the modifier that attaches the presentations; it is not held here.
    func handleImportedFile(_ result: Result<URL, Error>, store: MobileVaultStore) {
        guard case .success(let url) = result else { return }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? ExternalFileLimits.read(contentsOf: url) else {
            alertMessage = ExternalAccountImportError.invalidFile.errorDescription
            return
        }
        importBackup(data, password: "", store: store)
    }

    func submitBackupPassword(store: MobileVaultStore) {
        guard let data = pendingBackup else { return }
        let password = backupPassword
        pendingBackup = nil
        backupPassword = ""
        importBackup(data, password: password, store: store)
    }

    /// Tries without a password first (plain Authenticator backup) and asks for one only when needed.
    private func importBackup(_ data: Data, password: String, store: MobileVaultStore) {
        Task {
            do {
                _ = try await store.importBackup(data, password: password)
            } catch ExternalAccountImportError.passwordRequired {
                pendingBackup = data
            } catch {
                alertMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

// NSItemProvider is not Sendable: start loading on the main actor and only pass the result back from the callback.
@MainActor
private extension NSItemProvider {
    func loadImage() async -> UIImage? {
        await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
    }

    func loadText() async -> String? {
        await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: String.self) { object, _ in
                continuation.resume(returning: object)
            }
        }
    }
}

/// The "+" menu at the top trailing edge.
struct AddMenu: View {
    @Environment(AddFlowController.self) private var flow

    var body: some View {
        Menu {
            Button {
                flow.present(.scanner)
            } label: {
                Label(L10n.tr("Scan QR Code"), systemImage: "qrcode.viewfinder")
            }
            Button {
                flow.isPickingPhoto = true
            } label: {
                Label(L10n.tr("Choose from Photos"), systemImage: "photo")
            }
            Button {
                flow.pasteFromClipboard()
            } label: {
                Label(L10n.tr("Paste Setup Link"), systemImage: "doc.on.clipboard")
            }
            Button {
                flow.present(.manual)
            } label: {
                Label(L10n.tr("Enter Setup Key"), systemImage: "keyboard")
            }
            Divider()
            Button {
                flow.isImportingFile = true
            } label: {
                Label(L10n.tr("Import Backup File"), systemImage: "square.and.arrow.down")
            }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .accessibilityLabel(L10n.tr("Add Account"))
        }
    }
}

extension View {
    /// Attaches all presentations of the add flow.
    func addFlows(_ flow: AddFlowController) -> some View {
        modifier(AddFlowsModifier(flow: flow))
    }
}

private struct AddFlowsModifier: ViewModifier {
    @Environment(MobileVaultStore.self) private var store
    @Bindable var flow: AddFlowController

    func body(content: Content) -> some View {
        content
            .sheet(item: $flow.sheet, onDismiss: { flow.sheetDidDismiss() }) { sheet in
                switch sheet {
                case .scanner:
                    ScannerView { parsed in flow.sheet = .review(parsed) }
                case .manual:
                    ManualEntryView()
                case .review(let items):
                    ReviewParsedView(items: items)
                case .settings:
                    SettingsView()
                }
            }
            .fileImporter(isPresented: $flow.isImportingFile, allowedContentTypes: [.json, .data, .text]) {
                flow.handleImportedFile($0, store: store)
            }
            .photosPicker(isPresented: $flow.isPickingPhoto, selection: $flow.photoItem, matching: .images)
            .onChange(of: flow.photoItem) { _, item in flow.handlePhoto(item) }
            .alert(
                L10n.tr("Backup Password"),
                isPresented: Binding(get: { flow.pendingBackup != nil }, set: { if !$0 { flow.pendingBackup = nil } })
            ) {
                SecureField(L10n.tr("Enter password"), text: $flow.backupPassword)
                    .keyboardType(.asciiCapable)
                Button(L10n.tr("Cancel"), role: .cancel) { flow.backupPassword = "" }
                Button(L10n.tr("Import")) { flow.submitBackupPassword(store: store) }
            } message: {
                Text(L10n.tr("Enter the password that was used to export this backup."))
            }
            .alert(
                flow.alertMessage ?? "",
                isPresented: Binding(get: { flow.alertMessage != nil }, set: { if !$0 { flow.alertMessage = nil } })
            ) {
                Button(L10n.tr("Done"), role: .cancel) {}
            }
    }
}

/// Confirmation screen for recognized results: lists entries that can be added and those that could not be parsed, then inserts
/// them together.
struct ReviewParsedView: View {
    @Environment(MobileVaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var items: [ParsedOTPAuth]

    private var validCount: Int { items.filter(\.isValid).count }

    var body: some View {
        NavigationStack {
            List {
                let valid = items.filter(\.isValid)
                let invalid = items.filter { !$0.isValid }
                if !valid.isEmpty {
                    Section(L10n.tr("Parsed")) {
                        ForEach(valid) { item in
                            HStack(spacing: 12) {
                                MonogramBadge(issuer: item.issuer, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.issuer).font(.headline)
                                    Text(item.account).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if !invalid.isEmpty {
                    Section(L10n.tr("Unable to parse")) {
                        ForEach(invalid) { item in
                            Label(item.reason ?? L10n.tr("Unable to parse"), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(L10n.tr("Add Account"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(validCount > 1 ? L10n.format("Add %lld Accounts", validCount) : L10n.tr("Add Account")) {
                        store.addParsed(items)
                        dismiss()
                    }
                    .disabled(validCount == 0)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Manual secret entry.
struct ManualEntryView: View {
    @Environment(MobileVaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var issuer = ""
    @State private var username = ""
    @State private var secret = ""
    @State private var algorithm: TOTPAlgorithm = .sha1
    @State private var digits = 6
    @State private var period = 30
    @State private var error: String?
    @FocusState private var focused: Bool

    private var secretLooksInvalid: Bool {
        !OTPAuthCanonicalizer.cleanText(secret).isEmpty && OTPAuthCanonicalizer.standardizedSecret(secret) == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.tr("Service Name"), text: $issuer)
                        .textContentType(.organizationName)
                        .focused($focused)
                    TextField(L10n.tr("Account name or email"), text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                }
                Section {
                    TextField(L10n.tr("Enter or paste the key from the service"), text: $secret, axis: .vertical)
                        // Placeholder uses the same font as other fields; monospaced only once there is text, to make checking the
                        // secret easier
                        .font(secret.isEmpty ? .body : .body.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .lineLimit(1...3)
                } header: {
                    Text(L10n.tr("Secret"))
                } footer: {
                    if secretLooksInvalid {
                        Text(L10n.tr("Invalid secret key")).foregroundStyle(.red)
                    } else {
                        Text(L10n.tr("The secret is encrypted on this device and never leaves in plaintext."))
                    }
                }
                Section(L10n.tr("Advanced Options")) {
                    Picker(L10n.tr("Algorithm"), selection: $algorithm) {
                        ForEach(TOTPAlgorithm.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker(L10n.tr("Digits"), selection: $digits) {
                        Text(verbatim: "6").tag(6)
                        Text(verbatim: "8").tag(8)
                    }
                    Picker(L10n.tr("Refresh Interval"), selection: $period) {
                        Text(L10n.tr("30 seconds")).tag(30)
                        Text(L10n.tr("60 seconds")).tag(60)
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(L10n.tr("Enter Setup Key"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("Save")) {
                        error = store.addManual(
                            issuer: issuer, username: username, secret: secret, algorithm: algorithm, digits: digits, period: period)
                        if error == nil {
                            store.showToast(L10n.format("Added %lld accounts", 1), systemImage: "checkmark.circle.fill")
                            dismiss()
                        }
                    }
                    .disabled(OTPAuthCanonicalizer.standardizedSecret(secret) == nil)
                }
            }
            .onAppear { focused = true }
        }
    }
}

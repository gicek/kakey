import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ImportFileDropResolver {
    static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url.isFileURL ? url : nil
        }
        if let url = item as? NSURL {
            let swiftURL = url as URL
            return swiftURL.isFileURL ? swiftURL : nil
        }
        if let data = item as? Data,
            let text = String(data: data, encoding: .utf8)
        {
            return fileURL(fromDroppedText: text)
        }
        if let data = item as? NSData,
            let text = String(data: data as Data, encoding: .utf8)
        {
            return fileURL(fromDroppedText: text)
        }
        if let text = item as? String {
            return fileURL(fromDroppedText: text)
        }
        if let text = item as? NSString {
            return fileURL(fromDroppedText: text as String)
        }
        return nil
    }

    static func fileURL(fromDroppedText text: String) -> URL? {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return nil }

        if let url = URL(string: cleanText), url.isFileURL {
            return url
        }
        if cleanText.hasPrefix("/") {
            return URL(fileURLWithPath: cleanText)
        }
        return nil
    }
}

/// Encrypted export and bulk import. Same frame as adding an account: the content area has a minimum height, results and errors
/// appear only on the left of the bottom bar, and "Cancel" and the primary button are on the right.
struct ExportImportView: View {
    @EnvironmentObject private var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "export"
    @State private var selectedIDs = Set<Account.ID>()
    @State private var exportQuery = ""
    @State private var exportPassword = ""
    @State private var exportConfirm = ""
    @State private var importFileURL: URL?
    @State private var importPassword = ""
    @State private var statusMessage: String?
    @State private var statusStyle = StatusStyle.success
    @State private var isImportDropTargeted = false
    /// Password problems appear only after leaving the field, not while typing; editing again hides them first.
    @FocusState private var focusedPasswordField: PasswordField?
    @FocusState private var importPasswordFocused: Bool
    @State private var checksPassword = false
    @State private var checksConfirm = false
    @State private var confirmingFairPassword = false

    private enum PasswordField {
        case password
        case confirm
    }

    /// Bottom bar status: green for success, red for failure; "all accounts already exist" is just a note in the secondary color.
    private enum StatusStyle {
        case success
        case info
        case error

        var systemImage: String {
            switch self {
            case .success: "checkmark.circle.fill"
            case .info: "info.circle"
            case .error: "exclamationmark.triangle.fill"
            }
        }

        var color: Color {
            switch self {
            case .success: .green
            case .info: .secondary
            case .error: .red
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader(L10n.tr("Export / Import")) {
                Picker(L10n.tr("Mode"), selection: $tab) {
                    Text(L10n.tr("Encrypted Export")).tag("export")
                    Text(L10n.tr("Batch Import")).tag("import")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 14) {
                if tab == "export" { exportPanel } else { importPanel }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(minHeight: 300, alignment: .top)
            .resignsFocusOnBackgroundClick()
            Divider()
            footer
        }
        .onAppear {
            selectedIDs = Set(store.accounts.map(\.id))
        }
        .fairPasswordConfirmation(isPresented: $confirmingFairPassword, onConfirm: exportSelectedAccounts)
        .onChange(of: tab) { _, _ in
            clearStatusMessage()
        }
    }

    // MARK: - Bottom bar

    private var footer: some View {
        HStack(spacing: 10) {
            if let message = footerMessage {
                Label(message.text, systemImage: message.style.systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(message.style.color)
                    .lineLimit(1)
            }
            Spacer()
            Button(L10n.tr("Cancel")) { dismiss() }
                .buttonStyle(PressableButtonStyle())
            if tab == "export" {
                Button(L10n.tr("Export Encrypted File"), action: submitExport)
                    .buttonStyle(PressableButtonStyle(prominence: .primary))
                    .disabled(!canExport)
            } else {
                Button(L10n.tr("Import Accounts")) { importSelectedFile() }
                    .buttonStyle(PressableButtonStyle(prominence: .primary))
                    .disabled(importFileURL == nil)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(.bar)
    }

    /// The operation result takes priority; otherwise the export tab shows password problems (one at a time).
    private var footerMessage: (text: String, style: StatusStyle)? {
        if let statusMessage {
            return (statusMessage, statusStyle)
        }
        guard tab == "export" else { return nil }
        if checksPassword, let problem = PasswordPolicy.problem(for: exportPassword) { return (problem, .error) }
        if checksConfirm, exportPasswordMismatch { return (L10n.tr("Passwords don’t match"), .error) }
        return nil
    }

    // MARK: - Export

    private var exportPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L10n.tr("Search accounts"), text: $exportQuery)
                        .textFieldStyle(.plain)
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 8)
                .frame(width: 200, height: 26)
                .kakeyInputChrome(cornerRadius: 6)
                Text(L10n.format("%1$lld of %2$lld selected", selectedIDs.count, store.accounts.count))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if !store.categories.isEmpty {
                    Menu(L10n.tr("Select by Category")) {
                        ForEach(store.categories) { category in
                            Button(L10n.format("%1$@ (%2$lld)", category.name, category.accountIDs.count)) {
                                selectedIDs = Set(category.accountIDs)
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Button(allSelected ? L10n.tr("Deselect All") : L10n.tr("Select All")) {
                    selectedIDs = allSelected ? [] : Set(store.accounts.map(\.id))
                }
                .buttonStyle(.link)
            }
            .font(.system(size: 12.5))

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleExportAccounts) { account in
                        exportAccountRow(account)
                        Divider().padding(.leading, 44)
                    }
                }
            }
            .frame(height: 216)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.6)))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Both fields have titles, so no placeholders; the strength meter matches the master password's (weak passwords cannot
            // export).
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    SecureField("", text: $exportPassword)
                        .newPasswordInput($exportPassword)
                        .focused($focusedPasswordField, equals: .password)
                        .romanInputOnly(focused: focusedPasswordField == .password, revealed: false)
                        .accessibilityLabel(L10n.tr("Set Export Password"))
                        .labeled(L10n.tr("Set Export Password"))
                    StrengthMeter(strength: PasswordStrength.evaluate(exportPassword))
                }
                SecureField("", text: $exportConfirm)
                    .newPasswordInput($exportConfirm)
                    .focused($focusedPasswordField, equals: .confirm)
                    .romanInputOnly(focused: focusedPasswordField == .confirm, revealed: false)
                    .accessibilityLabel(L10n.tr("Confirm Password"))
                    .labeled(L10n.tr("Confirm Password"))
            }
            .padding(.top, 6)
            .onChange(of: focusedPasswordField) { previous, _ in
                if previous == .password { checksPassword = true }
                if previous == .confirm { checksConfirm = true }
            }
            .onChange(of: exportPassword) { _, _ in
                checksPassword = false
                checksConfirm = false
            }
            .onChange(of: exportConfirm) { _, _ in checksConfirm = false }
            Text(L10n.tr("The export is encrypted with this password and you’ll need it to import. Don’t lose it."))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }

    private var allSelected: Bool {
        !store.accounts.isEmpty && selectedIDs.count == store.accounts.count
    }

    private var visibleExportAccounts: [Account] {
        let query = exportQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? store.accounts : store.accounts.filter { $0.matchesSearch(query) }
    }

    private var exportPasswordMismatch: Bool {
        !exportConfirm.isEmpty && exportPassword != exportConfirm
    }

    private var canExport: Bool {
        !selectedIDs.isEmpty && PasswordPolicy.isAcceptableExportPassword(exportPassword) && exportPassword == exportConfirm
    }

    /// Single column: service and account name on separate lines, long account names truncated at the tail (two side-by-side
    /// columns truncated in the middle were hard to read).
    private func exportAccountRow(_ account: Account) -> some View {
        Toggle(
            isOn: Binding(
                get: { selectedIDs.contains(account.id) },
                set: { isOn in
                    if isOn { selectedIDs.insert(account.id) } else { selectedIDs.remove(account.id) }
                }
            )
        ) {
            HStack(spacing: 10) {
                LogoBadge(account: account, size: 22)
                Text(account.issuer)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(account.username)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    // MARK: - Import

    private var importPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let importFileURL {
                HStack(spacing: 10) {
                    Image(systemName: "doc")
                        .foregroundStyle(Color.accentColor)
                    Text(importFileURL.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        self.importFileURL = nil
                        importPassword = ""
                        clearStatusMessage()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(PressableButtonStyle(prominence: .icon))
                    .help(L10n.tr("Remove File"))
                }
                .padding(.leading, 12)
                .padding(.trailing, 4)
                .frame(height: 40)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

                SecureField(L10n.tr("Password for encrypted backups"), text: $importPassword)
                    .focused($importPasswordFocused)
                    .romanInputOnly(focused: importPasswordFocused, revealed: false)
                    .labeled(L10n.tr("File password (optional)"))
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 30, weight: .light))
                    Text(L10n.tr("Drop a Kakey or Authenticator backup here, or click to choose"))
                        .font(.system(size: 12.5))
                    Button(L10n.tr("Choose File")) { selectImportFile() }
                        .buttonStyle(PressableButtonStyle())
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 180)
                .background(isImportDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            isImportDropTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                            style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                        )
                )
                .contentShape(Rectangle())
                .onDrop(
                    of: [UTType.fileURL.identifier, UTType.url.identifier, UTType.text.identifier],
                    isTargeted: $isImportDropTargeted,
                    perform: handleDroppedImportFiles
                )
            }
            Text(L10n.tr("Supports Kakey encrypted exports and Authenticator backups. Existing accounts are skipped."))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }

    private var selectedExportAccounts: [Account] {
        store.accounts.filter { selectedIDs.contains($0.id) }
    }

    private func handleDroppedImportFiles(_ providers: [NSItemProvider]) -> Bool {
        var didAcceptDrop = false

        for provider in providers {
            let typeIdentifier = [
                UTType.fileURL.identifier,
                UTType.url.identifier,
                UTType.text.identifier,
            ].first { provider.hasItemConformingToTypeIdentifier($0) }

            guard let typeIdentifier else { continue }
            didAcceptDrop = true
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                guard let url = ImportFileDropResolver.fileURL(from: item) else { return }
                Task { @MainActor in
                    acceptImportFile(url)
                }
            }
        }

        return didAcceptDrop
    }

    /// A "fair" password first confirms that the export file might be cracked, and only then picks the save location; the button is
    /// disabled for weak passwords, so they never get here.
    private func submitExport() {
        if PasswordStrength.evaluate(exportPassword) == .fair {
            confirmingFairPassword = true
        } else {
            exportSelectedAccounts()
        }
    }

    private func exportSelectedAccounts() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Kakey-export-\(Self.timestamp.string(from: .now)).json"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let selected = selectedExportAccounts
        Task {
            do {
                try await store.exportAccounts(selected, password: exportPassword, to: url)
                setStatus(L10n.format("Exported %lld accounts", selected.count), .success)
            } catch is VaultPersistenceError {
                setStatus(L10n.tr("Export failed. Try again."), .error)
            } catch {
                // Writing the file failed (permissions, disk, ...): show one generic message instead of the system text.
                setStatus(L10n.tr("Couldn’t save the file"), .error)
            }
        }
    }

    private func selectImportFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if panel.runModal() == .OK {
            if let url = panel.url {
                acceptImportFile(url)
            }
        }
    }

    private func acceptImportFile(_ url: URL) {
        importFileURL = url
        importPassword = ""
        clearStatusMessage()
    }

    private func importSelectedFile() {
        guard let importFileURL, !store.isWorking else { return }

        Task {
            do {
                let (insertedCount, skippedCount) = try await store.importBackupFile(at: importFileURL, password: importPassword)
                if insertedCount == 0, skippedCount > 0 {
                    setStatus(L10n.tr("All accounts in this file already exist"), .info)
                } else if skippedCount > 0 {
                    setStatus(L10n.format("Imported %1$lld accounts, skipped %2$lld duplicates", insertedCount, skippedCount), .success)
                } else {
                    setStatus(L10n.format("Imported %lld accounts", insertedCount), .success)
                }
            } catch let error as ExternalAccountImportError {
                setStatus(error.errorDescription ?? L10n.tr("Import failed. Try again."), .error)
            } catch {
                setStatus(L10n.tr("Import failed. Try again."), .error)
            }
        }
    }

    private func setStatus(_ message: String, _ style: StatusStyle) {
        statusMessage = message
        statusStyle = style
    }

    private func clearStatusMessage() {
        statusMessage = nil
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter
    }()
}

import SwiftUI

/// Add account: three tabs, "Scan QR Code" (default, `QRScanPanel`), "Enter Secret" and "Paste Link" (`OTPAuthTextPanel`).
/// The content area has a minimum height so switching tabs does not resize the sheet; errors appear as a single line on the left
/// of the bottom bar.
struct AddAccountView: View {
    @EnvironmentObject private var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var method: AddMethod = .scan
    @State private var issuer = ""
    @State private var username = ""
    @State private var secret = ""
    @State private var algorithm: TOTPAlgorithm = .sha1
    @State private var digits = 6
    @State private var period = 30
    @State private var showAdvanced = false
    @State private var revealSecret = false
    /// Accounts recognized by the scan tab's three sources (screen selection, image, camera) combined; Google migration batch
    /// progress accumulates across sources.
    @State private var detectedQRItems: [ParsedOTPAuth] = []
    /// Google migration progress across multiple codes and sources (rules in the shared `MigrationBatchCollector`).
    @State private var migrationBatches = MigrationBatchCollector()
    @State private var otpAuthText = ""
    /// Scan failure (cancellation is not recorded); shown only on the left of the bottom bar, like "account already exists".
    @State private var scanError: QRScanError?
    @State private var showsDuplicateError = false
    /// The secret format is checked only after leaving the field, never while typing; editing again hides the error first.
    @FocusState private var secretFieldFocused: Bool
    @State private var checksSecret = false

    var parsed: [ParsedOTPAuth] { OTPAuthParser.parseLines(otpAuthText) }
    var deduplicatedParsed: [ParsedOTPAuth] { parsed.deduplicatedForDisplay }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader(L10n.tr("Add Account")) {
                Picker(L10n.tr("Method"), selection: $method) {
                    ForEach(AddMethod.allCases) { Text($0.localizedTitle).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 340, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 16) {
                switch method {
                case .scan:
                    QRScanPanel(
                        detectedItems: $detectedQRItems,
                        migrationBatches: $migrationBatches,
                        scanError: $scanError,
                        onSourceSelected: { showsDuplicateError = false }
                    )
                case .key:
                    keyPanel
                case .text:
                    OTPAuthTextPanel(text: $otpAuthText, items: deduplicatedParsed)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            // The three tabs have different heights; a minimum keeps the sheet from resizing when switching.
            .frame(minHeight: 236, alignment: .top)
            .resignsFocusOnBackgroundClick()
            .onChange(of: method) { _, _ in
                scanError = nil
                showsDuplicateError = false
            }
            Divider()
            HStack {
                if let footerError {
                    Label(footerError, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                Spacer()
                Button(L10n.tr("Cancel")) { dismiss() }
                    .buttonStyle(PressableButtonStyle())
                Button(saveTitle) { save() }
                    .buttonStyle(PressableButtonStyle(prominence: .primary))
                    .disabled(!canSave)
            }
            // Same horizontal inset as the content, so the bottom bar error lines up with the hints above.
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(.bar)
        }
    }

    // MARK: - Enter secret

    private var keyPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                TextField(L10n.tr("Service Name"), text: $issuer)
                    .labeled(L10n.tr("Service Name"))
                TextField(L10n.tr("Account name or email"), text: $username)
                    .labeled(L10n.tr("Account / Email"))
            }
            secretField
            advancedOptions
        }
    }

    private var advancedOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    showAdvanced.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Text(L10n.tr("Advanced Options"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAdvanced {
                HStack(alignment: .top, spacing: 18) {
                    advancedPicker(
                        L10n.tr("Algorithm"),
                        selection: $algorithm,
                        options: TOTPAlgorithm.allCases.map { ($0, $0.rawValue) }
                    )
                    advancedPicker(
                        L10n.tr("Digits"),
                        selection: $digits,
                        options: [(6, "6"), (8, "8")]
                    )
                    advancedPicker(
                        L10n.tr("Refresh Interval"),
                        selection: $period,
                        options: [(30, L10n.tr("30 seconds")), (60, L10n.tr("60 seconds"))]
                    )
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// Native pop-up pickers in three equal-width columns, aligned with the title.
    private func advancedPicker<Value: Hashable>(
        _ title: String,
        selection: Binding<Value>,
        options: [(value: Value, title: String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            FullWidthPopUpPicker(options: options, selection: selection)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var secretField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("Secret"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            HStack {
                Group {
                    if revealSecret {
                        TextField(L10n.tr("Enter or paste the key from the service"), text: $secret)
                    } else {
                        SecureField(L10n.tr("Enter or paste the key from the service"), text: $secret)
                    }
                }
                // 13 pt like the other fields: the placeholder font matches and focusing does not jump because of a different line
                // height. Switches to monospaced only once there is content, to make checking the secret easier.
                .font(.system(size: 13, design: secret.isEmpty ? .default : .monospaced))
                .textFieldStyle(.plain)
                .focused($secretFieldFocused)
                // A secret contains only Base32 / hex characters: Roman input only, like the password fields.
                .romanInputOnly(focused: secretFieldFocused, revealed: revealSecret)
                .onChange(of: secretFieldFocused) { wasFocused, _ in
                    if wasFocused { checksSecret = true }
                }
                .onChange(of: secret) { _, _ in checksSecret = false }
                RevealSecretButton(isRevealed: revealSecret, showTitle: L10n.tr("Show Secret")) { revealSecret.toggle() }
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: 36)
            .kakeyInputChrome(cornerRadius: 7)
            Text(L10n.tr("The secret is encrypted on this device and never leaves in plaintext."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Bottom bar and save

    /// The only error slot, on the left of the bottom bar: scan failure, invalid secret format, account already exists.
    private var footerError: String? {
        if showsDuplicateError {
            return L10n.tr("Account already exists")
        }
        switch method {
        case .scan:
            return scanError?.errorDescription
        case .key:
            let isInvalid = !OTPAuthCanonicalizer.cleanText(secret).isEmpty && OTPAuthCanonicalizer.standardizedSecret(secret) == nil
            return checksSecret && isInvalid ? L10n.tr("Invalid secret key") : nil
        case .text:
            return nil
        }
    }

    private var canSave: Bool {
        switch method {
        case .scan:
            detectedQRItems.contains { $0.isValid }
        case .key:
            OTPAuthCanonicalizer.standardizedSecret(secret) != nil
        case .text:
            deduplicatedParsed.contains { $0.isValid }
        }
    }

    private var saveTitle: String {
        let count: Int
        switch method {
        case .scan:
            count = detectedQRItems.filter(\.isValid).count
        case .key:
            count = 0
        case .text:
            count = deduplicatedParsed.filter(\.isValid).count
        }
        return count > 1 ? L10n.format("Add %lld Accounts", count) : L10n.tr("Save Account")
    }

    /// When the sheet is opened from a category in the main window, the new account also joins that category.
    private var targetCategoryID: AccountCategory.ID? {
        store.selectedSection.categoryID
    }

    private func save() {
        showsDuplicateError = false
        let insertedCount: Int

        switch method {
        case .scan:
            insertedCount = store.addParsedAccounts(detectedQRItems, into: targetCategoryID)
        case .key:
            insertedCount =
                store.addAccount(
                    issuer: issuer, username: username, secret: secret, algorithm: algorithm, digits: digits, period: period,
                    into: targetCategoryID
                ) ? 1 : 0
        case .text:
            insertedCount = store.addParsedAccounts(deduplicatedParsed, into: targetCategoryID)
        }

        guard insertedCount > 0 else {
            showsDuplicateError = true
            return
        }
        dismiss()
    }
}

extension Array where Element == ParsedOTPAuth {
    /// Deduplicated only for display and counting (a code recognized by two sources is listed once). On save, the core
    /// `insert_accounts` compares again against existing accounts with the same dedup key; this is not part of the save path.
    var deduplicatedForDisplay: [ParsedOTPAuth] {
        var seen = Set<String>()
        return filter { item in
            let key =
                item.isValid
                ? item.deduplicationKey
                : "invalid|\(item.reason ?? "")|\(item.id)"
            return seen.insert(key).inserted
        }
    }
}

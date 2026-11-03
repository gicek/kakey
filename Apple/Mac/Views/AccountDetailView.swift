import AppKit
import SwiftUI

/// Account details: a large tap-to-copy code at the top, then name editing, categories, read-only info and the secret.
/// Name changes are saved on "Done"; category checkmarks apply immediately (same as the context menu "Add to"). Only the name is
/// editable; the secret and parameters are read-only (`VaultDocument.update` accepts only the name).
/// Revealing the secret or showing the QR code (which contains the full secret) requires Touch ID or the login password first.
struct AccountDetailView: View {
    @EnvironmentObject private var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Account
    @State private var revealSecret = false
    @State private var authBusy = false
    @State private var authError: String?
    @State private var showsQRCode = false
    @State private var showDeleteConfirm = false

    init(account: Account) {
        _draft = State(initialValue: account)
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader(L10n.tr("Account Details"))
            VStack(alignment: .leading, spacing: 18) {
                summary
                HStack(spacing: 12) {
                    TextField(L10n.tr("Service Name"), text: $draft.issuer).labeled(L10n.tr("Service Name"))
                    TextField(L10n.tr("Account / Email"), text: $draft.username).labeled(L10n.tr("Account / Email"))
                }
                infoSection
                secretSection
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            Divider()
            HStack {
                // Delete sits on the left of the bottom bar (macOS convention) instead of a big red block in the middle of the form.
                Button(L10n.tr("Delete Account")) { showDeleteConfirm = true }
                    .buttonStyle(PressableButtonStyle(prominence: .danger))
                Spacer()
                Button(L10n.tr("Cancel")) { dismiss() }.buttonStyle(PressableButtonStyle())
                Button(L10n.tr("Done")) {
                    store.update(draft)
                    dismiss()
                }
                .buttonStyle(PressableButtonStyle(prominence: .primary))
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(.bar)
        }
        .confirmationDialog(
            L10n.format("Delete “%@”?", draft.issuer),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("Delete"), role: .destructive) {
                store.delete(draft)
                dismiss()
            }
            Button(L10n.tr("Cancel"), role: .cancel) {}
        }
        .sheet(isPresented: $showsQRCode) {
            AccountQRCodeView(account: draft)
                .frame(width: 420)
        }
        .background(
            // macOS gives focus to the form's first field and selects all, so the first keystroke overwrites the service name.
            // Hand focus back as soon as the sheet becomes key, so nothing is focused on open.
            WindowEventsView(onBecameKey: { window in window.makeFirstResponder(nil) })
                .frame(width: 0, height: 0)
        )
    }

    /// Badge, name and large code; clicking the code copies it and shows "Copied" in place.
    private var summary: some View {
        HStack(spacing: 14) {
            LogoBadge(account: draft, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(draft.issuer).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(draft.username).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            Button {
                store.copyCode(for: draft)
            } label: {
                CodeWithCountdown(account: draft, isCopied: store.copiedAccountID == draft.id, layout: .detail)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.tr("Copy code"))
            .accessibilityLabel(L10n.tr("Copy code"))
        }
    }

    /// Read-only info: categories (adjustable here), parameters, how and when it was added. Only the code and secret are monospaced.
    private var infoSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.tr("Categories")).foregroundStyle(.secondary)
                Spacer()
                categoryMenu
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            Divider()
            infoRow(
                L10n.tr("Algorithm"), L10n.format("%1$@ · %2$lld digits · %3$lld sec", draft.algorithm.rawValue, draft.digits, draft.period)
            )
            Divider()
            infoRow(L10n.tr("Added via"), AccountProvenance.localizedTitle(for: draft.addedBy))
            Divider()
            infoRow(
                L10n.tr("Date Added"),
                draft.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale)))
        }
        .font(.system(size: 12.5))
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))
    }

    /// Checking adds and unchecking removes; shows "Uncategorized" when there are no categories yet.
    private var categoryMenu: some View {
        Menu {
            ForEach(store.categories) { category in
                Toggle(
                    category.name,
                    isOn: Binding(
                        get: { store.isAccount(draft.id, in: category.id) },
                        set: { _ in store.toggleAccount(draft.id, in: category.id) }
                    ))
            }
            if store.categories.isEmpty {
                Text(L10n.tr("None"))
            }
        } label: {
            Text(categorySummary)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var categorySummary: String {
        let names = store.categories.containing(draft.id).map(\.name)
        return names.isEmpty ? L10n.tr("None") : names.joined(separator: L10n.tr(", "))
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
    }

    private var secretSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("Secret")).sectionLabel()
            HStack {
                Group {
                    if revealSecret {
                        // Read-only: selectable for copying once revealed, but not editable (to change the secret, delete and re-add).
                        Text(draft.secret)
                            .font(.system(size: 13, design: .monospaced))
                            .textSelection(.enabled)
                    } else {
                        Text(verbatim: String(repeating: "•", count: 16))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(L10n.tr("Secret"))
                    }
                }
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                RevealSecretButton(isRevealed: revealSecret, showTitle: L10n.tr("Show Secret"), action: toggleReveal)
                    .disabled(authBusy)
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: 36)
            .kakeyInputChrome(cornerRadius: 7)
            HStack(alignment: .firstTextBaseline) {
                if let authError {
                    Label(authError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else {
                    Text(L10n.tr("Showing the secret or QR code requires Touch ID or your Mac login password."))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showQRCode()
                } label: {
                    Label(L10n.tr("Show QR Code"), systemImage: "qrcode")
                }
                .buttonStyle(.link)
                .disabled(authBusy)
            }
            .font(.system(size: 11.5))
        }
    }

    /// Hiding needs no authentication; revealing the secret requires Touch ID or the login password first.
    private func toggleReveal() {
        if revealSecret {
            revealSecret = false
            return
        }
        authenticate(reason: L10n.tr("reveal the account secret")) { revealSecret = true }
    }

    /// The QR code contains the full secret, so it requires the same authentication as revealing the secret.
    private func showQRCode() {
        authenticate(reason: L10n.tr("show the account QR code")) { showsQRCode = true }
    }

    /// Re-authentication goes through the store's shared entry point (same as context menu "Show QR Code"): cancellation shows
    /// nothing; failure is explained below the secret field.
    private func authenticate(reason: String, then onSuccess: @escaping () -> Void) {
        authError = nil
        authBusy = true
        Task {
            switch await store.authenticateToRevealSecret(reason: reason) {
            case .granted: onSuccess()
            case .failed(let message): authError = message
            case .cancelled: break
            }
            authBusy = false
        }
    }
}

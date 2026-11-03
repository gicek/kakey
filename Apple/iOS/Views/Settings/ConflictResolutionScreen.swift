import SwiftUI

/// Conflict resolution (see docs/TECHNICAL.md): an overview of both sides, per-account differences, and the four choices with their
/// consequences; same rules as `ConflictResolutionView` on the Mac. For accounts changed on both sides the user picks a version per
/// account (only used by "merge both"). Secrets are only flagged as "secret differs", never shown.
struct ConflictResolutionScreen: View {
    enum Choice: Hashable {
        case merge
        case keepLocal
        case useBackup
    }

    let review: ConflictReview
    var onApply: (Choice, Set<UUID>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var choice: Choice = .merge
    @State private var preferRemote: Set<UUID>

    init(review: ConflictReview, onApply: @escaping (Choice, Set<UUID>) -> Void) {
        self.review = review
        self.onApply = onApply
        _preferRemote = State(initialValue: review.remoteIsNewer ? Set(review.changed.map(\.id)) : [])
    }

    var body: some View {
        Form {
            Section {
                side(L10n.tr("This Device"), count: review.localCount, date: review.localUpdatedAt, device: nil)
                side(L10n.tr("Backup"), count: review.remoteCount, date: review.remoteUpdatedAt, device: review.remoteDevice)
            }
            accounts(L10n.format("Only on this device (%lld)", review.onlyLocal.count), review.onlyLocal)
            accounts(L10n.format("Only in the backup (%lld)", review.onlyRemote.count), review.onlyRemote)
            if !review.changed.isEmpty {
                Section {
                    ForEach(review.changed) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.local.issuer)
                            if let names = item.differingNames {
                                Text(L10n.format("This device: %1$@ · Backup: %2$@", names.local, names.remote))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(L10n.format("Differs in: %@", ConflictReview.describe(item.changes))).font(.caption).foregroundStyle(
                                .secondary)
                            // Only relevant to "merge both"; hidden for the other choices
                            if choice == .merge {
                                Picker(L10n.tr("Which version to keep when merging"), selection: versionBinding(item.id)) {
                                    Text(L10n.tr("This Device")).tag(false)
                                    Text(L10n.tr("Backup")).tag(true)
                                }
                                .pickerStyle(.segmented)
                            }
                        }
                    }
                } header: {
                    Text(L10n.format("Different on both sides (%lld)", review.changed.count))
                } footer: {
                    if choice == .merge {
                        Text(L10n.tr("Pick which version Merge Both keeps for each account."))
                    }
                }
            }
            categories
            Section {
                choiceRow(
                    .merge, L10n.tr("Merge Both"),
                    L10n.format(
                        "Keeps every account from both sides: %lld in total. Accounts deleted on only one side come back.",
                        review.localCount + review.onlyRemote.count))
                choiceRow(
                    .keepLocal, L10n.tr("Keep This Device’s Copy"),
                    L10n.format(
                        "Overwrites the backup. Backup accounts removed: %1$lld · added: %2$lld · changed: %3$lld",
                        review.onlyRemote.count, review.onlyLocal.count, review.changed.count))
                choiceRow(
                    .useBackup, L10n.tr("Use the Backup’s Copy"),
                    L10n.format(
                        "Replaces the vault on this device. Accounts removed here: %1$lld · added: %2$lld · changed: %3$lld",
                        review.onlyLocal.count, review.onlyRemote.count, review.changed.count))
            }
        }
        .navigationTitle(L10n.tr("Resolve Conflict"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.tr("Decide Later")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.tr("Apply")) {
                    onApply(choice, preferRemote)
                    dismiss()
                }
            }
        }
    }

    private func side(_ title: String, count: Int, date: Date, device: String?) -> some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                Text(L10n.format("Accounts: %lld", count))
                Text(
                    [device, date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale))]
                        .compactMap { $0 }.joined(separator: " · ")
                )
                .font(.caption)
            }
        } label: {
            Text(title)
        }
    }

    @ViewBuilder
    private func accounts(_ title: String, _ accounts: [Account]) -> some View {
        if !accounts.isEmpty {
            Section(title) {
                ForEach(accounts) { account in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.issuer)
                        Text(account.username).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var categories: some View {
        let lines =
            review.categoriesOnlyLocal.map { L10n.format("Category only on this device: %@", $0) }
            + review.categoriesOnlyRemote.map { L10n.format("Category only in the backup: %@", $0) }
            + review.categoriesRenamed.map { L10n.format("Category renamed: %1$@ → %2$@", $0.local, $0.remote) }
        if !lines.isEmpty {
            Section(L10n.tr("Categories")) {
                ForEach(lines, id: \.self) { Text($0) }
            }
        }
    }

    private func versionBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { preferRemote.contains(id) },
            set: { useRemote in
                if useRemote { preferRemote.insert(id) } else { preferRemote.remove(id) }
            })
    }

    private func choiceRow(_ value: Choice, _ title: String, _ detail: String) -> some View {
        Button {
            choice = value
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: choice == value ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(choice == value ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

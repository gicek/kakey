import SwiftUI

/// Conflict resolution (see docs/TECHNICAL.md): an overview of both sides, per-account differences, and four choices with their
/// consequences. For accounts changed on both sides, the user picks a version per account (this only affects "Merge Both", so it
/// appears only when merging is selected); the side saved more recently is the default. Differing names list each side's value
/// side by side, without arrows (an arrow reads like "change to"). Secrets only say "secret differs" and never show values.
struct ConflictResolutionView: View {
    enum Choice: Hashable {
        case merge
        case keepLocal
        case useBackup
    }

    let review: ConflictReview
    var onApply: (Choice, Set<UUID>) -> Void
    var onLater: () -> Void

    @State private var choice: Choice = .merge
    @State private var preferRemote: Set<UUID>

    init(review: ConflictReview, onApply: @escaping (Choice, Set<UUID>) -> Void, onLater: @escaping () -> Void) {
        self.review = review
        self.onApply = onApply
        self.onLater = onLater
        _preferRemote = State(initialValue: review.remoteIsNewer ? Set(review.changed.map(\.id)) : [])
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    side(
                        title: L10n.tr("This Mac"), count: review.localCount, date: review.localUpdatedAt, device: nil,
                        systemImage: "laptopcomputer")
                    side(
                        title: L10n.tr("Backup"), count: review.remoteCount, date: review.remoteUpdatedAt, device: review.remoteDevice,
                        systemImage: "externaldrive")
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        group(L10n.format("Only on this Mac (%lld)", review.onlyLocal.count), accounts: review.onlyLocal)
                        group(L10n.format("Only in the backup (%lld)", review.onlyRemote.count), accounts: review.onlyRemote)
                        changedGroup
                        categoryGroup
                    }
                }
                .frame(height: 220)
                choices
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            Divider()
            HStack {
                Button(L10n.tr("Decide Later"), action: onLater)
                    .buttonStyle(PressableButtonStyle())
                Spacer()
                Button(L10n.tr("Apply")) { onApply(choice, preferRemote) }
                    .buttonStyle(PressableButtonStyle(prominence: .primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(.bar)
        }
    }

    // MARK: - Both sides

    private func side(title: String, count: Int, date: Date, device: String?, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(L10n.format("Accounts: %lld", count)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                Text(
                    [device, date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale))]
                        .compactMap { $0 }.joined(separator: " · ")
                )
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Differences

    @ViewBuilder
    private func group(_ title: String, accounts: [Account]) -> some View {
        if !accounts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).sectionLabel()
                ForEach(accounts) { account in
                    accountLine(account)
                }
            }
        }
    }

    private func accountLine(_ account: Account) -> some View {
        HStack(spacing: 6) {
            Text(account.issuer).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            Text(account.username).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var changedGroup: some View {
        if !review.changed.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.format("Different on both sides (%lld)", review.changed.count)).sectionLabel()
                    if choice == .merge {
                        Text(L10n.tr("Pick which version Merge Both keeps for each account."))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(review.changed) { item in
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.local.issuer).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                            if let names = item.differingNames {
                                Text(L10n.format("This Mac: %1$@ · Backup: %2$@", names.local, names.remote))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Text(L10n.format("Differs in: %@", ConflictReview.describe(item.changes)))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if choice == .merge {
                            Picker(L10n.tr("Which version to keep when merging"), selection: versionBinding(item.id)) {
                                Text(L10n.tr("This Mac")).tag(false)
                                Text(L10n.tr("Backup")).tag(true)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 170)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var categoryGroup: some View {
        let lines =
            review.categoriesOnlyLocal.map { L10n.format("Category only on this Mac: %@", $0) }
            + review.categoriesOnlyRemote.map { L10n.format("Category only in the backup: %@", $0) }
            + review.categoriesRenamed.map { L10n.format("Category renamed: %1$@ → %2$@", $0.local, $0.remote) }
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("Categories")).sectionLabel()
                ForEach(lines, id: \.self) { Text($0).font(.system(size: 12)) }
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

    // MARK: - Choices

    private var choices: some View {
        VStack(spacing: 6) {
            choiceRow(
                .merge, title: L10n.tr("Merge Both"),
                detail: L10n.format(
                    "Keeps every account from both sides: %lld in total. Accounts deleted on only one side come back.",
                    review.localCount + review.onlyRemote.count))
            choiceRow(
                .keepLocal, title: L10n.tr("Keep This Mac’s Copy"),
                detail: L10n.format(
                    "Overwrites the backup. Backup accounts removed: %1$lld · added: %2$lld · changed: %3$lld",
                    review.onlyRemote.count, review.onlyLocal.count, review.changed.count))
            choiceRow(
                .useBackup, title: L10n.tr("Use the Backup’s Copy"),
                detail: L10n.format(
                    "Replaces the vault on this Mac. Accounts removed here: %1$lld · added: %2$lld · changed: %3$lld",
                    review.onlyLocal.count, review.onlyRemote.count, review.changed.count))
        }
    }

    private func choiceRow(_ value: Choice, title: String, detail: String) -> some View {
        Button {
            choice = value
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: choice == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(choice == value ? Color.accentColor : Color.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .contentShape(Rectangle())
            .background(
                choice == value ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9).strokeBorder(
                    choice == value ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.2)))
        }
        .buttonStyle(.plain)
    }
}

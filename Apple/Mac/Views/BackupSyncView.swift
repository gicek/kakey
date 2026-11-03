import SwiftUI

/// Backup & Sync, using the same frame as other sheets. The overview shows a status card for the current location (Back Up Now,
/// Change, Turn Off), a line about end-to-end encryption, a card for choosing a direction when there is a conflict, and the backup
/// history. "Change" opens the location list; WebDAV / Nextcloud then continue to a connection step.
struct BackupSyncView: View {
    @EnvironmentObject private var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .overview
    @State private var confirmingTurnOff = false
    @State private var errorMessage: String?
    @State private var isLoadingReview = false
    @State private var reviewError: String?
    @State private var turnOffError: String?
    /// "Restore from Backup" for an unreadable backup first asks for that backup's master password; this Mac is replaced only after
    /// it opens.
    @State private var isEnteringRestorePassword = false
    @State private var restorePassword = ""
    @State private var restoreError: String?
    @State private var isRestoringBackup = false

    private enum Mode {
        case overview
        case choose
        case cloud(CloudSetupModel)
        case conflict(ConflictReview)
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader(headerTitle)
            switch mode {
            case .overview: overview
            case .choose: chooser
            case .conflict(let review):
                ConflictResolutionView(review: review) { choice, preferRemote in
                    switch choice {
                    case .merge: store.mergeWithBackup(review, preferRemote: preferRemote)
                    case .keepLocal: store.keepThisMacCopy()
                    case .useBackup: store.useBackupCopy()
                    }
                    mode = .overview
                } onLater: {
                    mode = .overview
                }
            case .cloud(let model):
                CloudSetupView(model: model, finishTitle: L10n.tr("Use This Folder"), onBack: { mode = .choose }) { result in
                    if let error = await store.configureSync(.cloud(result.location), connection: result.connection) { return error }
                    mode = .overview
                    return nil
                }
            }
        }
        .confirmationDialog(turnOffTitle, isPresented: $confirmingTurnOff) {
            if store.syncLocation?.isICloud == true {
                Button(L10n.tr("Turn Off and Keep Backup")) { store.turnOffSync() }
                Button(L10n.tr("Turn Off and Delete iCloud Backup"), role: .destructive) {
                    Task { turnOffError = await store.turnOffSyncDeletingICloudBackup() }
                }
            } else {
                Button(L10n.tr("Turn Off"), role: .destructive) { store.turnOffSync() }
            }
        } message: {
            Text(
                store.syncLocation?.isICloud == true
                    ? L10n.tr(
                        "Deleting removes the encrypted backup from iCloud for all your devices. Devices that still use iCloud backup upload their copy again."
                    )
                    : L10n.tr("The backup already stored there is kept."))
        }
        .alert(L10n.tr("Restore from Backup"), isPresented: $isEnteringRestorePassword) {
            SecureField(L10n.tr("Existing Master Password"), text: $restorePassword)
            Button(L10n.tr("Restore"), action: restoreBackup).disabled(restorePassword.isEmpty)
            Button(L10n.tr("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("To use that backup, restore from it and unlock with its master password. This replaces the vault on this Mac."))
        }
        .alert(
            L10n.tr("Couldn’t Delete the iCloud Backup"),
            isPresented: Binding(get: { turnOffError != nil }, set: { if !$0 { turnOffError = nil } })
        ) {
        } message: {
            Text(turnOffError ?? "")
        }
    }

    private var headerTitle: String {
        if case .cloud(let model) = mode { return model.title }
        if case .conflict = mode { return L10n.tr("Resolve Conflict") }
        return L10n.tr("Backup & Sync")
    }

    private var turnOffTitle: String {
        if case .cloud(let location) = store.syncLocation {
            return L10n.format("Turn off backup and sign out of %@?", location.provider.displayName)
        }
        return L10n.tr("Turn off backup?")
    }

    // MARK: - Overview

    private var overview: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    statusCard
                    if store.syncLocation?.isInsecure == true {
                        Label(L10n.tr("Unencrypted connection"), systemImage: "lock.open.fill")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.orange)
                            .padding(.leading, 4)
                    }
                    if store.syncLocation?.hasUnverifiedCertificate == true {
                        Label(L10n.tr("Certificate not verified"), systemImage: "exclamationmark.shield.fill")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.orange)
                            .padding(.leading, 4)
                    }
                    Label(
                        L10n.tr("Backups are end-to-end encrypted with your master password; only you can open them."),
                        systemImage: "lock.fill"
                    )
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                }
                if case .conflict = store.backupStatus {
                    conflictActions
                }
                if case .unreadable = store.backupStatus {
                    unreadableActions
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("Backup History")).sectionLabel()
                    if store.backupHistory.isEmpty {
                        Text(L10n.tr("No backup history yet"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 64)
                            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    } else {
                        backupHistoryList
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(minHeight: 300, alignment: .top)
            Divider()
            HStack {
                if store.syncLocation != nil {
                    Button(L10n.tr("Change")) { mode = .choose }
                        .buttonStyle(PressableButtonStyle())
                        .disabled(store.backupStatus == .running)
                    Button(L10n.tr("Turn Off Backup")) { confirmingTurnOff = true }
                        .buttonStyle(PressableButtonStyle())
                        .disabled(store.backupStatus == .running)
                }
                Spacer()
                Button(L10n.tr("Done")) { dismiss() }
                    .buttonStyle(PressableButtonStyle(prominence: .primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(.bar)
        }
    }

    // MARK: - Choose location

    private var chooser: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.tr("Choose where to keep the encrypted backup. Only one location is used at a time."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                SyncLocationPicker(current: store.syncLocation, iCloudAvailable: store.iCloud != nil, onChoose: choose)
                if let errorMessage {
                    InlineNotice(text: errorMessage, systemImage: "exclamationmark.triangle", tint: .red)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(minHeight: 300, alignment: .top)
            Divider()
            HStack {
                Button(L10n.tr("Back")) { mode = .overview }
                    .buttonStyle(PressableButtonStyle())
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(.bar)
        }
    }

    /// If the link check fails, stays on the location list and shows why.
    private func link(_ location: SyncLocation) {
        Task {
            if let error = await store.configureSync(location) {
                errorMessage = error
            } else {
                mode = .overview
            }
        }
    }

    private func choose(_ choice: SyncLocationChoice) {
        errorMessage = nil
        switch choice {
        case .iCloud:
            Task {
                if let error = await store.linkICloud() {
                    errorMessage = error
                } else {
                    mode = .overview
                }
            }
        case .folder(let url):
            do {
                link(try store.syncLocation(forFolder: url))
            } catch {
                errorMessage = SyncErrorText.message(for: error)
            }
        case .cloud(let provider):
            mode = .cloud(CloudSetupModel(provider: provider, service: store.cloudSetup) { NSWorkspace.shared.open($0) })
        case .exportFile:
            // The location list here does not accept files (`acceptsExportFile` is false), so this is unreachable.
            break
        }
    }

    /// Status card: location name and account on the left (hovering the location icon shows the full path), "Back Up Now" on the
    /// right with the status right-aligned below it; "Set Up" on the right when not configured. "Change" is in the bottom bar
    /// next to "Turn Off Backup".
    private var statusCard: some View {
        HStack(spacing: 14) {
            locationIcon
            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle).font(.system(size: 13.5, weight: .semibold))
                if let location = store.syncLocation {
                    if location.account != nil || location.detail != nil {
                        locationLine(location)
                    }
                } else {
                    Text(L10n.tr("Keep an end-to-end encrypted backup in iCloud, a folder or a cloud service"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            if store.syncLocation == nil {
                Button(L10n.tr("Set Up")) { mode = .choose }
                    .buttonStyle(PressableButtonStyle(prominence: .primary))
            } else {
                VStack(alignment: .trailing, spacing: 5) {
                    if store.backupStatus != .conflict, store.backupStatus != .unreadable {
                        Button {
                            store.runManualBackup()
                        } label: {
                            HStack(spacing: 6) {
                                if store.backupStatus == .running {
                                    ProgressView().controlSize(.small)
                                }
                                Text(store.backupStatus == .running ? L10n.tr("Syncing") : L10n.tr("Back Up Now"))
                            }
                        }
                        .buttonStyle(PressableButtonStyle())
                        .disabled(store.backupStatus == .running)
                    }
                    statusLine
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Second line: the account for cloud storage, followed by a location icon that shows the full path on hover; "Only your Apple
    /// Account can access" for iCloud; folders have no second line.
    private func locationLine(_ location: SyncLocation) -> some View {
        HStack(spacing: 5) {
            Text(location.account ?? location.detail ?? "")
                .lineLimit(1)
                .truncationMode(.middle)
            if location.account != nil {
                LocationPathHint(path: location.fullPath)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    /// With a location set, shows its brand icon with a dot in the corner for backup status; otherwise a gray "iCloud off".
    @ViewBuilder
    private var locationIcon: some View {
        if let location = store.syncLocation {
            SyncLocationIcon(kind: location.iconKind, size: 40)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.background, lineWidth: 2))
                        .offset(x: 3, y: 3)
                }
        } else {
            Image(systemName: "icloud.slash")
                .font(.system(size: 20))
                .foregroundStyle(statusColor)
                .frame(width: 40, height: 40)
                .background(statusColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var statusColor: Color {
        switch store.backupStatus {
        case .disabled: .secondary
        case .conflict: .orange
        case .failed, .unreadable: .red
        default: .green
        }
    }

    /// One row per record: direction icon on the left, result and trigger in the middle ("From X" when the data came from another
    /// device), time and size on the right.
    private var backupHistoryList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(store.backupHistory.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider().padding(.leading, 46)
                    }
                    historyRow(item)
                }
            }
        }
        .frame(height: min(CGFloat(store.backupHistory.count), 3) * Self.historyRowHeight)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private static let historyRowHeight: CGFloat = 44

    private func historyRow(_ item: BackupHistoryItem) -> some View {
        HStack(spacing: 10) {
            // Normal records use the secondary color; only failures and conflicts use orange.
            Image(systemName: item.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(item.isWarning ? Color.orange : Color.secondary)
                .frame(width: 24, height: 24)
                .background((item.isWarning ? Color.orange : Color.secondary).opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(item.isWarning ? Color.orange : Color.primary)
                if let detail = item.detail(thisDevice: store.system.deviceName) {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.date.formatted(Self.historyDateStyle))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Text(item.size)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .frame(height: Self.historyRowHeight)
    }

    private static var historyDateStyle: Date.FormatStyle {
        Date.FormatStyle(locale: L10n.locale).month(.abbreviated).day().hour().minute()
    }

    /// Conflict card: after the explanation there is only "Resolve Conflict", to see both sides' differences before choosing (see
    /// docs/TECHNICAL.md).
    private var conflictActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.tr("Sync Conflict Detected"), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.orange)
            Text(L10n.tr("This Mac and the backup both changed. Compare the accounts on each side, then keep one copy or merge both."))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    openConflict()
                } label: {
                    HStack(spacing: 6) {
                        if isLoadingReview { ProgressView().controlSize(.small) }
                        Text(L10n.tr("Resolve Conflict"))
                    }
                }
                .buttonStyle(PressableButtonStyle(prominence: .primary))
                .disabled(isLoadingReview)
                if let reviewError {
                    Text(reviewError).font(.system(size: 11.5)).foregroundStyle(.red).lineLimit(2)
                }
            }
            .disabled(store.backupStatus == .running)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.32)))
    }

    private func openConflict() {
        isLoadingReview = true
        reviewError = nil
        Task {
            switch await store.loadConflictReview() {
            case .success(let review): mode = .conflict(review)
            case .failure(let failure): reviewError = failure.message
            }
            isLoadingReview = false
        }
    }

    /// The remote backup cannot be opened with this Mac's key: syncing is impossible. The only options are entering that backup's
    /// master password and replacing this Mac with it, or choosing another location.
    private var unreadableActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.tr("Backup Can’t Be Opened"), systemImage: "lock.trianglebadge.exclamationmark.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.red)
            Text(VaultSyncError.unreadableRemote.errorDescription ?? "")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.tr("To use that backup, restore from it and unlock with its master password. This replaces the vault on this Mac."))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let restoreError {
                Text(restoreError)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button {
                    restorePassword = ""
                    isEnteringRestorePassword = true
                } label: {
                    Label(L10n.tr("Restore from Backup"), systemImage: "arrow.down.circle")
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(isRestoringBackup)
                if isRestoringBackup { ProgressView().controlSize(.small) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.red.opacity(0.28)))
    }

    /// Opens the backup with the entered password and replaces this Mac; with a wrong password nothing changes here and the reason
    /// is shown in the card.
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

    private var statusTitle: String {
        guard let location = store.syncLocation else { return L10n.tr("Backup is off") }
        return location.title
    }

    /// Status below the button: a green checkmark and time when synced (time only for today), nothing while syncing (the button
    /// shows progress), and the status color for everything else.
    @ViewBuilder
    private var statusLine: some View {
        switch store.backupStatus {
        case .enabled(let lastBackup):
            Label {
                Text(L10n.format("Last synced %@", Self.syncTimeText(lastBackup)))
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .font(.system(size: 11))
            .labelStyle(.titleAndIcon)
        case .running, .disabled:
            EmptyView()
        case .conflict:
            statusText(L10n.tr("Sync Conflict Detected"), color: .orange)
        case .unreadable:
            statusText(L10n.tr("Backup Can’t Be Opened"), color: .red)
        case .failed(let message):
            statusText(message, color: .red).help(message)
        }
    }

    private func statusText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(color)
            .multilineTextAlignment(.trailing)
            .lineLimit(2)
            .frame(maxWidth: 220, alignment: .trailing)
    }

    private static func syncTimeText(_ date: Date) -> String {
        let time = Date.FormatStyle(date: .omitted, time: .shortened, locale: L10n.locale)
        let style = Calendar.current.isDateInToday(date) ? time : time.month(.abbreviated).day()
        return date.formatted(style)
    }
}

/// The folder icon after the account: after a short hover, the full path floats above it (instead of the system tooltip, using the
/// card's corner radius and material).
private struct LocationPathHint: View {
    var path: String
    @State private var isShowing = false
    @State private var pending: Task<Void, Never>?

    var body: some View {
        Image(systemName: "folder")
            .font(.system(size: 10.5))
            .foregroundStyle(isShowing ? .secondary : .tertiary)
            .padding(3)
            .contentShape(Rectangle())
            .onHover { hovering in
                pending?.cancel()
                if hovering {
                    pending = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeOut(duration: 0.12)) { isShowing = true }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.1)) { isShowing = false }
                }
            }
            .overlay(alignment: .bottom) {
                if isShowing {
                    bubble
                        .fixedSize()
                        .alignmentGuide(.bottom) { $0[.top] - 4 }
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel(path)
    }

    private var bubble: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(path)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

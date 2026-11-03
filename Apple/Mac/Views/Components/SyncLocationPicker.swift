import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The item the user chose in the backup location list (see docs/TECHNICAL.md).
enum SyncLocationChoice {
    case iCloud
    case folder(URL)
    case cloud(CloudProvider)
    /// A Kakey encrypted export file (`.json`); only selectable during first-run restore (`acceptsExportFile`).
    case exportFile(URL)
}

/// Backup location list: iCloud (CloudKit), the cloud storage providers available in this build, and finally "Other Folder" (picked
/// with an open panel; iCloud Drive and folders synced by cloud drive clients both work). Only "Other Folder" has a description; the
/// rest show just a name. Shared by the Backup & Sync sheet and the first-run restore step.
/// When the build has no iCloud capability (no development team configured), the iCloud row is disabled with an explanation.
/// During first-run restore the list ends with "Other Folder" and "Kakey Exported File", both without a description, each opening
/// a panel limited to folders or to export files (the same rows as on iOS); changing the backup location keeps the described
/// "Other Folder" row.
/// `columns: 2` lays the rows out in a two-column grid (first-run restore, where the page has width but not height to spare); rows
/// in the same line share the taller one's height.
struct SyncLocationPicker: View {
    var current: SyncLocation?
    var iCloudAvailable: Bool
    var acceptsExportFile = false
    var columns = 1
    var onChoose: (SyncLocationChoice) -> Void

    private struct Item: Identifiable {
        let id: String
        let title: String
        var subtitle: String?
        let icon: SyncLocationIcon.Kind
        let isCurrent: Bool
        var isEnabled = true
        let action: () -> Void
    }

    private var items: [Item] {
        var items = [
            Item(
                id: "iCloud", title: "iCloud", subtitle: iCloudAvailable ? nil : L10n.tr("Not available in this build of Kakey"),
                icon: .iCloud, isCurrent: current?.isICloud == true, isEnabled: iCloudAvailable
            ) { onChoose(.iCloud) }
        ]
        items += CloudProvider.available.map { provider in
            Item(id: provider.rawValue, title: provider.displayName, icon: .provider(provider), isCurrent: isCurrent(provider)) {
                onChoose(.cloud(provider))
            }
        }
        if acceptsExportFile {
            items.append(
                Item(id: "folder", title: L10n.tr("Other Folder"), icon: .folder, isCurrent: false) { chooseFolder(restoring: true) })
            items.append(
                Item(id: "export", title: L10n.tr("Kakey Exported File"), icon: .exportFile, isCurrent: false) { chooseExportFile() })
        } else {
            items.append(
                Item(
                    id: "folder", title: L10n.tr("Other Folder"), subtitle: L10n.tr("iCloud Drive or a folder synced by another app"),
                    icon: .folder, isCurrent: isCurrentFolder
                ) { chooseFolder(restoring: false) })
        }
        return items
    }

    var body: some View {
        if columns > 1 {
            let items = items
            let lines = stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(lines, id: \.first?.id) { line in
                    GridRow {
                        ForEach(line) { item in
                            cell(item).frame(maxHeight: .infinity)
                        }
                    }
                }
            }
            // Ideal height only: each line is as tall as its tallest cell, instead of the grid filling the page.
            .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 8) {
                ForEach(items) { cell($0) }
            }
        }
    }

    private func cell(_ item: Item) -> some View {
        row(title: item.title, subtitle: item.subtitle, icon: item.icon, isCurrent: item.isCurrent, action: item.action)
            .disabled(!item.isEnabled)
    }

    private var isCurrentFolder: Bool {
        if case .folder = current { return true }
        return false
    }

    private func isCurrent(_ provider: CloudProvider) -> Bool {
        if case .cloud(let location) = current { return location.provider == provider }
        return false
    }

    /// When restoring, the folder must already hold a backup, so the panel neither creates folders nor explains where a new backup
    /// would go.
    private func chooseFolder(restoring: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = !restoring
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.tr("Choose")
        if !restoring {
            panel.message = L10n.tr("Kakey stores the encrypted backup in a Kakey folder inside the folder you choose")
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onChoose(.folder(url))
    }

    private func chooseExportFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.tr("Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onChoose(.exportFile(url))
    }

    private func row(title: String, subtitle: String? = nil, icon: SyncLocationIcon.Kind, isCurrent: Bool, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            HStack(spacing: 12) {
                SyncLocationIcon(kind: icon, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if isCurrent {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                } else {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            // In the grid a row stretches to the height of its neighbor, so the backgrounds line up.
            .frame(maxHeight: columns > 1 ? .infinity : nil)
            .contentShape(Rectangle())
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

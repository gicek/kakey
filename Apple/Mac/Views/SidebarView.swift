import SwiftUI

/// The sidebar shows "All" and user categories at the top, with Export / Import, iCloud backup and Settings pinned at the bottom;
/// adding accounts is in the toolbar. Right-click empty space to create a category.
struct SidebarView: View {
    @EnvironmentObject private var store: VaultStore
    @Environment(\.openSettings) private var openSettings
    @State private var categoryEditing: CategoryNameEditing?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("Accounts"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 14)
                    sidebarButton(.all, title: L10n.tr("All"), image: "rectangle.grid.1x2", count: store.accounts.count)
                    CategorySidebarSection(editing: $categoryEditing)
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .contextMenu {
                Button(L10n.tr("New Category")) {
                    categoryEditing = .new
                }
            }
            Divider()
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            toolButton(L10n.tr("Export / Import"), image: "square.and.arrow.up.on.square") {
                store.activeSheet = .exportImport
            }
            toolButton(L10n.tr("Backup & Sync"), image: store.syncLocation?.systemImage ?? "icloud", statusColor: backupStatusColor) {
                store.activeSheet = .backupSync
            }
            toolButton(L10n.tr("Settings"), image: "gearshape") {
                openSettings()
            }
            .padding(.bottom, 10)
        }
        .padding(.horizontal, 8)
        .background(.bar)
    }

    private func sidebarButton(_ section: VaultSection, title: String, image: String, count: Int? = nil) -> some View {
        Button {
            store.selectedSection = section
        } label: {
            HStack(spacing: 0) {
                SidebarRowLabel(title: title, image: image)
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(SidebarButtonStyle(isActive: store.selectedSection == section))
    }

    private func toolButton(
        _ title: String,
        image: String,
        statusColor: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 0) {
                SidebarRowLabel(title: title, image: image)
                Spacer()
                if let statusColor {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                        .padding(.trailing, 4)
                }
            }
        }
        .buttonStyle(SidebarButtonStyle(isActive: false))
    }

    /// Status dot at the end of the "Backup & Sync" row: hidden when off; green when healthy, orange for conflicts, red for failures.
    private var backupStatusColor: Color? {
        switch store.backupStatus {
        case .disabled: nil
        case .conflict: .orange
        case .failed, .unreadable: .red
        case .enabled, .running: .green
        }
    }
}

struct SidebarRowLabel: View {
    var title: String
    var image: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: image)
                .font(.system(size: 17, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .frame(width: 24, alignment: .center)
            Text(title)
                .lineLimit(1)
        }
    }
}

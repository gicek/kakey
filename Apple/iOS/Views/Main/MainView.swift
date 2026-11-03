import SwiftUI
import UniformTypeIdentifiers

/// Main screen after unlock.
/// - Compact width (iPhone, narrow iPad split view): single-column `NavigationStack` list; the menu in the middle of the navigation
///   bar switches between All and a category (category management at the end).
/// - Regular width (iPad): the sidebar lists All and each category, and accounts appear as a two- or three-column grid on the right.
/// Tapping an account copies its code; details open from the long-press menu as a system sheet.
struct MainView: View {
    @Environment(MobileVaultStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var detail: AccountDetailItem?
    @State private var flow = AddFlowController()

    var body: some View {
        Group {
            if sizeClass == .compact {
                NavigationStack {
                    AccountListView(layout: .list, onShowDetail: showDetail)
                }
            } else {
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
                } detail: {
                    NavigationStack {
                        AccountListView(layout: .grid, onShowDetail: showDetail)
                    }
                }
            }
        }
        .sheet(item: $detail) { item in
            NavigationStack { AccountDetailView(accountID: item.id) }
        }
        // Attach presentations before injecting the environment so sheets (Settings, confirmation) can also read `flow`
        .addFlows(flow)
        .environment(flow)
        // iPad: drop an image or otpauth text onto the window to recognize it
        .onDrop(of: [.image, .plainText, .url], isTargeted: nil) { providers in
            flow.handleDrop(providers)
            return true
        }
        #if DEBUG
            .task { openDemoScreenIfRequested() }
        #endif
        .onChange(of: store.accounts.map(\.id)) { _, ids in
            if let detail, !ids.contains(detail.id) { self.detail = nil }
        }
    }

    private func showDetail(_ id: Account.ID) {
        detail = AccountDetailItem(id: id)
    }
}

/// Presentation item for the detail sheet (`UUID` itself is not `Identifiable`).
private struct AccountDetailItem: Identifiable {
    let id: Account.ID
}

#if DEBUG
    extension MainView {
        /// Screenshot checks: `-KakeyDemoScreen detail|settings|manual|review|category|categories|detail-categories` opens that
        /// screen directly.
        fileprivate func openDemoScreenIfRequested() {
            guard DemoVault.isRequested, let screen = UserDefaults.standard.string(forKey: "KakeyDemoScreen") else { return }
            switch screen {
            case "detail", "detail-categories":
                if let id = store.accounts.first?.id { showDetail(id) }
            case "settings": flow.present(.settings)
            case "manual": flow.present(.manual)
            case "review": flow.present(.review(OTPAuthParser.parseLines(DemoVault.sampleLinks)))
            // Use the second category (Work), which contains an account that is also in Favorites
            case "category": if let id = store.categories.dropFirst().first?.id { store.section = .category(id) }
            default: break
            }
        }
    }
#endif

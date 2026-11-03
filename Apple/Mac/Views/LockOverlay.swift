import SwiftUI

/// The main window lock screen: no title bar, the unlock form centered in the whole window (including the traffic light strip), on
/// the same background as the main content area. When the main window becomes key, the form focuses itself and prompts Touch ID
/// according to the rules.
///
/// Whether the window is key is used only here, so it is local state of this view (as in the menu bar panel), not in `VaultStore`:
/// published on the store, every focus change of the main window (such as opening the menu bar panel) would recompute every
/// store-observing view in both the main window and the panel.
struct LockOverlay: View {
    /// After a menu bar Touch ID unlock, briefly keeps the lock screen look and accepts no input.
    var isPassive = false
    @State private var isWindowKey = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            UnlockForm(style: .window, isPassive: isPassive, isHostKey: isWindowKey)
                .padding(24)
        }
        .ignoresSafeArea()
        .background(
            WindowEventsView(
                onBecameKey: { _ in isWindowKey = true },
                onResignedKey: { _ in isWindowKey = false }
            )
            .frame(width: 0, height: 0)
        )
    }
}

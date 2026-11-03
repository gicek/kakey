import SwiftUI
import UniformTypeIdentifiers

/// Drag reordering session for iPad cards.
///
/// SwiftUI on iOS has no "drag ended" callback. With a drop target on each card, releasing often triggers no `performDrop` at all
/// (the dragged card has just moved under the finger and replaced the target view), leaving the session stuck halfway. So the whole
/// grid has a single drop target: cards swap places live as the finger moves, the preview order lives only in memory here (same as
/// the Mac), and releasing anywhere in the grid ends the session through that one target and saves once. Dragging out of the grid
/// discards the preview and clears the fade.
@MainActor @Observable
final class GridReorder {
    nonisolated static let space = "account-grid"
    /// Private type shared with the Mac (declared in Info.plist): images and text dragged in from outside are not accepted here
    /// and still go to MainView for recognition.
    nonisolated static let contentType = UTType(exportedAs: "com.gicek.kakey.account-reorder", conformingTo: .item)

    private(set) var draggedID: Account.ID?
    /// Set when the drop target actually sees the drag inside the grid; only then does the dragged card show as a faded
    /// placeholder. Not set in `begin`: SwiftUI may call the onDrag closure on long-press menus and even around release, and
    /// setting it there would leave the card faded.
    var isInside = false
    @ObservationIgnored var frames: [Account.ID: CGRect] = [:]
    var viewportHeight: CGFloat = 0
    /// Preview order during the drag; nil means nothing has moved.
    private(set) var previewIDs: [Account.ID]?

    func isFaded(_ id: Account.ID) -> Bool {
        isInside && draggedID == id
    }

    /// Visible accounts in preview order; accounts missing from the preview (newly shown after a search) go last.
    func ordered(_ accounts: [Account]) -> [Account] {
        guard let previewIDs else { return accounts }
        let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let previewSet = Set(previewIDs)
        return previewIDs.compactMap { byID[$0] } + accounts.filter { !previewSet.contains($0.id) }
    }

    /// The finger is over another card: move the dragged card to its position in the preview.
    func moveDragged(to target: Account.ID, in visibleIDs: [Account.ID]) {
        guard let draggedID, target != draggedID else { return }
        var ids = previewIDs ?? visibleIDs
        guard let from = ids.firstIndex(of: draggedID), let to = ids.firstIndex(of: target) else { return }
        ids.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        previewIDs = ids
    }

    func cancelPreview() {
        previewIDs = nil
    }

    func begin(_ id: Account.ID) -> NSItemProvider {
        draggedID = id
        previewIDs = nil
        let provider = NSItemProvider()
        // Visible only inside this app
        provider.registerDataRepresentation(forTypeIdentifier: Self.contentType.identifier, visibility: .ownProcess) { completion in
            completion(Data(id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }

    func target(at location: CGPoint) -> Account.ID? {
        frames.first { $0.value.contains(location) }?.key
    }

    /// Ends the session and returns the order to commit (nil when nothing moved).
    func end() -> [Account.ID]? {
        let result = previewIDs
        withAnimation(.snappy(duration: 0.2)) {
            draggedID = nil
            isInside = false
            previewIDs = nil
        }
        return result
    }
}

struct GridReorderDropDelegate: DropDelegate {
    let reorder: GridReorder
    let store: MobileVaultStore
    let isEnabled: Bool

    func validateDrop(info: DropInfo) -> Bool {
        reorder.draggedID != nil
    }

    func dropEntered(info: DropInfo) {
        reorder.isInside = true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if isEnabled, let draggedID = reorder.draggedID, let target = reorder.target(at: info.location), target != draggedID {
            withAnimation(.snappy(duration: 0.25)) {
                reorder.moveDragged(to: target, in: store.visibleAccounts.map(\.id))
            }
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        withAnimation(.snappy(duration: 0.2)) {
            reorder.isInside = false
            reorder.cancelPreview()
        }
    }

    /// Release: persists the preview order in one go (re-encrypts only once).
    func performDrop(info: DropInfo) -> Bool {
        if let orderedIDs = reorder.end() {
            store.applyAccountOrder(orderedIDs)
        }
        return true
    }
}

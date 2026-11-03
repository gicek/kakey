import AppKit
import SwiftUI

enum ReorderAutoScrollDirection: Equatable {
    case up
    case down

    var anchor: UnitPoint {
        switch self {
        case .up: .top
        case .down: .bottom
        }
    }
}

/// Coordinate space name shared by drag-to-reorder: the container (a scroll view or the sidebar category block) declares it, and
/// both item frames and the pointer location are expressed in it. The account list and the sidebar categories are two non-nested
/// containers, each resolving to its nearest space of this name, so they do not interfere.
enum ReorderSpace {
    static let name = "KakeyReorder"
    /// Height of the top / bottom edge zones and the auto-scroll beat (each beat scrolls `step` items).
    static let edgeZoneHeight: CGFloat = 44
    static let autoScrollInterval: TimeInterval = 0.16
}

/// The stand-in's position lives in its own object: only the stand-in view observes it, so pointer moves never re-evaluate the
/// list / cards.
@MainActor
final class ReorderPointerState: ObservableObject {
    /// The stand-in rectangle following the pointer (container coordinates); nil when there is no stand-in.
    @Published fileprivate(set) var previewFrame: CGRect?
}

/// A single drag-to-reorder session, shared by the main window's account list / cards and the sidebar categories.
///
/// Event-driven: instead of a system drag session (`onDrag` / `onDrop` with a private UTType), a `DragGesture` on each row / card
/// tracks the pointer itself. A system drag session has no "ended" callback and the drag manager swallows mouse events during the
/// drag, so the release could only be polled; the gesture's `onEnded` is the release, and Esc is turned into `escape()` by a key
/// monitor on the container, so nothing polls. Rows / cards report their frames in container coordinates through
/// `onGeometryChange`, and pointer moves are hit-tested against those frames.
///
/// Reordering previews live as the drag passes over targets (only the session's `previewOrder` changes, never the store), and the
/// result is decided on release:
/// - Released inside the container (rows, cards, gaps between rows, edge scroll zones) -> `commit()` saves once.
/// - Released outside the container (toolbar, sidebar, outside the window) or cancelled with Esc -> `cancel()`: the stand-in fades
///   out and the original order is restored.
///
/// Hit-testing uses enter / leave semantics: while the pointer stays within the same item's frame, nothing is re-evaluated. During
/// the swap animation item frames are interpolated, and re-evaluating on every move would flip back and forth; items swap only when
/// the pointer leaves the current item and enters another, and hit-testing prefers the current item and the dragged item's slot.
@MainActor
final class ReorderSession<ID: Hashable & Sendable>: ObservableObject {
    @Published private(set) var draggedID: ID?
    @Published private(set) var dropTargetID: ID?
    /// Preview order during the drag (the section's full ID sequence); exists only in session memory.
    @Published private(set) var previewOrder: [ID]?
    /// The pointer is resting in the top / bottom edge zone: the container calls `autoScrollTick` on each beat.
    @Published private(set) var autoScrollDirection: ReorderAutoScrollDirection?
    let pointer = ReorderPointerState()
    /// When the session started; the stand-in renders codes statically as of this moment.
    private(set) var startedAt = Date()
    /// When the pointer started hovering the auto-scroll zone; the container's timeline beats from here.
    private(set) var autoScrollStartedAt = Date()

    private let animation: Animation
    private var originalOrder: [ID] = []
    private var commitOrder: (([ID]) -> Void)?
    private var frames: [ID: CGRect] = [:]
    private var containerSize: CGSize = .zero
    private var autoScrolls = false
    /// The item currently under the pointer (including the dragged item's own slot), for enter / leave detection.
    private var hoveredID: ID?
    private var grabOffset: CGPoint = .zero
    private var draggedSize: CGSize = .zero
    /// After an Esc cancel the gesture keeps reporting moves; no new session starts until release.
    private var suppressedUntilRelease = false
    private var autoScrollAnchorID: ID?

    init(animation: Animation = .snappy(duration: 0.18)) {
        self.animation = animation
    }

    var isActive: Bool { draggedID != nil }

    /// Returns the items in preview order; unchanged when not dragging.
    func displayOrder<Item: Identifiable>(of items: [Item]) -> [Item] where Item.ID == ID {
        guard let previewOrder else { return items }
        return Self.applying(previewOrder, to: items)
    }

    // MARK: - Geometry reports (container and items)

    func setContainer(size: CGSize, autoScrolls: Bool) {
        containerSize = size
        self.autoScrolls = autoScrolls
    }

    func updateFrame(_ id: ID, _ frame: CGRect) {
        frames[id] = frame
    }

    func forgetFrame(_ id: ID) {
        frames[id] = nil
    }

    // MARK: - Session

    /// `order` is the section's full order, `start` the press location (container coordinates); `commit` is called once on release
    /// inside the drop zone if the order changed.
    func beginDrag(_ id: ID, at start: CGPoint, order: [ID], commit: @escaping ([ID]) -> Void) {
        guard !suppressedUntilRelease else { return }
        originalOrder = order
        previewOrder = order
        commitOrder = commit
        startedAt = Date()
        hoveredID = id
        autoScrollAnchorID = nil
        autoScrollDirection = nil
        let frame = frames[id] ?? CGRect(origin: start, size: .zero)
        grabOffset = CGPoint(x: start.x - frame.minX, y: start.y - frame.minY)
        draggedSize = frame.size
        pointer.previewFrame = CGRect(origin: frame.origin, size: frame.size)
        withAnimation(animation) {
            draggedID = id
            dropTargetID = nil
        }
    }

    /// Every gesture move. `begin` is called when no session has started yet (the caller opens one with the section's current order).
    func dragChanged(_ id: ID, from start: CGPoint, to location: CGPoint, begin: (CGPoint) -> Void) {
        if draggedID == nil {
            guard !suppressedUntilRelease else { return }
            begin(start)
        }
        guard draggedID == id else { return }
        pointerMoved(to: location)
    }

    func dragEnded(_ id: ID, at location: CGPoint) {
        guard draggedID == nil || draggedID == id else { return }
        pointerReleased(at: location)
    }

    func pointerMoved(to location: CGPoint) {
        guard isActive else { return }
        pointer.previewFrame = CGRect(
            origin: CGPoint(x: location.x - grabOffset.x, y: location.y - grabOffset.y),
            size: draggedSize
        )
        let edge = autoScrolls ? Self.edgeDirection(at: location, containerSize: containerSize) : nil
        if edge != autoScrollDirection {
            autoScrollStartedAt = Date()
            autoScrollDirection = edge
        }
        // The edge zones cover the first and last rows: while hovering a zone, only scroll; rows under the zone are not targets.
        setHovered(edge == nil ? hitTest(location) : nil)
    }

    /// Release: commit inside the container, restore outside it.
    func pointerReleased(at location: CGPoint) {
        suppressedUntilRelease = false
        guard isActive else { return }
        if CGRect(origin: .zero, size: containerSize).contains(location) {
            commit()
        } else {
            cancel()
        }
    }

    /// Esc: restore the original order. The gesture only really ends on release, and moves until then are ignored.
    func escape() {
        guard isActive else { return }
        suppressedUntilRelease = true
        cancel()
    }

    func dragEntered(_ targetID: ID) {
        guard let draggedID, draggedID != targetID else { return }
        autoScrollAnchorID = nil
        dropTargetID = targetID
        movePreview(draggedID, over: targetID)
    }

    func dragExited(_ targetID: ID) {
        if dropTargetID == targetID {
            dropTargetID = nil
        }
    }

    func commit() {
        guard isActive else { return }
        if let previewOrder, previewOrder != originalOrder {
            commitOrder?(previewOrder)
        }
        finish()
    }

    func cancel() {
        guard isActive else { return }
        finish()
    }

    /// One auto-scroll beat, called by the container every `autoScrollInterval` while `autoScrollDirection` is non-nil.
    /// `visibleIDs` is the currently displayed order (possibly filtered by search); `scrollTo` scrolls the viewport to an item.
    func autoScrollTick(step: Int, visibleIDs: [ID], scrollTo: (ID, UnitPoint) -> Void) {
        guard let draggedID, let direction = autoScrollDirection else { return }
        let anchorID = autoScrollAnchorID ?? dropTargetID ?? draggedID
        switch Self.autoScrollStep(visibleIDs: visibleIDs, anchorID: anchorID, draggedID: draggedID, direction: direction, step: step) {
        case .scroll(let id):
            autoScrollAnchorID = id
            withAnimation(.easeOut(duration: ReorderSpace.autoScrollInterval)) {
                scrollTo(id, direction.anchor)
            }
        case .moveToEdge(let edgeID):
            dropTargetID = edgeID
            movePreview(draggedID, over: edgeID)
        case .none:
            break
        }
    }

    // MARK: - Pure computation (testable)

    /// Moves `draggedID` to `targetID`'s position: after the target when dragging down, before it when dragging up.
    nonisolated static func movedOrder(_ order: [ID], moving draggedID: ID, over targetID: ID) -> [ID]? {
        guard draggedID != targetID,
            let sourceIndex = order.firstIndex(of: draggedID),
            let targetIndex = order.firstIndex(of: targetID)
        else { return nil }
        var moved = order
        moved.move(
            fromOffsets: IndexSet(integer: sourceIndex),
            toOffset: targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
        )
        return moved
    }

    /// Items missing from the preview order (added during the drag, or revealed by search filtering) are appended at the end.
    nonisolated static func applying<Item: Identifiable>(_ order: [ID], to items: [Item]) -> [Item] where Item.ID == ID {
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var ordered = order.compactMap { byID[$0] }
        let seen = Set(order)
        ordered.append(contentsOf: items.filter { !seen.contains($0.id) })
        return ordered
    }

    enum AutoScrollStep: Equatable {
        /// Scroll the viewport to this item.
        case scroll(to: ID)
        /// Reached the end: move the dragged item's preview to the very first / last position. The edge zones cover the first and
        /// last rows, so without this fallback an item could never be dragged to the first / last place.
        case moveToEdge(ID)
        case none
    }

    nonisolated static func autoScrollStep(
        visibleIDs: [ID],
        anchorID: ID?,
        draggedID: ID,
        direction: ReorderAutoScrollDirection,
        step: Int
    ) -> AutoScrollStep {
        guard let first = visibleIDs.first, let last = visibleIDs.last else { return .none }
        let anchorIndex =
            visibleIDs.firstIndex { $0 == anchorID }
            ?? (direction == .down ? 0 : visibleIDs.count - 1)
        let delta = direction == .down ? step : -step
        let nextIndex = min(max(anchorIndex + delta, 0), visibleIDs.count - 1)
        if nextIndex == anchorIndex {
            let edgeID = direction == .up ? first : last
            return draggedID == edgeID ? .none : .moveToEdge(edgeID)
        }
        return .scroll(to: visibleIDs[nextIndex])
    }

    /// The pointer is in a zone when within `ReorderSpace.edgeZoneHeight` of the container's top / bottom; no zones until the
    /// container has been measured.
    nonisolated static func edgeDirection(at location: CGPoint, containerSize: CGSize) -> ReorderAutoScrollDirection? {
        let zone = ReorderSpace.edgeZoneHeight
        guard containerSize.height > zone * 2, location.x >= 0, location.x <= containerSize.width else { return nil }
        if location.y >= 0, location.y < zone { return .up }
        if location.y > containerSize.height - zone, location.y <= containerSize.height { return .down }
        return nil
    }

    /// Which item the pointer is on: first the current item, then the dragged item's slot, otherwise the frame containing the
    /// pointer (the one with the nearest center when frames overlap).
    nonisolated static func hitTest(_ location: CGPoint, frames: [ID: CGRect], hoveredID: ID?, draggedID: ID?) -> ID? {
        if let hoveredID, frames[hoveredID]?.contains(location) == true { return hoveredID }
        if let draggedID, frames[draggedID]?.contains(location) == true { return draggedID }
        return
            frames
            .filter { $0.value.contains(location) }
            .min { lhs, rhs in
                Self.distanceSquared(location, lhs.value) < Self.distanceSquared(location, rhs.value)
            }?
            .key
    }

    // MARK: - Private

    private nonisolated static func distanceSquared(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = point.x - rect.midX
        let dy = point.y - rect.midY
        return dx * dx + dy * dy
    }

    private func hitTest(_ location: CGPoint) -> ID? {
        Self.hitTest(location, frames: frames, hoveredID: hoveredID, draggedID: draggedID)
    }

    private func setHovered(_ id: ID?) {
        guard id != hoveredID else { return }
        if let hoveredID {
            dragExited(hoveredID)
        }
        hoveredID = id
        if let id {
            dragEntered(id)
        }
    }

    private func movePreview(_ draggedID: ID, over targetID: ID) {
        guard let previewOrder, let moved = Self.movedOrder(previewOrder, moving: draggedID, over: targetID) else { return }
        withAnimation(animation) {
            self.previewOrder = moved
        }
    }

    private func finish() {
        autoScrollAnchorID = nil
        hoveredID = nil
        originalOrder = []
        commitOrder = nil
        // The commit order written back before previewOrder is cleared matches the preview, so nothing jumps.
        // On cancel nothing is written back: clearing the preview springs back to the original order with the same animation while
        // the stand-in fades out.
        withAnimation(animation) {
            draggedID = nil
            dropTargetID = nil
            previewOrder = nil
            autoScrollDirection = nil
            pointer.previewFrame = nil
        }
    }
}

// MARK: - View wiring

/// Scroll proxy needed for auto-scrolling: provided only by the account list / card scroll containers; sidebar categories have no
/// edge zones.
struct ReorderAutoScroll<ID: Hashable & Sendable> {
    var proxy: ScrollViewProxy
    var step: Int
    var visibleIDs: @MainActor () -> [ID]
}

extension View {
    /// Row / card: reports its frame and opens a session after dragging more than 4 pt (`begin` receives the press location; the caller
    /// opens the session with the section's current order).
    func reorderItem<ID: Hashable & Sendable>(
        _ id: ID,
        session: ReorderSession<ID>,
        begin: @escaping (CGPoint) -> Void
    ) -> some View {
        modifier(ReorderItemModifier(id: id, session: session, begin: begin))
    }

    /// Container: declares the coordinate space and hosts the stand-in and the Esc monitor; with `autoScroll`, edge zones for
    /// auto-scrolling appear at the top and bottom during a drag.
    func reorderContainer<ID: Hashable & Sendable, Preview: View>(
        session: ReorderSession<ID>,
        autoScroll: ReorderAutoScroll<ID>? = nil,
        @ViewBuilder preview: @escaping (ID) -> Preview
    ) -> some View {
        modifier(ReorderContainerModifier(session: session, autoScroll: autoScroll, preview: preview))
    }
}

private struct ReorderItemModifier<ID: Hashable & Sendable>: ViewModifier {
    let id: ID
    let session: ReorderSession<ID>
    let begin: (CGPoint) -> Void

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(ReorderSpace.name))
            } action: { frame in
                session.updateFrame(id, frame)
            }
            .onDisappear { session.forgetFrame(id) }
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named(ReorderSpace.name))
                    .onChanged { value in
                        session.dragChanged(id, from: value.startLocation, to: value.location, begin: begin)
                    }
                    .onEnded { value in
                        session.dragEnded(id, at: value.location)
                    }
            )
    }
}

private struct ReorderContainerModifier<ID: Hashable & Sendable, Preview: View>: ViewModifier {
    @ObservedObject var session: ReorderSession<ID>
    let autoScroll: ReorderAutoScroll<ID>?
    let preview: (ID) -> Preview
    @State private var escapeMonitor = ReorderEscapeMonitor()

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: ReorderSpace.name)
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                session.setContainer(size: size, autoScrolls: autoScroll != nil)
            }
            .overlay(alignment: .top) { autoScrollZone(.up) }
            .overlay(alignment: .bottom) { autoScrollZone(.down) }
            .overlay(alignment: .topLeading) {
                ReorderPreviewOverlay(pointer: session.pointer, draggedID: session.draggedID, preview: preview)
            }
            .onChange(of: session.isActive) { _, isActive in
                if isActive {
                    escapeMonitor.start { session.escape() }
                } else {
                    escapeMonitor.stop()
                }
            }
            .onDisappear {
                escapeMonitor.stop()
                session.cancel()
            }
    }

    @ViewBuilder
    private func autoScrollZone(_ direction: ReorderAutoScrollDirection) -> some View {
        if let autoScroll, session.isActive {
            ReorderAutoScrollZone(
                direction: direction,
                isScrolling: session.autoScrollDirection == direction,
                startedAt: session.autoScrollStartedAt
            ) {
                session.autoScrollTick(step: autoScroll.step, visibleIDs: autoScroll.visibleIDs()) { id, anchor in
                    autoScroll.proxy.scrollTo(id, anchor: anchor)
                }
            }
        }
    }
}

/// The stand-in following the pointer: observes only the pointer state, so the list does not redraw as the pointer moves.
private struct ReorderPreviewOverlay<ID: Hashable & Sendable, Preview: View>: View {
    @ObservedObject var pointer: ReorderPointerState
    let draggedID: ID?
    let preview: (ID) -> Preview

    var body: some View {
        if let draggedID, let frame = pointer.previewFrame {
            preview(draggedID)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}

/// Auto-scroll zones at the top and bottom of the scroll container during a drag; while the pointer hovers one, a periodic timeline
/// drives the scroll beat.
private struct ReorderAutoScrollZone: View {
    var direction: ReorderAutoScrollDirection
    var isScrolling: Bool
    var startedAt: Date
    var tick: () -> Void

    var body: some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.10), Color.accentColor.opacity(0.025), .clear],
            startPoint: direction == .up ? .top : .bottom,
            endPoint: direction == .up ? .bottom : .top
        )
        .frame(height: ReorderSpace.edgeZoneHeight)
        .allowsHitTesting(false)
        .background {
            if isScrolling {
                TimelineView(.periodic(from: startedAt, by: ReorderSpace.autoScrollInterval)) { context in
                    Color.clear
                        .onChange(of: context.date) { _, _ in tick() }
                }
            }
        }
    }
}

/// Watches Esc in this window during a drag: pressing it cancels the session and the event is not passed on.
@MainActor
private final class ReorderEscapeMonitor {
    private var monitor: Any?

    func start(onEscape: @escaping () -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { onEscape() }
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

import SwiftUI
import XCTest

@testable import Kakey

/// Drag reordering: pure computation (preview moves, applying the preview order, the next auto-scroll step at the edges, hot zones
/// and hit testing) and the session state machine (begin / move / release inside or outside the container / Esc / hot-zone
/// auto-scroll).
final class ReorderSessionTests: XCTestCase {
    private typealias Session = ReorderSession<String>

    func testMovingDownInsertsAfterTarget() {
        XCTAssertEqual(Session.movedOrder(["a", "b", "c", "d"], moving: "a", over: "c"), ["b", "c", "a", "d"])
    }

    func testMovingUpInsertsBeforeTarget() {
        XCTAssertEqual(Session.movedOrder(["a", "b", "c", "d"], moving: "d", over: "b"), ["a", "d", "b", "c"])
    }

    func testMovingOverItselfOrUnknownIsNoop() {
        XCTAssertNil(Session.movedOrder(["a", "b"], moving: "a", over: "a"))
        XCTAssertNil(Session.movedOrder(["a", "b"], moving: "a", over: "zzz"))
    }

    func testPreviewOrderAppendsItemsItDoesNotKnow() {
        struct Item: Identifiable, Equatable {
            let id: String
        }
        let items = [Item(id: "a"), Item(id: "b"), Item(id: "new")]
        XCTAssertEqual(Session.applying(["b", "a"], to: items).map(\.id), ["b", "a", "new"])
        XCTAssertEqual(Session.applying(["b", "gone", "a"], to: items).map(\.id), ["b", "a", "new"])
    }

    func testAutoScrollStepsByAnchorAndClampsAtEdges() {
        let ids = ["a", "b", "c", "d", "e"]
        XCTAssertEqual(Session.autoScrollStep(visibleIDs: ids, anchorID: "b", draggedID: "c", direction: .down, step: 2), .scroll(to: "d"))
        XCTAssertEqual(Session.autoScrollStep(visibleIDs: ids, anchorID: "d", draggedID: "c", direction: .down, step: 2), .scroll(to: "e"))
        // At the end: move the dragged item to the last position; do nothing if it is already there
        XCTAssertEqual(Session.autoScrollStep(visibleIDs: ids, anchorID: "e", draggedID: "c", direction: .down, step: 2), .moveToEdge("e"))
        XCTAssertEqual(Session.autoScrollStep(visibleIDs: ids, anchorID: "e", draggedID: "e", direction: .down, step: 2), .none)
        XCTAssertEqual(Session.autoScrollStep(visibleIDs: ids, anchorID: "a", draggedID: "c", direction: .up, step: 3), .moveToEdge("a"))
        // Anchor not in the visible list: count from the end when moving up, from the start when moving down
        XCTAssertEqual(Session.autoScrollStep(visibleIDs: ids, anchorID: nil, draggedID: "c", direction: .up, step: 1), .scroll(to: "d"))
        XCTAssertEqual(Session.autoScrollStep(visibleIDs: [], anchorID: nil, draggedID: "c", direction: .up, step: 1), .none)
    }

    func testEdgeDirectionUsesTopAndBottomZonesInsideContainer() {
        let size = CGSize(width: 400, height: 300)
        XCTAssertEqual(Session.edgeDirection(at: CGPoint(x: 10, y: 10), containerSize: size), .up)
        XCTAssertEqual(Session.edgeDirection(at: CGPoint(x: 10, y: 43), containerSize: size), .up)
        XCTAssertEqual(Session.edgeDirection(at: CGPoint(x: 10, y: 44), containerSize: size), nil)
        XCTAssertEqual(Session.edgeDirection(at: CGPoint(x: 10, y: 150), containerSize: size), nil)
        XCTAssertEqual(Session.edgeDirection(at: CGPoint(x: 10, y: 257), containerSize: size), .down)
        // No hot zones outside the container or before the container has been measured
        XCTAssertEqual(Session.edgeDirection(at: CGPoint(x: -1, y: 10), containerSize: size), nil)
        XCTAssertEqual(Session.edgeDirection(at: CGPoint(x: 10, y: 301), containerSize: size), nil)
        XCTAssertEqual(Session.edgeDirection(at: CGPoint(x: 10, y: 10), containerSize: .zero), nil)
    }

    func testHitTestKeepsCurrentItemAndPlaceholderWhileFramesOverlap() {
        // During the swap animation b's rect overlaps the dragged a: stay on b while still inside it, otherwise prefer a's slot, and
        // only then pick the nearest by center distance
        let frames = ["a": CGRect(x: 0, y: 0, width: 100, height: 50), "b": CGRect(x: 0, y: 20, width: 100, height: 50)]
        let point = CGPoint(x: 50, y: 40)
        XCTAssertEqual(Session.hitTest(point, frames: frames, hoveredID: "b", draggedID: "a"), "b")
        XCTAssertEqual(Session.hitTest(point, frames: frames, hoveredID: nil, draggedID: "a"), "a")
        XCTAssertEqual(Session.hitTest(point, frames: frames, hoveredID: nil, draggedID: nil), "b")
        XCTAssertEqual(Session.hitTest(CGPoint(x: 50, y: 25), frames: frames, hoveredID: nil, draggedID: nil), "a")
        XCTAssertNil(Session.hitTest(CGPoint(x: 200, y: 30), frames: frames, hoveredID: "b", draggedID: "a"))
    }

    // MARK: - State machine

    private struct Item: Identifiable, Equatable {
        let id: String
    }

    /// Four rows 50 pt tall in a 300 pt container: hot zones are 0–44 and 256–300.
    @MainActor
    private func makeSession(rows: [String] = ["a", "b", "c", "d"], committed: @escaping ([String]) -> Void = { _ in }) -> Session {
        let session = Session(animation: .linear(duration: 0))
        session.setContainer(size: CGSize(width: 400, height: 300), autoScrolls: true)
        for (index, id) in rows.enumerated() {
            session.updateFrame(id, CGRect(x: 0, y: CGFloat(index) * 50, width: 400, height: 50))
        }
        return session
    }

    @MainActor
    func testBeginRecordsOrderAndPlacesPreviewUnderPointer() {
        let session = makeSession()
        session.beginDrag("b", at: CGPoint(x: 30, y: 70), order: ["a", "b", "c", "d"]) { _ in }
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(session.draggedID, "b")
        XCTAssertNil(session.dropTargetID)
        XCTAssertEqual(session.previewOrder, ["a", "b", "c", "d"])
        XCTAssertEqual(session.pointer.previewFrame, CGRect(x: 0, y: 50, width: 400, height: 50))

        session.pointerMoved(to: CGPoint(x: 40, y: 90))
        // The drag image keeps the grab offset from the press (30, 20)
        XCTAssertEqual(session.pointer.previewFrame, CGRect(x: 10, y: 70, width: 400, height: 50))
    }

    @MainActor
    func testMovingOverAnotherRowPreviewsOnceAndReleaseInsideCommits() {
        var committed: [[String]] = []
        let session = makeSession()
        session.beginDrag("b", at: CGPoint(x: 30, y: 70), order: ["a", "b", "c", "d"]) { committed.append($0) }

        session.pointerMoved(to: CGPoint(x: 30, y: 130))
        XCTAssertEqual(session.dropTargetID, "c")
        XCTAssertEqual(session.previewOrder, ["a", "c", "b", "d"])
        XCTAssertEqual(session.displayOrder(of: ["a", "b", "c", "d"].map(Item.init)).map(\.id), ["a", "c", "b", "d"])
        // After the swap c's rect has not moved yet (animating): the pointer still inside c does not swap back
        session.pointerMoved(to: CGPoint(x: 31, y: 131))
        XCTAssertEqual(session.previewOrder, ["a", "c", "b", "d"])
        XCTAssertTrue(committed.isEmpty, "Nothing is written back during the drag")

        session.pointerReleased(at: CGPoint(x: 31, y: 131))
        XCTAssertEqual(committed, [["a", "c", "b", "d"]])
        XCTAssertFalse(session.isActive)
        XCTAssertNil(session.previewOrder)
        XCTAssertNil(session.dropTargetID)
        XCTAssertNil(session.pointer.previewFrame)
    }

    @MainActor
    func testReleaseWithoutOrderChangeDoesNotCommit() {
        var commits = 0
        let session = makeSession()
        session.beginDrag("b", at: CGPoint(x: 30, y: 70), order: ["a", "b", "c", "d"]) { _ in commits += 1 }
        session.pointerMoved(to: CGPoint(x: 30, y: 80))
        session.pointerReleased(at: CGPoint(x: 30, y: 80))
        XCTAssertEqual(commits, 0)
        XCTAssertFalse(session.isActive)
    }

    @MainActor
    func testLeavingAndReenteringRowClearsAndRestoresTarget() {
        let session = makeSession()
        session.beginDrag("a", at: CGPoint(x: 30, y: 20), order: ["a", "b", "c", "d"]) { _ in }
        session.pointerMoved(to: CGPoint(x: 30, y: 130))
        XCTAssertEqual(session.dropTargetID, "c")
        XCTAssertEqual(session.previewOrder, ["b", "c", "a", "d"])
        // Pointer leaves all rows (empty space right of the container): target highlight disappears, preview order is kept
        session.pointerMoved(to: CGPoint(x: 500, y: 130))
        XCTAssertNil(session.dropTargetID)
        XCTAssertEqual(session.previewOrder, ["b", "c", "a", "d"])
    }

    @MainActor
    func testReleaseOutsideContainerRestoresOriginalOrder() {
        var committed: [[String]] = []
        let session = makeSession()
        session.beginDrag("b", at: CGPoint(x: 30, y: 70), order: ["a", "b", "c", "d"]) { committed.append($0) }
        session.pointerMoved(to: CGPoint(x: 30, y: 130))
        XCTAssertEqual(session.previewOrder, ["a", "c", "b", "d"])

        session.pointerReleased(at: CGPoint(x: -20, y: 130))
        XCTAssertTrue(committed.isEmpty)
        XCTAssertFalse(session.isActive)
        XCTAssertNil(session.previewOrder, "Original order restored")
        XCTAssertNil(session.pointer.previewFrame)
    }

    @MainActor
    func testEscapeCancelsAndIgnoresGestureUntilRelease() {
        var committed: [[String]] = []
        let session = makeSession()
        session.beginDrag("b", at: CGPoint(x: 30, y: 70), order: ["a", "b", "c", "d"]) { committed.append($0) }
        session.pointerMoved(to: CGPoint(x: 30, y: 130))
        session.escape()
        XCTAssertFalse(session.isActive)
        XCTAssertNil(session.previewOrder)

        // Gesture has not ended: further moves do not start a new session, and release does not commit
        session.dragChanged("b", from: CGPoint(x: 30, y: 70), to: CGPoint(x: 30, y: 180)) { start in
            session.beginDrag("b", at: start, order: ["a", "b", "c", "d"]) { committed.append($0) }
        }
        XCTAssertFalse(session.isActive)
        session.dragEnded("b", at: CGPoint(x: 30, y: 180))
        XCTAssertTrue(committed.isEmpty)

        // A new session can start after release
        session.dragChanged("b", from: CGPoint(x: 30, y: 70), to: CGPoint(x: 30, y: 130)) { start in
            session.beginDrag("b", at: start, order: ["a", "b", "c", "d"]) { committed.append($0) }
        }
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(session.previewOrder, ["a", "c", "b", "d"])
    }

    @MainActor
    func testEscapeWithoutSessionIsNoop() {
        let session = makeSession()
        session.escape()
        XCTAssertFalse(session.isActive)
        session.pointerReleased(at: .zero)
        session.cancel()
        session.commit()
        XCTAssertFalse(session.isActive)
    }

    @MainActor
    func testGestureFromAnotherItemIsIgnoredWhileSessionRuns() {
        let session = makeSession()
        session.beginDrag("b", at: CGPoint(x: 30, y: 70), order: ["a", "b", "c", "d"]) { _ in }
        session.dragChanged("c", from: CGPoint(x: 30, y: 120), to: CGPoint(x: 30, y: 180)) { _ in XCTFail("No new session") }
        XCTAssertEqual(session.draggedID, "b")
        XCTAssertEqual(session.previewOrder, ["a", "b", "c", "d"])
        session.dragEnded("c", at: CGPoint(x: 30, y: 180))
        XCTAssertTrue(session.isActive)
    }

    @MainActor
    func testEdgeZoneScrollsThenMovesDraggedItemToEnd() {
        var committed: [[String]] = []
        var scrolled: [(String, UnitPoint)] = []
        let session = makeSession()
        session.beginDrag("b", at: CGPoint(x: 30, y: 70), order: ["a", "b", "c", "d"]) { committed.append($0) }

        // Entering the bottom hot zone: row d beneath it is not a target; scrolling starts instead
        session.pointerMoved(to: CGPoint(x: 30, y: 280))
        XCTAssertEqual(session.autoScrollDirection, .down)
        XCTAssertNil(session.dropTargetID)
        XCTAssertEqual(session.previewOrder, ["a", "b", "c", "d"])

        let visible = ["a", "b", "c", "d"]
        session.autoScrollTick(step: 2, visibleIDs: visible) { scrolled.append(($0, $1)) }
        XCTAssertEqual(scrolled.map(\.0), ["d"])
        XCTAssertEqual(scrolled.map(\.1), [.bottom])
        // Hovering on after scrolling to the end: move the dragged item to the last position
        session.autoScrollTick(step: 2, visibleIDs: visible) { scrolled.append(($0, $1)) }
        XCTAssertEqual(scrolled.count, 1)
        XCTAssertEqual(session.dropTargetID, "d")
        XCTAssertEqual(session.previewOrder, ["a", "c", "d", "b"])
        // Already at the end: further hovering does not change the order
        session.autoScrollTick(step: 2, visibleIDs: ["a", "c", "d", "b"]) { scrolled.append(($0, $1)) }
        XCTAssertEqual(session.previewOrder, ["a", "c", "d", "b"])

        // Leaving the hot zone (into empty space outside the container) stops scrolling; a later release in the hot zone still
        // counts as inside the container and commits
        session.pointerMoved(to: CGPoint(x: 500, y: 150))
        XCTAssertNil(session.autoScrollDirection)
        session.pointerMoved(to: CGPoint(x: 30, y: 20))
        XCTAssertEqual(session.autoScrollDirection, .up)
        session.pointerReleased(at: CGPoint(x: 30, y: 20))
        XCTAssertEqual(committed, [["a", "c", "d", "b"]])
        XCTAssertNil(session.autoScrollDirection)
    }

    @MainActor
    func testContainerWithoutAutoScrollHasNoEdgeZones() {
        // The container exactly wraps four rows: the last row falls in 156–200, where the bottom hot zone would be
        let session = makeSession()
        session.setContainer(size: CGSize(width: 400, height: 200), autoScrolls: false)
        session.beginDrag("b", at: CGPoint(x: 30, y: 70), order: ["a", "b", "c", "d"]) { _ in }
        XCTAssertEqual(Session.edgeDirection(at: CGPoint(x: 30, y: 180), containerSize: CGSize(width: 400, height: 200)), .down)
        session.pointerMoved(to: CGPoint(x: 30, y: 180))
        XCTAssertNil(session.autoScrollDirection)
        // Without hot zones the edge rows are targets as usual
        XCTAssertEqual(session.dropTargetID, "d")
        XCTAssertEqual(session.previewOrder, ["a", "c", "d", "b"])
        session.autoScrollTick(step: 2, visibleIDs: ["a", "c", "d", "b"]) { _, _ in XCTFail("Must not scroll without hot zones") }
    }

    @MainActor
    func testBeginWithoutKnownFrameStillTracksPointer() {
        let session = Session()
        session.setContainer(size: CGSize(width: 400, height: 300), autoScrolls: false)
        session.beginDrag("x", at: CGPoint(x: 10, y: 10), order: ["x"]) { _ in }
        XCTAssertEqual(session.pointer.previewFrame, CGRect(x: 10, y: 10, width: 0, height: 0))
        session.pointerMoved(to: CGPoint(x: 20, y: 30))
        XCTAssertEqual(session.pointer.previewFrame, CGRect(x: 20, y: 30, width: 0, height: 0))
        session.forgetFrame("x")
        session.pointerReleased(at: CGPoint(x: 20, y: 30))
        XCTAssertFalse(session.isActive)
    }
}

package com.gicek.kakey.android

import androidx.compose.runtime.MonotonicFrameClock
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import com.gicek.kakey.android.ui.main.EdgeAutoScroll
import com.gicek.kakey.android.ui.main.ReorderController
import kotlin.coroutines.resume
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure drag-to-reorder logic: edge zones and the speed curve, move targets, and targets following the layout during
 * auto-scroll (fake layout + manually advanced frames).
 */
class ReorderControllerTest {
    private val metrics = EdgeAutoScroll.Metrics(zone = 56f, maxSpeed = 1200f)

    private val viewport = 0f..800f

    @Test
    fun velocityIsZeroOutsideTheEdgeZones() {
        assertEquals(0f, EdgeAutoScroll.velocity(200f, 272f, viewport, -10f, metrics))
        assertEquals(0f, EdgeAutoScroll.velocity(200f, 272f, viewport, 10f, metrics))
        assertEquals("Top edge exactly on the zone boundary", 0f, EdgeAutoScroll.velocity(56f, 128f, viewport, -10f, metrics))
        assertEquals("Bottom edge exactly on the zone boundary", 0f, EdgeAutoScroll.velocity(672f, 744f, viewport, 10f, metrics))
        assertEquals("Zero-size zone", 0f, EdgeAutoScroll.velocity(0f, 72f, viewport, -10f, EdgeAutoScroll.Metrics(0f, 1200f)))
    }

    @Test
    fun velocityGrowsWithDepthAndIsCapped() {
        assertEquals("Halfway into the top zone: half speed up", -600f, EdgeAutoScroll.velocity(28f, 100f, viewport, -10f, metrics))
        assertEquals("At the top edge: full speed", -1200f, EdgeAutoScroll.velocity(0f, 72f, viewport, -10f, metrics))
        assertEquals("No faster beyond the top edge", -1200f, EdgeAutoScroll.velocity(-300f, -228f, viewport, -10f, metrics))
        assertEquals(
            "A quarter into the bottom zone: quarter speed down",
            300f,
            EdgeAutoScroll.velocity(686f, 758f, viewport, 10f, metrics),
        )
        assertEquals("At the bottom edge: full speed", 1200f, EdgeAutoScroll.velocity(728f, 800f, viewport, 10f, metrics))
        assertEquals(
            "Viewport top not at 0 (content padding) is still relative",
            -600f,
            EdgeAutoScroll.velocity(4f, 76f, -24f..776f, -10f, metrics),
        )
    }

    @Test
    fun zoneOnlyArmsAfterMovingTowardsIt() {
        assertEquals("Picked up inside the top zone, not moved yet: no scroll", 0f, EdgeAutoScroll.velocity(0f, 72f, viewport, 0f, metrics))
        assertEquals("In the top zone but dragging down: no scroll", 0f, EdgeAutoScroll.velocity(10f, 82f, viewport, 10f, metrics))
        assertEquals("In the bottom zone but dragging up: no scroll", 0f, EdgeAutoScroll.velocity(728f, 800f, viewport, -10f, metrics))
    }

    @Test
    fun distanceFollowsFrameTimeWithACap() {
        assertEquals(20f, EdgeAutoScroll.distance(1200f, 16_666_667L), 0.01f)
        assertEquals("Dropped frames count as at most 64 ms", 1200f * 0.064f, EdgeAutoScroll.distance(1200f, 500_000_000L), 0.01f)
        assertEquals("Time going backwards counts as 0", 0f, EdgeAutoScroll.distance(1200f, -5L))
        assertEquals(0f, EdgeAutoScroll.distance(0f, 16_000_000L))
    }

    @Test
    fun targetIsTheItemUnderTheCenterOrTheEdgeItemBeyondAllItems() {
        val visible = (0 until 4).map { ReorderController.Item("k$it", it, Rect(0f, it * 100f, 300f, it * 100f + 90f)) }
        assertEquals("k2", ReorderController.targetOf(visible, "k0", Offset(10f, 250f), Int.MAX_VALUE)?.key)
        assertNull("No move onto itself", ReorderController.targetOf(visible, "k2", Offset(10f, 250f), Int.MAX_VALUE))
        assertNull("No move in the gap between items", ReorderController.targetOf(visible, "k0", Offset(10f, 95f), Int.MAX_VALUE))
        assertEquals(
            "Past the last item's bottom: last item",
            "k3",
            ReorderController.targetOf(visible, "k0", Offset(10f, 700f), Int.MAX_VALUE)?.key,
        )
        assertNull("Already the last item", ReorderController.targetOf(visible, "k3", Offset(10f, 700f), Int.MAX_VALUE))
        assertEquals(
            "Past the first item's top: first item",
            "k0",
            ReorderController.targetOf(visible, "k3", Offset(10f, -40f), Int.MAX_VALUE)?.key,
        )
        assertEquals(
            "Trailing non-sortable items are never targets, even when dragged past",
            "k2",
            ReorderController.targetOf(visible, "k0", Offset(10f, 700f), 3)?.key,
        )
        assertEquals(
            "Center over a trailing non-sortable item counts as past the last sortable item",
            "k2",
            ReorderController.targetOf(visible, "k0", Offset(10f, 350f), 3)?.key,
        )
        assertNull(ReorderController.targetOf(emptyList(), "k0", Offset(10f, 10f), Int.MAX_VALUE))
    }

    @Test
    fun autoScrollMovesTheDraggedItemToTheEndAndStopsAtTheBound() {
        val layout = FakeLayout(count = 20, itemHeight = 100f, viewportHeight = 500f)
        val clock = TestFrameClock()
        var drops = 0
        val controller =
            ReorderController(layout, CoroutineScope(Dispatchers.Unconfined + clock), onMove = layout::move, onDrop = { drops++ })
        controller.start("k0", metrics)
        controller.drag(Offset(0f, 420f)) // Bottom edge 520 > 500 - 56: enters the bottom zone
        assertEquals("Moves to wherever it is dragged first", 4, layout.indexOf("k0"))
        assertTrue(clock.hasWaiter)

        var frames = 0
        var t = 0L
        while (clock.hasWaiter && frames < 200) {
            t += 16_000_000L
            clock.frame(t)
            frames++
        }
        assertFalse("Frame loop ends by itself at the bottom", clock.hasWaiter)
        assertEquals("List scrolled to the bottom", layout.maxScroll, layout.scroll, 0.01f)
        assertEquals("Dragged item follows the scroll to the last position", 19, layout.indexOf("k0"))
        assertEquals(
            "Overlay stays under the finger: start 0 + total offset 420 (viewport coordinates)",
            420f,
            controller.lifted.top + controller.offset.y,
            0.01f,
        )
        assertEquals("Nothing saved while scrolling", 0, drops)

        controller.end()
        assertEquals("Saved once on release", 1, drops)
        assertNull(controller.draggedKey)
        assertEquals(Offset.Zero, controller.offset)
    }

    @Test
    fun autoScrollStopsWhenTheItemLeavesTheZoneAndNeverScrollsPastTheTop() {
        val layout = FakeLayout(count = 20, itemHeight = 100f, viewportHeight = 500f)
        val clock = TestFrameClock()
        val controller = ReorderController(layout, CoroutineScope(Dispatchers.Unconfined + clock), onMove = layout::move, onDrop = {})
        controller.start("k0", metrics)
        controller.drag(Offset(0f, 430f))
        clock.frame(16_000_000L)
        clock.frame(32_000_000L)
        assertTrue("Scrolled some distance", layout.scroll > 0f)
        controller.drag(Offset(0f, -300f)) // Leave the zone
        assertFalse("Stops on leaving the zone", clock.hasWaiter)
        val stopped = layout.scroll
        clock.frame(48_000_000L)
        assertEquals(stopped, layout.scroll, 0f)

        controller.drag(Offset(0f, -250f)) // Top edge at -120: enters the top zone and scrolls all the way back up
        var t = 48_000_000L
        while (clock.hasWaiter && t < 5_000_000_000L) {
            t += 16_000_000L
            clock.frame(t)
        }
        assertEquals("Never scrolls past the top", 0f, layout.scroll, 0f)
        assertEquals("Back in first position", 0, layout.indexOf("k0"))
        controller.end()
    }

    @Test
    fun autoScrollKeepsMovingByTrackedIndexWhileTheDraggedItemIsNotComposed() {
        val layout = FakeLayout(count = 20, itemHeight = 100f, viewportHeight = 500f)
        val clock = TestFrameClock()
        val controller = ReorderController(layout, CoroutineScope(Dispatchers.Unconfined + clock), onMove = layout::move, onDrop = {})
        controller.start("k0", metrics)
        layout.hidden = "k0" // When scrolling outpaces recomposition, the dragged item is briefly missing from the layout
        controller.drag(Offset(0f, 420f))
        assertEquals("Moves by the tracked index even when not visible", 4, layout.indexOf("k0"))
        var t = 0L
        while (clock.hasWaiter && t < 5_000_000_000L) {
            t += 16_000_000L
            clock.frame(t)
        }
        assertEquals(layout.maxScroll, layout.scroll, 0.01f)
        assertEquals(19, layout.indexOf("k0"))
        controller.end()
    }

    @Test
    fun staleLayoutDoesNotRepeatAMove() {
        val layout = FakeLayout(count = 20, itemHeight = 100f, viewportHeight = 500f)
        var moves = 0
        val controller = ReorderController(layout, CoroutineScope(Dispatchers.Unconfined + TestFrameClock()), onMove = { from, to ->
            moves++
            layout.move(from, to)
        }, onDrop = {})
        controller.start("k0", metrics)
        layout.frozen = true // The move is in the data, but the layout is still stale
        controller.drag(Offset(0f, 250f)) // Center 300 lands on k3
        assertEquals(1, moves)
        assertEquals(3, layout.indexOf("k0"))
        controller.drag(Offset(0f, 10f))
        assertEquals("No further moves until the layout catches up", 1, moves)
        layout.frozen = false
        controller.drag(Offset(0f, 0f))
        assertEquals("Layout caught up, finger still on the same item: no move", 1, moves)
        assertEquals(3, layout.indexOf("k0"))
        controller.end()
    }

    /**
     * A vertical list of equal-height items: visible items are mapped to viewport coordinates by the scroll offset, and
     * scrolling is clamped between 0 and the maximum and returns the distance actually scrolled.
     */
    private class FakeLayout(count: Int, private val itemHeight: Float, private val viewportHeight: Float) : ReorderController.Layout {
        private val keys = (0 until count).map { "k$it" }.toMutableList()
        var scroll = 0f
            private set
        val maxScroll = count * itemHeight - viewportHeight

        /** An item missing from the layout (simulates being recycled after leaving the viewport). */
        var hidden: String? = null

        /** The layout stops following [move] (simulates the stale layout before recomposition). */
        var frozen = false
        private var snapshot: List<ReorderController.Item> = emptyList()

        fun indexOf(key: String) = keys.indexOf(key)

        override fun items(): List<ReorderController.Item> {
            if (frozen) return snapshot
            return keys.mapIndexedNotNull { index, key ->
                val top = index * itemHeight - scroll
                ReorderController.Item(key, index, Rect(0f, top, 300f, top + itemHeight))
                    .takeIf { key != hidden && top + itemHeight > 0f && top < viewportHeight }
            }.also { snapshot = it }
        }

        fun move(from: Int, to: Int) {
            keys.add(to, keys.removeAt(from))
        }

        override fun viewport() = 0f..viewportHeight

        override fun holdScrollPosition() = Unit

        override suspend fun scrollBy(delta: Float): Float {
            val next = (scroll + delta).coerceIn(0f, maxScroll)
            val consumed = next - scroll
            scroll = next
            return consumed
        }
    }

    /** A manually advanced frame clock: `frame(nanos)` resumes every coroutine waiting for the frame. */
    private class TestFrameClock : MonotonicFrameClock {
        private val waiters = mutableListOf<(Long) -> Unit>()
        val hasWaiter get() = waiters.isNotEmpty()

        override suspend fun <R> withFrameNanos(onFrame: (frameTimeNanos: Long) -> R): R = suspendCancellableCoroutine { continuation ->
            val waiter: (Long) -> Unit = { nanos -> continuation.resume(onFrame(nanos)) }
            waiters += waiter
            continuation.invokeOnCancellation { waiters -= waiter }
        }

        fun frame(nanos: Long) {
            val pending = waiters.toList()
            waiters.clear()
            pending.forEach { it(nanos) }
        }
    }
}

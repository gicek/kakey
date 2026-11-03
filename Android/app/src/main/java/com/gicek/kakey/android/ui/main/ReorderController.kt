package com.gicek.kakey.android.ui.main

import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.round
import androidx.compose.ui.unit.toSize
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * Drag-to-reorder shared by lists and grids: the dragged item follows the finger and swaps immediately as it passes other
 * items (the in-memory order moves along as a preview); [onDrop] saves once on release, matching iPhone / iPad. Reorderable
 * items come first in the Lazy container, so container indices are data indices; non-reorderable items at the end (such as
 * footnotes) are excluded from swap targets via [count].
 *
 * What follows the finger is an overlay ([ReorderOverlay], the counterpart of iPad's drag preview) outside the Lazy
 * container's layout: the item in the list leaves only a faded placeholder ([reorderable]) that slides to its new position
 * with the others via `animateItem`. Translating the in-list item by "start + accumulated offset − current position" doesn't
 * work: right after a swap the layout has changed but the translation isn't recomputed until the next pointer event, so the
 * item jumps a row and snaps back; and with bouncy springs on the items making way, the whole column wobbles during
 * consecutive swaps.
 *
 * When the dragged item's top / bottom edge enters the viewport's top / bottom hot zone it auto-scrolls ([EdgeAutoScroll]):
 * a coroutine in [scope] runs on frame time (`withFrameNanos`), calling [scrollBy] each frame and then recomputing the swap
 * target from the new layout; it stops on leaving the zone, hitting the end, or release.
 * Swap and hot zone coordinates are in the Lazy container's layout space (item `offset`), with [Layout.viewport] being the
 * visible top and bottom in that space; overlay coordinates are in the host container ([reorderHost]), converted through each
 * item's [LayoutCoordinates], independent of the Lazy container's content padding.
 */
@Stable
class ReorderController(
    private val layout: Layout,
    private val scope: CoroutineScope,
    private val count: () -> Int = { Int.MAX_VALUE },
    private val onMove: (from: Int, to: Int) -> Unit,
    private val onDrop: () -> Unit,
) {
    data class Item(val key: Any, val index: Int, val bounds: Rect)

    /** Reads and scrolls the Lazy container's current layout (tests substitute a fake layout). */
    interface Layout {
        fun items(): List<Item>

        fun viewport(): ClosedFloatingPointRange<Float>

        /** Scrolls by [delta] pixels (positive is down) and returns the amount actually scrolled; 0 at the top / bottom. */
        suspend fun scrollBy(delta: Float): Float

        /**
         * After a swap, pins the scroll position by "index + pixel offset". By default the Lazy container anchors scrolling to
         * the first visible item's key, so when the dragged item is the first visible one the list jumps along with it (which
         * then puts the next item under the finger, jumping all the way to the end).
         */
        fun holdScrollPosition()
    }

    var draggedKey by mutableStateOf<Any?>(null)
        private set

    /** Accumulated finger movement since pickup (pixels); the overlay follows it starting from [lifted]. */
    var offset by mutableStateOf(Offset.Zero)
        private set

    /** Position and size of the dragged item in the host container at pickup (pixels): the overlay's starting point. */
    var lifted by mutableStateOf(Rect.Zero)
        private set

    /** Layout coordinates of each item and the host container (registered by [reorderable] / [reorderHost]); read only once at pickup. */
    internal val coordinates = mutableMapOf<Any, LayoutCoordinates>()
    internal var host: LayoutCoordinates? = null

    private var origin = Offset.Zero
    private var draggedSize = Size.Zero
    private var metrics = EdgeAutoScroll.Metrics(0f, 0f)

    /**
     * Data index of the dragged item, updated after each [onMove]. If its index in the layout differs, the layout hasn't caught
     * up with the last swap yet, so no further swap happens (avoiding repeated moves based on a stale layout). If the dragged
     * item isn't in the layout at all (scrolling outran recomposition and it briefly left the viewport), swapping continues
     * based on this index.
     */
    private var draggedIndex = 0
    private var autoScroll: Job? = null

    /** Where the dragged item follows the finger (layout space): start + accumulated offset, with size unchanged during the drag. */
    private val ghost: Rect get() = Rect(origin + offset, draggedSize)

    fun start(key: Any, metrics: EdgeAutoScroll.Metrics) {
        val item = layout.items().firstOrNull { it.key == key } ?: return
        lifted = liftedBounds(key) ?: item.bounds
        draggedKey = key
        origin = item.bounds.topLeft
        draggedSize = item.bounds.size
        offset = Offset.Zero
        draggedIndex = item.index
        this.metrics = metrics
    }

    fun drag(delta: Offset) {
        if (draggedKey == null) return
        offset += delta
        update()
        syncAutoScroll()
    }

    fun end() {
        val moved = draggedKey != null
        stopAutoScroll()
        draggedKey = null
        offset = Offset.Zero
        if (moved) onDrop()
    }

    /**
     * The dragged item's position in the host container: both are converted to root coordinates and subtracted. Null when not
     * registered (fake layouts in tests).
     */
    private fun liftedBounds(key: Any): Rect? {
        val item = coordinates[key]?.takeIf { it.isAttached } ?: return null
        val host = host?.takeIf { it.isAttached } ?: return null
        return Rect(item.positionInRoot() - host.positionInRoot(), item.size.toSize())
    }

    /** Recomputes the translation and swap target from the latest layout: needed after finger movement and after each auto-scroll step. */
    private fun update() {
        val key = draggedKey ?: return
        val visible = layout.items()
        val current = visible.firstOrNull { it.key == key }
        // Don't swap while the layout index hasn't caught up with the last swap
        if (current != null && current.index != draggedIndex) return
        val target = targetOf(visible, key, ghost.center, count()) ?: return
        if (target.index == draggedIndex) return
        onMove(draggedIndex, target.index)
        draggedIndex = target.index
        layout.holdScrollPosition()
    }

    private fun velocity(): Float = EdgeAutoScroll.velocity(ghost.top, ghost.bottom, layout.viewport(), offset.y, metrics)

    private fun syncAutoScroll() {
        if (velocity() == 0f) {
            stopAutoScroll()
        } else if (autoScroll?.isActive != true) {
            autoScroll = scope.launch { runAutoScroll() }
        }
    }

    private fun stopAutoScroll() {
        autoScroll?.cancel()
        autoScroll = null
    }

    /**
     * Frame loop: each frame scrolls velocity × frame interval, then recomputes the target; ends on leaving the zone, hitting
     * the top / bottom (no distance scrolled) or release.
     */
    private suspend fun runAutoScroll() {
        var previous = withFrameNanos { it }
        var velocity = velocity()
        while (draggedKey != null && velocity != 0f) {
            val now = withFrameNanos { it }
            val distance = EdgeAutoScroll.distance(velocity, now - previous)
            previous = now
            // Stop when nothing scrolled (top / bottom reached); drag() re-evaluates when the finger moves again
            if (distance != 0f && layout.scrollBy(distance) == 0f) break
            update()
            velocity = velocity()
        }
    }

    companion object {
        /**
         * Swaps to whichever item the dragged item's center lands on. If the center passes below every visible item (scrolled
         * to the end, landing in trailing space) it swaps to the last visible item, and above every visible item to the first;
         * landing in a gap between items doesn't swap. Items with index ≥ [count] aren't reorderable and are never targets.
         */
        fun targetOf(visible: List<Item>, draggedKey: Any, center: Offset, count: Int): Item? {
            val candidates = visible.filter { it.index < count }
            candidates.firstOrNull { it.key != draggedKey && it.bounds.contains(center) }?.let { return it }
            val edge = when {
                candidates.all { center.y >= it.bounds.bottom } -> candidates.maxByOrNull { it.index }
                candidates.all { center.y < it.bounds.top } -> candidates.minByOrNull { it.index }
                else -> null
            }
            return edge?.takeIf { it.key != draggedKey }
        }

        fun forList(
            state: LazyListState,
            scope: CoroutineScope,
            onMove: (Int, Int) -> Unit,
            onDrop: () -> Unit,
            count: () -> Int = { Int.MAX_VALUE },
        ) = ReorderController(
            layout = object : Layout {
                override fun items(): List<Item> {
                    val width = state.layoutInfo.viewportSize.width.toFloat()
                    return state.layoutInfo.visibleItemsInfo.map {
                        Item(it.key, it.index, Rect(0f, it.offset.toFloat(), width, (it.offset + it.size).toFloat()))
                    }
                }

                override fun viewport() = state.layoutInfo.viewportStartOffset.toFloat()..state.layoutInfo.viewportEndOffset.toFloat()

                override suspend fun scrollBy(delta: Float) = state.scrollBy(delta)

                override fun holdScrollPosition() =
                    state.requestScrollToItem(state.firstVisibleItemIndex, state.firstVisibleItemScrollOffset)
            },
            scope = scope,
            count = count,
            onMove = onMove,
            onDrop = onDrop,
        )

        fun forGrid(state: LazyGridState, scope: CoroutineScope, onMove: (Int, Int) -> Unit, onDrop: () -> Unit) = ReorderController(
            layout = object : Layout {
                override fun items() = state.layoutInfo.visibleItemsInfo.map {
                    Item(
                        it.key,
                        it.index,
                        Rect(
                            Offset(it.offset.x.toFloat(), it.offset.y.toFloat()),
                            Size(it.size.width.toFloat(), it.size.height.toFloat()),
                        ),
                    )
                }

                override fun viewport() = state.layoutInfo.viewportStartOffset.toFloat()..state.layoutInfo.viewportEndOffset.toFloat()

                override suspend fun scrollBy(delta: Float) = state.scrollBy(delta)

                override fun holdScrollPosition() =
                    state.requestScrollToItem(state.firstVisibleItemIndex, state.firstVisibleItemScrollOffset)
            },
            scope = scope,
            onMove = onMove,
            onDrop = onDrop,
        )
    }
}

/**
 * Reorderable item: registers its layout coordinates (used to compute the overlay's start at pickup), stays in place as a
 * faded placeholder while dragged, and slides to its new position via `animateItem`. Whether it is being dragged is read
 * only in the draw phase, so pickup and release don't recompose the whole column.
 */
fun Modifier.reorderable(controller: ReorderController, key: Any): Modifier = this
    .onGloballyPositioned { controller.coordinates[key] = it }
    .graphicsLayer { alpha = if (controller.draggedKey == key) PLACEHOLDER_ALPHA else 1f }

/** Overlay host: the same Box laid over the Lazy container; [ReorderOverlay] coordinates are relative to it. */
fun Modifier.reorderHost(controller: ReorderController): Modifier = onGloballyPositioned { controller.host = it }

/**
 * The overlay following the finger: draws a copy of [content] at the dragged item's pickup position and size, slightly
 * enlarged with a shadow, moving with the finger; draws nothing when not dragging. The position reads
 * [ReorderController.offset] in the layout phase, so each pointer event only re-places the overlay without recomposing the
 * list.
 */
@Composable
fun ReorderOverlay(controller: ReorderController, content: @Composable (key: Any) -> Unit) {
    val key = controller.draggedKey ?: return
    val lifted = controller.lifted
    val width = lifted.width.toInt()
    val height = lifted.height.toInt()
    if (width <= 0 || height <= 0) return
    Box(
        Modifier
            .offset { (lifted.topLeft + controller.offset).round() }
            .layout { measurable, _ ->
                val placeable = measurable.measure(Constraints.fixed(width, height))
                layout(width, height) { placeable.place(0, 0) }
            }
            .graphicsLayer {
                scaleX = DRAG_SCALE
                scaleY = DRAG_SCALE
            },
    ) {
        Surface(shape = MaterialTheme.shapes.large, shadowElevation = DRAG_ELEVATION) { content(key) }
    }
}

/** Overlay scale and shadow elevation; placeholder alpha. */
private const val DRAG_SCALE = 1.03f
private val DRAG_ELEVATION = 8.dp
private const val PLACEHOLDER_ALPHA = 0.3f

/** Edge hot zone height and maximum speed converted to pixels for the current screen density. */
fun Density.autoScrollMetrics() = EdgeAutoScroll.Metrics(EdgeAutoScroll.ZONE_DP.dp.toPx(), EdgeAutoScroll.MAX_SPEED_DP_PER_SECOND.dp.toPx())

/**
 * Drag handle (category management): draggable on press. Account lists and grids drag the whole row after a long-press
 * instead; see the gestures in `AccountItem`.
 */
fun Modifier.dragHandle(controller: ReorderController, key: Any): Modifier = pointerInput(key) {
    detectDragGestures(
        onDragStart = { controller.start(key, autoScrollMetrics()) },
        onDrag = { change, delta ->
            change.consume()
            controller.drag(delta)
        },
        onDragEnd = controller::end,
        onDragCancel = controller::end,
    )
}

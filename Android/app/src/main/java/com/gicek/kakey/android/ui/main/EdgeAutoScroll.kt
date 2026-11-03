package com.gicek.kakey.android.ui.main

/**
 * Auto-scroll when a dragged item reaches the top / bottom edge of the viewport during reordering: pure math with no Compose
 * or Android dependency. Coordinates are pixels with the main axis positive downward; time is frame time (nanoseconds),
 * driven by [ReorderController]'s frame loop.
 */
object EdgeAutoScroll {
    /** Height of the top / bottom hot zones (dp), same as Mac / iPad. */
    const val ZONE_DP = 56

    /** Maximum scroll speed (dp / second), reached when the dragged item's edge touches the viewport edge. */
    const val MAX_SPEED_DP_PER_SECOND = 1200

    /** Cap on the time one frame's movement is computed for, so a dropped frame or returning from the background doesn't jump far. */
    const val MAX_FRAME_NANOS = 64_000_000L

    private const val NANOS_PER_SECOND = 1_000_000_000f

    /** Hot zone height and maximum speed converted to pixels. */
    data class Metrics(val zone: Float, val maxSpeed: Float)

    /**
     * Scroll speed for the current frame (pixels / second): scrolls up (negative) when the dragged item's top edge enters the
     * top zone and down (positive) when its bottom edge enters the bottom zone, faster the deeper it goes, reaching
     * [Metrics.maxSpeed] at the viewport edge. A zone only takes effect after the item has moved toward it ([travel] is the
     * cumulative vertical movement since pickup), so an item picked up inside a zone doesn't scroll away immediately. Zero
     * outside a zone or when the zone isn't active.
     */
    fun velocity(itemTop: Float, itemBottom: Float, viewport: ClosedFloatingPointRange<Float>, travel: Float, metrics: Metrics): Float {
        if (metrics.zone <= 0f || metrics.maxSpeed <= 0f) return 0f
        val up = if (travel < 0f) ((viewport.start + metrics.zone - itemTop) / metrics.zone).coerceIn(0f, 1f) else 0f
        val down = if (travel > 0f) ((itemBottom - (viewport.endInclusive - metrics.zone)) / metrics.zone).coerceIn(0f, 1f) else 0f
        return if (up > 0f) -up * metrics.maxSpeed else down * metrics.maxSpeed
    }

    /**
     * Pixels to scroll this frame: velocity × frame interval, with the interval capped at [MAX_FRAME_NANOS] and negative time
     * treated as 0.
     */
    fun distance(velocity: Float, elapsedNanos: Long): Float = velocity * (elapsedNanos.coerceIn(0L, MAX_FRAME_NANOS) / NANOS_PER_SECOND)
}

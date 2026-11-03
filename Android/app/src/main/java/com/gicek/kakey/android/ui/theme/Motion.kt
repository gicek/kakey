package com.gicek.kakey.android.ui.theme

import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.spring

/**
 * Material 3 Expressive spring motion (stiffness / damping from the spec's expressive motion scheme).
 * In stable Material 3 (1.4), `MotionScheme` and `MaterialExpressiveTheme` are still internal APIs, so this is built here to
 * spec; once the Expressive API is public it can be replaced with `MaterialTheme.motionScheme`. Screen transitions are in
 * [Transitions].
 */
object Motion {
    /** Position, size and shape changes: a slight bounce. */
    fun <T> spatial(): FiniteAnimationSpec<T> = spring(dampingRatio = 0.8f, stiffness = 380f)

    /** Position and scale of small elements (menu items, buttons): faster with a more noticeable bounce. */
    fun <T> fastSpatial(): FiniteAnimationSpec<T> = spring(dampingRatio = 0.6f, stiffness = 800f)

    /**
     * Other rows / cards making way during drag-to-reorder: slide once without bouncing. The bouncy [spatial] makes every swap
     * wobble, which turns into jitter during consecutive swaps; with critical damping the movement converges monotonically, so
     * other rows slide only once per row the finger passes.
     */
    fun <T> shift(): FiniteAnimationSpec<T> = spring(dampingRatio = 1f, stiffness = 500f)

    /** Color and alpha: no bounce. */
    fun <T> effects(): FiniteAnimationSpec<T> = spring(dampingRatio = 1f, stiffness = 1600f)

    fun <T> fastEffects(): FiniteAnimationSpec<T> = spring(dampingRatio = 1f, stiffness = 3800f)
}

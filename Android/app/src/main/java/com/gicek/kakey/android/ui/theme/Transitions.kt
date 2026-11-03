package com.gicek.kakey.android.ui.theme

import androidx.compose.animation.ContentTransform
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp

/**
 * Screen transition animations (only what they look like; which one is used when is decided by `ui/main/NavTransitions.kt`).
 *
 * Three transitions, following Material 3 transition patterns and Android predictive back guidelines:
 * - [enter]: entering a child page. The new page slides in [SHARED_AXIS_OFFSET_DP] from the right and fades in (the enter
 *   half of shared axis X).
 * - [sharedAxisX]: back via button / back key, and onboarding steps. Old and new content slide in opposite directions and
 *   crossfade.
 * - [previewBack]: back gesture. While dragging, the current page shrinks into an opaque preview following the finger with the
 *   previous page visible behind; on release it fades out in place.
 *
 * Navigation 3's default 700 ms crossfade feels sluggish both entering and leaving, hence these.
 */
object Transitions {
    /** Shared axis X offset (Material 3 transition patterns call for around 30dp; 32dp is used). */
    const val SHARED_AXIS_OFFSET_DP = 32

    /** Scale of the preview (the system's cross-Activity back shrinks to about 90%). */
    private const val PREVIEW_SCALE = 0.9f

    /**
     * Total duration of the preview animation and of its trailing fade-out. NavDisplay seeks the whole animation by gesture
     * progress and finishes it on release over "remaining fraction × total duration": the longer the total, the slower the
     * preview disappears after a quick flick, so it gets only 200 ms; scaling during the drag follows progress and doesn't depend
     * on duration. The fade takes only the last 80 ms (after 60% progress), so the page never disappears mid-drag and comes back
     * intact if the gesture is canceled (tuned on a real device).
     */
    private const val PREVIEW_TOTAL_MS = 200
    private const val PREVIEW_FADE_MS = 80

    /** `NavigationEvent.EDGE_LEFT`: the gesture started from the left edge. */
    private const val SWIPE_EDGE_LEFT = 0

    /** Shared axis X offset converted to pixels for the current density. */
    @Composable
    fun sharedAxisOffsetPx(): Int = with(LocalDensity.current) { SHARED_AXIS_OFFSET_DP.dp.roundToPx() }

    /**
     * Entering a child page: slides in [offsetPx] from the right and fades in. Slide uses the fast spatial spring and alpha
     * the effects spring, about 300 ms in total.
     */
    fun enter(offsetPx: Int): EnterTransition = fadeIn(Motion.effects()) + slideInHorizontally(Motion.fastSpatial()) { offsetPx }

    /**
     * Shared axis X: new content slides in [offsetPx] from one side and fades in while old content slides the same distance
     * the other way and fades out; mirrored when `forward` is false.
     */
    fun sharedAxisX(offsetPx: Int, forward: Boolean): ContentTransform {
        val direction = if (forward) 1 else -1
        val enter = fadeIn(Motion.effects()) + slideInHorizontally(Motion.fastSpatial()) { direction * offsetPx }
        val exit = fadeOut(Motion.effects()) + slideOutHorizontally(Motion.fastSpatial()) { -direction * offsetPx }
        return enter togetherWith exit
    }

    /** A transition with no duration: NavDisplay settles on the new page immediately. */
    val instant: ContentTransform get() = EnterTransition.None togetherWith ExitTransition.None

    /**
     * Back gesture preview: the current page scales down uniformly to [PREVIEW_SCALE], anchored on the side opposite the gesture
     * (anchored right when swiping from the left edge) so the preview follows the finger; the previous page is fully shown
     * behind from the start (entering with `EnterTransition.None`). No translation: after release the page would look flung far
     * away.
     */
    fun previewBack(swipeEdge: Int): ContentTransform {
        val pivot = TransformOrigin(pivotFractionX = if (swipeEdge == SWIPE_EDGE_LEFT) 1f else 0f, pivotFractionY = 0.5f)
        val exit = scaleOut(
            animationSpec = tween(PREVIEW_TOTAL_MS, easing = LinearEasing),
            targetScale = PREVIEW_SCALE,
            transformOrigin = pivot,
        ) + fadeOut(tween(PREVIEW_FADE_MS, delayMillis = PREVIEW_TOTAL_MS - PREVIEW_FADE_MS, easing = LinearEasing))
        return EnterTransition.None togetherWith exit
    }
}

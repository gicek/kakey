package com.gicek.kakey.android.ui.main

import androidx.compose.animation.AnimatedContentTransitionScope
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.ContentTransform
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.navigation3.scene.Scene
import com.gicek.kakey.android.ui.theme.Transitions

/**
 * Decides in one place which transition main navigation (Navigation 3 `NavDisplay`) uses; the animations themselves are in
 * [Transitions].
 *
 * - **Forward**: [forward] is an instant switch and the new page plays its own enter animation on first appearance
 *   ([EnterOnAppear]). Enter isn't a NavDisplay transition because until a transition finishes, Navigation 3 state stays on
 *   the previous page and a back gesture can't trigger the previewing animation; a page animating itself doesn't hold the
 *   navigation state, so swipe-back works as soon as it appears.
 * - **Back key / back button**: [pop] uses the mirrored shared X axis. When the system has no predictive back progress events
 *   (Android 13, or Android 14 / 15 with predictive back disabled), a back gesture also only fires `onBack` and lands here,
 *   giving a plain slide-back.
 * - **Back gesture** (with progress events): [predictivePop] previews, with NavDisplay seeking by gesture progress.
 * - **Direction**: decided by the order of the two pages in the back stack ([isForward]) rather than trusting whether
 *   NavDisplay picked the forward or pop spec. If a back gesture starts before a forward animation finishes, Navigation 3 1.2
 *   re-evaluates the pop with the forward spec after the gesture ends (reproduced on a Pixel 7), so a hard-coded direction
 *   would slide the wrong way. Scene entries map back to the back stack via [Route.contentKey] (`NavEntry.key` is private).
 */
class NavTransitions(private val backStack: List<Route>, private val sharedAxisOffsetPx: Int) {
    val forward: AnimatedContentTransitionScope<Scene<Route>>.() -> ContentTransform = {
        if (isForward(initialState, targetState)) Transitions.instant else Transitions.sharedAxisX(sharedAxisOffsetPx, forward = false)
    }

    val pop: AnimatedContentTransitionScope<Scene<Route>>.() -> ContentTransform = {
        Transitions.sharedAxisX(sharedAxisOffsetPx, forward = isForward(initialState, targetState))
    }

    val predictivePop: AnimatedContentTransitionScope<Scene<Route>>.(Int) -> ContentTransform = { swipeEdge ->
        Transitions.previewBack(swipeEdge)
    }

    private fun isForward(from: Scene<Route>, to: Scene<Route>): Boolean =
        isForward(backStack.map { it.contentKey }, from.contentKey, to.contentKey)

    private val Scene<Route>.contentKey: Any? get() = entries.lastOrNull()?.contentKey

    companion object {
        /** The destination is always in the stack; it's a pop when the origin has been popped or sits after the destination. */
        fun isForward(stackKeys: List<String>, fromKey: Any?, toKey: Any?): Boolean {
            val fromIndex = stackKeys.lastIndexOf(fromKey)
            val toIndex = stackKeys.lastIndexOf(toKey)
            return when {
                toIndex < 0 -> true
                fromIndex < 0 -> false
                else -> toIndex >= fromIndex
            }
        }
    }
}

/** NavDisplay's three transitionSpecs, remembered per back stack and density. */
@Composable
fun rememberNavTransitions(backStack: List<Route>): NavTransitions {
    val offset = Transitions.sharedAxisOffsetPx()
    return remember(backStack, offset) { NavTransitions(backStack, offset) }
}

/**
 * A just-pushed page plays its enter animation ([Transitions.enter]) once on first appearance; when returning to it or after
 * recreation it shows directly. Both cases must have the same composition tree shape (both wrapped in AnimatedVisibility),
 * otherwise state that rememberSaveable restores by position, such as scroll position, doesn't line up (returning to
 * settings would scroll the list back to the top); without the animation the initial state is simply "visible".
 */
@Composable
fun EnterOnAppear(route: Route, content: @Composable () -> Unit) {
    val navigator = LocalNavigator.current
    val offset = Transitions.sharedAxisOffsetPx()
    val visible = remember(route) {
        val animate = navigator.consumeEnter(route)
        MutableTransitionState(!animate).apply { targetState = true }
    }
    AnimatedVisibility(visibleState = visible, enter = Transitions.enter(offset), exit = ExitTransition.None) { content() }
}

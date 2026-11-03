package com.gicek.kakey.android

import com.gicek.kakey.android.ui.main.NavTransitions
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The transition direction depends only on the order of the two pages in the back stack, not on which spec NavDisplay picked. */
class NavTransitionsTest {
    private val stack = listOf("home", "settings", "categories")

    @Test
    fun deeperTargetIsForward() {
        assertTrue(NavTransitions.isForward(stack, fromKey = "home", toKey = "settings"))
        assertTrue(NavTransitions.isForward(stack, fromKey = "settings", toKey = "categories"))
    }

    @Test
    fun shallowerTargetIsBack() {
        assertFalse(NavTransitions.isForward(stack, fromKey = "categories", toKey = "settings"))
        assertFalse(NavTransitions.isForward(stack, fromKey = "settings", toKey = "home"))
    }

    @Test
    fun poppedOriginIsBack() {
        // After a committed back gesture the origin is no longer in the stack; Navigation 3 may still evaluate it with the forward spec
        assertFalse(NavTransitions.isForward(listOf("home"), fromKey = "settings", toKey = "home"))
    }

    @Test
    fun sameSceneAndUnknownTargetCountAsForward() {
        assertTrue(NavTransitions.isForward(stack, fromKey = "home", toKey = "home"))
        assertTrue(NavTransitions.isForward(stack, fromKey = "home", toKey = null))
    }
}

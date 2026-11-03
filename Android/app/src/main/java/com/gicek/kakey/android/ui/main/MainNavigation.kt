package com.gicek.kakey.android.ui.main

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.navigation3.runtime.NavEntry
import androidx.navigation3.ui.NavDisplay
import com.gicek.kakey.android.DemoVault
import com.gicek.kakey.android.core.ParsedOtpAuth
import com.gicek.kakey.android.ui.SecureWindow
import com.gicek.kakey.android.ui.add.AddFlowHost
import com.gicek.kakey.android.ui.add.ManualEntryScreen
import com.gicek.kakey.android.ui.add.ReviewScreen
import com.gicek.kakey.android.ui.add.ScannerScreen
import com.gicek.kakey.android.ui.settings.CategoryManagerScreen
import com.gicek.kakey.android.ui.settings.SettingsScreen

/**
 * Pages after unlock. The review page carries recognition results and isn't restored after process recreation (it falls back
 * to the previous page).
 */
sealed interface Route {
    data object Home : Route
    data object Settings : Route
    data object Categories : Route
    data object Scanner : Route
    data object Manual : Route
    data class Review(val items: List<ParsedOtpAuth>) : Route

    /** Pages in the add flow: scanner, manual entry, review. */
    val inAddFlow: Boolean get() = this is Scanner || this is Manual || this is Review

    /**
     * The NavEntry `contentKey`: Navigation 3 defaults to the string `"$key:${key::class}"`; this uses a stable name under our
     * control so scenes map back to the back stack by it (see [NavTransitions]). Only one page of each kind exists at a time,
     * so it carries no arguments.
     */
    val contentKey: String
        get() = when (this) {
            Home -> "home"
            Settings -> "settings"
            Categories -> "categories"
            Scanner -> "scanner"
            Manual -> "manual"
            is Review -> "review"
        }
}

class Navigator(val backStack: SnapshotStateList<Route>) {
    /** The page just pushed that hasn't played its enter animation yet (see `EnterOnAppear`). */
    private var pendingEnter: Route? = null

    fun push(route: Route) {
        pendingEnter = route
        backStack.add(route)
    }

    /** Whether the page should play its enter animation: true only right after it is pushed, never replayed when returning to it. */
    fun consumeEnter(route: Route): Boolean = (pendingEnter == route).also { if (it) pendingEnter = null }

    fun pop() {
        if (backStack.size > 1) backStack.removeAt(backStack.lastIndex)
    }

    /** Closes the add flow pages (scanner -> review) and returns to the main screen or settings. */
    fun popAddFlow() {
        while (backStack.size > 1 && backStack.last().inAddFlow) pop()
    }
}

val LocalNavigator = staticCompositionLocalOf<Navigator> { error("Navigator not provided") }

private val backStackSaver = listSaver<SnapshotStateList<Route>, String>(
    save = { stack -> stack.mapNotNull { route -> route::class.simpleName.takeIf { route !is Route.Review } } },
    restore = { names ->
        val routes = names.mapNotNull { name ->
            when (name) {
                "Home" -> Route.Home
                "Settings" -> Route.Settings
                "Categories" -> Route.Categories
                "Scanner" -> Route.Scanner
                "Manual" -> Route.Manual
                else -> null
            }
        }
        mutableStateListOf<Route>().apply { addAll(routes.ifEmpty { listOf(Route.Home) }) }
    },
)

/** Main navigation (Navigation 3): the back stack survives recreation such as a language change, and predictive back is supported. */
@Composable
fun MainNavigation() {
    val backStack = rememberSaveable(saver = backStackSaver) {
        // Debug screenshots: open the requested screen directly (DemoVault.screen is always null in Release)
        val demo = when (DemoVault.screen) {
            "settings" -> Route.Settings
            "categories" -> Route.Categories
            "manual" -> Route.Manual
            else -> null
        }
        mutableStateListOf<Route>(Route.Home).apply { demo?.let(::add) }
    }
    val navigator = remember(backStack) { Navigator(backStack) }
    val transitions = rememberNavTransitions(backStack)
    // Block screenshots only while the home screen (including the account detail sheet on top of it) is topmost; settings,
    // scanner, manual add and others can be captured
    SecureWindow(enabled = backStack.lastOrNull() == Route.Home)
    CompositionLocalProvider(LocalNavigator provides navigator) {
        AddFlowHost {
            NavDisplay(
                backStack = backStack,
                onBack = { navigator.pop() },
                transitionSpec = transitions.forward,
                popTransitionSpec = transitions.pop,
                predictivePopTransitionSpec = transitions.predictivePop,
                entryProvider = { route ->
                    NavEntry(route, contentKey = route.contentKey) {
                        EnterOnAppear(route) {
                            when (route) {
                                Route.Home -> HomeScreen()
                                Route.Settings -> SettingsScreen()
                                Route.Categories -> CategoryManagerScreen()
                                Route.Scanner -> ScannerScreen()
                                Route.Manual -> ManualEntryScreen()
                                is Route.Review -> ReviewScreen(route.items)
                            }
                        }
                    }
                },
            )
        }
    }
}

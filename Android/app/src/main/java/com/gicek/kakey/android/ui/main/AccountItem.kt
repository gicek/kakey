package com.gicek.kakey.android.ui.main

import android.view.HapticFeedbackConstants
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.AnimationVector1D
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.LocalIndication
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.awaitTouchSlopOrCancellation
import androidx.compose.foundation.gestures.drag
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.indication
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.PressInteraction
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.FolderOff
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.input.pointer.PointerEventTimeoutCancellationException
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.onLongClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupPositionProvider
import androidx.compose.ui.window.PopupProperties
import com.gicek.kakey.android.R
import com.gicek.kakey.android.core.Account
import com.gicek.kakey.android.core.AccountCategory
import com.gicek.kakey.android.core.Core
import com.gicek.kakey.android.platform.Clipboard
import com.gicek.kakey.android.ui.components.AccountTitle
import com.gicek.kakey.android.ui.components.CodeText
import com.gicek.kakey.android.ui.components.CountdownRing
import com.gicek.kakey.android.ui.components.MonogramBadge
import com.gicek.kakey.android.ui.components.Segmented
import com.gicek.kakey.android.ui.theme.Motion
import java.time.Instant
import kotlin.math.max
import kotlin.math.roundToInt
import kotlinx.coroutines.delay

/** Account item actions, implemented by the main screen. */
@Suppress("LongParameterList") // This is the parameter object that gathers the item's callbacks and context
class AccountActions(
    val showDetail: (Account) -> Unit,
    val delete: (Account) -> Unit,
    val newCategory: (Account) -> Unit,
    val toggleCategory: (Account, AccountCategory) -> Unit,
    val removeFromSection: ((Account) -> Unit)?,
    /** Opens the "Add to" category bottom sheet. */
    val addTo: (Account) -> Unit,
    val sectionCategory: AccountCategory?,
)

/** Tap to copy (clipboard marked sensitive; the system shows its own copy confirmation), with haptic feedback. */
@Composable
fun rememberCopy(): (Account) -> Unit {
    val context = LocalContext.current
    val view = LocalView.current
    return remember(context, view) {
        { account ->
            Clipboard.copySensitive(context, Core.code(account))
            view.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
        }
    }
}

/**
 * Interaction shell shared by rows and cards (one gesture set, matching iPhone / iPad):
 * - Tap copies: pressing shows a Material ripple, and on release the background flashes the accent color once and fades
 *   ([rememberCopyFlash]).
 * - At the long-press timeout (with haptic feedback) the menu pops up at the touch point right away without lifting the
 *   finger: lifting there keeps the menu open; moving past the touch slop instead dismisses the menu and starts drag-to-reorder
 *   (when [reorder] isn't null), with other rows making way live and a single save on release.
 * With [interactive] false there are no gestures or feedback (the floating copy that follows the finger while dragging).
 * [content] receives the gesture modifier for the tappable area and the modifier that draws the flash, and decides its own
 * layout.
 */
@Composable
private fun AccountPressable(
    account: Account,
    actions: AccountActions,
    reorder: ReorderController?,
    interactive: Boolean,
    content: @Composable (pressable: Modifier, flash: Modifier) -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    var copies by remember { mutableIntStateOf(0) }
    val copy = rememberCopy()
    val view = LocalView.current
    val anchor = remember { MenuAnchor() }
    val interactions = remember { MutableInteractionSource() }
    val copyLabel = stringResource(R.string.copy_code_1589)
    val pressable = if (interactive) {
        Modifier
            .semantics(mergeDescendants = true) {
                role = Role.Button
                onClick(label = copyLabel) {
                    copy(account)
                    copies++
                    true
                }
                onLongClick {
                    menu = true
                    true
                }
            }
            .indication(interactions, LocalIndication.current)
            .accountGestures(
                key = account.id,
                interactions = interactions,
                anchor = anchor,
                reorder = reorder,
                haptic = { view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS) },
                onTap = {
                    copy(account)
                    copies++
                },
                onMenu = { menu = true },
                onHideMenu = { menu = false },
            )
    } else {
        Modifier
    }
    val flash = rememberCopyFlash(copies)
    val tint = MaterialTheme.colorScheme.primaryContainer
    content(
        pressable,
        Modifier.drawBehind { if (flash.value > 0f) drawRect(tint, alpha = flash.value) },
    )
    if (interactive) AccountMenu(account, expanded = menu, onDismiss = { menu = false }, actions = actions, anchor = anchor)
}

/**
 * Strength of the post-copy feedback (0–1): the background flashes to the accent color immediately, holds briefly, then fades
 * out once (Expressive, never covering the code). Triggered by a monotonically increasing copy count so recomposition doesn't
 * retrigger it; callers read the value only in the draw phase for alpha, never interpolating from transparent black, so there
 * is no dark-then-light flicker.
 */
@Composable
private fun rememberCopyFlash(copies: Int): Animatable<Float, AnimationVector1D> {
    val flash = remember { Animatable(0f) }
    LaunchedEffect(copies) {
        if (copies == 0) return@LaunchedEffect
        flash.snapTo(1f)
        delay(FLASH_HOLD_MS)
        flash.animateTo(0f, Motion.effects())
    }
    return flash
}

/** Phone list row: badge, names, code and countdown. Tap to copy; long-press for the menu or to drag-reorder. */
@Composable
fun AccountRow(
    account: Account,
    now: Instant,
    actions: AccountActions,
    modifier: Modifier = Modifier,
    /** Long-press then drag to reorder; null when reordering isn't possible right now (while searching). */
    reorder: ReorderController? = null,
    interactive: Boolean = true,
) {
    val remaining = Core.secondsRemaining(account, now)
    Box(modifier) {
        AccountPressable(account, actions, reorder, interactive) { pressable, flash ->
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(14.dp),
                modifier = Modifier.fillMaxWidth().then(flash).then(pressable).padding(horizontal = 16.dp, vertical = 14.dp),
            ) {
                MonogramBadge(account.issuer)
                AccountTitle(account, Modifier.weight(1f))
                CodeText(Core.code(account, now), urgent = remaining <= 5)
                CountdownRing(Core.progress(account, now), remaining)
            }
        }
    }
}

/** Tablet card: badge and names on top, code and countdown below (so names aren't squeezed out even at half-screen width). */
@Composable
fun AccountCard(
    account: Account,
    now: Instant,
    actions: AccountActions,
    modifier: Modifier = Modifier,
    reorder: ReorderController? = null,
    interactive: Boolean = true,
) {
    val remaining = Core.secondsRemaining(account, now)
    Box(modifier) {
        AccountPressable(account, actions, reorder, interactive) { pressable, flash ->
            Column(
                verticalArrangement = Arrangement.spacedBy(14.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .background(Segmented.item, MaterialTheme.shapes.large)
                    .then(flash)
                    .then(pressable)
                    .padding(18.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    MonogramBadge(account.issuer, size = 40.dp)
                    AccountTitle(account, Modifier.weight(1f))
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CodeText(Core.code(account, now), urgent = remaining <= 5)
                    Spacer(Modifier.weight(1f).width(8.dp))
                    CountdownRing(Core.progress(account, now), remaining)
                }
            }
        }
    }
}

/**
 * Where the finger went down (in tappable-area coordinates); the long-press menu pops up from here. Read only while the menu
 * is open, so pressing doesn't recompose the row.
 */
class MenuAnchor {
    var touch by mutableStateOf(Offset.Zero)
}

/**
 * Tap / long-press / long-press-then-drag gestures, with ripples emitted through [interactions]:
 * pressing emits Press; lifting before the long-press timeout is a tap (Release + [onTap]), and moving out or being taken over
 * by scrolling cancels. At the long-press timeout: haptic feedback, release the ripple and call [onMenu] immediately (finger
 * still down); then moving past the touch slop calls [onHideMenu] and starts the drag (consuming events so the list doesn't
 * scroll along), while lifting directly keeps the menu. The menu is a Popup in another window, but the system keeps
 * delivering the rest of this touch to the window where it started, so this item's pointer input is the gesture's only
 * owner; list reordering and the floating item are handled by [ReorderController].
 */
@Suppress("LongParameterList") // The gesture's exit points
private fun Modifier.accountGestures(
    key: Any,
    interactions: MutableInteractionSource,
    anchor: MenuAnchor,
    reorder: ReorderController?,
    haptic: () -> Unit,
    onTap: () -> Unit,
    onMenu: () -> Unit,
    onHideMenu: () -> Unit,
): Modifier = pointerInput(key, reorder) {
    awaitEachGesture {
        val down = awaitFirstDown()
        anchor.touch = down.position
        val press = PressInteraction.Press(down.position)
        interactions.tryEmit(press)
        var longPressed = false
        val up = try {
            withTimeout(viewConfiguration.longPressTimeoutMillis) { waitForUpOrCancellation() }
        } catch (_: PointerEventTimeoutCancellationException) {
            longPressed = true
            null
        }
        if (!longPressed) {
            if (up == null) {
                interactions.tryEmit(PressInteraction.Cancel(press))
            } else {
                up.consume()
                interactions.tryEmit(PressInteraction.Release(press))
                onTap()
            }
            return@awaitEachGesture
        }
        interactions.tryEmit(PressInteraction.Release(press))
        haptic()
        onMenu()
        if (reorder == null) return@awaitEachGesture
        val metrics = autoScrollMetrics()
        val first = awaitTouchSlopOrCancellation(down.id) { change, overSlop ->
            change.consume()
            onHideMenu()
            reorder.start(key, metrics)
            reorder.drag(overSlop)
        }
        // Lifted without moving (or taken over by another gesture): keep the menu
        if (first == null) return@awaitEachGesture
        drag(first.id) { change ->
            // Read the delta before consuming: positionChange() is always zero afterwards
            val delta = change.positionChange()
            change.consume()
            reorder.drag(delta)
        }
        reorder.end()
    }
}

/**
 * Long-press menu: a rounded panel popping up from the touch point. The account itself (badge and names) is on top, followed
 * by "Copy", "Details", "Add to ›" (closes the menu and opens the [AddToCategoriesSheet] bottom sheet), "Remove from “X”" when
 * inside a category, and "Delete" in the error color at the bottom.
 * Placement comes from [TouchMenuPosition]: a corner sits at the touch point, flipping to the other side near edges.
 */
@Composable
private fun AccountMenu(account: Account, expanded: Boolean, onDismiss: () -> Unit, actions: AccountActions, anchor: MenuAnchor) {
    val visible = remember { MutableTransitionState(false) }
    visible.targetState = expanded
    if (!visible.currentState && !visible.targetState) return
    val copy = rememberCopy()
    val density = LocalDensity.current
    val touch = anchor.touch
    val position = remember(touch, density) { TouchMenuPosition(touch, density) }
    Popup(popupPositionProvider = position, onDismissRequest = onDismiss, properties = PopupProperties(focusable = true)) {
        AnimatedVisibility(
            visibleState = visible,
            enter = scaleIn(Motion.effects(), initialScale = MENU_SCALE, transformOrigin = position.origin) + fadeIn(Motion.effects()),
            exit = scaleOut(Motion.effects(), targetScale = MENU_SCALE, transformOrigin = position.origin) + fadeOut(Motion.effects()),
            label = "menu",
        ) {
            Surface(
                shape = MaterialTheme.shapes.large,
                color = MaterialTheme.colorScheme.surfaceContainerHigh,
                shadowElevation = MENU_ELEVATION,
            ) {
                Column(
                    Modifier
                        .widthIn(min = MENU_MIN_WIDTH, max = MENU_MAX_WIDTH)
                        .width(IntrinsicSize.Max)
                        .verticalScroll(rememberScrollState())
                        .padding(vertical = 8.dp),
                ) {
                    MenuItems(account, actions, copy, onDismiss)
                }
            }
        }
    }
}

@Composable
private fun MenuItems(account: Account, actions: AccountActions, copy: (Account) -> Unit, onDismiss: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 8.dp),
    ) {
        MonogramBadge(account.issuer, size = 36.dp)
        AccountTitle(
            account,
            Modifier.weight(1f),
            titleStyle = MaterialTheme.typography.titleSmall,
            subtitleStyle = MaterialTheme.typography.bodySmall,
        )
    }
    DropdownMenuItem(
        text = { Text(stringResource(R.string.copy)) },
        leadingIcon = { Icon(Icons.Outlined.ContentCopy, null) },
        onClick = {
            onDismiss()
            copy(account)
        },
    )
    DropdownMenuItem(
        text = { Text(stringResource(R.string.details)) },
        leadingIcon = { Icon(Icons.Outlined.Info, null) },
        onClick = {
            onDismiss()
            actions.showDetail(account)
        },
    )
    DropdownMenuItem(
        text = { Text(stringResource(R.string.add_to)) },
        leadingIcon = { Icon(Icons.Outlined.Folder, null) },
        trailingIcon = { Icon(Icons.AutoMirrored.Outlined.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant) },
        onClick = {
            onDismiss()
            actions.addTo(account)
        },
    )
    actions.sectionCategory?.let { category ->
        DropdownMenuItem(
            text = { Text(stringResource(R.string.remove_from_x, category.name), maxLines = 1, overflow = TextOverflow.Ellipsis) },
            leadingIcon = { Icon(Icons.Outlined.FolderOff, null) },
            onClick = {
                onDismiss()
                actions.removeFromSection?.invoke(account)
            },
        )
    }
    HorizontalDivider(Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
    DropdownMenuItem(
        text = { Text(stringResource(R.string.delete), color = MaterialTheme.colorScheme.error) },
        leadingIcon = { Icon(Icons.Outlined.Delete, null, tint = MaterialTheme.colorScheme.error) },
        onClick = {
            onDismiss()
            actions.delete(account)
        },
    )
}

/**
 * Menu placement: the top-left corner sits 8dp below-right of the touch point; if it doesn't fit on the right, the top-right
 * corner goes to the left of the touch point; if it doesn't fit below, the bottom-left corner goes above it. When it fits
 * neither above nor below (the menu is taller than the space left), it opens downward from the touch point and is pulled in
 * against the bottom edge, keeping the top edge as close to the touch point as possible.
 * Margins are 48dp vertically (system bars) and 8dp horizontally. The scale animation's origin follows the corner at the touch
 * point ([origin]).
 */
private class TouchMenuPosition(private val touch: Offset, density: Density) : PopupPositionProvider {
    private val gap = with(density) { MENU_GAP.roundToPx() }
    private val sideMargin = with(density) { MENU_SIDE_MARGIN.roundToPx() }
    private val verticalMargin = with(density) { MENU_VERTICAL_MARGIN.roundToPx() }

    var origin by mutableStateOf(TransformOrigin(0f, 0f))
        private set

    override fun calculatePosition(
        anchorBounds: IntRect,
        windowSize: IntSize,
        layoutDirection: LayoutDirection,
        popupContentSize: IntSize,
    ): IntOffset {
        val x0 = anchorBounds.left + touch.x.roundToInt()
        val y0 = anchorBounds.top + touch.y.roundToInt()
        val (x, pivotX) = place(x0, popupContentSize.width, windowSize.width, sideMargin)
        val (y, pivotY) = place(y0, popupContentSize.height, windowSize.height, verticalMargin)
        origin = TransformOrigin(pivotX, pivotY)
        return IntOffset(x, y)
    }

    /**
     * Position and scale origin on one axis: try after the touch point, then before it; failing both, start after it and pull
     * in against the edge.
     */
    private fun place(at: Int, size: Int, window: Int, margin: Int): Pair<Int, Float> = when {
        at + gap + size <= window - margin -> (at + gap) to 0f
        at - gap - size >= margin -> (at - gap - size) to 1f
        else -> (at + gap).coerceIn(margin, max(margin, window - margin - size)) to 0f
    }
}

/** How long the copy flash holds (ms). */
private const val FLASH_HOLD_MS = 120L

/**
 * Long-press menu: width range (too wide on phones would cover most of a row), gap from the touch point, margin from window
 * edges, and initial scale of the pop-up animation.
 */
private val MENU_MIN_WIDTH = 200.dp
private val MENU_MAX_WIDTH = 260.dp
private val MENU_GAP = 8.dp
private val MENU_SIDE_MARGIN = 8.dp
private val MENU_VERTICAL_MARGIN = 48.dp
private const val MENU_SCALE = 0.85f

private val MENU_ELEVATION = 8.dp

package com.gicek.kakey.android.ui.onboarding

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.ripple
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import com.gicek.kakey.android.ui.components.BrandMark
import com.gicek.kakey.android.ui.components.Segmented
import com.gicek.kakey.android.ui.theme.Motion
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

/*
 * Visual components for onboarding (Material 3 Expressive): petal-shaped (cookie) badges and segmented choice cards.
 * There are no enter animations (cards popping in one after another on open felt sluggish); only the shape feedback when a
 * card is pressed remains. Stable Material 3 (1.4) doesn't expose `MaterialShapes` or the Expressive theme yet, so shapes and
 * motion are built here to spec, sharing the same system as [Motion] and [Segmented].
 */

/**
 * Expressive "cookie" shape: a soft petal undulating [lobes] times around the circle; [depth] is the undulation as a fraction
 * of the radius.
 */
private class CookieShape(private val lobes: Int, private val depth: Float) : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection, density: Density): Outline {
        val center = Offset(size.width / 2, size.height / 2)
        val radius = min(size.width, size.height) / 2 / (1 + depth)
        val path = Path()
        for (step in 0..STEPS) {
            val angle = 2 * PI * step / STEPS - PI / 2
            val r = radius * (1 + depth * cos(lobes * angle)).toFloat()
            val point = Offset(center.x + r * cos(angle).toFloat(), center.y + r * sin(angle).toFloat())
            if (step == 0) path.moveTo(point.x, point.y) else path.lineTo(point.x, point.y)
        }
        path.close()
        return Outline.Generic(path)
    }

    private companion object {
        const val STEPS = 240
    }
}

private val HeroShape: Shape = CookieShape(lobes = 9, depth = 0.07f)
private val IconShape: Shape = CookieShape(lobes = 7, depth = 0.09f)

/** Large badge on the welcome page: the brand mark on a petal with a gradient from the primary to the tertiary color. */
@Composable
fun HeroBadge(size: Dp) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(size)
            .background(
                Brush.linearGradient(listOf(MaterialTheme.colorScheme.primaryContainer, MaterialTheme.colorScheme.tertiaryContainer)),
                HeroShape,
            ),
    ) {
        BrandMark(size = size * 0.72f)
    }
}

/** Header for the create and restore pages: a petal icon, a title and one line of description. */
@Composable
fun StepHeader(icon: ImageVector, title: String, detail: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier.size(88.dp).background(MaterialTheme.colorScheme.secondaryContainer, IconShape),
        ) {
            Icon(icon, null, tint = MaterialTheme.colorScheme.onSecondaryContainer, modifier = Modifier.size(40.dp))
        }
        Text(title, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
        Text(
            detail,
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
    }
}

/**
 * One option on the welcome page (same structure as iOS's ChoiceCard): a tinted icon, title and description, and a trailing
 * chevron. Laid out as a segmented card; when pressed, the small corners next to the other card open into large corners
 * (Expressive shape feedback).
 */
@Composable
fun ChoiceRow(
    icon: ImageVector,
    title: String,
    detail: String,
    index: Int,
    count: Int,
    iconContainer: Color,
    iconContent: Color,
    onClick: () -> Unit,
) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val outer = 28.dp
    val inner by animateDpAsState(if (pressed) outer else 8.dp, Motion.fastSpatial(), label = "corner")
    val shape = RoundedCornerShape(
        topStart = if (index == 0) outer else inner,
        topEnd = if (index == 0) outer else inner,
        bottomStart = if (index == count - 1) outer else inner,
        bottomEnd = if (index == count - 1) outer else inner,
    )
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(Segmented.item)
            .clickable(interactionSource = interaction, indication = ripple(), role = Role.Button, onClick = onClick)
            .padding(horizontal = 18.dp, vertical = 18.dp),
    ) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier.size(48.dp).background(iconContainer, RoundedCornerShape(16.dp)),
        ) {
            Icon(icon, null, tint = iconContent, modifier = Modifier.size(26.dp))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text(detail, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Icon(Icons.AutoMirrored.Outlined.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/**
 * A vertical group of choice cards, each as tall as the tallest one, so wrapped description text doesn't leave the cards
 * uneven. Height is the maximum intrinsic height of the cards at the current width, with content vertically centered inside
 * (the Row in [ChoiceRow] is already center-aligned).
 */
@Composable
fun EqualHeightColumn(gap: Dp, content: @Composable () -> Unit) {
    Layout(content) { measurables, constraints ->
        val width = constraints.maxWidth
        val height = measurables.maxOfOrNull { it.maxIntrinsicHeight(width) } ?: 0
        val fixed = Constraints.fixed(width, height)
        val placeables = measurables.map { it.measure(fixed) }
        val spacing = gap.roundToPx()
        val total = placeables.size * height + (placeables.size - 1).coerceAtLeast(0) * spacing
        layout(width, total) {
            placeables.forEachIndexed { index, placeable -> placeable.place(0, index * (height + spacing)) }
        }
    }
}

/**
 * Restore failure card: an error-colored container with a warning icon and explanation, optionally with an action button
 * at the bottom right (e.g. "Choose Folder" when no backup was found), so the error and its action read as one unit.
 */
@Composable
fun NoticeCard(text: String, actionLabel: String? = null, onAction: () -> Unit = {}) {
    Column(
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(24.dp))
            .background(MaterialTheme.colorScheme.errorContainer)
            .padding(start = 20.dp, end = 12.dp, top = 16.dp, bottom = if (actionLabel == null) 16.dp else 8.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.padding(end = 8.dp)) {
            Icon(Icons.Outlined.ErrorOutline, null, tint = MaterialTheme.colorScheme.onErrorContainer, modifier = Modifier.size(22.dp))
            Text(text, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onErrorContainer)
        }
        if (actionLabel != null) {
            TextButton(onClick = onAction, modifier = Modifier.align(Alignment.End)) {
                Text(actionLabel, color = MaterialTheme.colorScheme.onErrorContainer, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

/**
 * White card with large corners that lifts a group of fields or switches off the page background (same color as the segmented
 * cards in settings).
 */
@Composable
fun FormCard(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Box(modifier.fillMaxWidth().clip(RoundedCornerShape(28.dp)).background(Segmented.item).padding(16.dp)) { content() }
}

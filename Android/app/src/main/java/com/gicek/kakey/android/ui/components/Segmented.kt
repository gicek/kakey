package com.gicek.kakey.android.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * Segmented list (Material 3 Expressive / Android 16 system settings style): each row in a group is its own rounded
 * container, with large top corners on the first row, large bottom corners on the last and small corners in between, and a
 * 2dp gap between rows, so the group reads as one segmented card.
 */
object Segmented {
    val Gap = 2.dp
    private val outer = 24.dp
    private val inner = 6.dp

    fun shape(index: Int, count: Int): Shape = RoundedCornerShape(
        topStart = if (index == 0) outer else inner,
        topEnd = if (index == 0) outer else inner,
        bottomStart = if (index == count - 1) outer else inner,
        bottomEnd = if (index == count - 1) outer else inner,
    )

    /**
     * Horizontally connected button group (Expressive connected button group): large left corners on the first, large right
     * corners on the last, small corners where they meet. Shared by "Show Secret / Export QR Code" on the detail page and
     * [ConnectedChoice].
     */
    fun connectedShape(index: Int, count: Int, outer: Dp, inner: Dp): Shape = RoundedCornerShape(
        topStart = if (index == 0) outer else inner,
        bottomStart = if (index == 0) outer else inner,
        topEnd = if (index == count - 1) outer else inner,
        bottomEnd = if (index == count - 1) outer else inner,
    )

    /** Page background: group containers need to sit on it to stand out. */
    val background: Color
        @Composable @ReadOnlyComposable
        get() = MaterialTheme.colorScheme.surfaceContainer

    /** Background of each row in a group. */
    val item: Color
        @Composable @ReadOnlyComposable
        get() = MaterialTheme.colorScheme.surfaceBright
}

/**
 * Connected single-choice button group (the app's only segmented single-choice style; Material's SegmentedButton is not used):
 * pill-shaped ends, small corners where segments meet, 2dp gaps; the selected segment is filled (primary color) and the rest
 * use a tonal background. Segments have equal width, and text is a single line with ellipsis.
 */
@Composable
fun <T> ConnectedChoice(
    options: List<T>,
    selected: T,
    onSelect: (T) -> Unit,
    modifier: Modifier = Modifier,
    label: @Composable (T) -> String,
) {
    Row(horizontalArrangement = Arrangement.spacedBy(Segmented.Gap), modifier = modifier.fillMaxWidth()) {
        options.forEachIndexed { index, option ->
            ConnectedSegment(
                text = label(option),
                selected = option == selected,
                shape = Segmented.connectedShape(index, options.size, outer = 20.dp, inner = 6.dp),
                onClick = { onSelect(option) },
            )
        }
    }
}

@Composable
private fun RowScope.ConnectedSegment(text: String, selected: Boolean, shape: Shape, onClick: () -> Unit) {
    val modifier = Modifier.weight(1f).height(48.dp).semantics { this.selected = selected }
    val padding = PaddingValues(horizontal = 12.dp)
    val content: @Composable RowScope.() -> Unit = { Text(text, maxLines = 1, overflow = TextOverflow.Ellipsis) }
    if (selected) {
        Button(onClick = onClick, shape = shape, contentPadding = padding, modifier = modifier, content = content)
    } else {
        FilledTonalButton(onClick = onClick, shape = shape, contentPadding = padding, modifier = modifier, content = content)
    }
}

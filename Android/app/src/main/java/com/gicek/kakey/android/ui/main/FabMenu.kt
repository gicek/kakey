package com.gicek.kakey.android.ui.main

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.FileOpen
import androidx.compose.material.icons.outlined.Keyboard
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material.icons.outlined.QrCodeScanner
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.gicek.kakey.android.R
import com.gicek.kakey.android.ui.add.LocalAddFlow
import com.gicek.kakey.android.ui.theme.Motion

/**
 * The "Add" floating action button menu (Material 3 Expressive FAB Menu style; the component isn't public in stable Material 3
 * 1.4, so it's built here to spec): when opened, the button morphs from a rounded square to a circle and the plus turns into a
 * cross, four pill buttons for the add methods pop up above it, and a light scrim appears behind.
 * Tapping the scrim, going back or picking any option closes it. Motion uses the theme's spring curves.
 */
@Composable
fun AddFabMenu(expanded: Boolean, onExpandedChange: (Boolean) -> Unit, modifier: Modifier = Modifier) {
    val flow = LocalAddFlow.current
    BackHandler(enabled = expanded) { onExpandedChange(false) }

    val scrim by animateColorAsState(
        if (expanded) MaterialTheme.colorScheme.scrim.copy(alpha = 0.32f) else Color.Transparent,
        Motion.effects(),
        label = "scrim",
    )
    if (expanded || scrim.alpha > 0f) {
        Box(
            Modifier
                .fillMaxSize()
                .background(scrim)
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, enabled = expanded) {
                    onExpandedChange(false)
                },
        )
    }

    fun choose(action: () -> Unit) {
        onExpandedChange(false)
        action()
    }
    val items = listOf(
        Triple(Icons.Outlined.QrCodeScanner, R.string.scan_qr_code, flow.scan),
        Triple(Icons.Outlined.PhotoLibrary, R.string.choose_from_photos, flow.pickPhotos),
        Triple(Icons.Outlined.Keyboard, R.string.enter_setup_key, flow.enterKey),
        Triple(Icons.Outlined.FileOpen, R.string.import_backup_file, flow.importFile),
    )

    Column(
        horizontalAlignment = Alignment.End,
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = modifier.navigationBarsPadding().padding(16.dp),
    ) {
        items.forEachIndexed { index, (icon, label, action) ->
            AnimatedVisibility(
                visible = expanded,
                // Pop up from bottom to top: the farther from the button, the later it appears
                enter =
                    scaleIn(
                        Motion.fastSpatial(),
                        initialScale = 0.6f,
                        transformOrigin = androidx.compose.ui.graphics.TransformOrigin(1f, 1f),
                    ) +
                        fadeIn(Motion.fastEffects()),
                exit =
                    scaleOut(
                        Motion.fastSpatial(),
                        targetScale = 0.6f,
                        transformOrigin = androidx.compose.ui.graphics.TransformOrigin(1f, 1f),
                    ) +
                        fadeOut(Motion.fastEffects()),
                label = "item$index",
            ) {
                MenuItem(icon, stringResource(label)) { choose(action) }
            }
        }
        val corner by animateDpAsState(if (expanded) 28.dp else 16.dp, Motion.spatial(), label = "corner")
        val rotation by animateFloatAsState(if (expanded) 45f else 0f, Motion.spatial(), label = "rotation")
        val container by animateColorAsState(
            if (expanded) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.primaryContainer,
            Motion.effects(),
            label = "container",
        )
        val content by animateColorAsState(
            if (expanded) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onPrimaryContainer,
            Motion.effects(),
            label = "content",
        )
        Surface(
            onClick = { onExpandedChange(!expanded) },
            shape = RoundedCornerShape(corner),
            color = container,
            contentColor = content,
            shadowElevation = 6.dp,
            modifier = Modifier.size(56.dp),
        ) {
            Box(contentAlignment = Alignment.Center) {
                Icon(
                    Icons.Outlined.Add,
                    contentDescription = stringResource(if (expanded) R.string.close else R.string.add_account),
                    modifier = Modifier.rotate(rotation),
                )
            }
        }
    }
}

@Composable
private fun MenuItem(icon: ImageVector, label: String, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        shape = CircleShape,
        color = MaterialTheme.colorScheme.primaryContainer,
        contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
        shadowElevation = 3.dp,
        modifier = Modifier.height(56.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.padding(start = 20.dp, end = 24.dp),
        ) {
            Icon(icon, contentDescription = null)
            Text(label, style = MaterialTheme.typography.titleMedium)
        }
    }
}

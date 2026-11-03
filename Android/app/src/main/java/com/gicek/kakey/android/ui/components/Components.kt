package com.gicek.kakey.android.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.gicek.kakey.android.R
import com.gicek.kakey.android.core.Account
import com.gicek.kakey.android.core.Core
import com.gicek.kakey.android.ui.theme.CodeFontFamily
import com.gicek.kakey.android.ui.theme.MonogramPalette
import com.gicek.kakey.android.ui.theme.extended
import com.gicek.kakey.core.CorePasswordStrength
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import kotlinx.coroutines.delay

/**
 * The current time, refreshed on each whole second: codes and countdown rings update with it without recomposing the whole
 * list every second.
 */
@Composable
fun rememberNow(): Instant {
    var now by remember { mutableStateOf(Instant.now()) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(1_000 - System.currentTimeMillis() % 1_000)
            now = Instant.now()
        }
    }
    return now
}

/** Date and time in the current language and system time zone (added date on the detail page, backup history). */
@Composable
fun Instant.formatted(): String {
    // Read via LocalConfiguration so a language change recomposes (Android Lint LocalContextConfigurationRead)
    val locale = LocalConfiguration.current.locales[0]
    return DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)
        .withLocale(locale)
        .format(atZone(ZoneId.systemDefault()))
}

/**
 * Service and account names on two lines (shared by list rows, cards, long-press menus and the detail page), each truncated to
 * one line.
 */
@Composable
fun AccountTitle(
    account: Account,
    modifier: Modifier = Modifier,
    titleStyle: TextStyle = MaterialTheme.typography.titleMedium,
    subtitleStyle: TextStyle = MaterialTheme.typography.bodyMedium,
) {
    Column(modifier) {
        Text(account.issuer, style = titleStyle, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(
            account.username,
            style = subtitleStyle,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/**
 * Round icon on a tinted background at the start of a settings row (Android 16 system settings style); destructive actions use
 * the error color.
 */
@Composable
fun IconTile(icon: ImageVector, modifier: Modifier = Modifier, destructive: Boolean = false) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .size(40.dp)
            .background(
                if (destructive) MaterialTheme.colorScheme.errorContainer else MaterialTheme.colorScheme.secondaryContainer,
                CircleShape,
            ),
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = if (destructive) MaterialTheme.colorScheme.onErrorContainer else MaterialTheme.colorScheme.onSecondaryContainer,
            modifier = Modifier.size(22.dp),
        )
    }
}

/** The app's brand mark (lock shield on a transparent background), used on the lock screen and onboarding. */
@Composable
fun BrandMark(size: Dp, modifier: Modifier = Modifier) {
    Image(
        painter = painterResource(R.mipmap.ic_launcher_foreground),
        contentDescription = null,
        modifier = modifier.size(size),
    )
}

/** Brand badge on the lock and welcome screens: the logo on a soft accent-colored circle (Expressive's large size and strong hierarchy). */
@Composable
fun BrandBadge(size: Dp, modifier: Modifier = Modifier) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .size(size)
            .background(
                Brush.linearGradient(listOf(MaterialTheme.colorScheme.primaryContainer, MaterialTheme.colorScheme.tertiaryContainer)),
                androidx.compose.foundation.shape.CircleShape,
            ),
    ) {
        BrandMark(size = size * 0.78f)
    }
}

/** Service initial badge: the color comes from the core by issuer, consistent across platforms. */
@Composable
fun MonogramBadge(issuer: String, size: Dp = 42.dp) {
    val color = MonogramPalette[Core.paletteIndex(issuer) % MonogramPalette.size]
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(size)
            .background(
                Brush.verticalGradient(listOf(color.copy(alpha = 0.85f), color)),
                RoundedCornerShape(size * 0.28f),
            ),
    ) {
        Text(
            text = Core.monogram(issuer),
            color = Color.White,
            fontWeight = FontWeight.SemiBold,
            fontSize = (size.value * 0.34f).sp,
            maxLines = 1,
        )
    }
}

/** Ring showing the time left in the current period, switching to the warning color in the last 5 seconds. */
@Composable
fun CountdownRing(progress: Float, secondsRemaining: Int, size: Dp = 26.dp) {
    val urgent = secondsRemaining <= 5
    val urgentColor = MaterialTheme.extended.urgent
    val accent = if (urgent) urgentColor else MaterialTheme.colorScheme.primary
    val track = MaterialTheme.colorScheme.outlineVariant
    // No reverse animation when the period rolls over (progress jumps from near 1 back to 0)
    val animated by animateFloatAsState(progress, animationSpec = tween(if (progress < 0.05f) 0 else 900), label = "ring")
    val description = stringResource(R.string.refreshes_in_x_s, secondsRemaining)
    Box(contentAlignment = Alignment.Center, modifier = Modifier.size(size).semantics { contentDescription = description }) {
        Canvas(Modifier.size(size)) {
            val stroke = 2.5.dp.toPx()
            drawArc(track, 0f, 360f, false, style = Stroke(stroke))
            drawArc(accent, -90f, 360f * animated, false, style = Stroke(stroke, cap = StrokeCap.Round))
        }
        Text(
            "$secondsRemaining",
            fontSize = (size.value * 0.4f).sp,
            fontWeight = FontWeight.SemiBold,
            color = if (urgent) urgentColor else MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** Large monospace verification code (Atkinson Hyperlegible Mono) with a gap in the middle by digit count; always one line. */
@Composable
fun CodeText(code: String, urgent: Boolean, modifier: Modifier = Modifier, fontSize: TextUnit = 24.sp) {
    val spoken = code.toList().joinToString(" ")
    Text(
        text = Core.formatted(code),
        style = TextStyle(fontFamily = CodeFontFamily, fontWeight = FontWeight.SemiBold, fontSize = fontSize, letterSpacing = 0.5.sp),
        color = if (urgent) MaterialTheme.extended.urgent else MaterialTheme.colorScheme.onSurface,
        maxLines = 1,
        softWrap = false,
        overflow = TextOverflow.Visible,
        modifier = modifier.semantics { contentDescription = spoken },
    )
}

/** Master password strength bar and hint (rules in core `password.rs`). */
@Composable
fun PasswordStrengthBar(password: String, modifier: Modifier = Modifier) {
    val (filled, color) = when (Core.evaluatePassword(password)) {
        CorePasswordStrength.EMPTY -> 0 to MaterialTheme.colorScheme.error
        CorePasswordStrength.WEAK -> 1 to MaterialTheme.colorScheme.error
        CorePasswordStrength.FAIR -> 2 to MaterialTheme.extended.urgent
        CorePasswordStrength.GOOD -> 3 to MaterialTheme.extended.success
        CorePasswordStrength.STRONG -> 4 to MaterialTheme.extended.success
    }
    val track = MaterialTheme.colorScheme.surfaceContainerHighest
    Row(horizontalArrangement = Arrangement.spacedBy(4.dp), modifier = modifier) {
        for (index in 1..4) {
            val segment by animateColorAsState(if (index <= filled) color else track, tween(200), label = "strength")
            Box(
                Modifier
                    .weight(1f)
                    .height(4.dp)
                    .background(segment, CircleShape),
            )
        }
    }
}

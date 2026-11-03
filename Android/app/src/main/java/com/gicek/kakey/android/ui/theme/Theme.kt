package com.gicek.kakey.android.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.gicek.kakey.android.R
import com.gicek.kakey.android.domain.AppearanceMode

/**
 * Material 3 theme tuned for the Expressive style: dynamic color from the system on Android 12+ (always available with
 * minSdk 33), light / dark following the system or the user's setting, a rounder shape scale, and spring motion in [Motion].
 * Colors are read only through `MaterialTheme.colorScheme`.
 */
@Composable
fun KakeyTheme(appearance: AppearanceMode, content: @Composable () -> Unit) {
    val dark = when (appearance) {
        AppearanceMode.SYSTEM -> isSystemInDarkTheme()
        AppearanceMode.LIGHT -> false
        AppearanceMode.DARK -> true
    }
    val context = LocalContext.current
    CompositionLocalProvider(LocalExtendedColors provides if (dark) DarkExtendedColors else LightExtendedColors) {
        MaterialTheme(
            colorScheme = if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context),
            shapes = KakeyShapes,
            content = content,
        )
    }
}

/**
 * Two semantic colors beyond the Material scheme (dynamic color has no "warning" or "success"): the warning orange for the
 * last 5 seconds and the green for password strength. Uses the light / dark values of Apple's system colors, brighter in dark
 * appearance to keep contrast.
 */
@Immutable
data class ExtendedColors(val urgent: Color, val success: Color)

private val LightExtendedColors = ExtendedColors(urgent = Color(0xFFFF9500), success = Color(0xFF34C759))
private val DarkExtendedColors = ExtendedColors(urgent = Color(0xFFFF9F0A), success = Color(0xFF30D158))

val LocalExtendedColors = staticCompositionLocalOf { LightExtendedColors }

val MaterialTheme.extended: ExtendedColors
    @Composable @ReadOnlyComposable
    get() = LocalExtendedColors.current

/** A rounder-than-default shape scale (Expressive): 24dp for cards, 32dp for sheets and large containers. */
val KakeyShapes = Shapes(
    extraSmall = RoundedCornerShape(8.dp),
    small = RoundedCornerShape(12.dp),
    medium = RoundedCornerShape(16.dp),
    large = RoundedCornerShape(24.dp),
    extraLarge = RoundedCornerShape(32.dp),
)

/**
 * Verification code font: Atkinson Hyperlegible Mono bundled with the app (the same variable font file as on Apple), using
 * semibold on the weight axis. Used only for the codes themselves.
 */
val CodeFontFamily = FontFamily(
    Font(
        R.font.atkinson_hyperlegible_mono,
        weight = FontWeight.SemiBold,
        variationSettings = FontVariation.Settings(FontVariation.weight(600)),
    ),
)

/** Colors for service initial badges, indexed by the core, using the same set of system colors as Apple. */
val MonogramPalette = listOf(
    Color(0xFF007AFF), // blue
    Color(0xFFAF52DE), // purple
    Color(0xFFFF9500), // orange
    Color(0xFF34C759), // green
    Color(0xFF5856D6), // indigo
    Color(0xFFFF2D55), // pink
    Color(0xFF30B0C7), // teal
    Color(0xFFA2845E), // brown
)

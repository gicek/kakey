package com.gicek.kakey.android.core

import android.content.Context
import androidx.annotation.PluralsRes
import androidx.annotation.StringRes
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext

/**
 * Text to show the user: state stores only resource IDs and arguments, resolved in the current language at display time
 * (so a language change never leaves stale text). Verbatim text from the system or elsewhere (e.g. system error messages)
 * uses [Raw].
 */
sealed interface UiText {
    data class Res(@param:StringRes val id: Int, val args: List<Any>) : UiText {
        constructor(@StringRes id: Int, vararg args: Any) : this(id, args.toList())
    }

    data class Plural(@param:PluralsRes val id: Int, val count: Int, val args: List<Any>) : UiText {
        constructor(@PluralsRes id: Int, count: Int) : this(id, count, listOf(count))
    }

    data class Raw(val text: String) : UiText

    // getString / getQuantityString only have vararg overloads; with one or two arguments the spread cost is negligible
    @Suppress("SpreadOperator")
    fun resolve(context: Context): String = when (this) {
        is Res -> context.getString(id, *args.map { it.resolved(context) }.toTypedArray())
        is Plural -> context.resources.getQuantityString(id, count, *args.map { it.resolved(context) }.toTypedArray())
        is Raw -> text
    }

    private fun Any.resolved(context: Context): Any = if (this is UiText) resolve(context) else this
}

@Composable
fun UiText.text(): String = resolve(LocalContext.current)

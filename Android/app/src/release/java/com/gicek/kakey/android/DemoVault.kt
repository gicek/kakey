package com.gicek.kakey.android

import android.content.Intent

/**
 * In Release the demo vault entry point is empty: it ignores all launch extras, so release builds contain no demo data and
 * no path that skips `FLAG_SECURE` (see docs/SECURITY.md). The real implementation is in `src/debug`.
 */
object DemoVault {
    val screen: String? get() = null

    @Suppress("UNUSED_PARAMETER", "FunctionOnlyReturningConstant") // Empty implementation: Release never enters demo mode
    fun start(app: KakeyApplication, intent: Intent): Boolean = false

    fun clearScreen() = Unit
}

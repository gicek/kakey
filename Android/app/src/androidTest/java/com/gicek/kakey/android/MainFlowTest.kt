package com.gicek.kakey.android

import android.content.ClipDescription
import android.content.ClipboardManager
import android.os.ParcelFileDescriptor
import androidx.annotation.StringRes
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isToggleable
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextInput
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.gicek.kakey.android.core.Account
import com.gicek.kakey.android.core.Core
import com.gicek.kakey.android.domain.Phase
import com.gicek.kakey.android.platform.Biometrics
import com.gicek.kakey.core.CoreTotpAlgorithm
import java.time.Instant
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The main UI flows of the real app, driven through the Compose semantics tree without the demo vault: onboarding creates
 * a vault -> empty list -> add an account by entering the secret manually -> a 6-digit verification code appears in the row
 * -> tap to copy (clipboard marked sensitive) -> lock -> wrong password error -> unlock with the right password -> Settings
 * -> reset back to onboarding.
 *
 * Every test starts from a wiped sandbox ([AppSandbox]). All text is looked up from the app's resources in its current
 * language, so the device language does not affect matching. Waiting uses only waitUntil with a timeout, never sleep;
 * Argon2id vault creation and unlock take several seconds on a real device. Buttons on scrollable screens get
 * `performScrollTo()` first: with the soft keyboard up the button may sit underneath it, and a plain click would hit the keyboard.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class MainFlowTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    private lateinit var scenario: ActivityScenario<MainActivity>
    private val app get() = AppSandbox.app

    /** The device's autofill service before the test, restored afterwards. */
    private var autofillService: String? = null

    @Before
    fun launchFromEmptySandbox() {
        // Typing the master password triggers a password manager's (e.g. Bitwarden) "Save password?" system dialog. Once it
        // takes window focus the app process cannot read the clipboard and the copy test waits until it times out, so the
        // autofill service is turned off during the test and restored afterwards.
        autofillService = shell("settings get secure autofill_service").trim().takeUnless { it.isEmpty() || it == "null" }
        shell("settings put secure autofill_service null")
        AppSandbox.reset()
        scenario = ActivityScenario.launch(MainActivity::class.java)
    }

    @After
    fun leaveSandboxEmpty() {
        scenario.close()
        AppSandbox.reset()
        shell("settings put secure autofill_service ${autofillService ?: "null"}")
    }

    @Test
    fun createVaultAddAccountAndCopyCode() {
        createVault()
        compose.onNodeWithText(string(R.string.no_2fa_accounts_yet)).assertExists()
        addAccount()

        val shown = displayedCode()
        assertTrue("Displayed verification code should have 6 digits: $shown", shown.matches(Regex("\\d{6}")))
        val now = Instant.now()
        val expected = listOf(now, now.minusSeconds(PERIOD), now.plusSeconds(PERIOD)).map { Core.code(account(), it) }
        assertTrue("Code $shown should match one of the adjacent periods computed by the core $expected", shown in expected)

        compose.onNodeWithText(ISSUER).performClick()
        compose.waitUntil(TIMEOUT) { clipboardText() != null }
        val clip = app.getSystemService(ClipboardManager::class.java).primaryClip!!
        val copied = clip.getItemAt(0).text.toString()
        // A period boundary may pass between the tap and the read; the copied code is the one shown before or after the tap
        assertTrue("Clipboard $copied should be the code shown in the row", copied == shown || copied == displayedCode())
        assertTrue("Clipboard should be marked sensitive", clip.description.extras?.getBoolean(ClipDescription.EXTRA_IS_SENSITIVE) == true)
    }

    @Test
    fun lockThenUnlockWithWrongAndRightPassword() {
        createVault()
        addAccount()

        compose.onNodeWithContentDescription(string(R.string.more)).performClick()
        compose.onNodeWithText(string(R.string.lock_now)).performClick()
        compose.waitUntilExactlyOneExists(hasText(string(R.string.kakey_is_locked)), TIMEOUT)
        assertEquals(Phase.LOCKED, app.store.state.value.phase)

        val field = string(R.string.enter_password_5705)
        compose.onNodeWithText(field).performTextInput("not-the-password-1")
        compose.onNodeWithText(string(R.string.unlock)).performScrollTo().performClick()
        compose.waitUntilExactlyOneExists(hasText(string(R.string.err_vault_invalid_password)), TIMEOUT)
        assertEquals(Phase.LOCKED, app.store.state.value.phase)

        compose.onNodeWithText(field).performTextClearance()
        compose.onNodeWithText(field).performTextInput(PASSWORD)
        compose.onNodeWithText(string(R.string.unlock)).performScrollTo().performClick()
        compose.waitUntilExactlyOneExists(hasText(ISSUER), TIMEOUT)
        assertEquals(Phase.UNLOCKED, app.store.state.value.phase)
    }

    @Test
    fun resetAppReturnsToOnboarding() {
        createVault()
        addAccount()
        openSettings()

        scrollSettingsTo(string(R.string.reset_app))
        compose.onNodeWithText(string(R.string.reset_app)).performClick()
        compose.waitUntilExactlyOneExists(hasText(string(R.string.reset_kakey)), TIMEOUT)
        compose.onNodeWithText(string(R.string.erase_local_data)).performClick()

        if (Biometrics.canVerifyOwner(app)) {
            // On a device with a screen lock or biometrics, confirming first shows owner verification (SystemUI's
            // BiometricPrompt window or the screen lock credential page). With face unlock enrolled it may pass right away
            // while the owner looks at the screen (the UI then returns to onboarding). Otherwise the test cannot act as the
            // owner: press Back to cancel, check that nothing was reset without verification, then call the same reset path
            // Settings uses after successful verification.
            compose.waitUntil(TIMEOUT) { app.store.state.value.phase == Phase.ONBOARDING || ownerVerificationShowing() }
            if (app.store.state.value.phase != Phase.ONBOARDING) {
                shell("input keyevent KEYCODE_BACK")
                compose.waitUntil(TIMEOUT) { !ownerVerificationShowing() }
                compose.waitUntilExactlyOneExists(hasText(string(R.string.reset_app)), TIMEOUT)
                assertEquals(Phase.UNLOCKED, app.store.state.value.phase)
                assertTrue("Vault should still exist after canceling owner verification", vaultFile().exists())
                runBlocking { app.store.resetApplication() }
            }
        }

        compose.waitUntilExactlyOneExists(hasText(string(R.string.protect_your_2fa_with_kakey)), TIMEOUT)
        assertEquals(Phase.ONBOARDING, app.store.state.value.phase)
        assertFalse("Local vault file should be deleted after reset", vaultFile().exists())
    }

    // --- Steps ---

    /**
     * Onboarding -> "Start fresh" -> set the master password (turning off the biometrics toggle if present, so the lock
     * screen does not prompt for system verification automatically) -> empty list.
     */
    private fun createVault() {
        compose.waitUntilExactlyOneExists(hasText(string(R.string.protect_your_2fa_with_kakey)), TIMEOUT)
        compose.onNodeWithText(string(R.string.start_fresh)).performClick()
        compose.waitUntilExactlyOneExists(hasText(string(R.string.new_password)), TIMEOUT)
        compose.onNodeWithText(string(R.string.new_password)).performTextInput(PASSWORD)
        compose.onNodeWithText(string(R.string.enter_again)).performTextInput(PASSWORD)
        compose.onAllNodes(isToggleable()).fetchSemanticsNodes().forEach { node ->
            if (node.config.getOrNull(SemanticsProperties.ToggleableState)?.name == "On") {
                compose.onNode(isToggleable()).performClick()
            }
        }
        compose.onNodeWithText(string(R.string.create_vault)).performScrollTo().assertIsEnabled().performClick()
        compose.waitUntilExactlyOneExists(hasText(string(R.string.no_2fa_accounts_yet)), TIMEOUT)
        assertEquals(Phase.UNLOCKED, app.store.state.value.phase)
    }

    /**
     * "Enter Setup Key" on the empty list -> switch to "Manual Entry" -> fill in the service, account name and a known Base32
     * secret -> save -> the row appears in the list.
     */
    private fun addAccount() {
        compose.onNodeWithText(string(R.string.enter_setup_key)).performClick()
        // The screen opens on "Paste otpauth"; switch to manual entry first
        compose.waitUntilExactlyOneExists(hasText(string(R.string.manual_entry)), TIMEOUT)
        compose.onNodeWithText(string(R.string.manual_entry)).performClick()
        compose.waitUntilExactlyOneExists(hasText(string(R.string.service_name)), TIMEOUT)
        compose.onNodeWithText(string(R.string.service_name)).performTextInput(ISSUER)
        compose.onNodeWithText(string(R.string.account_name_or_email)).performTextInput(USERNAME)
        compose.onNodeWithText(string(R.string.secret)).performTextInput(SECRET)
        compose.onNodeWithText(string(R.string.save)).assertIsEnabled().performClick()
        compose.waitUntilExactlyOneExists(hasText(ISSUER), TIMEOUT)
        compose.waitUntilAtLeastOneExists(sixDigitCode, TIMEOUT)
    }

    private fun openSettings() {
        compose.onNodeWithContentDescription(string(R.string.more)).performClick()
        compose.onNodeWithText(string(R.string.settings)).performClick()
        compose.waitUntilExactlyOneExists(hasText(string(R.string.security)), TIMEOUT)
    }

    /**
     * The verification code in the row. `CodeText`'s accessibility description reads digit by digit ("1 2 3 4 5 6"), so it
     * is read from the unmerged semantics tree.
     */
    private fun displayedCode(): String {
        val node = compose.onAllNodes(sixDigitCode, useUnmergedTree = true).fetchSemanticsNodes().first()
        return node.config[SemanticsProperties.ContentDescription].first { it.matches(SPOKEN_CODE) }.replace(" ", "")
    }

    private val sixDigitCode = SemanticsMatcher("6-digit code") { node ->
        node.config.getOrNull(SemanticsProperties.ContentDescription)?.any { it.matches(SPOKEN_CODE) } == true
    }

    /**
     * Settings is a LazyColumn (the only node with CollectionInfo on the screen); rows near the bottom are not in the
     * semantics tree until scrolled into view, so scroll to them before clicking.
     */
    private fun scrollSettingsTo(text: String) {
        compose.onNode(
            hasScrollAction() and SemanticsMatcher.keyIsDefined(SemanticsProperties.CollectionInfo),
        ).performScrollToNode(hasText(text))
    }

    /**
     * Whether the system owner verification window (BiometricPrompt) or the screen lock credential page is showing. The Compose
     * semantics tree cannot see system windows, so this asks the window manager.
     */
    private fun ownerVerificationShowing(): Boolean =
        shell("dumpsys window windows").lineSequence().any { "BiometricPrompt" in it || "ConfirmDeviceCredential" in it }

    private fun shell(command: String): String =
        ParcelFileDescriptor.AutoCloseInputStream(InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(command))
            .bufferedReader().use { it.readText() }

    private fun vaultFile() = app.filesDir.resolve("Kakey/vault.json")

    private fun clipboardText(): String? =
        app.getSystemService(ClipboardManager::class.java).primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString()

    private fun account() =
        Account("TEST", ISSUER, USERNAME, SECRET, CoreTotpAlgorithm.SHA1, 6, PERIOD.toInt(), Instant.now(), Account.PROVENANCE_MANUAL)

    private fun string(@StringRes id: Int): String = app.getString(id)

    private companion object {
        const val TIMEOUT = 60_000L
        const val PASSWORD = "Correct-Horse-Battery-9"
        const val ISSUER = "Example"
        const val USERNAME = "alice@example.com"
        const val SECRET = "JBSWY3DPEHPK3PXP"
        const val PERIOD = 30L
        val SPOKEN_CODE = Regex("\\d( \\d){5}")
    }
}

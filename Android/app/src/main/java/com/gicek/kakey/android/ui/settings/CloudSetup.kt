package com.gicek.kakey.android.ui.settings

import android.content.ActivityNotFoundException
import android.content.Intent
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.CreateNewFolder
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.LockOpen
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Shield
import androidx.compose.material.icons.outlined.Star
import androidx.compose.material.icons.outlined.TurnLeft
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.RadioButton
import androidx.compose.material3.SheetValue
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import com.gicek.kakey.android.R
import com.gicek.kakey.android.core.UiText
import com.gicek.kakey.android.core.text
import com.gicek.kakey.android.domain.CloudCertificateException
import com.gicek.kakey.android.domain.CloudProvider
import com.gicek.kakey.android.domain.CloudSetup
import com.gicek.kakey.android.domain.CloudSyncException
import com.gicek.kakey.android.domain.DropboxAppAuthenticator
import com.gicek.kakey.android.domain.InMemoryCloudConnectionStore
import com.gicek.kakey.android.domain.NextcloudLoginWake
import com.gicek.kakey.android.domain.ServerTrustDecision
import com.gicek.kakey.android.domain.SyncLocation
import com.gicek.kakey.android.domain.WebAuthenticator
import com.gicek.kakey.android.domain.awaitNextcloudLogin
import com.gicek.kakey.android.platform.CustomTabAuthenticator
import com.gicek.kakey.android.platform.OfficialDropboxAppAuthenticator
import com.gicek.kakey.android.ui.components.BrandMark
import com.gicek.kakey.android.ui.components.KakeyTextField
import com.gicek.kakey.android.ui.components.PasswordField
import com.gicek.kakey.android.ui.components.Segmented
import com.gicek.kakey.android.ui.theme.extended
import com.gicek.kakey.core.CoreCloudAccess
import com.gicek.kakey.core.CoreCloudEntry
import com.gicek.kakey.core.CoreNextcloudLogin
import com.gicek.kakey.core.coreCloudCompleteAddress
import com.gicek.kakey.core.coreCloudFolderHasBackup
import com.gicek.kakey.core.coreCloudIsUsableFolder
import java.io.IOException
import javax.net.ssl.SSLException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Backup location list (docs/TECHNICAL.md): the cloud storage available in this build, ending with "Other Folder" (SAF).
 * Only "Other Folder" has a description; the others show just their names (same as Apple). Shared by settings and first-run
 * restore. With [segmented] true each row is a segment of a segmented card (onboarding, on a [Segmented.background]
 * background); otherwise rows are plain list rows (the location dialog in settings).
 * Only first-run restore passes [onExportFile]: a "Kakey Exported File" row is added below "Other Folder" that opens the file
 * picker directly (SAF folder and file picking are separate entry points, and two rows save a step over a menu).
 */
@Composable
fun SyncLocationOptions(
    current: SyncLocation?,
    onFolder: () -> Unit,
    onCloud: (CloudProvider) -> Unit,
    segmented: Boolean = false,
    onExportFile: (() -> Unit)? = null,
) {
    val count = CloudProvider.available.size + if (onExportFile == null) 1 else 2
    Column(verticalArrangement = Arrangement.spacedBy(if (segmented) Segmented.Gap else 0.dp)) {
        CloudProvider.available.forEachIndexed { index, provider ->
            val shape = if (segmented) Segmented.shape(index, count) else null
            OptionRow(provider.displayName, null, provider, (current as? SyncLocation.Cloud)?.provider == provider, shape) {
                onCloud(provider)
            }
        }
        OptionRow(
            stringResource(R.string.other_folder),
            // Android has no iCloud Drive
            stringResource(R.string.a_folder_on_this_device_or),
            null,
            current is SyncLocation.Folder,
            if (segmented) Segmented.shape(CloudProvider.available.size, count) else null,
            onClick = onFolder,
        )
        if (onExportFile != null) {
            OptionRow(
                stringResource(R.string.kakey_exported_file),
                null,
                null,
                false,
                if (segmented) Segmented.shape(count - 1, count) else null,
                Icons.Filled.Description,
                onExportFile,
            )
        }
    }
}

@Composable
@Suppress("LongParameterList")
private fun OptionRow(
    title: String,
    subtitle: String?,
    provider: CloudProvider?,
    isCurrent: Boolean,
    shape: Shape?,
    symbol: ImageVector? = null,
    onClick: () -> Unit,
) {
    ListItem(
        headlineContent = { Text(title) },
        supportingContent = subtitle?.let { { Text(it) } },
        leadingContent = { SyncLocationIcon(provider, tint = MaterialTheme.colorScheme.onSurface, symbol = symbol) },
        trailingContent = {
            if (isCurrent) {
                Icon(Icons.Outlined.Check, null, tint = MaterialTheme.colorScheme.primary)
            } else if (shape != null) {
                Icon(Icons.AutoMirrored.Outlined.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        },
        colors = if (shape != null) ListItemDefaults.colors(containerColor = Segmented.item) else ListItemDefaults.colors(),
        // Segmented card rows are 72dp tall: single-line titles don't look cramped, and the height is close to the "Other
        // Folder" row with its description
        modifier = (if (shape != null) Modifier.clip(shape).heightIn(min = 72.dp) else Modifier).clickableRow(onClick = onClick),
    )
}

/**
 * Whether the connection is for backup (setting up or changing the location) or first-run restore (matching Apple's
 * `CloudSetupModel.Purpose`): the title, description, third step and folder picking rules differ. Restore is read-only: no
 * recommended folder, no folder creation, and only folders with an existing backup can be chosen.
 */
enum class CloudSetupPurpose { BACKUP, RESTORE }

/**
 * The form filled in for a WebDAV / Nextcloud connection (matching Apple's `CloudSetupModel.FormInput`): kept in memory with
 * the authorization during first-run restore and prefilled when the service is chosen again, so a reused connection that
 * falls back to the form after a transient network or server error needn't be retyped. Cleartext HTTP confirmation and the
 * trusted certificate are carried along.
 */
class CloudForm(
    val address: String,
    val username: String,
    val password: String,
    val insecureConfirmed: Boolean,
    val trustedCertificate: ByteArray?,
)

/**
 * Opens the connection page with a connection authorized during first-run restore: [anotherFolder] is true for "Choose Folder"
 * after no backup was found, otherwise it's choosing an already authorized service again (the connection lives only in
 * memory, held by onboarding). [form] is the form filled in for that connection (null for OAuth), used to prefill.
 */
class CloudResume(val location: SyncLocation.Cloud, val connection: ByteArray, val anotherFolder: Boolean, val form: CloudForm? = null)

/** Step state for connecting cloud storage (Compose state; network runs on IO); the same flow as Apple's `CloudSetupModel`. */
private class CloudSetupState(
    val provider: CloudProvider,
    val purpose: CloudSetupPurpose,
    private val setup: CloudSetup,
    private val authenticator: WebAuthenticator,
    private val dropboxApp: DropboxAppAuthenticator,
    /**
     * Called on getting a connection and entering folder picking: during first-run restore the authorization is remembered as
     * soon as it arrives, without waiting for a folder with a backup to be chosen. The third argument is the form filled in for
     * this connection; null when reusing an existing connection or for OAuth.
     */
    private val onConnected: ((SyncLocation.Cloud, ByteArray, CloudForm?) -> Unit)?,
) {
    enum class Step { FORM, WAITING, CHOOSE_FOLDER }

    /**
     * OAuth connection progress: sign in and authorize -> connect account -> check backup. The three-step description doubles as
     * progress items: after the browser returns it takes a few seconds to finish (token exchange, folder listing, link check),
     * so every step must be visible. Matches Apple's `CloudSetupModel.ConnectPhase`.
     */
    enum class ConnectPhase { SIGNING_IN, CONNECTING, CHECKING_BACKUP }

    /** OAuth access scope: app folder only by default; changeable only when a full-drive key is configured. */
    var access by mutableStateOf(CoreCloudAccess.APP_FOLDER)
    val offersFullAccess: Boolean = provider.fullAccessAvailable
    var oauthJob: Job? = null

    var address by mutableStateOf("")
    var username by mutableStateOf("")
    var password by mutableStateOf("")
    var step by mutableStateOf(Step.FORM)
    var loginUrl by mutableStateOf<String?>(null)
    var isWorking by mutableStateOf(false)

    /** The current OAuth step; null before starting or after returning to the form. */
    var phase by mutableStateOf<ConnectPhase?>(null)
    var error by mutableStateOf<UiText?>(null)
    var needsInsecureConfirmation by mutableStateOf(false)
    var insecureConfirmed = false

    /**
     * The system rejects the server certificate: the leaf certificate fingerprint for the user to check; once confirmed,
     * reconnect with it and trust only this certificate from then on.
     */
    var untrustedCertificate by mutableStateOf<ByteArray?>(null)
    var trustedCertificate: ByteArray? = null
    var currentPath by mutableStateOf("")
    var folders by mutableStateOf<List<CoreCloudEntry>>(emptyList())

    /**
     * Whether the current folder can be the backup folder: empty (ignoring hidden files) or already holding a Kakey backup;
     * rules live in the core.
     */
    var canUseCurrentFolder by mutableStateOf(false)

    /** The current folder holds a Kakey backup (rules in the core); restore can only choose such folders. */
    var currentFolderHasBackup by mutableStateOf(false)

    /**
     * The folder holds only the backup and no subfolders: the folder page shows "Backup found" in the middle instead of a
     * single row (same on all platforms).
     */
    val currentFolderHasOnlyBackup: Boolean get() = currentFolderHasBackup && folders.isEmpty()

    /**
     * Whether the folder page's done button is enabled: backup needs an empty folder or an existing backup; restore needs an
     * existing backup.
     */
    val canFinish: Boolean get() = if (purpose == CloudSetupPurpose.RESTORE) currentFolderHasBackup else canUseCurrentFolder

    /**
     * Why the current folder can't be chosen for backup; null when it can, or when restoring (the disabled primary button is
     * enough there).
     */
    val folderHint: Int?
        get() = if (purpose == CloudSetupPurpose.BACKUP && !canFinish) R.string.choose_an_empty_folder_or_one else null

    /** Connection blob after sign-in (in memory); tokens refreshed while browsing folders are written back here too. */
    val connections = InMemoryCloudConnectionStore()
    var pollJob: Job? = null

    /**
     * The form at the start of Nextcloud sign-in, handed to [onConnected] (without the password) when authorization completes
     * and folder picking begins.
     */
    private var pollForm: CloudForm? = null

    /**
     * The immediate authorization check after returning to the app is running: the waiting page shows "Finishing sign-in"
     * (same as Apple).
     */
    var isCheckingSignIn by mutableStateOf(false)

    /** Wakes a pending Nextcloud authorization to check immediately when returning to the app. */
    val wake = NextcloudLoginWake { isCheckingSignIn = it }

    val canSubmit: Boolean
        get() = !isWorking &&
            when (provider) {
                CloudProvider.DROPBOX, CloudProvider.ONEDRIVE, CloudProvider.GOOGLE_DRIVE -> true
                CloudProvider.NEXTCLOUD -> address.isNotBlank()
                CloudProvider.WEBDAV -> address.isNotBlank() && username.isNotBlank() && password.isNotEmpty()
            }

    /** The address with a scheme filled in (rules in the core): without `scheme://`, IPs get `http://` and domain names `https://`. */
    private val completedAddress: String get() = coreCloudCompleteAddress(address)

    /** The completed address is cleartext HTTP: confirmation is needed even when only an IP was entered. */
    private val addressIsInsecure: Boolean get() = completedAddress.lowercase().startsWith("http://")

    /**
     * Returns the Nextcloud sign-in page URL (the caller opens the browser and starts polling); WebDAV goes straight to folder
     * picking after validation.
     */
    suspend fun submit(): CoreNextcloudLogin? {
        error = null
        if (addressIsInsecure && !insecureConfirmed) {
            needsInsecureConfirmation = true
            return null
        }
        return working {
            val url = completedAddress
            when (provider) {
                CloudProvider.WEBDAV -> {
                    val created = io { setup.webDavConnection(url, username.trim(), password, insecureConfirmed, trustedCertificate) }
                    val form = formInput()
                    password = ""
                    enterFolderStep(created, form = form)
                    null
                }
                CloudProvider.NEXTCLOUD -> {
                    val (login, poll) = io { setup.beginNextcloudLogin(url, insecureConfirmed, trustedCertificate) }
                    loginUrl = login
                    step = Step.WAITING
                    pollForm = formInput()
                    poll
                }
                CloudProvider.DROPBOX, CloudProvider.ONEDRIVE, CloudProvider.GOOGLE_DRIVE -> null
            }
        }
    }

    /**
     * OAuth sign-in (Dropbox, OneDrive, Google Drive): browser sign-in -> the core validates the redirect and exchanges it for a token. With
     * app folder access, uses its root directly and returns the result; if it unexpectedly holds other files, falls back to
     * folder picking, with the same rules as other backends. With full-drive access, goes to folder picking. If the user gives
     * up, the coroutine is canceled and the form returns.
     */
    suspend fun signIn(): Pair<SyncLocation.Cloud, ByteArray>? {
        error = null
        phase = ConnectPhase.SIGNING_IN
        isWorking = true
        val created = try {
            val session = io { setup.beginOAuth(provider, access) }
            // Prefer authorizing Dropbox through the official app: launch it when a correctly signed app is installed,
            // otherwise fall back to the browser
            val appResult = session.dropboxAppRequest()?.let { request ->
                dropboxApp.authenticate(request) { session.acceptsDropboxApp(it) }
            }
            if (appResult != null) {
                phase = ConnectPhase.CONNECTING
                io { setup.completeDropboxApp(session, appResult) }
            } else {
                val callback = authenticator.authenticate(session.url()) { session.accepts(it) }
                phase = ConnectPhase.CONNECTING
                io { setup.completeOAuth(session, callback) }
            }
        } catch (cancel: CancellationException) {
            phase = null
            isWorking = false
            throw cancel
        } catch (failure: Exception) {
            error = describe(failure)
            phase = null
            isWorking = false
            return null
        }
        isWorking = false
        if (access == CoreCloudAccess.FULL) {
            phase = null
            enterFolderStep(created)
            return null
        }
        connections.save(created)
        load("")
        if (error != null) {
            phase = null
            return null
        }
        if (canUseCurrentFolder) return finish()
        phase = null
        step = Step.CHOOSE_FOLDER
        return null
    }

    /**
     * Hands the result to the caller to enable (link check + first sync, or first-run restore). Shows "checking backup" and
     * disables actions meanwhile; error text returned by the caller stays on this page.
     */
    suspend fun complete(result: Pair<SyncLocation.Cloud, ByteArray>, onFinish: suspend (SyncLocation.Cloud, ByteArray) -> UiText?) {
        error = null
        if (provider.usesOAuth) phase = ConnectPhase.CHECKING_BACKUP
        isWorking = true
        val failure = try {
            onFinish(result.first, result.second)
        } finally {
            isWorking = false
        }
        if (failure != null) {
            error = failure
            phase = null
        }
    }

    /**
     * Waits for Nextcloud authorization in the browser (polling rules in [CloudSetup.awaitNextcloudLogin]); returns to the
     * form on failure or timeout.
     */
    suspend fun poll(login: CoreNextcloudLogin) {
        val created = try {
            setup.awaitNextcloudLogin(login, POLL_ATTEMPTS, POLL_INTERVAL_MILLIS, wake)
        } catch (cancel: CancellationException) {
            isCheckingSignIn = false
            throw cancel
        } catch (failure: Exception) {
            error = describe(failure)
            step = Step.FORM
            return
        }
        if (created != null) {
            enterFolderStep(created, form = pollForm)
            isCheckingSignIn = false
        } else {
            error = UiText.Res(R.string.sign_in_timed_out_try_again)
            step = Step.FORM
        }
    }

    suspend fun load(path: String) {
        working {
            val entries = io { setup.entries(path, connections) }
            folders = entries.filter { it.isDir }
            canUseCurrentFolder = coreCloudIsUsableFolder(entries.map { it.name })
            currentFolderHasBackup = coreCloudFolderHasBackup(entries.map { it.name })
            currentPath = path
        }
    }

    suspend fun createFolder(name: String) {
        val trimmed = name.trim().takeIf { it.isNotEmpty() } ?: return
        val path = if (currentPath.isEmpty()) trimmed else "$currentPath/$trimmed"
        if (working { io { setup.createFolder(path, connections) } } != null) load(path)
    }

    /**
     * Recommended folder: Kakey under the current folder (used directly if the current folder is Kakey, created if missing).
     * It's created under the current folder rather than jumping back to the root because many servers (e.g. Synology) don't
     * allow creating folders at the root. On failure, stays put and shows the reason.
     */
    suspend fun useDefaultFolder(): Pair<SyncLocation.Cloud, ByteArray>? {
        error = null
        if (currentPath.substringAfterLast('/') != DEFAULT_FOLDER) {
            val existing = folders.firstOrNull { it.name == DEFAULT_FOLDER }
            if (existing != null) load(existing.path) else createFolder(DEFAULT_FOLDER)
        }
        return if (error == null && currentPath.substringAfterLast('/') == DEFAULT_FOLDER) finish() else null
    }

    fun finish(): Pair<SyncLocation.Cloud, ByteArray>? {
        val current = connections.load() ?: return null
        if (!canUseCurrentFolder) {
            error = UiText.Res(R.string.choose_an_empty_folder_or_one)
            return null
        }
        return runCatching { setup.location(current, currentPath) to current }.getOrElse {
            error = describe(it)
            null
        }
    }

    /**
     * Opens with a connection authorized during first-run restore (see [CloudResume]). "Choose Folder" after no backup was
     * found: a connection with a chosen folder starts picking from the original folder's parent; one authorized only for the
     * app folder preselects "Any Folder" and waits on the form for the user to sign in again. Choosing an authorized service
     * again: goes straight to the previous folder (the app folder's root) without signing in; if the connection has expired or
     * there's a transient network or server error, returns to the form with the reason, prefilled with the previous input, and
     * the new connection replaces the old one after reconnecting.
     */
    suspend fun reopen(resume: CloudResume) {
        resume.form?.let(::prefill)
        val location = resume.location
        if (resume.anotherFolder && location.isAppFolder) {
            access = CoreCloudAccess.FULL
            return
        }
        access = if (location.isAppFolder) CoreCloudAccess.APP_FOLDER else CoreCloudAccess.FULL
        enterFolderStep(resume.connection, if (resume.anotherFolder) location.folder.substringBeforeLast('/', "") else location.folder)
        if (!resume.anotherFolder && error != null) backToForm()
    }

    fun backToForm() {
        pollJob?.cancel()
        oauthJob?.cancel()
        connections.remove()
        folders = emptyList()
        currentPath = ""
        phase = null
        step = Step.FORM
    }

    private fun formInput() = CloudForm(address, username, password, insecureConfirmed, trustedCertificate)

    private fun prefill(form: CloudForm) {
        address = form.address
        username = form.username
        password = form.password
        insecureConfirmed = form.insecureConfirmed
        trustedCertificate = form.trustedCertificate
    }

    private suspend fun enterFolderStep(created: ByteArray, path: String = "", form: CloudForm? = null) {
        connections.save(created)
        onConnected?.let { notify -> runCatching { setup.location(created, path) }.getOrNull()?.let { notify(it, created, form) } }
        // Sign-in progress ends here: the close button must work while picking folders (same as Apple)
        phase = null
        step = Step.CHOOSE_FOLDER
        load(path)
    }

    private suspend fun <T> working(body: suspend () -> T): T? {
        isWorking = true
        return try {
            body().also { error = null }
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (untrusted: CloudCertificateException.Untrusted) {
            // Not an error: ask the user to check the fingerprint and decide whether to trust it
            untrustedCertificate = untrusted.fingerprint
            null
        } catch (failure: Exception) {
            error = describe(failure)
            null
        } finally {
            isWorking = false
        }
    }

    private suspend fun <T> io(body: () -> T): T = withContext(Dispatchers.IO) { body() }

    companion object {
        const val DEFAULT_FOLDER = "Kakey"
        const val POLL_INTERVAL_MILLIS = 2_000L

        /** Wait at most 10 minutes. */
        const val POLL_ATTEMPTS = 300

        fun describe(failure: Throwable): UiText = when (failure) {
            is CloudSyncException -> failure.text
            // A changed certificate gets no one-tap trust: it may be a man-in-the-middle, so the user must re-check on
            // the connection page
            is CloudCertificateException.Changed -> UiText.Res(R.string.the_servers_certificate_has_changed_set)
            is CloudCertificateException.Untrusted -> UiText.Res(R.string.the_servers_certificate_cant_be_verified)
            is SSLException -> UiText.Res(R.string.the_servers_certificate_isnt_trusted)
            is IOException -> UiText.Res(R.string.cant_reach_the_server_check_the)
            else -> UiText.Res(R.string.sync_failed)
        }
    }
}

/**
 * One run of connecting cloud storage: fill in the form (choose the access scope for OAuth) -> browser sign-in -> choose the
 * remote folder (skipped for OAuth app folder access). On completion the location and connection blob go to [onFinish], and
 * the caller decides whether to enable backup or do a first-run restore; error text it returns (e.g. the local key can't
 * open the remote backup) stays on this page, and null lets the caller close it.
 *
 * Both first-run restore and changing the location in settings use the [CloudSetupSheet] bottom sheet: the title row has only
 * the title and close, and each step's single action button sits at the bottom (sign in / connect while filling in, cancel
 * while signing in, open browser again while waiting, done while picking a folder), not repeated in the body.
 */
private class CloudSetupHost(
    val state: CloudSetupState,
    val finishLabel: String,
    val submit: () -> Unit,
    val openBrowser: (String) -> Unit,
    val finish: () -> Unit,
    val useDefaultFolder: () -> Unit,
)

@Composable
private fun rememberCloudSetupHost(
    provider: CloudProvider,
    setup: CloudSetup,
    finishLabel: String,
    purpose: CloudSetupPurpose,
    resume: CloudResume?,
    saved: ((CoreCloudAccess) -> CloudResume?)?,
    onConnected: ((SyncLocation.Cloud, ByteArray, CloudForm?) -> Unit)?,
    onFinish: suspend (SyncLocation.Cloud, ByteArray) -> UiText?,
): CloudSetupHost {
    val context = LocalContext.current
    val state = remember(provider) {
        CloudSetupState(provider, purpose, setup, CustomTabAuthenticator(context), OfficialDropboxAppAuthenticator(context), onConnected)
    }
    val scope = rememberCoroutineScope()
    // "Choose Folder" after restore found no backup: open with the original location and connection and switch folders directly
    LaunchedEffect(Unit) { resume?.let { state.reopen(it) } }
    DisposableEffect(Unit) {
        onDispose {
            state.pollJob?.cancel()
            state.oauthJob?.cancel()
        }
    }

    fun openBrowser(url: String) {
        try {
            context.startActivity(Intent(Intent.ACTION_VIEW, url.toUri()))
        } catch (_: ActivityNotFoundException) {
            state.error = UiText.Raw(url)
        }
    }

    fun submit() {
        if (provider.usesOAuth) {
            // The chosen access scope was already authorized during first-run restore, so don't sign in again: app folder access
            // looks for the backup directly as on first sign-in without listing folders (that list looks much like the "Any
            // Folder" one and is easy to confuse); "Any Folder" goes to the previous folder
            saved?.invoke(state.access)?.let { existing ->
                state.oauthJob = scope.launch {
                    if (existing.location.isAppFolder) {
                        state.complete(existing.location to existing.connection, onFinish)
                    } else {
                        state.reopen(existing)
                    }
                }
                return
            }
            state.oauthJob = scope.launch {
                state.signIn()?.let { state.complete(it, onFinish) }
            }
            return
        }
        scope.launch {
            val login = state.submit() ?: return@launch
            state.loginUrl?.let(::openBrowser)
            state.pollJob = scope.launch { state.poll(login) }
        }
    }

    return CloudSetupHost(
        state = state,
        finishLabel = finishLabel,
        submit = ::submit,
        openBrowser = ::openBrowser,
        finish = { state.finish()?.let { scope.launch { state.complete(it, onFinish) } } },
        useDefaultFolder = { scope.launch { state.useDefaultFolder()?.let { state.complete(it, onFinish) } } },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CloudSetupSheet(
    provider: CloudProvider,
    setup: CloudSetup,
    finishLabel: String,
    onDismiss: () -> Unit,
    purpose: CloudSetupPurpose = CloudSetupPurpose.BACKUP,
    resume: CloudResume? = null,
    saved: ((CoreCloudAccess) -> CloudResume?)? = null,
    onConnected: ((SyncLocation.Cloud, ByteArray, CloudForm?) -> Unit)? = null,
    onFinish: suspend (SyncLocation.Cloud, ByteArray) -> UiText?,
) {
    val host = rememberCloudSetupHost(provider, setup, finishLabel, purpose, resume, saved, onConnected, onFinish)
    val state = host.state
    // Check once immediately on returning from browser authorization instead of waiting for the next poll
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        if (state.step == CloudSetupState.Step.WAITING) state.wake.request()
    }
    // Once the browser has returned, the sheet can't be swiped down or dismissed via the scrim
    val blocked by rememberUpdatedState(state.isLeavingBlocked)
    val sheetState =
        rememberModalBottomSheetState(skipPartiallyExpanded = true, confirmValueChange = { it != SheetValue.Hidden || !blocked })
    // When picking folders, match iOS: if the list isn't at the top the sheet doesn't follow the drag and only the list
    // scrolls; pulling down further once back at the top dismisses the sheet
    val folderList = rememberLazyListState()
    val listAtTop by remember { derivedStateOf { folderList.firstVisibleItemIndex == 0 && folderList.firstVisibleItemScrollOffset == 0 } }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        // Don't cover the status bar when expanded to the top on edge-to-edge screens
        modifier = Modifier.statusBarsPadding().padding(top = 12.dp),
        sheetState = sheetState,
        sheetGesturesEnabled = state.step != CloudSetupState.Step.CHOOSE_FOLDER || listAtTop,
        containerColor = Segmented.background,
    ) {
        Column(Modifier.imePadding()) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().padding(start = 24.dp, end = 8.dp),
            ) {
                Text(state.title(), style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
                CloseButton(state, onDismiss)
            }
            Column(Modifier.weight(1f, fill = false)) { CloudSetupBody(host, folderList) }
            BottomAction(host)
        }
    }
    InsecureConfirmation(host)
    CertificateConfirmation(host)
}

/**
 * Once the browser has returned (token exchange, backup check), the user can't leave midway; while the sign-in page is still
 * open, closing this page abandons it.
 */
private val CloudSetupState.isLeavingBlocked: Boolean
    get() = phase.let { it != null && it != CloudSetupState.ConnectPhase.SIGNING_IN }

@Composable
private fun CloudSetupState.title(): String = stringResource(
    if (purpose == CloudSetupPurpose.RESTORE) R.string.restore_from_x else R.string.connect_to_x,
    provider.displayName,
)

/**
 * Close button on the right of the title row: closes the whole flow at every step, including while waiting for browser
 * authorization (a back arrow to the form in the close position would look like a broken icon, and iOS swipes down to close
 * here too). Closing cancels the sheet's coroutines, which stops polling.
 */
@Composable
private fun CloseButton(state: CloudSetupState, onDismiss: () -> Unit) {
    IconButton(enabled = !state.isLeavingBlocked, onClick = onDismiss) {
        Icon(Icons.Outlined.Close, stringResource(R.string.close))
    }
}

/**
 * The single action button at the bottom of the sheet: sign in / connect while filling in (with a spinner while running),
 * cancel while the OAuth sign-in page is open, open the browser again while waiting for authorization, and done while picking
 * a folder. After the browser returns (token exchange, backup check) progress is drawn in the three-step description, and the
 * button spins and is disabled.
 */
@Composable
private fun BottomAction(host: CloudSetupHost) {
    val state = host.state
    val modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 12.dp).height(52.dp)
    when {
        state.step == CloudSetupState.Step.WAITING ->
            OutlinedButton(onClick = { state.loginUrl?.let(host.openBrowser) }, modifier = modifier) {
                Text(stringResource(R.string.open_browser_again))
            }
        state.phase == CloudSetupState.ConnectPhase.SIGNING_IN ->
            OutlinedButton(onClick = state::backToForm, modifier = modifier) { Text(stringResource(R.string.cancel)) }
        state.step == CloudSetupState.Step.FORM ->
            Button(onClick = host.submit, enabled = state.canSubmit && state.phase == null, modifier = modifier) {
                if (state.isWorking) {
                    CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                } else {
                    Text(stringResource(state.provider.submitLabel))
                }
            }
        else -> Button(onClick = host.finish, enabled = state.canFinish && !state.isWorking, modifier = modifier) {
            if (state.isWorking && state.phase != null) {
                CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
            } else {
                Text(host.finishLabel)
            }
        }
    }
}

@Composable
private fun CloudSetupBody(host: CloudSetupHost, folderList: LazyListState) {
    val state = host.state
    when (state.step) {
        CloudSetupState.Step.FORM ->
            if (state.provider.usesOAuth) OAuthForm(state) else SetupForm(state)
        CloudSetupState.Step.WAITING -> Waiting(state.isCheckingSignIn)
        CloudSetupState.Step.CHOOSE_FOLDER -> FolderBrowser(state, folderList, host.useDefaultFolder)
    }
    state.error?.let {
        Text(
            it.text(),
            color = MaterialTheme.colorScheme.error,
            modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp),
        )
    }
}

@Composable
private fun InsecureConfirmation(host: CloudSetupHost) {
    val state = host.state
    if (!state.needsInsecureConfirmation) return
    AlertDialog(
        onDismissRequest = { state.needsInsecureConfirmation = false },
        icon = { Icon(Icons.Outlined.LockOpen, null) },
        title = { Text(stringResource(R.string.unencrypted_connection)) },
        text = { Text(stringResource(R.string.your_password_is_sent_over_http)) },
        confirmButton = {
            TextButton(onClick = {
                state.insecureConfirmed = true
                state.needsInsecureConfirmation = false
                host.submit()
            }) { Text(stringResource(R.string.use_unencrypted_connection), color = MaterialTheme.colorScheme.error) }
        },
        dismissButton = { TextButton(onClick = { state.needsInsecureConfirmation = false }) { Text(stringResource(R.string.cancel)) } },
    )
}

/**
 * The system rejects the certificate: shows the fingerprint for the user to check; once confirmed, only this certificate
 * is trusted.
 */
@Composable
private fun CertificateConfirmation(host: CloudSetupHost) {
    val state = host.state
    val fingerprint = state.untrustedCertificate ?: return
    AlertDialog(
        onDismissRequest = { state.untrustedCertificate = null },
        title = { Text(stringResource(R.string.the_servers_certificate_cant_be_verified)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(stringResource(R.string.continue_only_if_this_fingerprint_matches))
                Text(stringResource(R.string.sha_256_fingerprint), style = MaterialTheme.typography.labelLarge)
                SelectionContainer {
                    Text(
                        ServerTrustDecision.formatted(fingerprint),
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace,
                    )
                }
            }
        },
        confirmButton = {
            TextButton(onClick = {
                state.trustedCertificate = fingerprint
                state.untrustedCertificate = null
                host.submit()
            }) { Text(stringResource(R.string.trust_this_certificate), color = MaterialTheme.colorScheme.error) }
        },
        dismissButton = { TextButton(onClick = { state.untrustedCertificate = null }) { Text(stringResource(R.string.cancel)) } },
    )
}

@Composable
private fun SetupForm(state: CloudSetupState) {
    // WebDAV / Nextcloud (same structure as OAuth): pairing illustration -> form. Fields have labels and no placeholders; the
    // address format is described under the address field
    Column(
        Modifier.padding(horizontal = 24.dp, vertical = 12.dp).verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        PairingHeader(state)
        Spacer(Modifier.height(4.dp))
        // The app-wide text field ([KakeyTextField]); the password field has show / hide
        // The placeholder hints that the scheme can be omitted: an IP alone gets http://, a domain https://
        KakeyTextField(
            placeholder = "https://", // i18n-guard: allow scheme names are not translated
            value = state.address,
            onValueChange = {
                state.address = it
                // A changed address needs cleartext HTTP and the server certificate to be confirmed again
                state.insecureConfirmed = false
                state.trustedCertificate = null
            },
            label = stringResource(R.string.server_address),
            supportingText = stringResource(
                if (state.provider == CloudProvider.WEBDAV) {
                    R.string.the_webdav_address_of_the_folder
                } else {
                    R.string.for_example_https_cloud_example_com
                },
            ),
            enabled = !state.isWorking,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false),
        )
        if (state.provider == CloudProvider.WEBDAV) {
            KakeyTextField(
                value = state.username,
                onValueChange = { state.username = it },
                label = stringResource(R.string.username),
                enabled = !state.isWorking,
                keyboardOptions = KeyboardOptions(autoCorrectEnabled = false),
            )
            PasswordField(
                value = state.password,
                onValueChange = { state.password = it },
                label = stringResource(R.string.password),
                enabled = !state.isWorking,
            )
        }
    }
}

/**
 * OAuth (same structure as Apple): pairing illustration (Kakey ↔ provider) -> access scope -> three-step description. After
 * tapping "Sign In" the three steps become progress; sign in and cancel are at the bottom of the sheet ([BottomAction]).
 * The access scope can be chosen only when a full-drive key is configured.
 */
@Composable
private fun OAuthForm(state: CloudSetupState) {
    Column(
        Modifier.padding(horizontal = 24.dp, vertical = 12.dp).verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        PairingHeader(state)
        // Access scope as a segmented card: two connected segments, the selected one with an accent background and bold title;
        // a single commitment card when only the app folder is available
        if (state.offersFullAccess) {
            val options = listOf(CoreCloudAccess.APP_FOLDER, CoreCloudAccess.FULL)
            Column(Modifier.selectableGroup(), verticalArrangement = Arrangement.spacedBy(Segmented.Gap)) {
                options.forEachIndexed { index, access ->
                    val selected = state.access == access
                    ListItem(
                        headlineContent = {
                            Text(stringResource(access.title), fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal)
                        },
                        supportingContent = { Text(accessDetail(access, state.provider)) },
                        leadingContent = { RadioButton(selected = selected, onClick = null) },
                        colors = ListItemDefaults.colors(
                            containerColor = if (selected) MaterialTheme.colorScheme.secondaryContainer else Segmented.item,
                        ),
                        modifier = Modifier
                            .clip(Segmented.shape(index, options.size))
                            .selectable(selected = selected, enabled = state.phase == null, role = Role.RadioButton) {
                                state.access = access
                            },
                    )
                }
            }
        } else {
            ListItem(
                headlineContent = { Text(stringResource(R.string.kakey_folder_only), fontWeight = FontWeight.SemiBold) },
                supportingContent = { Text(accessDetail(CoreCloudAccess.APP_FOLDER, state.provider)) },
                leadingContent = { Icon(Icons.Outlined.Shield, null, tint = MaterialTheme.colorScheme.primary) },
                colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.secondaryContainer),
                modifier = Modifier.clip(RoundedCornerShape(24.dp)),
            )
        }
        ConnectSteps(state)
    }
}

/**
 * Pairing illustration of Kakey and the provider: a locked link between the two icons (only the encrypted vault is
 * transferred), with the sign-in method and a description below: backup says only the encrypted vault is stored, restore
 * says only the encrypted backup is read.
 */
@Composable
private fun PairingHeader(state: CloudSetupState) {
    val provider = state.provider
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.clearAndSetSemantics {},
        ) {
            Surface(color = MaterialTheme.colorScheme.surfaceContainerHigh, shape = MaterialTheme.shapes.large) {
                BrandMark(56.dp)
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                LinkDash()
                Surface(color = MaterialTheme.colorScheme.surfaceContainerHighest, shape = CircleShape) {
                    Icon(
                        Icons.Filled.Lock,
                        null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(5.dp).size(12.dp),
                    )
                }
                LinkDash()
            }
            SyncLocationIcon(
                provider,
                size = 56.dp,
                shape = MaterialTheme.shapes.large,
                container = MaterialTheme.colorScheme.surfaceContainerHigh,
            )
        }
        Text(
            stringResource(if (provider == CloudProvider.WEBDAV) R.string.connect_to_your_own_server_or else provider.subtitle),
            style = MaterialTheme.typography.titleMedium,
            textAlign = TextAlign.Center,
        )
        val restoring = state.purpose == CloudSetupPurpose.RESTORE
        Text(
            when {
                provider == CloudProvider.WEBDAV && restoring -> stringResource(R.string.kakey_only_reads_your_encrypted_backup_2be8)
                provider == CloudProvider.WEBDAV -> stringResource(R.string.only_the_encrypted_vault_is_stored_62aa)
                restoring -> stringResource(R.string.kakey_only_reads_your_encrypted_backup_7e6d, provider.displayName)
                else -> stringResource(R.string.only_the_encrypted_vault_is_stored_ca2e, provider.displayName)
            },
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun LinkDash() {
    Box(Modifier.size(width = 14.dp, height = 2.dp).background(MaterialTheme.colorScheme.outlineVariant, CircleShape))
}

/**
 * Three-step description that becomes progress once sign-in starts: done steps get a checkmark, the current one spins in bold,
 * upcoming ones are dimmed. Before sign-in they're all numbered descriptions.
 */
@Composable
private fun ConnectSteps(state: CloudSetupState) {
    val name = state.provider.displayName
    val steps = listOf(
        stringResource(R.string.sign_in_to_x_and_allow, name),
        stringResource(R.string.connect_to_your_x_account, name),
        // With full-drive access the third step is choosing a folder; wording differs between backup and restore
        stringResource(
            when {
                state.purpose == CloudSetupPurpose.RESTORE && state.access == CoreCloudAccess.APP_FOLDER -> R.string.find_your_backup
                state.purpose == CloudSetupPurpose.RESTORE -> R.string.open_the_folder_with_your_backup
                state.access == CoreCloudAccess.APP_FOLDER -> R.string.look_for_an_existing_backup_then
                else -> R.string.choose_a_folder_for_the_backup
            },
        ),
    )
    val doneLabel = stringResource(R.string.done)
    val activeLabel = stringResource(R.string.in_progress)
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        steps.forEachIndexed { index, text ->
            val phase = state.phase
            val stepState = when {
                phase == null -> StepState.UPCOMING
                index < phase.ordinal -> StepState.DONE
                index == phase.ordinal -> StepState.ACTIVE
                else -> StepState.PENDING
            }
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(14.dp),
                modifier = Modifier.semantics(mergeDescendants = true) {
                    stateDescription = when (stepState) {
                        StepState.DONE -> doneLabel
                        StepState.ACTIVE -> activeLabel
                        else -> ""
                    }
                },
            ) {
                Box(Modifier.size(24.dp), contentAlignment = Alignment.Center) {
                    AnimatedContent(stepState, transitionSpec = { scaleIn(initialScale = 0.6f) + fadeIn() togetherWith fadeOut() }) {
                        StepMarker(index, it)
                    }
                }
                Text(
                    text,
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = if (stepState == StepState.ACTIVE) FontWeight.SemiBold else FontWeight.Normal,
                    color = when (stepState) {
                        StepState.DONE, StepState.ACTIVE -> MaterialTheme.colorScheme.onSurface
                        StepState.UPCOMING -> MaterialTheme.colorScheme.onSurfaceVariant
                        StepState.PENDING -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.55f)
                    },
                )
            }
        }
    }
}

private enum class StepState { UPCOMING, DONE, ACTIVE, PENDING }

@Composable
private fun StepMarker(index: Int, state: StepState) {
    when (state) {
        StepState.DONE -> Icon(Icons.Filled.CheckCircle, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(22.dp))
        StepState.ACTIVE -> CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
        StepState.UPCOMING, StepState.PENDING -> Box(
            Modifier.size(22.dp).border(1.dp, MaterialTheme.colorScheme.outline, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                "${index + 1}",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun Waiting(checking: Boolean) {
    Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
            Text(
                stringResource(if (checking) R.string.finishing_sign_in else R.string.waiting_for_you_to_grant_access),
                style = MaterialTheme.typography.titleMedium,
            )
        }
        Text(
            stringResource(R.string.sign_in_to_nextcloud_in_the),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/**
 * Choosing the remote folder (Material 3 Expressive): path card (up one level, path, refresh / loading, new folder when
 * backing up) -> hint -> backup file card -> subfolder segmented card. When backing up, a recommended "Use “Kakey” Folder"
 * card is on top; restore is read-only, with no recommendation or folder creation.
 */
@Composable
private fun FolderBrowser(state: CloudSetupState, list: LazyListState, onUseDefault: () -> Unit) {
    val scope = rememberCoroutineScope()
    var naming by remember { mutableStateOf(false) }
    var newName by remember { mutableStateOf("") }
    val restoring = state.purpose == CloudSetupPurpose.RESTORE
    // Scroll back to the top when entering a subfolder or going up a level
    LaunchedEffect(state.currentPath) { list.scrollToItem(0) }
    LazyColumn(
        state = list,
        // Top padding is 12dp, the same as the connection form
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 8.dp),
        verticalArrangement = Arrangement.spacedBy(Segmented.Gap),
    ) {
        // The recommended folder is created when needed, so it's for backup only; restore is read-only
        if (!restoring) {
            item {
                ListItem(
                    headlineContent = {
                        Text(stringResource(R.string.use_x_folder, CloudSetupState.DEFAULT_FOLDER), fontWeight = FontWeight.SemiBold)
                    },
                    leadingContent = { Icon(Icons.Outlined.Star, null, tint = MaterialTheme.colorScheme.onSecondaryContainer) },
                    colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.secondaryContainer),
                    modifier = Modifier.padding(bottom = 10.dp).clip(RoundedCornerShape(24.dp))
                        .clickableRow(enabled = !state.isWorking, onClick = onUseDefault),
                )
            }
        }
        item {
            PathBar(state, onRefresh = { scope.launch { state.load(state.currentPath) } }, onNewFolder = { naming = true })
        }
        val hint = state.folderHint
        if (hint != null && !state.isWorking) {
            item {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 8.dp),
                ) {
                    Icon(Icons.Outlined.Info, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(18.dp))
                    Text(
                        stringResource(hint),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
        // The first row is always "up one level" (same as iOS), disabled at the root; the backup file itself (not tappable)
        // and subfolders share the same card group
        val showsBackupRow = state.currentFolderHasBackup && !state.currentFolderHasOnlyBackup
        val folderOffset = if (showsBackupRow) 2 else 1
        val rowCount = folderOffset + state.folders.size
        item {
            ParentFolderRow(
                enabled = state.currentPath.isNotEmpty() && !state.isWorking,
                shape = Segmented.shape(0, rowCount),
                onClick = { scope.launch { state.load(state.currentPath.substringBeforeLast('/', "")) } },
            )
        }
        if (showsBackupRow) {
            item {
                ListItem(
                    headlineContent = { Text(stringResource(R.string.kakey_backup), fontWeight = FontWeight.SemiBold) },
                    leadingContent = {
                        FolderTile(
                            Icons.Filled.Verified,
                            MaterialTheme.extended.success.copy(alpha = 0.16f),
                            MaterialTheme.extended.success,
                        )
                    },
                    colors = ListItemDefaults.colors(containerColor = Segmented.item),
                    modifier = Modifier.clip(Segmented.shape(1, rowCount)),
                )
            }
        }
        if (state.currentFolderHasOnlyBackup) {
            item { BackupFound() }
        } else if (state.folders.isEmpty() && !state.currentFolderHasBackup && state.isWorking) {
            // On the first listing (just signed in, or opened with a reused authorization) the list is still empty: show loading
            item {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterHorizontally),
                    modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp),
                ) {
                    CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                    Text(
                        stringResource(R.string.loading_folders),
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        } else if (state.folders.isEmpty() && !state.currentFolderHasBackup) {
            item {
                Text(
                    stringResource(R.string.no_folders),
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp),
                )
            }
        }
        itemsIndexed(state.folders, key = { _, entry -> entry.path }) { index, entry ->
            ListItem(
                headlineContent = { Text(entry.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                leadingContent = {
                    FolderTile(
                        Icons.Filled.Folder,
                        MaterialTheme.colorScheme.primaryContainer,
                        MaterialTheme.colorScheme.onPrimaryContainer,
                    )
                },
                trailingContent = {
                    Icon(Icons.AutoMirrored.Outlined.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                },
                colors = ListItemDefaults.colors(containerColor = Segmented.item),
                modifier = Modifier
                    .clip(Segmented.shape(folderOffset + index, rowCount))
                    .clickableRow(enabled = !state.isWorking) { scope.launch { state.load(entry.path) } },
            )
        }
    }
    if (naming) {
        AlertDialog(
            onDismissRequest = { naming = false },
            title = { Text(stringResource(R.string.new_folder)) },
            text = {
                KakeyTextField(value = newName, onValueChange = { newName = it }, label = stringResource(R.string.new_folder_name))
            },
            confirmButton = {
                TextButton(onClick = {
                    val name = newName
                    newName = ""
                    naming = false
                    scope.launch { state.createFolder(name) }
                }, enabled = newName.isNotBlank()) { Text(stringResource(R.string.create)) }
            },
            dismissButton = { TextButton(onClick = { naming = false }) { Text(stringResource(R.string.cancel)) } },
        )
    }
}

/** Centered display when the folder holds only the backup: a large icon on a success-colored circle and "Backup found". */
@Composable
private fun BackupFound() {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp),
        modifier = Modifier.fillMaxWidth().padding(vertical = 48.dp).semantics(mergeDescendants = true) {},
    ) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier.size(88.dp).background(MaterialTheme.extended.success.copy(alpha = 0.16f), CircleShape),
        ) {
            Icon(Icons.Filled.Verified, null, tint = MaterialTheme.extended.success, modifier = Modifier.size(48.dp))
        }
        Text(stringResource(R.string.backup_found), style = MaterialTheme.typography.titleLarge)
    }
}

/**
 * Path row (same as iOS): the path in small text, wrapping when long; a fixed spot on the right shows a spinner while loading
 * and refresh otherwise, plus new folder when backing up. Going up a level is the list's first row ([ParentFolderRow]).
 */
@Composable
private fun PathBar(state: CloudSetupState, onRefresh: () -> Unit, onNewFolder: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(start = 8.dp)) {
        Text(
            state.currentPath.split('/').filter { it.isNotEmpty() }.joinToString(" › ").ifEmpty { stringResource(R.string.root_folder) },
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f).padding(end = 8.dp),
        )
        Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) {
            if (state.isWorking) {
                CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
            } else {
                IconButton(onClick = onRefresh) { Icon(Icons.Outlined.Refresh, stringResource(R.string.refresh)) }
            }
        }
        if (state.purpose == CloudSetupPurpose.BACKUP) {
            IconButton(onClick = onNewFolder, enabled = !state.isWorking) {
                Icon(Icons.Outlined.CreateNewFolder, stringResource(R.string.new_folder))
            }
        }
    }
}

/** Up one level: accent-colored when available to set it apart from subfolders; gray and disabled at the root. */
@Composable
private fun ParentFolderRow(enabled: Boolean, shape: Shape, onClick: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    val content = if (enabled) colors.primary else colors.onSurface.copy(alpha = 0.38f)
    val tile = if (enabled) colors.primaryContainer.copy(alpha = 0.5f) else colors.onSurface.copy(alpha = 0.06f)
    ListItem(
        headlineContent = { Text(stringResource(R.string.parent_directory), fontWeight = FontWeight.Medium) },
        leadingContent = { FolderTile(Icons.Outlined.TurnLeft, tile, content) },
        colors = ListItemDefaults.colors(containerColor = Segmented.item, headlineColor = content),
        modifier = Modifier.clip(shape).clickableRow(enabled = enabled, onClick = onClick),
    )
}

/** Tinted icon at the start of a folder row. */
@Composable
private fun FolderTile(icon: ImageVector, container: Color, content: Color) {
    Box(Modifier.size(40.dp).background(container, RoundedCornerShape(12.dp)), contentAlignment = Alignment.Center) {
        Icon(icon, null, tint = content, modifier = Modifier.size(22.dp))
    }
}

private fun Modifier.clickableRow(enabled: Boolean = true, onClick: () -> Unit): Modifier = clickable(enabled = enabled, onClick = onClick)

/**
 * Backup location icon (the counterpart of Apple's `SyncLocationIcon`): a null `provider` means a folder.
 * Cloud storage uses the full-color brand logo (exported from `design/brands` by `scripts/export-brand-icons.py`); folders and
 * WebDAV use a primary-colored icon. The plate is neutral so brand colors don't mix with theme colors.
 */
@Composable
fun SyncLocationIcon(
    provider: CloudProvider?,
    modifier: Modifier = Modifier,
    size: Dp = 40.dp,
    shape: Shape = CircleShape,
    container: Color = MaterialTheme.colorScheme.surfaceContainerHighest,
    // When set, brand icons and symbols are all drawn in this color (location list); when null, brand icons keep their colors
    // and symbols use the primary color
    tint: Color? = null,
    // Rows that aren't backup locations (first-run restore's "Kakey Exported File") bring their own symbol, with a null provider
    symbol: ImageVector? = null,
) {
    Box(contentAlignment = Alignment.Center, modifier = modifier.size(size).background(container, shape)) {
        val brand = provider?.brand
        if (brand != null && tint != null) {
            Icon(painterResource(brand), null, tint = tint, modifier = Modifier.size(size * 0.6f))
        } else if (brand != null) {
            Image(painterResource(brand), null, Modifier.size(size * 0.6f))
        } else {
            Icon(
                symbol ?: if (provider == null) Icons.Filled.Folder else Icons.Filled.Dns,
                null,
                tint = tint ?: MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(size * 0.55f),
            )
        }
    }
}

private val CloudProvider.brand: Int?
    get() = when (this) {
        CloudProvider.DROPBOX -> R.drawable.brand_dropbox
        CloudProvider.ONEDRIVE -> R.drawable.brand_onedrive
        CloudProvider.GOOGLE_DRIVE -> R.drawable.brand_googledrive
        CloudProvider.NEXTCLOUD -> R.drawable.brand_nextcloud
        CloudProvider.WEBDAV -> null
    }

private val CloudProvider.subtitle: Int
    get() = when (this) {
        CloudProvider.DROPBOX -> R.string.sign_in_with_your_dropbox_account
        CloudProvider.ONEDRIVE -> R.string.sign_in_with_your_microsoft_account
        CloudProvider.GOOGLE_DRIVE -> R.string.sign_in_with_your_google_account
        CloudProvider.NEXTCLOUD -> R.string.sign_in_with_your_nextcloud_account
        CloudProvider.WEBDAV -> R.string.your_own_server_or_nas
    }

private val CloudProvider.submitLabel: Int get() = if (usesOAuth) R.string.sign_in else R.string.connect

private val CoreCloudAccess.title: Int
    get() = when (this) {
        CoreCloudAccess.APP_FOLDER -> R.string.kakey_folder_only
        CoreCloudAccess.FULL -> R.string.any_folder
    }

/** What each access scope lets Kakey see; the app folder sits under "Apps" on Dropbox / OneDrive and in My Drive on Google. */
@Composable
private fun accessDetail(access: CoreCloudAccess, provider: CloudProvider): String = when (access) {
    CoreCloudAccess.APP_FOLDER ->
        stringResource(R.string.kakey_can_only_see_its_own, stringResource(provider.appFolderPath), provider.displayName)
    CoreCloudAccess.FULL -> stringResource(R.string.kakey_can_read_and_change_every, provider.displayName)
}

/** "Apps › Kakey" (Dropbox / OneDrive) or "My Drive › Kakey" (Google Drive), see docs/TECHNICAL.md. */
private val CloudProvider.appFolderPath: Int
    get() = if (this == CloudProvider.GOOGLE_DRIVE) R.string.my_drive_kakey else R.string.apps_kakey

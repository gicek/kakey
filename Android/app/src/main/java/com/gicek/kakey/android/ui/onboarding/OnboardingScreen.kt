package com.gicek.kakey.android.ui.onboarding

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.CloudDownload
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Fingerprint
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Password
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.gicek.kakey.android.R
import com.gicek.kakey.android.core.Core
import com.gicek.kakey.android.core.UiText
import com.gicek.kakey.android.core.VaultException
import com.gicek.kakey.android.core.text
import com.gicek.kakey.android.domain.CloudProvider
import com.gicek.kakey.android.domain.FileLimits
import com.gicek.kakey.android.domain.FileLimits.readAtMost
import com.gicek.kakey.android.domain.SyncLocation
import com.gicek.kakey.android.platform.Biometrics
import com.gicek.kakey.android.ui.LocalStore
import com.gicek.kakey.android.ui.LocalSyncBackends
import com.gicek.kakey.android.ui.components.FairPasswordDialog
import com.gicek.kakey.android.ui.components.NewPasswordFields
import com.gicek.kakey.android.ui.components.PasswordField
import com.gicek.kakey.android.ui.components.Segmented
import com.gicek.kakey.android.ui.components.icon
import com.gicek.kakey.android.ui.components.rememberBiometricKind
import com.gicek.kakey.android.ui.components.unlockTitleRes
import com.gicek.kakey.android.ui.settings.CloudForm
import com.gicek.kakey.android.ui.settings.CloudResume
import com.gicek.kakey.android.ui.settings.CloudSetupPurpose
import com.gicek.kakey.android.ui.settings.CloudSetupSheet
import com.gicek.kakey.android.ui.settings.SyncLocationOptions
import com.gicek.kakey.android.ui.theme.Transitions
import com.gicek.kakey.android.ui.theme.extended
import com.gicek.kakey.core.CoreCloudAccess
import com.gicek.kakey.core.CorePasswordStrength
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private enum class Step { WELCOME, CREATE, RESTORE }

/**
 * First run: create a vault (set a master password, optionally biometrics), or restore from a backup location and unlock with
 * the original master password.
 */
@Composable
fun OnboardingScreen() {
    var step by rememberSaveable { mutableStateOf(Step.WELCOME) }

    // Cloud storage connections authorized during first-run restore, kept per service and access scope (app folder only or not)
    // so choosing the same one again doesn't require signing in again; Dropbox / OneDrive scopes use two developer keys and two
    // authorizations, so they're kept apart. Memory only (not in Keystore, never on disk): released when onboarding leaves
    // composition after a successful restore or vault creation, and gone when the process ends
    val restoreConnections = remember { mutableMapOf<Pair<CloudProvider, Boolean>, CloudResume>() }
    BackHandler(enabled = step != Step.WELCOME) { step = Step.WELCOME }
    // Welcome -> create / restore is parent -> child, using the same shared X axis as main navigation
    val sharedAxisOffset = Transitions.sharedAxisOffsetPx()
    AnimatedContent(
        step,
        transitionSpec = { Transitions.sharedAxisX(sharedAxisOffset, forward = targetState != Step.WELCOME) },
        label = "onboarding",
    ) { current ->
        when (current) {
            Step.WELCOME -> Welcome(onNew = { step = Step.CREATE }, onRestore = { step = Step.RESTORE })
            Step.CREATE -> CreateVault(onBack = { step = Step.WELCOME })
            Step.RESTORE -> RestoreVault(restoreConnections, onBack = { step = Step.WELCOME })
        }
    }
}

/** [title] is shown centered in the top bar (the password step of restore); other pages put their title in the content header. */
@Composable
private fun Page(onBack: (() -> Unit)?, title: String? = null, content: @Composable () -> Unit) {
    Column(
        Modifier
            .fillMaxSize()
            .background(Segmented.background)
            .safeDrawingPadding()
            .imePadding()
            .verticalScroll(rememberScrollState()),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(Modifier.fillMaxWidth().padding(4.dp), contentAlignment = Alignment.Center) {
            if (onBack != null) {
                IconButton(onClick = onBack, modifier = Modifier.align(Alignment.CenterStart)) {
                    Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = stringResource(R.string.back))
                }
            } else {
                Spacer(Modifier.height(48.dp))
            }
            title?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.titleLarge,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(horizontal = 56.dp),
                )
            }
        }
        // Leave some space between a titled top bar and the first card
        if (title != null) Spacer(Modifier.height(12.dp))
        Column(
            Modifier.widthIn(max = 480.dp).padding(horizontal = 24.dp).padding(bottom = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) { content() }
    }
}

/**
 * Welcome page (same structure as iOS, in Material 3 Expressive): a petal-shaped brand badge, a title and a one-line tagline,
 * followed by two connected choice cards, "Start fresh" and "Restore a backup" (tinted icon, description, chevron).
 */
@Composable
private fun Welcome(onNew: () -> Unit, onRestore: () -> Unit) {
    Page(onBack = null) {
        Spacer(Modifier.height(24.dp))
        HeroBadge(size = 136.dp)
        Spacer(Modifier.height(8.dp))
        Text(
            stringResource(R.string.protect_your_2fa_with_kakey),
            style = MaterialTheme.typography.displaySmall,
            fontWeight = FontWeight.Bold,
            textAlign = TextAlign.Center,
        )
        Text(
            stringResource(R.string.end_to_end_encrypted_effortless_to),
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(16.dp))
        EqualHeightColumn(gap = Segmented.Gap) {
            ChoiceRow(
                Icons.Outlined.AutoAwesome,
                stringResource(R.string.start_fresh),
                stringResource(R.string.set_a_master_password_to_get),
                index = 0,
                count = 2,
                iconContainer = MaterialTheme.colorScheme.primaryContainer,
                iconContent = MaterialTheme.colorScheme.onPrimaryContainer,
                onClick = onNew,
            )
            ChoiceRow(
                Icons.Outlined.CloudDownload,
                stringResource(R.string.restore_a_backup),
                stringResource(R.string.from_a_folder_or_a_cloud),
                index = 1,
                count = 2,
                iconContainer = MaterialTheme.colorScheme.tertiaryContainer,
                iconContent = MaterialTheme.colorScheme.onTertiaryContainer,
                onClick = onRestore,
            )
        }
    }
}

@Composable
private fun CreateVault(onBack: () -> Unit) {
    val store = LocalStore.current
    val state by store.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var password by remember { mutableStateOf("") }
    var confirmation by remember { mutableStateOf("") }
    val biometricsAvailable = remember { Biometrics.isAvailable(context) }
    var enableBiometrics by rememberSaveable { mutableStateOf(biometricsAvailable) }
    val canCreate = Core.isAcceptableMasterPassword(password) && password == confirmation && !state.isWorking
    var confirmingFairPassword by remember { mutableStateOf(false) }
    val create: () -> Unit = { scope.launch { store.createVault(password, enableBiometrics) } }
    if (confirmingFairPassword) {
        FairPasswordDialog(
            onConfirm = {
                confirmingFairPassword = false
                create()
            },
            onDismiss = { confirmingFairPassword = false },
        )
    }

    // Header -> password card -> biometrics switch card -> notice -> primary button (Material 3 Expressive)
    Page(onBack = onBack) {
        StepHeader(
            Icons.Outlined.Password,
            stringResource(R.string.set_master_password),
            stringResource(R.string.your_master_password_encrypts_your_2fa_4548),
        )
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            FormCard {
                // Clear the creation error once the password is edited (same as Apple)
                NewPasswordFields(
                    password,
                    {
                        password = it
                        store.clearUnlockError()
                    },
                    confirmation,
                    {
                        confirmation = it
                        store.clearUnlockError()
                    },
                    enabled = !state.isWorking,
                )
            }
            if (biometricsAvailable) BiometricsCard(enableBiometrics) { enableBiometrics = it }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.padding(horizontal = 8.dp)) {
                Icon(
                    Icons.Outlined.Info,
                    null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(18.dp).padding(top = 2.dp),
                )
                Text(
                    stringResource(R.string.your_master_password_is_never_uploaded),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        state.unlockError?.let { Text(it.text(), color = MaterialTheme.colorScheme.error) }
        Button(
            // A "fair" strength password needs confirmation before creating; the button is disabled for weak passwords
            onClick = { if (Core.evaluatePassword(password) == CorePasswordStrength.FAIR) confirmingFairPassword = true else create() },
            enabled = canCreate,
            modifier = Modifier.fillMaxWidth().height(56.dp),
        ) {
            if (state.isWorking) {
                CircularProgressIndicator(Modifier.height(20.dp), strokeWidth = 2.dp)
            } else {
                Text(stringResource(R.string.create_vault))
            }
        }
    }
}

@Composable
private fun RestoreVault(connections: MutableMap<Pair<CloudProvider, Boolean>, CloudResume>, onBack: () -> Unit) {
    val store = LocalStore.current
    val syncBackends = LocalSyncBackends.current
    val state by store.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var error by remember { mutableStateOf<UiText?>(null) }
    var cloudProvider by remember { mutableStateOf<CloudProvider?>(null) }
    var pendingExport by remember { mutableStateOf<PendingExport?>(null) }
    // Location of the found backup: the backup itself is held only in memory in the store and written to disk once opened with
    // the original master password
    var foundBackup by remember { mutableStateOf<SyncLocation?>(null) }

    // When no backup was found in cloud storage and the service allows changing folders, remember the location and connection
    // so "Choose Folder" below the message can reopen the connection page with them (resumeCloud); same as Apple
    var missingCloudBackup by remember { mutableStateOf<Pair<SyncLocation.Cloud, ByteArray>?>(null) }
    var resumeCloud by remember { mutableStateOf<CloudResume?>(null) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri: Uri? ->
        uri ?: return@rememberLauncherForActivityResult
        syncBackends.takePermission(uri)
        missingCloudBackup = null
        scope.launch {
            error = store.restore(uri.toString())
            if (error == null) foundBackup = store.pendingRestoreLocation
        }
    }
    val exportPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        uri ?: return@rememberLauncherForActivityResult
        missingCloudBackup = null
        scope.launch {
            val export = withContext(Dispatchers.IO) { readExport(context, uri) }
            error = if (export == null) UiText.Res(R.string.this_file_isnt_a_kakey_export) else null
            pendingExport = export
        }
    }

    // Remember the authorization; when form is null (reusing an existing connection, OAuth) keep the form from the last connection
    fun keepConnection(location: SyncLocation.Cloud, connection: ByteArray, form: CloudForm? = null) {
        val key = location.provider to location.isAppFolder
        connections[key] = CloudResume(location, connection, anotherFolder = false, form = form ?: connections[key]?.form)
    }

    // The result shows on onboarding (same as Apple). Restore runs in the connection page's coroutine, so close the page only
    // after it finishes; closing first would cancel the restore
    val finishCloudRestore: suspend (SyncLocation.Cloud, ByteArray) -> UiText? = { location, connection ->
        keepConnection(location, connection)
        error = store.restoreFromCloud(location, connection)
        if (error == null) {
            // If the token was refreshed while fetching, also update the connection remembered for this onboarding (reused if
            // the same service is chosen again after going back)
            store.pendingRestoreConnection?.let { keepConnection(location, it) }
            foundBackup = store.pendingRestoreLocation
        }
        if (error != null && store.restoreMissedBackup && location.provider.canChooseFolder) {
            missingCloudBackup = location to connection
        }
        cloudProvider = null
        null
    }
    // Header -> location cards (segmented) -> result and "Choose Folder" (Material 3 Expressive)
    // A found backup or a chosen export file is the next step: the back arrow and system back return to the location list to
    // pick another source, and going back again returns to the welcome page to start fresh; there's no "change location" on
    // the page. Going back is blocked while unlocking / creating the vault
    val inSecondStep = pendingExport != null || foundBackup != null
    val leaveSecondStep = {
        if (!state.isWorking) {
            pendingExport = null
            foundBackup = null
            store.discardRestore()
        }
    }
    BackHandler(enabled = inSecondStep, onBack = leaveSecondStep)
    // The password step (backup found or export file chosen) has no header: the title moves to the center of the top bar and
    // content starts with the source card
    Page(
        onBack = if (inSecondStep) leaveSecondStep else onBack,
        title = if (inSecondStep) stringResource(R.string.restore_a_backup) else null,
    ) {
        if (!inSecondStep) {
            StepHeader(
                Icons.Outlined.CloudDownload,
                stringResource(R.string.restore_a_backup),
                stringResource(R.string.choose_where_your_backup_is_then),
            )
        }
        pendingExport?.let { export ->
            ExportRestore(export)
            return@Page
        }
        foundBackup?.let { location ->
            BackupRestore(location)
            return@Page
        }
        // The failure reason and "Choose Folder" share one message card
        error?.takeIf { !state.isWorking }?.let { message ->
            val missing = missingCloudBackup
            NoticeCard(message.text(), actionLabel = missing?.let { stringResource(R.string.choose_folder) }) {
                if (missing != null) {
                    error = null
                    missingCloudBackup = null
                    val (location, connection) = missing
                    val form = connections[location.provider to location.isAppFolder]?.form
                    resumeCloud = CloudResume(location, connection, anotherFolder = true, form = form)
                    cloudProvider = missing.first.provider
                }
            }
        }
        if (state.isWorking) {
            CircularProgressIndicator(Modifier.size(28.dp), strokeWidth = 3.dp)
            Text(stringResource(R.string.looking_for_a_kakey_backup), color = MaterialTheme.colorScheme.onSurfaceVariant)
        } else {
            SyncLocationOptions(current = null, segmented = true, onFolder = { picker.launch(null) }, onExportFile = {
                exportPicker.launch(arrayOf("*/*"))
            }, onCloud = {
                missingCloudBackup = null
                // Already authorized services don't sign in again: services with a single access scope go straight to folder
                // picking; those with two stay on the form and reuse the authorization on "Sign In" only if the chosen scope
                // was authorized
                val provider = it
                resumeCloud = if (provider.usesOAuth && provider.fullAccessAvailable) {
                    null
                } else {
                    connections.entries.firstOrNull { (key, _) -> key.first == provider }?.value
                }
                val direct = resumeCloud?.takeIf { saved -> saved.location.isAppFolder }
                if (direct != null) {
                    // An authorized service limited to its app folder: skip the connection page and look for the backup
                    // directly, as on first sign-in
                    resumeCloud = null
                    scope.launch { finishCloudRestore(direct.location, direct.connection) }
                } else {
                    cloudProvider = provider
                }
            })
        }
    }
    // Connecting cloud storage always uses a bottom sheet
    cloudProvider?.let { provider ->
        CloudSetupSheet(
            provider,
            store.cloudSetup,
            stringResource(R.string.restore),
            onDismiss = { cloudProvider = null },
            purpose = CloudSetupPurpose.RESTORE,
            resume = resumeCloud,
            saved = { access -> connections[provider to (access == CoreCloudAccess.APP_FOLDER)] },
            // Remember the authorization as soon as it arrives (on entering folder picking): if "Any Folder" finds no backup
            // and the connection page is closed, the connection never comes back through onFinish
            onConnected = ::keepConnection,
            onFinish = finishCloudRestore,
        )
    }
}

/** The Kakey export file chosen for first-run restore (same as Apple): contents only in memory, released with onboarding. */
private class PendingExport(val data: ByteArray, val fileName: String)

/**
 * Reads the chosen file, capped at [FileLimits.MAX_EXTERNAL_FILE_BYTES] like import; returns null if unreadable, oversized or
 * not a Kakey export.
 */
private fun readExport(context: Context, uri: Uri): PendingExport? = runCatching {
    val resolver = context.contentResolver
    val data = resolver.openInputStream(uri)?.use { it.readAtMost() } ?: return null
    if (!Core.isKakeyExport(data)) return null
    val name = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
        if (cursor.moveToFirst()) cursor.getString(0) else null
    }
    PendingExport(data, name ?: uri.lastPathSegment.orEmpty())
}.getOrNull()

/**
 * Export file chosen: source and file name, export password, a "Use as Master Password" switch, a biometrics switch and a
 * continue button. The switch is on by default, using the export password as the master password to keep the page simple;
 * turning it off reveals new password and confirmation fields with the same rules as creating a vault: weak passwords are
 * rejected and "fair" ones need confirmation. No backup location is enabled.
 */
@Composable
private fun ExportRestore(export: PendingExport) {
    val store = LocalStore.current
    val state by store.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var password by remember { mutableStateOf("") }
    var useAsMaster by rememberSaveable { mutableStateOf(true) }
    var newPassword by remember { mutableStateOf("") }
    var confirmation by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<UiText?>(null) }
    var confirmingFairPassword by remember { mutableStateOf(false) }
    val biometricsAvailable = remember { Biometrics.isAvailable(context) }
    var enableBiometrics by rememberSaveable { mutableStateOf(biometricsAvailable) }
    val masterPassword = if (useAsMaster) password else newPassword
    val masterReady = useAsMaster || (Core.isAcceptableMasterPassword(newPassword) && newPassword == confirmation)
    val canContinue = password.isNotEmpty() && masterReady && !state.isWorking
    val restore: () -> Unit = {
        scope.launch {
            error = null
            error = try {
                store.restoreFromExport(export.data, password, masterPassword, enableBiometrics)
            } catch (failure: VaultException) {
                failure.text
            }
        }
    }
    // Confirm first when the new vault's master password is "fair" strength (same as creating a vault)
    val submit: () -> Unit = {
        if (canContinue) {
            if (Core.evaluatePassword(masterPassword) == CorePasswordStrength.FAIR) confirmingFairPassword = true else restore()
        }
    }
    if (confirmingFairPassword) {
        FairPasswordDialog(
            onConfirm = {
                confirmingFairPassword = false
                restore()
            },
            onDismiss = { confirmingFairPassword = false },
        )
    }

    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        FormCard {
            CardRow(
                Icons.Outlined.Description,
                MaterialTheme.colorScheme.onSurfaceVariant,
                stringResource(R.string.from_an_exported_file),
                export.fileName,
                detailMaxLines = 2,
            )
        }
        FormCard {
            PasswordField(
                password,
                {
                    password = it
                    error = null
                },
                stringResource(R.string.export_password),
                Modifier.fillMaxWidth(),
                enabled = !state.isWorking,
                onDone = submit,
            )
        }
        FormCard(
            Modifier.toggleable(useAsMaster, enabled = !state.isWorking, role = Role.Switch) {
                useAsMaster = it
                error = null
            },
        ) {
            CardRow(Icons.Outlined.Password, MaterialTheme.colorScheme.onSurfaceVariant, stringResource(R.string.use_as_master_password)) {
                Switch(checked = useAsMaster, onCheckedChange = null, enabled = !state.isWorking)
            }
        }
        AnimatedVisibility(!useAsMaster, enter = expandVertically() + fadeIn(), exit = shrinkVertically() + fadeOut()) {
            FormCard {
                NewPasswordFields(
                    newPassword,
                    {
                        newPassword = it
                        error = null
                    },
                    confirmation,
                    {
                        confirmation = it
                        error = null
                    },
                    enabled = !state.isWorking,
                    label = stringResource(R.string.master_password),
                )
            }
        }
        if (biometricsAvailable) BiometricsCard(enableBiometrics) { enableBiometrics = it }
    }
    error?.let { NoticeCard(it.text()) }
    Button(onClick = submit, enabled = canContinue, modifier = Modifier.fillMaxWidth().height(56.dp)) {
        if (state.isWorking) {
            CircularProgressIndicator(Modifier.height(20.dp), strokeWidth = 2.dp)
        } else {
            Text(stringResource(R.string.unlock_continue))
        }
    }
}

/**
 * Backup found (same as Apple): "backup found" with its source, the original master password, a biometrics switch and a
 * continue button. It's written to disk and the location enabled only once opened; a user who can't remember the password
 * goes back to pick another source or start fresh. The source shows only the kind or service name, never account, host or
 * path.
 */
@Composable
private fun BackupRestore(location: SyncLocation) {
    val store = LocalStore.current
    val origin = when (location) {
        is SyncLocation.Folder -> stringResource(R.string.from_a_backup_folder)
        is SyncLocation.Cloud -> stringResource(R.string.from_x, location.provider.displayName)
    }
    RestoreUnlock(
        Icons.Filled.Verified,
        MaterialTheme.extended.success,
        stringResource(R.string.backup_found),
        origin,
        stringResource(R.string.existing_master_password),
    ) { password, enableBiometrics -> store.completeRestore(password, enableBiometrics) }
}

/**
 * Shared layout for the second step of first-run restore: source card, password, biometrics switch, continue button and
 * failure reason; [submit] returns null on success.
 */
@Suppress("LongParameterList") // Source card icon, color, two text lines and password title, which differ between the two callers
@Composable
private fun RestoreUnlock(
    icon: ImageVector,
    iconTint: Color,
    title: String,
    detail: String,
    passwordLabel: String,
    submit: suspend (password: String, enableBiometrics: Boolean) -> UiText?,
) {
    val state by LocalStore.current.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var password by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<UiText?>(null) }
    val biometricsAvailable = remember { Biometrics.isAvailable(context) }
    var enableBiometrics by rememberSaveable { mutableStateOf(biometricsAvailable) }
    val canContinue = password.isNotEmpty() && !state.isWorking
    val onSubmit: () -> Unit = {
        if (canContinue) {
            scope.launch {
                error = null
                error = try {
                    submit(password, enableBiometrics)
                } catch (failure: VaultException) {
                    failure.text
                }
            }
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        FormCard { CardRow(icon, iconTint, title, detail, detailMaxLines = 2) }
        FormCard {
            PasswordField(
                password,
                {
                    password = it
                    error = null
                },
                passwordLabel,
                Modifier.fillMaxWidth(),
                enabled = !state.isWorking,
                onDone = onSubmit,
            )
        }
        if (biometricsAvailable) BiometricsCard(enableBiometrics) { enableBiometrics = it }
    }
    error?.let { NoticeCard(it.text()) }
    Button(onClick = onSubmit, enabled = canContinue, modifier = Modifier.fillMaxWidth().height(56.dp)) {
        if (state.isWorking) {
            CircularProgressIndicator(Modifier.height(20.dp), strokeWidth = 2.dp)
        } else {
            Text(stringResource(R.string.unlock_continue))
        }
    }
}

/** "Unlock with biometrics" switch card, shared by vault creation and restore from an export file. */
@Composable
private fun BiometricsCard(enabled: Boolean, onChange: (Boolean) -> Unit) {
    val biometricKind = rememberBiometricKind()
    FormCard(Modifier.toggleable(enabled, role = Role.Switch, onValueChange = onChange)) {
        CardRow(
            biometricKind.icon,
            MaterialTheme.colorScheme.onSurfaceVariant,
            stringResource(biometricKind.unlockTitleRes),
            stringResource(R.string.you_can_always_unlock_with_your),
        ) { Switch(checked = enabled, onCheckedChange = null) }
    }
}

/**
 * One row in a card: icon, title and description, and an optional trailing control. ListItem isn't used: its padding stacks
 * on [FormCard]'s and looks empty, and it pushes the icon to the top on multiple lines; here the icon is a fixed 28dp,
 * vertically centered with the text, so icons and text line up across cards.
 */
@Composable
private fun CardRow(
    icon: ImageVector,
    iconTint: Color,
    title: String,
    detail: String? = null,
    detailMaxLines: Int = Int.MAX_VALUE,
    trailing: (@Composable () -> Unit)? = null,
) {
    Row(
        Modifier.padding(horizontal = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Icon(icon, contentDescription = null, tint = iconTint, modifier = Modifier.size(28.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            detail?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = detailMaxLines,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        trailing?.invoke()
    }
}

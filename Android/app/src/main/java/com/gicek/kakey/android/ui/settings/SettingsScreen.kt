package com.gicek.kakey.android.ui.settings

import android.app.LocaleManager
import android.net.Uri
import android.os.LocaleList
import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.ArrowDownward
import androidx.compose.material.icons.outlined.ArrowUpward
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.CloudSync
import androidx.compose.material.icons.outlined.DeleteForever
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.Fingerprint
import androidx.compose.material.icons.outlined.GppMaybe
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material.icons.outlined.LockClock
import androidx.compose.material.icons.outlined.LockOpen
import androidx.compose.material.icons.outlined.Palette
import androidx.compose.material.icons.outlined.Password
import androidx.compose.material.icons.outlined.Upload
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AlertDialogDefaults
import androidx.compose.material3.BasicAlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.gicek.kakey.android.BuildConfig
import com.gicek.kakey.android.R
import com.gicek.kakey.android.core.Core
import com.gicek.kakey.android.core.UiText
import com.gicek.kakey.android.core.VaultException
import com.gicek.kakey.android.core.text
import com.gicek.kakey.android.domain.AppearanceMode
import com.gicek.kakey.android.domain.AutoLockMode
import com.gicek.kakey.android.domain.BackupHistoryItem
import com.gicek.kakey.android.domain.BiometricFailed
import com.gicek.kakey.android.domain.CloudProvider
import com.gicek.kakey.android.domain.ConflictChoice
import com.gicek.kakey.android.domain.ConflictReview
import com.gicek.kakey.android.domain.ConflictReviewResult
import com.gicek.kakey.android.domain.LanguageMode
import com.gicek.kakey.android.domain.SyncLocation
import com.gicek.kakey.android.domain.SyncStatus
import com.gicek.kakey.android.platform.Biometrics
import com.gicek.kakey.android.platform.DeviceInfo
import com.gicek.kakey.android.ui.LocalSnackbar
import com.gicek.kakey.android.ui.LocalStore
import com.gicek.kakey.android.ui.LocalSyncBackends
import com.gicek.kakey.android.ui.add.LocalAddFlow
import com.gicek.kakey.android.ui.components.FairPasswordDialog
import com.gicek.kakey.android.ui.components.IconTile
import com.gicek.kakey.android.ui.components.NewPasswordFields
import com.gicek.kakey.android.ui.components.PasswordField
import com.gicek.kakey.android.ui.components.PasswordRequirement
import com.gicek.kakey.android.ui.components.PasswordStrengthBar
import com.gicek.kakey.android.ui.components.Segmented
import com.gicek.kakey.android.ui.components.formatted
import com.gicek.kakey.android.ui.components.icon
import com.gicek.kakey.android.ui.components.nameRes
import com.gicek.kakey.android.ui.components.rememberBiometricKind
import com.gicek.kakey.android.ui.components.unlockTitleRes
import com.gicek.kakey.android.ui.findActivity
import com.gicek.kakey.android.ui.main.LocalNavigator
import com.gicek.kakey.android.ui.main.Route
import com.gicek.kakey.core.CorePasswordStrength
import java.time.LocalDate
import kotlinx.coroutines.launch

private enum class Dialog { AUTO_LOCK, LANGUAGE, CHANGE_PASSWORD, EXPORT, RESET }

/** Settings: security, sync and backup, data, appearance and language, about (version). A grouped list. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen() {
    val store = LocalStore.current
    val state by store.state.collectAsStateWithLifecycle()
    val navigator = LocalNavigator.current
    val addFlow = LocalAddFlow.current
    val syncBackends = LocalSyncBackends.current
    val context = LocalContext.current
    val resources = LocalResources.current
    val snackbar = LocalSnackbar.current
    val scope = rememberCoroutineScope()
    var dialog by remember { mutableStateOf<Dialog?>(null) }
    var exportData by remember { mutableStateOf<ByteArray?>(null) }
    val biometricsAvailable = remember { Biometrics.isAvailable(context) }
    val biometricKind = rememberBiometricKind()
    val preferences = state.preferences
    val verifyTitle = stringResource(R.string.verify_your_identity)
    val resetReason = stringResource(R.string.reset_kakey_and_erase_local_data_5e09)

    /**
     * Reset app: even when unlocked, requires biometrics or the screen lock credential on the spot (docs/SECURITY.md; matches
     * the Mac's `deviceOwnerAuthentication`), so someone holding an unlocked phone can't wipe the data. When the device has
     * neither biometrics nor a screen lock the system can't prompt, and only the preceding confirmation dialog applies.
     */
    suspend fun resetAfterVerification() {
        val verified = if (!Biometrics.canVerifyOwner(context)) {
            true
        } else {
            try {
                Biometrics.verifyOwner(context.findActivity(), verifyTitle, resetReason)
            } catch (error: BiometricFailed) {
                snackbar.showSnackbar(error.reason)
                false
            }
        }
        if (verified) store.resetApplication()
    }

    var choosingLocation by remember { mutableStateOf(false) }
    var cloudProvider by remember { mutableStateOf<CloudProvider?>(null) }
    val folderPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri: Uri? ->
        uri ?: return@rememberLauncherForActivityResult
        syncBackends.takePermission(uri)
        scope.launch { store.configureSync(uri.toString())?.let { snackbar.showSnackbar(it.resolve(context)) } }
    }
    val exporter = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri: Uri? ->
        val data = exportData
        exportData = null
        if (uri == null || data == null) return@rememberLauncherForActivityResult
        val written = runCatching {
            context.contentResolver.openOutputStream(uri, "wt")?.use { it.write(data) } != null
        }.getOrDefault(false)
        scope.launch {
            snackbar.showSnackbar(resources.getString(if (written) R.string.encrypted_backup_exported else R.string.couldnt_save_the_file))
        }
    }

    Scaffold(
        containerColor = Segmented.background,
        topBar = {
            TopAppBar(
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Segmented.background),
                title = { Text(stringResource(R.string.settings)) },
                navigationIcon = {
                    IconButton(onClick = navigator::pop) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, stringResource(R.string.back)) }
                },
            )
        },
        snackbarHost = { SnackbarHost(snackbar) },
    ) { padding ->
        LazyColumn(
            Modifier.padding(padding).fillMaxWidth(),
            contentPadding = PaddingValues(bottom = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            item {
                SettingsGroup(
                    stringResource(R.string.security),
                    buildList {
                        if (biometricsAvailable) {
                            add { modifier ->
                                SettingRow(
                                    icon = biometricKind.icon,
                                    title = stringResource(biometricKind.unlockTitleRes),
                                    summary = if (preferences.biometricsEnabled && !state.biometricKeyAvailable) {
                                        stringResource(
                                            R.string.unlock_once_with_your_master_password,
                                            stringResource(biometricKind.nameRes),
                                        )
                                    } else {
                                        stringResource(R.string.the_vault_key_is_protected_by)
                                    },
                                    trailing = {
                                        Switch(checked = preferences.biometricsEnabled, onCheckedChange = { enabled ->
                                            scope.launch { store.setBiometricsEnabled(enabled) }
                                        })
                                    },
                                    modifier = modifier,
                                    onClick = { scope.launch { store.setBiometricsEnabled(!preferences.biometricsEnabled) } },
                                )
                            }
                        }
                        add { modifier ->
                            SettingRow(
                                Icons.Outlined.LockClock,
                                stringResource(R.string.auto_lock),
                                autoLockLabel(preferences.autoLock),
                                modifier = modifier,
                            ) {
                                dialog = Dialog.AUTO_LOCK
                            }
                        }
                        add { modifier ->
                            SettingRow(
                                Icons.Outlined.Password,
                                stringResource(R.string.change_master_password),
                                null,
                                modifier = modifier,
                            ) {
                                dialog = Dialog.CHANGE_PASSWORD
                            }
                        }
                    },
                )
            }
            item {
                SettingsGroup(
                    stringResource(R.string.sync_backup),
                    listOf { modifier ->
                        SyncSection(state.syncStatus, state.syncFolderName, preferences.syncLocation, modifier) {
                            choosingLocation = true
                        }
                    },
                )
            }
            if (state.syncHistory.isNotEmpty()) {
                item {
                    SettingsGroup(
                        stringResource(R.string.backup_history),
                        state.syncHistory.take(10).map { item ->
                            { modifier -> HistoryRow(item, modifier) }
                        },
                    )
                }
            }
            item {
                SettingsGroup(
                    stringResource(R.string.data),
                    listOf(
                        { modifier ->
                            SettingRow(Icons.Outlined.Upload, stringResource(R.string.export_encrypted_backup), null, modifier = modifier) {
                                dialog =
                                    Dialog.EXPORT
                            }
                        },
                        { modifier ->
                            SettingRow(
                                Icons.Outlined.Download,
                                stringResource(R.string.import_backup_file),
                                null,
                                modifier = modifier,
                                onClick = addFlow.importFile,
                            )
                        },
                        { modifier ->
                            SettingRow(
                                Icons.Outlined.DeleteForever,
                                stringResource(R.string.reset_app),
                                stringResource(R.string.erases_the_vault_and_settings_on),
                                modifier = modifier,
                                destructive = true,
                            ) { dialog = Dialog.RESET }
                        },
                    ),
                )
            }
            item {
                SettingsGroup(
                    stringResource(R.string.appearance),
                    listOf(
                        { modifier -> AppearancePicker(preferences.appearance, store::setAppearance, modifier) },
                        { modifier ->
                            SettingRow(
                                Icons.Outlined.Language,
                                stringResource(R.string.language),
                                languageLabel(currentLanguage(context)),
                                modifier = modifier,
                            ) {
                                dialog = Dialog.LANGUAGE
                            }
                        },
                    ),
                )
            }
            item {
                SettingsGroup(
                    stringResource(R.string.about),
                    listOf(
                        { modifier ->
                            SettingRow(
                                Icons.Outlined.Info,
                                stringResource(R.string.version),
                                BuildConfig.VERSION_NAME,
                                modifier = modifier,
                                onClick = null,
                            )
                        },
                    ),
                )
            }
        }
    }

    if (choosingLocation) {
        AlertDialog(
            onDismissRequest = { choosingLocation = false },
            title = { Text(stringResource(R.string.choose_location)) },
            text = {
                SyncLocationOptions(
                    current = preferences.syncLocation,
                    onFolder = {
                        choosingLocation = false
                        folderPicker.launch(null)
                    },
                    onCloud = {
                        choosingLocation = false
                        cloudProvider = it
                    },
                )
            },
            confirmButton = {},
            dismissButton = { TextButton(onClick = { choosingLocation = false }) { Text(stringResource(R.string.cancel)) } },
        )
    }
    cloudProvider?.let { provider ->
        CloudSetupSheet(provider, store.cloudSetup, stringResource(R.string.use_this_folder), onDismiss = {
            cloudProvider = null
        }) { location, connection ->
            store.configureCloudSync(location, connection).also { if (it == null) cloudProvider = null }
        }
    }
    when (dialog) {
        Dialog.AUTO_LOCK -> ChoiceDialog(
            title = stringResource(R.string.auto_lock),
            message = stringResource(R.string.locks_after_the_selected_time_without),
            options = AutoLockMode.entries,
            selected = preferences.autoLock,
            label = { autoLockLabel(it) },
            onSelect = {
                store.setAutoLock(it)
                dialog = null
            },
            onDismiss = { dialog = null },
        )
        Dialog.LANGUAGE -> ChoiceDialog(
            title = stringResource(R.string.language),
            options = LanguageMode.entries,
            selected = currentLanguage(context),
            label = { languageLabel(it) },
            onSelect = { mode ->
                dialog = null
                // System per-app language (Android 13+): the UI is recreated, and vault state in the process is unaffected
                context.getSystemService(LocaleManager::class.java).applicationLocales =
                    mode.tag?.let(LocaleList::forLanguageTags) ?: LocaleList.getEmptyLocaleList()
            },
            onDismiss = { dialog = null },
        )
        Dialog.CHANGE_PASSWORD -> ChangePasswordDialog { dialog = null }
        Dialog.EXPORT -> ExportDialog(onDismiss = { dialog = null }) { data ->
            dialog = null
            exportData = data
            exporter.launch("Kakey-${LocalDate.now()}.json")
        }
        Dialog.RESET -> AlertDialog(
            onDismissRequest = { dialog = null },
            title = { Text(stringResource(R.string.reset_kakey)) },
            text = { Text(stringResource(R.string.erases_the_vault_and_settings_on)) },
            confirmButton = {
                TextButton(onClick = {
                    dialog = null
                    scope.launch { resetAfterVerification() }
                }) {
                    Text(stringResource(R.string.erase_local_data), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { dialog = null }) { Text(stringResource(R.string.cancel)) } },
        )
        null -> Unit
    }
}

/**
 * Settings group: a title plus a segmented card (each row rounded, large outer corners, thin gaps between rows). Width-limited
 * to 720dp and centered on tablets.
 */
@Composable
private fun SettingsGroup(title: String, rows: List<@Composable (Modifier) -> Unit>) {
    Column(Modifier.widthIn(max = 720.dp).fillMaxWidth().padding(horizontal = 16.dp)) {
        Text(
            title,
            style = MaterialTheme.typography.titleSmall,
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier.padding(start = 16.dp, top = 24.dp, bottom = 8.dp),
        )
        Column(verticalArrangement = Arrangement.spacedBy(Segmented.Gap)) {
            rows.forEachIndexed { index, row ->
                row(Modifier.fillMaxWidth().clip(Segmented.shape(index, rows.size)).background(Segmented.item))
            }
        }
    }
}

/** Settings row: a round icon on a tinted background at the start (Android 16 system settings style) and an optional trailing control. */
@Composable
private fun SettingRow(
    icon: ImageVector,
    title: String,
    summary: String?,
    modifier: Modifier = Modifier,
    trailing: (@Composable () -> Unit)? = null,
    destructive: Boolean = false,
    onClick: (() -> Unit)?,
) {
    ListItem(
        leadingContent = { IconTile(icon, destructive = destructive) },
        headlineContent = { Text(title, color = if (destructive) MaterialTheme.colorScheme.error else Color.Unspecified) },
        supportingContent = summary?.let { { Text(it) } },
        trailingContent = trailing,
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
        modifier = modifier.then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier),
    )
}

/**
 * Sync and backup (the location can be a folder or cloud storage): when off, an explanation and "Set Up"; when on, the
 * location, status, Back Up Now and change location. Cleartext HTTP locations are marked "unencrypted connection",
 * conflicts let the user pick a direction, and stopping sync asks for confirmation first.
 */
@Composable
private fun SyncSection(status: SyncStatus, name: String?, location: SyncLocation?, modifier: Modifier, onChoose: () -> Unit) {
    val store = LocalStore.current
    val scope = rememberCoroutineScope()
    var confirmingStop by remember { mutableStateOf(false) }
    // "Restore from Backup" when the backup can't be opened asks for that backup's master password first; the local vault is
    // replaced only after it opens
    var restoringBackup by remember { mutableStateOf(false) }
    var review by remember { mutableStateOf<ConflictReview?>(null) }
    var reviewError by remember { mutableStateOf<UiText?>(null) }
    review?.let { current ->
        ConflictResolutionDialog(current, onDismiss = { review = null }) { choice, preferRemote ->
            review = null
            reviewError = null
            scope.launch {
                when (choice) {
                    ConflictChoice.MERGE -> store.mergeWithBackup(current, preferRemote)
                    ConflictChoice.KEEP_LOCAL -> store.resolveConflictKeepingLocal()
                    ConflictChoice.USE_BACKUP -> store.resolveConflictUsingRemote()
                }
            }
        }
    }
    Column(modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (location == null) {
            Text(
                stringResource(R.string.backups_are_end_to_end_encrypted),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Button(onClick = onChoose) {
                Icon(Icons.Outlined.CloudSync, null)
                Text(stringResource(R.string.set_up), Modifier.padding(start = 8.dp))
            }
            return@Column
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            SyncLocationIcon((location as? SyncLocation.Cloud)?.provider)
            Column(Modifier.weight(1f)) {
                Text(name ?: stringResource(R.string.cant_access_the_sync_folder_choose), style = MaterialTheme.typography.titleMedium)
                val statusText = when (status) {
                    SyncStatus.Running -> stringResource(R.string.syncing)
                    SyncStatus.Conflict -> stringResource(R.string.sync_conflict)
                    SyncStatus.Unreadable -> stringResource(R.string.backup_cant_be_opened)
                    is SyncStatus.Failed -> status.message.text()
                    else -> (location as? SyncLocation.Cloud)?.let {
                        when {
                            !it.isAppFolder -> it.detail
                            it.provider == CloudProvider.GOOGLE_DRIVE -> stringResource(R.string.x_my_drive_kakey, it.username)
                            else -> stringResource(R.string.x_apps_kakey, it.username)
                        }
                    } ?: stringResource(R.string.sync_folder)
                }
                Text(
                    statusText,
                    style = MaterialTheme.typography.bodySmall,
                    color = if (status is SyncStatus.Failed || status == SyncStatus.Conflict || status == SyncStatus.Unreadable) {
                        MaterialTheme.colorScheme.error
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    },
                )
            }
            if (status == SyncStatus.Running) {
                CircularProgressIndicator(Modifier.padding(4.dp).widthIn(max = 20.dp), strokeWidth = 2.dp)
            }
        }
        if ((location as? SyncLocation.Cloud)?.isSecure == false) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(Icons.Outlined.LockOpen, null, tint = MaterialTheme.colorScheme.error)
                Text(
                    stringResource(R.string.unencrypted_connection),
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.labelLarge,
                )
            }
        }
        if ((location as? SyncLocation.Cloud)?.isCertificatePinned == true) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(Icons.Outlined.GppMaybe, null, tint = MaterialTheme.colorScheme.error)
                Text(
                    stringResource(R.string.certificate_not_verified),
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.labelLarge,
                )
            }
        }
        if (status == SyncStatus.Unreadable) {
            Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Outlined.Warning, null, tint = MaterialTheme.colorScheme.error)
                Text(
                    stringResource(R.string.the_backup_here_cant_be_opened) + " " +
                        stringResource(R.string.to_use_that_backup_restore_from_0813),
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
            OutlinedButton(onClick = { restoringBackup = true }, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.restore_from_backup))
            }
            OutlinedButton(onClick = onChoose, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.change_location)) }
        } else if (status == SyncStatus.Conflict) {
            Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Outlined.Warning, null, tint = MaterialTheme.colorScheme.error)
                Text(stringResource(R.string.this_device_and_the_backup_both), style = MaterialTheme.typography.bodyMedium)
            }
            reviewError?.let { Text(it.text(), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
            Button(onClick = {
                scope.launch {
                    when (val result = store.conflictReview()) {
                        is ConflictReviewResult.Ready -> review = result.review
                        is ConflictReviewResult.Failed -> reviewError = result.message
                    }
                }
            }, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.resolve_conflict))
            }
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = { scope.launch { store.sync() } }, enabled = status != SyncStatus.Running) {
                    Text(stringResource(R.string.back_up_now))
                }
                OutlinedButton(onClick = onChoose, enabled = status != SyncStatus.Running) {
                    Text(stringResource(R.string.change_location))
                }
            }
        }
        TextButton(onClick = { confirmingStop = true }) {
            Text(stringResource(R.string.stop_syncing), color = MaterialTheme.colorScheme.error)
        }
    }
    if (restoringBackup) RestoreBackupDialog(onDismiss = { restoringBackup = false })
    if (confirmingStop) {
        AlertDialog(
            onDismissRequest = { confirmingStop = false },
            title = {
                Text(
                    if (location is SyncLocation.Cloud) {
                        stringResource(R.string.turn_off_backup_and_sign_out, location.provider.displayName)
                    } else {
                        stringResource(R.string.turn_off_backup_ad42)
                    },
                )
            },
            text = { Text(stringResource(R.string.the_backup_already_stored_there_is)) },
            confirmButton = {
                TextButton(onClick = {
                    confirmingStop = false
                    store.stopSync()
                }) { Text(stringResource(R.string.stop_syncing), color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { confirmingStop = false }) { Text(stringResource(R.string.cancel)) } },
        )
    }
}

/**
 * Same layout as the Mac: direction icon and result, a second line with location and trigger (naming the device when it came
 * from another one), time and size on the right.
 */
@Composable
private fun HistoryRow(item: BackupHistoryItem, modifier: Modifier) {
    val context = LocalContext.current
    val source = stringResource(
        when (item.source) {
            BackupHistoryItem.Source.AUTO -> R.string.icloud_hist_auto
            BackupHistoryItem.Source.MANUAL -> R.string.icloud_hist_manual
            BackupHistoryItem.Source.SYNC -> R.string.icloud_hist_sync
            BackupHistoryItem.Source.RESTORE -> R.string.restore_from_backup
            BackupHistoryItem.Source.MERGE -> R.string.icloud_hist_merge
        },
    )
    val status = if (item.isFailure) stringResource(R.string.icloud_hist_failed_fmt, source) else null
    // On success the title is the result and the second line the trigger; for failures and records without a direction the
    // title is the status
    val result = when (item.direction) {
        BackupHistoryItem.Direction.UPLOAD -> stringResource(R.string.uploaded)
        BackupHistoryItem.Direction.DOWNLOAD -> stringResource(R.string.downloaded)
        BackupHistoryItem.Direction.UNCHANGED -> stringResource(R.string.no_changes)
        null -> null
    }
    val title = status ?: result ?: source
    val origin = item.otherDevice(DeviceInfo.name(context))?.let { stringResource(R.string.from_x, it) }
    val detail = listOfNotNull(item.location, source.takeIf { title != it && status == null }, origin).joinToString(" · ")
    val tint = if (item.isWarning) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant
    ListItem(
        leadingContent = {
            Icon(
                when {
                    item.isWarning -> Icons.Outlined.Warning
                    item.direction == BackupHistoryItem.Direction.UPLOAD -> Icons.Outlined.ArrowUpward
                    item.direction == BackupHistoryItem.Direction.DOWNLOAD -> Icons.Outlined.ArrowDownward
                    item.direction == BackupHistoryItem.Direction.UNCHANGED -> Icons.Outlined.Check
                    else -> Icons.Outlined.History
                },
                contentDescription = null,
                tint = tint,
                modifier = Modifier
                    .size(32.dp)
                    .background(tint.copy(alpha = 0.12f), CircleShape)
                    .padding(7.dp),
            )
        },
        headlineContent = {
            Text(title, color = if (item.isWarning) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface)
        },
        supportingContent = detail.takeIf { it.isNotEmpty() }?.let { { Text(it, maxLines = 1) } },
        trailingContent = {
            Column(horizontalAlignment = Alignment.End) {
                Text(item.date.formatted(), style = MaterialTheme.typography.bodySmall)
                if (item.sizeBytes > 0) {
                    Text(
                        Formatter.formatShortFileSize(context, item.sizeBytes),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        },
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
        modifier = modifier,
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AppearancePicker(selected: AppearanceMode, onSelect: (AppearanceMode) -> Unit, modifier: Modifier) {
    val options = listOf(
        AppearanceMode.SYSTEM to R.string.system,
        AppearanceMode.LIGHT to R.string.light,
        AppearanceMode.DARK to R.string.dark,
    )
    Row(modifier.padding(horizontal = 16.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
        IconTile(Icons.Outlined.Palette, Modifier.padding(end = 16.dp))
        SingleChoiceSegmentedButtonRow(Modifier.weight(1f)) {
            options.forEachIndexed { index, (mode, label) ->
                SegmentedButton(selected = mode == selected, onClick = {
                    onSelect(mode)
                }, shape = SegmentedButtonDefaults.itemShape(index, options.size)) {
                    Text(stringResource(label))
                }
            }
        }
    }
}

// Dimensions match the Clock app's single-choice dialog (measured from a Pixel 420dpi screenshot): 20sp title,
// 48dp rows with a full-width touch target, radio center 36dp from the start, 18sp text 72dp from the start, button row
// padding 4dp vertical and 12dp horizontal.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun <T> ChoiceDialog(
    title: String,
    options: List<T>,
    message: String? = null,
    selected: T,
    label: @Composable (T) -> String,
    onSelect: (T) -> Unit,
    onDismiss: () -> Unit,
) {
    BasicAlertDialog(
        onDismissRequest = onDismiss,
        // The platform default dialog is 320dp wide, while system apps use screen width minus 27dp on each side; tablets are
        // still capped at BasicAlertDialog's 560dp
        modifier = Modifier.padding(horizontal = 27.dp),
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(
            Modifier.fillMaxWidth(),
            shape = AlertDialogDefaults.shape,
            color = AlertDialogDefaults.containerColor,
            tonalElevation = AlertDialogDefaults.TonalElevation,
        ) {
            Column(Modifier.selectableGroup()) {
                Text(
                    title,
                    Modifier.padding(start = 24.dp, end = 24.dp, top = 21.dp, bottom = 10.dp),
                    color = AlertDialogDefaults.titleContentColor,
                    style = MaterialTheme.typography.titleLarge.copy(fontSize = 20.sp, lineHeight = 24.sp),
                )
                if (message != null) {
                    Text(
                        message,
                        Modifier.padding(start = 24.dp, end = 24.dp, bottom = 8.dp),
                        color = AlertDialogDefaults.textContentColor,
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
                options.forEach { option ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(48.dp)
                            .selectable(selected = option == selected, role = Role.RadioButton, onClick = { onSelect(option) })
                            .padding(horizontal = 24.dp),
                    ) {
                        RadioButton(selected = option == selected, onClick = null)
                        Text(
                            label(option),
                            Modifier.padding(start = 24.dp),
                            color = MaterialTheme.colorScheme.onSurface,
                            style = MaterialTheme.typography.bodyLarge.copy(fontSize = 18.sp),
                        )
                    }
                }
                Row(
                    Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 12.dp, vertical = 4.dp),
                    horizontalArrangement = Arrangement.End,
                ) {
                    TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) }
                }
            }
        }
    }
}

@Composable
private fun ChangePasswordDialog(onDismiss: () -> Unit) {
    val store = LocalStore.current
    val state by store.state.collectAsStateWithLifecycle()
    val snackbar = LocalSnackbar.current
    val context = LocalContext.current
    val resources = LocalResources.current
    val scope = rememberCoroutineScope()
    var current by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var confirmation by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<UiText?>(null) }
    var confirmingFairPassword by remember { mutableStateOf(false) }
    var updatingBackup by remember { mutableStateOf(false) }
    var backupNotUpdated by remember { mutableStateOf(false) }
    // The dialog can't be dismissed while the password change and the following backup update run: swapping the file and key
    // can't be canceled, and the UI shouldn't vanish midway
    val busy = state.isWorking || updatingBackup
    val dismiss = { if (!busy) onDismiss() }
    val change: () -> Unit = {
        scope.launch {
            error = store.changePassword(current, password)
            if (error != null) return@launch
            // Backup is on: sync right away and warn if the backup wasn't updated (it still holds the vault encrypted with the
            // old password)
            updatingBackup = true
            val updated = store.backupUpdatedAfterPasswordChange()
            updatingBackup = false
            if (updated) {
                onDismiss()
                snackbar.showSnackbar(resources.getString(R.string.master_password_changed))
            } else {
                backupNotUpdated = true
            }
        }
    }
    if (confirmingFairPassword) {
        FairPasswordDialog(
            onConfirm = {
                confirmingFairPassword = false
                change()
            },
            onDismiss = { confirmingFairPassword = false },
        )
    }
    if (backupNotUpdated) {
        AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text(stringResource(R.string.backup_not_updated)) },
            text = { Text(stringResource(R.string.your_new_password_is_in_use)) },
            confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.ok)) } },
        )
        return
    }
    AlertDialog(
        onDismissRequest = dismiss,
        title = { Text(stringResource(R.string.change_master_password)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                PasswordField(
                    current,
                    {
                        current = it
                        error = null
                    },
                    stringResource(R.string.current_master_password),
                    isError =
                        error != null,
                )
                NewPasswordFields(password, { password = it }, confirmation, { confirmation = it })
                Text(
                    stringResource(R.string.the_vault_on_this_device_is),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                error?.let { Text(it.text(), color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            TextButton(
                enabled = current.isNotEmpty() && Core.isAcceptableMasterPassword(password) && password == confirmation && !busy,
                // A "fair" strength password needs confirmation before changing; the button is disabled for weak passwords
                onClick = { if (Core.evaluatePassword(password) == CorePasswordStrength.FAIR) confirmingFairPassword = true else change() },
            ) {
                if (updatingBackup) {
                    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                } else {
                    Text(stringResource(R.string.change_password))
                }
            }
        },
        dismissButton = { TextButton(onClick = dismiss, enabled = !busy) { Text(stringResource(R.string.cancel)) } },
    )
}

/**
 * "Restore from Backup" when the backup can't be opened (same on all platforms): enter that backup's master password; only
 * once it opens is the local vault replaced, staying unlocked. On a wrong password the local vault is untouched and the
 * reason shows in the dialog. Can't be dismissed while running.
 */
@Composable
private fun RestoreBackupDialog(onDismiss: () -> Unit) {
    val store = LocalStore.current
    val scope = rememberCoroutineScope()
    var password by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<UiText?>(null) }
    var working by remember { mutableStateOf(false) }
    val canRestore = password.isNotEmpty() && !working
    val restore: () -> Unit = {
        if (canRestore) {
            scope.launch {
                working = true
                error = store.restoreUnreadableBackup(password)
                working = false
                if (error == null) onDismiss()
            }
        }
    }
    AlertDialog(
        onDismissRequest = { if (!working) onDismiss() },
        title = { Text(stringResource(R.string.restore_from_backup)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.to_use_that_backup_restore_from_0813), style = MaterialTheme.typography.bodyMedium)
                PasswordField(
                    password,
                    {
                        password = it
                        error = null
                    },
                    stringResource(R.string.existing_master_password),
                    Modifier.fillMaxWidth(),
                    isError = error != null,
                    enabled = !working,
                    onDone = restore,
                )
                error?.let { Text(it.text(), color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            TextButton(onClick = restore, enabled = canRestore) {
                if (working) {
                    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                } else {
                    Text(stringResource(R.string.restore))
                }
            }
        },
        dismissButton = { TextButton(onClick = onDismiss, enabled = !working) { Text(stringResource(R.string.cancel)) } },
    )
}

/** Encrypted export: a separate export password (entered twice); the export file can be imported on other devices only with it. */
@Composable
private fun ExportDialog(onDismiss: () -> Unit, onExported: (ByteArray) -> Unit) {
    val store = LocalStore.current
    val scope = rememberCoroutineScope()
    var password by remember { mutableStateOf("") }
    var confirmation by remember { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<UiText?>(null) }
    var confirmingFairPassword by remember { mutableStateOf(false) }
    val export: () -> Unit = {
        working = true
        scope.launch {
            try {
                onExported(store.exportBackup(password))
            } catch (exception: VaultException) {
                error = exception.text
            } finally {
                working = false
            }
        }
    }
    if (confirmingFairPassword) {
        FairPasswordDialog(
            onConfirm = {
                confirmingFairPassword = false
                export()
            },
            onDismiss = { confirmingFairPassword = false },
        )
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.export_encrypted_backup)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.the_backup_is_encrypted_with_this), style = MaterialTheme.typography.bodyMedium)
                // Like a new master password, accept only digits, ASCII letters and ASCII symbols
                PasswordField(password, { password = Core.filterPasswordInput(it) }, stringResource(R.string.export_password))
                // Same rules as the master password: weak passwords can't export, and "fair" ones are confirmed before exporting
                PasswordStrengthBar(password, Modifier.fillMaxWidth())
                PasswordRequirement(password)
                PasswordField(
                    confirmation,
                    { confirmation = Core.filterPasswordInput(it) },
                    stringResource(R.string.enter_again),
                    isError =
                        confirmation.isNotEmpty() && confirmation != password,
                )
                error?.let { Text(it.text(), color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            TextButton(
                enabled = Core.isAcceptableExportPassword(password) && password == confirmation && !working,
                onClick = { if (Core.evaluatePassword(password) == CorePasswordStrength.FAIR) confirmingFairPassword = true else export() },
            ) { Text(stringResource(R.string.export)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

@Composable
private fun autoLockLabel(mode: AutoLockMode): String = stringResource(
    when (mode) {
        AutoLockMode.ONE_MINUTE -> R.string.s_1_minute
        AutoLockMode.FIVE_MINUTES -> R.string.s_5_minutes
        AutoLockMode.THIRTY_MINUTES -> R.string.s_30_minutes
    },
)

/**
 * Each language's display name is written in that language and not localized; only "Follow system" is translated
 * (docs/LOCALIZATION.md).
 */
@Composable
private fun languageLabel(mode: LanguageMode): String = when (mode) {
    LanguageMode.SYSTEM -> stringResource(R.string.system)
    LanguageMode.ENGLISH -> "English"
    LanguageMode.SIMPLIFIED_CHINESE -> "简体中文" // i18n-guard: allow language names are written in their own language
    LanguageMode.TRADITIONAL_CHINESE -> "繁體中文" // i18n-guard: allow language names are written in their own language
}

private fun currentLanguage(context: android.content.Context): LanguageMode {
    val locales = context.getSystemService(LocaleManager::class.java).applicationLocales
    if (locales.isEmpty) return LanguageMode.SYSTEM
    val locale = locales[0]
    return when {
        locale.language == "en" -> LanguageMode.ENGLISH
        locale.language == "zh" && (
            locale.script == "Hant" || locale.country in setOf(
                "TW",
                "HK",
                "MO",
            )
            ) -> LanguageMode.TRADITIONAL_CHINESE
        locale.language == "zh" -> LanguageMode.SIMPLIFIED_CHINESE
        else -> LanguageMode.SYSTEM
    }
}

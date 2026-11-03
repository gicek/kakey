package com.gicek.kakey.android.ui.add

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.gicek.kakey.android.R
import com.gicek.kakey.android.core.Core
import com.gicek.kakey.android.core.UiText
import com.gicek.kakey.android.core.VaultException
import com.gicek.kakey.android.core.text
import com.gicek.kakey.android.domain.FileLimits.readAtMost
import com.gicek.kakey.android.platform.QrImageDecoder
import com.gicek.kakey.android.ui.LocalStore
import com.gicek.kakey.android.ui.components.PasswordField
import com.gicek.kakey.android.ui.main.LocalNavigator
import com.gicek.kakey.android.ui.main.Route
import com.gicek.kakey.core.KakeyException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Flow shared by every add-account entry point (the counterpart of iOS's `AddFlowController`): scanning, photos, entering a
 * setup key (including pasting otpauth), and importing a backup file. Recognized results go to the review page first and,
 * once the user confirms, are inserted together through core deduplication.
 */
class AddFlow(val scan: () -> Unit, val pickPhotos: () -> Unit, val enterKey: () -> Unit, val importFile: () -> Unit)

val LocalAddFlow = staticCompositionLocalOf<AddFlow> { error("AddFlow not provided") }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AddFlowHost(content: @Composable () -> Unit) {
    val store = LocalStore.current
    val navigator = LocalNavigator.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var alert by remember { mutableStateOf<UiText?>(null) }
    var pendingBackup by remember { mutableStateOf<ByteArray?>(null) }
    var backupPassword by remember { mutableStateOf("") }

    fun review(payloads: List<String>) {
        val parsed = payloads.flatMap { Core.parseLines(it, Core.placeholders(context)) }
        if (parsed.none { it.isValid }) {
            alert = UiText.Res(R.string.no_qr_code_found)
        } else {
            navigator.push(Route.Review(parsed))
        }
    }

    /** Tries without a password first (plaintext Authenticator backup) and asks for one only when needed. */
    fun importBackup(data: ByteArray, password: String) {
        scope.launch {
            try {
                store.importBackup(data, password)
            } catch (error: VaultException) {
                when (error.error) {
                    is KakeyException.PasswordRequired, is KakeyException.EmptyPassword -> pendingBackup = data
                    else -> alert = error.text
                }
            }
        }
    }

    val photoPicker = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia()) { uris: List<Uri> ->
        if (uris.isEmpty()) return@rememberLauncherForActivityResult
        scope.launch { review(withContext(Dispatchers.Default) { uris.flatMap { QrImageDecoder.decode(context, it) } }) }
    }
    val filePicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        uri ?: return@rememberLauncherForActivityResult
        scope.launch {
            // Read the file in the background, up to FileLimits.MAX_EXTERNAL_FILE_BYTES; unreadable means invalid, oversized
            // gets its own message
            val stream = withContext(Dispatchers.IO) { runCatching { context.contentResolver.openInputStream(uri) }.getOrNull() }
            if (stream == null) {
                alert = UiText.Res(R.string.err_import_invalid_file)
                return@launch
            }
            val read = withContext(Dispatchers.IO) { runCatching { stream.use { it.readAtMost() } } }
            val data = read.getOrNull()
            when {
                read.isFailure -> alert = UiText.Res(R.string.err_import_invalid_file)
                data == null -> alert = UiText.Res(R.string.the_file_is_too_large)
                else -> importBackup(data, "")
            }
        }
    }

    val flow = remember(navigator) {
        AddFlow(
            scan = { navigator.push(Route.Scanner) },
            pickPhotos = { photoPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
            enterKey = { navigator.push(Route.Manual) },
            importFile = { filePicker.launch(arrayOf("*/*")) },
        )
    }

    CompositionLocalProvider(LocalAddFlow provides flow) { content() }

    pendingBackup?.let { data ->
        AlertDialog(
            onDismissRequest = {
                pendingBackup = null
                backupPassword = ""
            },
            title = { Text(stringResource(R.string.backup_password)) },
            text = {
                Column {
                    Text(stringResource(R.string.enter_the_password_that_was_used), Modifier.padding(bottom = 12.dp))
                    PasswordField(backupPassword, { backupPassword = it }, stringResource(R.string.enter_password_5705))
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        val password = backupPassword
                        pendingBackup = null
                        backupPassword = ""
                        importBackup(data, password)
                    },
                    enabled = backupPassword.isNotEmpty(),
                ) { Text(stringResource(R.string.import_label)) }
            },
            dismissButton = {
                TextButton(onClick = {
                    pendingBackup = null
                    backupPassword = ""
                }) { Text(stringResource(R.string.cancel)) }
            },
        )
    }

    alert?.let { message ->
        AlertDialog(
            onDismissRequest = { alert = null },
            text = { Text(message.text()) },
            confirmButton = { TextButton(onClick = { alert = null }) { Text(stringResource(R.string.done)) } },
        )
    }
}

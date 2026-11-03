package com.gicek.kakey.android.ui.detail

import android.graphics.Bitmap
import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.CreateNewFolder
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.outlined.QrCode2
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.gicek.kakey.android.R
import com.gicek.kakey.android.core.Account
import com.gicek.kakey.android.core.Core
import com.gicek.kakey.android.core.label
import com.gicek.kakey.android.domain.BiometricFailed
import com.gicek.kakey.android.platform.Biometrics
import com.gicek.kakey.android.platform.Clipboard
import com.gicek.kakey.android.platform.QrCodeImage
import com.gicek.kakey.android.ui.LocalStore
import com.gicek.kakey.android.ui.components.AccountTitle
import com.gicek.kakey.android.ui.components.CodeText
import com.gicek.kakey.android.ui.components.CountdownRing
import com.gicek.kakey.android.ui.components.KakeyTextField
import com.gicek.kakey.android.ui.components.MonogramBadge
import com.gicek.kakey.android.ui.components.Segmented
import com.gicek.kakey.android.ui.components.formatted
import com.gicek.kakey.android.ui.components.rememberNow
import com.gicek.kakey.android.ui.findActivity
import com.gicek.kakey.android.ui.main.CategoryNameDialog
import com.gicek.kakey.android.ui.main.CategoryPrompt
import com.gicek.kakey.android.ui.main.rememberCopy
import com.gicek.kakey.android.ui.theme.Motion
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Account detail (bottom sheet; centered on tablets): a large verification code (tap to copy), name editing, categories,
 * parameters, plus "Show Secret" and "Export QR Code" (which require re-verifying the device owner) and delete (confirmation).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AccountDetailSheet(account: Account, onDismiss: () -> Unit) {
    val store = LocalStore.current
    val state by store.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val copy = rememberCopy()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var editing by remember { mutableStateOf(false) }
    var issuer by remember(account.id) { mutableStateOf(account.issuer) }
    var username by remember(account.id) { mutableStateOf(account.username) }
    var secret by remember { mutableStateOf<String?>(null) }
    var qr by remember { mutableStateOf<Bitmap?>(null) }
    var authError by remember { mutableStateOf<String?>(null) }
    var confirmDelete by remember { mutableStateOf(false) }
    var newCategory by remember { mutableStateOf(false) }
    var copied by remember { mutableStateOf(false) }
    LaunchedEffect(copied) {
        if (copied) {
            delay(1_500)
            copied = false
        }
    }
    // Don't leave the plaintext secret in memory after leaving the detail view
    DisposableEffect(Unit) { onDispose { secret = null } }

    val verifyTitle = stringResource(R.string.verify_your_identity)
    val revealReason = stringResource(R.string.reveal_the_account_secret_92b0)
    val qrReason = stringResource(R.string.show_the_account_qr_code_8719)
    fun verified(reason: String, then: () -> Unit) {
        scope.launch {
            try {
                if (Biometrics.verifyOwner(context.findActivity(), verifyTitle, reason)) {
                    authError = null
                    then()
                }
            } catch (error: BiometricFailed) {
                authError = error.reason
            }
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            Modifier
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp)
                .navigationBarsPadding()
                .padding(bottom = 16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            // Title and editing
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                MonogramBadge(account.issuer, size = 48.dp)
                AccountTitle(account, Modifier.weight(1f), titleStyle = MaterialTheme.typography.titleLarge)
                if (editing) {
                    TextButton(onClick = {
                        store.update(account.copy(issuer = issuer, username = username))
                        editing = false
                    }) { Text(stringResource(R.string.done)) }
                } else {
                    IconButton(onClick = {
                        editing = true
                    }) { Icon(Icons.Outlined.Edit, contentDescription = stringResource(R.string.edit)) }
                }
            }

            // Large verification code; tap to copy
            val now = rememberNow()
            val remaining = Core.secondsRemaining(account, now)
            // Tap to copy: the card background turns to the accent color and "Copy" becomes "Copied"; the code itself stays put
            val cardColor by animateColorAsState(
                if (copied) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceContainerHigh,
                Motion.effects(),
                label = "codeCard",
            )
            Card(
                shape = MaterialTheme.shapes.extraLarge,
                colors = CardDefaults.cardColors(containerColor = cardColor),
                modifier = Modifier.fillMaxWidth().clickable {
                    copy(account)
                    copied = true
                },
            ) {
                Column(Modifier.fillMaxWidth().padding(vertical = 20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    CodeText(Core.code(account, now), urgent = remaining <= 5, fontSize = 42.sp)
                    Spacer(Modifier.height(10.dp))
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        CountdownRing(Core.progress(account, now), remaining, size = 20.dp)
                        Text(
                            stringResource(R.string.refreshes_in_x_s, remaining),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Text("·", color = MaterialTheme.colorScheme.outline)
                        Icon(
                            if (copied) Icons.Outlined.Check else Icons.Outlined.ContentCopy,
                            null,
                            Modifier.size(16.dp),
                            tint = MaterialTheme.colorScheme.primary,
                        )
                        Text(
                            stringResource(if (copied) R.string.copied else R.string.copy),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.primary,
                        )
                    }
                }
            }

            if (editing) {
                KakeyTextField(issuer, { issuer = it }, label = stringResource(R.string.service_name))
                KakeyTextField(username, { username = it }, label = stringResource(R.string.account_name_or_email))
            }

            // Categories: checking toggles membership
            Text(stringResource(R.string.categories), style = MaterialTheme.typography.titleSmall)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                state.categories.forEach { category ->
                    val member = account.id in category.accountIds
                    FilterChip(
                        selected = member,
                        onClick = { store.toggleAccount(account.id, category.id) },
                        label = { Text(category.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                        leadingIcon = if (member) ({ Icon(Icons.Outlined.Check, null, Modifier.size(18.dp)) }) else null,
                    )
                }
                FilterChip(
                    selected = false,
                    onClick = { newCategory = true },
                    label = { Text(stringResource(R.string.new_category)) },
                    leadingIcon = { Icon(Icons.Outlined.CreateNewFolder, null, Modifier.size(18.dp)) },
                )
            }

            // Parameters
            Column {
                InfoRow(
                    stringResource(R.string.algorithm),
                    stringResource(R.string.x_x_digits_x_sec, account.algorithm.label, account.digits, account.period),
                )
                HorizontalDivider()
                InfoRow(
                    stringResource(R.string.added_via),
                    stringResource(
                        if (account.addedBy ==
                            Account.PROVENANCE_MANUAL
                        ) {
                            R.string.added_manually
                        } else {
                            R.string.imported
                        },
                    ),
                )
                HorizontalDivider()
                InfoRow(stringResource(R.string.date_added), account.createdAt.formatted())
            }

            // Secret and QR code: verify the device owner first
            Text(stringResource(R.string.secret), style = MaterialTheme.typography.titleSmall)
            secret?.let { value ->
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth().background(
                        MaterialTheme.colorScheme.surfaceContainerHigh,
                        MaterialTheme.shapes.medium,
                    ).padding(start = 16.dp),
                ) {
                    Text(value, fontFamily = FontFamily.Monospace, modifier = Modifier.weight(1f).padding(vertical = 12.dp))
                    IconButton(onClick = {
                        Clipboard.copySensitive(context, value)
                    }) { Icon(Icons.Outlined.ContentCopy, stringResource(R.string.copy)) }
                }
            }
            // The two actions that need verification form a connected button group (Expressive connected button group)
            Row(horizontalArrangement = Arrangement.spacedBy(Segmented.Gap), modifier = Modifier.fillMaxWidth()) {
                FilledTonalButton(
                    onClick = { if (secret == null) verified(revealReason) { secret = account.secret } else secret = null },
                    shape = Segmented.connectedShape(0, count = 2, outer = 28.dp, inner = 8.dp),
                    modifier = Modifier.weight(1f).height(56.dp),
                ) {
                    Icon(if (secret == null) Icons.Outlined.Key else Icons.Outlined.VisibilityOff, null, Modifier.size(18.dp))
                    Text(
                        stringResource(
                            if (secret ==
                                null
                            ) {
                                R.string.show_secret
                            } else {
                                R.string.hide
                            },
                        ),
                        Modifier.padding(start = 8.dp),
                        maxLines = 1,
                    )
                }
                FilledTonalButton(
                    onClick = {
                        verified(qrReason) { qr = QrCodeImage.make(Core.otpauthUrl(account, Core.placeholders(context))) }
                    },
                    shape = Segmented.connectedShape(1, count = 2, outer = 28.dp, inner = 8.dp),
                    modifier = Modifier.weight(1f).height(56.dp),
                ) {
                    Icon(Icons.Outlined.QrCode2, null, Modifier.size(18.dp))
                    Text(stringResource(R.string.export_qr_code), Modifier.padding(start = 8.dp), maxLines = 1)
                }
            }
            Text(
                authError ?: stringResource(R.string.revealing_the_secret_or_qr_code),
                style = MaterialTheme.typography.bodySmall,
                color = if (authError != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
            )

            HorizontalDivider()
            FilledTonalButton(
                onClick = { confirmDelete = true },
                colors = ButtonDefaults.filledTonalButtonColors(
                    containerColor = MaterialTheme.colorScheme.errorContainer,
                    contentColor = MaterialTheme.colorScheme.onErrorContainer,
                ),
                modifier = Modifier.fillMaxWidth().height(56.dp),
            ) {
                Icon(Icons.Outlined.Delete, null, Modifier.size(18.dp))
                Text(stringResource(R.string.delete_this_account), Modifier.padding(start = 8.dp))
            }
        }
    }

    if (newCategory) CategoryNameDialog(CategoryPrompt.New(account.id)) { newCategory = false }
    qr?.let { bitmap ->
        AlertDialog(
            onDismissRequest = { qr = null },
            title = { Text(stringResource(R.string.export_qr_code)) },
            text = {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Image(
                        bitmap.asImageBitmap(),
                        contentDescription = null,
                        filterQuality = FilterQuality.None,
                        modifier = Modifier.size(240.dp).background(Color.White, RoundedCornerShape(12.dp)).padding(8.dp),
                    )
                    Text(account.issuer, style = MaterialTheme.typography.titleMedium)
                    Text(
                        stringResource(R.string.anyone_who_scans_this_code_can),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                    )
                }
            },
            confirmButton = { TextButton(onClick = { qr = null }) { Text(stringResource(R.string.done)) } },
        )
    }
    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text(stringResource(R.string.delete_x, account.issuer)) },
            text = { Text(stringResource(R.string.this_cant_be_undone_make_sure)) },
            confirmButton = {
                TextButton(onClick = {
                    confirmDelete = false
                    store.delete(account)
                    onDismiss()
                }) { Text(stringResource(R.string.delete), color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text(stringResource(R.string.cancel)) } },
        )
    }
}

@Composable
private fun InfoRow(title: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f))
        Text(value, textAlign = TextAlign.End)
    }
}

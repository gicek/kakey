package com.gicek.kakey.android.ui.add

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ContentPaste
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.gicek.kakey.android.R
import com.gicek.kakey.android.core.Core
import com.gicek.kakey.android.core.ParsedOtpAuth
import com.gicek.kakey.android.core.UiText
import com.gicek.kakey.android.core.label
import com.gicek.kakey.android.core.message
import com.gicek.kakey.android.core.text
import com.gicek.kakey.android.platform.Clipboard
import com.gicek.kakey.android.ui.LocalStore
import com.gicek.kakey.android.ui.components.ConnectedChoice
import com.gicek.kakey.android.ui.components.KakeyTextField
import com.gicek.kakey.android.ui.components.MonogramBadge
import com.gicek.kakey.android.ui.components.Segmented
import com.gicek.kakey.android.ui.main.LocalNavigator
import com.gicek.kakey.android.ui.main.Route
import com.gicek.kakey.android.ui.theme.Motion
import com.gicek.kakey.core.CoreTotpAlgorithm

/** The two ways to enter a setup key: paste an otpauth link to parse, or fill in the service, account and secret by hand. */
private enum class EntryMode { Paste, Manual }

/**
 * Enter Setup Key: a connected button group at the top switches between "Paste otpauth" and "Manual Entry".
 * Paste: a multi-line field (the trailing button pastes from the clipboard); "Parse" goes to the review page, where entries
 * that couldn't be parsed show the reason.
 * Manual: service, account and secret (an invalid secret shows an error and can't be saved); "Advanced Options" is collapsed
 * by default and expands to change algorithm, digits and period.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ManualEntryScreen() {
    val store = LocalStore.current
    val navigator = LocalNavigator.current
    val context = LocalContext.current
    var mode by rememberSaveable { mutableStateOf(EntryMode.Paste) }
    var links by rememberSaveable { mutableStateOf("") }
    var issuer by rememberSaveable { mutableStateOf("") }
    var username by rememberSaveable { mutableStateOf("") }
    var secret by remember { mutableStateOf("") }
    var algorithm by rememberSaveable { mutableStateOf(CoreTotpAlgorithm.SHA1) }
    var digits by rememberSaveable { mutableStateOf(6) }
    var period by rememberSaveable { mutableStateOf(30) }
    var advanced by rememberSaveable { mutableStateOf(false) }
    var error by remember { mutableStateOf<UiText?>(null) }
    val secretInvalid = secret.isNotBlank() && Core.standardizedSecret(secret) == null

    fun save() {
        error = store.addManual(issuer, username, secret, algorithm, digits, period)
        if (error == null) navigator.popAddFlow()
    }

    fun parse() {
        val parsed = Core.parseLines(links, Core.placeholders(context))
        if (parsed.isEmpty()) {
            error = UiText.Res(R.string.the_clipboard_doesnt_contain_an_otpauth)
        } else {
            navigator.push(Route.Review(parsed))
        }
    }

    Scaffold(
        containerColor = Segmented.background,
        topBar = {
            TopAppBar(
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Segmented.background),
                title = { Text(stringResource(R.string.enter_setup_key)) },
                navigationIcon = { IconButton(onClick = navigator::pop) { Icon(Icons.Outlined.Close, stringResource(R.string.cancel)) } },
                actions = {
                    when (mode) {
                        EntryMode.Paste -> TextButton(onClick = ::parse, enabled = links.isNotBlank()) {
                            Text(stringResource(R.string.parse))
                        }
                        EntryMode.Manual -> TextButton(onClick = ::save, enabled = secret.isNotBlank() && !secretInvalid) {
                            Text(stringResource(R.string.save))
                        }
                    }
                },
            )
        },
    ) { padding ->
        Column(
            Modifier.padding(padding).fillMaxSize().imePadding().verticalScroll(rememberScrollState()),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Column(Modifier.widthIn(max = 560.dp).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                ConnectedChoice(EntryMode.entries, mode, onSelect = {
                    mode = it
                    error = null
                }) { stringResource(if (it == EntryMode.Paste) R.string.paste_otpauth else R.string.manual_entry) }
                when (mode) {
                    EntryMode.Paste -> PasteFields(links, onChange = {
                        links = it
                        error = null
                    })
                    EntryMode.Manual -> ManualFields(
                        issuer = issuer,
                        onIssuer = { issuer = it },
                        username = username,
                        onUsername = { username = it },
                        secret = secret,
                        onSecret = {
                            secret = it
                            error = null
                        },
                        secretInvalid = secretInvalid,
                        advanced = advanced,
                        onAdvanced = { advanced = it },
                        algorithm = algorithm,
                        onAlgorithm = { algorithm = it },
                        digits = digits,
                        onDigits = { digits = it },
                        period = period,
                        onPeriod = { period = it },
                    )
                }
                error?.let { Text(it.text(), color = MaterialTheme.colorScheme.error) }
            }
        }
    }
}

/** Paste otpauth: a multi-line field whose trailing button pastes the clipboard (the clipboard is read only when the user taps it). */
@Composable
private fun PasteFields(links: String, onChange: (String) -> Unit) {
    val context = LocalContext.current
    KakeyTextField(
        links,
        onChange,
        label = stringResource(R.string.paste_otpauth),
        supportingText = stringResource(R.string.paste_one_otpauth_or_migration_link),
        textStyle = MaterialTheme.typography.bodyLarge.copy(fontFamily = if (links.isEmpty()) FontFamily.Default else FontFamily.Monospace),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false),
        singleLine = false,
        minLines = 4,
        maxLines = 8,
        trailingIcon = {
            IconButton(onClick = { Clipboard.text(context)?.let { onChange(if (links.isBlank()) it else links.trimEnd() + "\n" + it) } }) {
                Icon(Icons.Outlined.ContentPaste, contentDescription = stringResource(R.string.paste))
            }
        },
    )
}

/** Manual entry: three fields plus collapsed advanced options. */
@Suppress("LongParameterList") // Values and callbacks for each form field
@Composable
private fun ManualFields(
    issuer: String,
    onIssuer: (String) -> Unit,
    username: String,
    onUsername: (String) -> Unit,
    secret: String,
    onSecret: (String) -> Unit,
    secretInvalid: Boolean,
    advanced: Boolean,
    onAdvanced: (Boolean) -> Unit,
    algorithm: CoreTotpAlgorithm,
    onAlgorithm: (CoreTotpAlgorithm) -> Unit,
    digits: Int,
    onDigits: (Int) -> Unit,
    period: Int,
    onPeriod: (Int) -> Unit,
) {
    KakeyTextField(
        issuer,
        onIssuer,
        label = stringResource(R.string.service_name),
        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words),
    )
    KakeyTextField(
        username,
        onUsername,
        label = stringResource(R.string.account_name_or_email),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
    )
    KakeyTextField(
        secret,
        onSecret,
        label = stringResource(R.string.secret),
        placeholder = stringResource(R.string.enter_or_paste_the_key_from),
        isError = secretInvalid,
        supportingText = stringResource(
            if (secretInvalid) R.string.invalid_secret_key else R.string.the_secret_is_encrypted_on_this,
        ),
        // The placeholder uses the same font as other fields; monospace kicks in only once there is content, to make checking
        // the secret easier
        textStyle = MaterialTheme.typography.bodyLarge.copy(
            fontFamily = if (secret.isEmpty()) FontFamily.Default else FontFamily.Monospace,
        ),
        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters, autoCorrectEnabled = false),
        singleLine = false,
        maxLines = 3,
    )
    // Advanced options: collapsed by default, the header row shows current parameters and expands on tap; the chevron flips with it
    val rotation by animateFloatAsState(if (advanced) CHEVRON_EXPANDED_DEGREES else 0f, Motion.spatial(), label = "chevron")
    Column(Modifier.fillMaxWidth().background(Segmented.item, MaterialTheme.shapes.large)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .clickable(role = Role.Button) { onAdvanced(!advanced) }
                .padding(horizontal = 16.dp, vertical = 12.dp),
        ) {
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.advanced_options), style = MaterialTheme.typography.titleSmall)
                Text(
                    stringResource(R.string.x_x_digits_x_sec, algorithm.label, digits, period),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Icon(
                Icons.Outlined.ExpandMore,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.rotate(rotation),
            )
        }
        AnimatedVisibility(
            advanced,
            enter = expandVertically(Motion.spatial()) + fadeIn(Motion.effects()),
            exit =
                shrinkVertically(Motion.spatial()) + fadeOut(Motion.effects()),
        ) {
            Column(
                verticalArrangement = Arrangement.spacedBy(16.dp),
                modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 16.dp),
            ) {
                Choice(stringResource(R.string.algorithm), CoreTotpAlgorithm.entries, algorithm, { it.label }, onAlgorithm)
                Choice(stringResource(R.string.digits), listOf(6, 8), digits, { "$it" }, onDigits)
                Choice(stringResource(R.string.refresh_interval), listOf(30, 60), period, {
                    stringResource(if (it == 30) R.string.s_30_seconds else R.string.s_60_seconds)
                }, onPeriod)
            }
        }
    }
}

/** Chevron rotation when advanced options are expanded. */
private const val CHEVRON_EXPANDED_DEGREES = 180f

/** One advanced option: a title plus a connected radio button group (same style as the mode switch at the top). */
@Composable
private fun <T> Choice(title: String, options: List<T>, selected: T, label: @Composable (T) -> String, onSelect: (T) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        ConnectedChoice(options, selected, onSelect, label = label)
    }
}

/** Review page: two groups, "Parsed" and "couldn't parse (with reason)"; confirming deduplicates and inserts them together. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReviewScreen(items: List<ParsedOtpAuth>) {
    val store = LocalStore.current
    val navigator = LocalNavigator.current
    val valid = items.filter { it.isValid }
    val invalid = items.filterNot { it.isValid }
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.add_account)) },
                navigationIcon = { IconButton(onClick = navigator::pop) { Icon(Icons.Outlined.Close, stringResource(R.string.cancel)) } },
            )
        },
        bottomBar = {
            Button(
                onClick = {
                    store.addParsed(valid)
                    navigator.popAddFlow()
                },
                enabled = valid.isNotEmpty(),
                modifier = Modifier.fillMaxWidth().padding(16.dp),
            ) { Text(pluralStringResource(R.plurals.add_x_accounts, valid.size, valid.size)) }
        },
    ) { padding ->
        LazyColumn(contentPadding = PaddingValues(bottom = 16.dp), modifier = Modifier.padding(padding)) {
            if (valid.isNotEmpty()) {
                item { SectionTitle(stringResource(R.string.parsed)) }
                items(valid) { item ->
                    ListItem(
                        leadingContent = { MonogramBadge(item.issuer, size = 40.dp) },
                        headlineContent = { Text(item.issuer) },
                        supportingContent = { Text(item.account) },
                        trailingContent = {
                            Text(
                                stringResource(R.string.x_x_digits_x_sec, item.algorithm.label, item.digits, item.period),
                                style = MaterialTheme.typography.bodySmall,
                            )
                        },
                    )
                }
            }
            if (invalid.isNotEmpty()) {
                item { SectionTitle(stringResource(R.string.unable_to_parse)) }
                items(invalid) { item ->
                    ListItem(
                        leadingContent = { Icon(Icons.Outlined.ErrorOutline, null, tint = MaterialTheme.colorScheme.error) },
                        headlineContent = { Text(item.issuer.ifBlank { "—" }) },
                        supportingContent = { item.failure?.let { Text(it.message.text(), color = MaterialTheme.colorScheme.error) } },
                    )
                }
            }
        }
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 4.dp),
    )
}

package com.gicek.kakey.android.ui.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.gicek.kakey.android.R
import com.gicek.kakey.android.core.Account
import com.gicek.kakey.android.domain.ConflictChoice
import com.gicek.kakey.android.domain.ConflictReview
import com.gicek.kakey.core.CoreAccountChange
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/**
 * Conflict resolution (docs/TECHNICAL.md; same rules as Apple): an overview of both sides, per-account differences, and the
 * consequences of each choice. For accounts changed on both sides the user picks which version to keep per account (affects
 * only "Merge Both"), defaulting to the side saved more recently. Secrets are only marked "secret differs", never shown.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConflictResolutionDialog(review: ConflictReview, onDismiss: () -> Unit, onApply: (ConflictChoice, Set<String>) -> Unit) {
    var choice by remember { mutableStateOf(ConflictChoice.MERGE) }
    var preferRemote by remember { mutableStateOf(if (review.remoteIsNewer) review.changed.map { it.local.id }.toSet() else emptySet()) }
    val formatter =
        remember { DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT).withZone(ZoneId.systemDefault()) }

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = { Text(stringResource(R.string.resolve_conflict)) },
                    navigationIcon = {
                        IconButton(onClick = onDismiss) { Icon(Icons.Outlined.Close, stringResource(R.string.decide_later)) }
                    },
                    actions = { TextButton(onClick = { onApply(choice, preferRemote) }) { Text(stringResource(R.string.apply)) } },
                )
            },
        ) { padding ->
            LazyColumn(Modifier.padding(padding).fillMaxSize()) {
                item {
                    Side(stringResource(R.string.this_device), review.localCount, formatter.format(review.localUpdatedAt), null)
                    Side(stringResource(R.string.backup), review.remoteCount, formatter.format(review.remoteUpdatedAt), review.remoteDevice)
                }
                accountGroup(R.string.only_on_this_device_x, review.onlyLocal)
                accountGroup(R.string.only_in_the_backup_x, review.onlyRemote)
                if (review.changed.isNotEmpty()) {
                    item {
                        Header(stringResource(R.string.different_on_both_sides_x, review.changed.size))
                        // Per-account version picking only affects "Merge Both": hidden for other resolutions
                        if (choice == ConflictChoice.MERGE) {
                            Text(
                                stringResource(R.string.pick_which_version_merge_both_keeps),
                                Modifier.padding(horizontal = 24.dp),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                    items(review.changed, key = { it.local.id }) { item ->
                        val useRemote = item.local.id in preferRemote
                        Column(Modifier.padding(horizontal = 24.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(item.local.issuer, style = MaterialTheme.typography.bodyLarge)
                            item.differingNames?.let { (local, remote) ->
                                Text(
                                    stringResource(R.string.this_device_x_backup_x, local, remote),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            Text(
                                stringResource(R.string.differs_in_x, describe(item.changes)),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            // Per-account version picking only affects "Merge Both"
                            if (choice == ConflictChoice.MERGE) {
                                val sides = listOf(false to R.string.this_device, true to R.string.backup)
                                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                                    sides.forEachIndexed { index, (remote, label) ->
                                        SegmentedButton(
                                            selected = useRemote == remote,
                                            onClick = {
                                                preferRemote =
                                                    if (remote) preferRemote + item.local.id else preferRemote - item.local.id
                                            },
                                            shape = SegmentedButtonDefaults.itemShape(index, 2),
                                        ) { Text(stringResource(label)) }
                                    }
                                }
                            }
                        }
                    }
                }
                categoryLines(review).takeIf { it.isNotEmpty() }?.let { lines ->
                    item { Header(stringResource(R.string.categories)) }
                    items(lines) { line ->
                        Text(
                            line.resolve(),
                            Modifier.padding(horizontal = 24.dp, vertical = 4.dp),
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    }
                }
                item {
                    Header(stringResource(R.string.resolve_conflict))
                    ChoiceRow(
                        choice == ConflictChoice.MERGE,
                        stringResource(R.string.merge_both),
                        stringResource(R.string.keeps_every_account_from_both_sides, review.localCount + review.onlyRemote.size),
                    ) { choice = ConflictChoice.MERGE }
                    ChoiceRow(
                        choice == ConflictChoice.KEEP_LOCAL,
                        stringResource(R.string.keep_this_devices_copy),
                        stringResource(
                            R.string.overwrites_the_backup_backup_accounts_removed,
                            review.onlyRemote.size,
                            review.onlyLocal.size,
                            review.changed.size,
                        ),
                    ) { choice = ConflictChoice.KEEP_LOCAL }
                    ChoiceRow(
                        choice == ConflictChoice.USE_BACKUP,
                        stringResource(R.string.use_the_backups_copy),
                        stringResource(
                            R.string.replaces_the_vault_on_this_device,
                            review.onlyLocal.size,
                            review.onlyRemote.size,
                            review.changed.size,
                        ),
                    ) { choice = ConflictChoice.USE_BACKUP }
                }
            }
        }
    }
}

private fun androidx.compose.foundation.lazy.LazyListScope.accountGroup(title: Int, accounts: List<Account>) {
    if (accounts.isEmpty()) return
    item { Header(stringResource(title, accounts.size)) }
    items(accounts, key = { "${title}_${it.id}" }) { account ->
        ListItem(headlineContent = { Text(account.issuer) }, supportingContent = { Text(account.username) })
    }
}

@Composable
private fun Header(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 24.dp, end = 24.dp, top = 20.dp, bottom = 4.dp),
    )
}

@Composable
private fun Side(title: String, count: Int, time: String, device: String?) {
    ListItem(
        headlineContent = { Text(title) },
        supportingContent = { Text(listOfNotNull(device, time).joinToString(" · ")) },
        trailingContent = { Text(stringResource(R.string.accounts_x, count)) },
    )
}

@Composable
private fun ChoiceRow(selected: Boolean, title: String, detail: String, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.Top,
    ) {
        RadioButton(selected = selected, onClick = onClick)
        Column(Modifier.padding(top = 12.dp)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun describe(changes: List<CoreAccountChange>): String = changes.map {
    stringResource(
        when (it) {
            CoreAccountChange.ISSUER -> R.string.name
            CoreAccountChange.USERNAME -> R.string.account_name
            CoreAccountChange.SECRET -> R.string.secret_key
            CoreAccountChange.PARAMETERS -> R.string.algorithm_digits_or_period
            CoreAccountChange.CATEGORIES -> R.string.categories
        },
    )
}.joinToString(stringResource(R.string.str_d3bc9a37))

private fun categoryLines(review: ConflictReview): List<CategoryLine> =
    review.categoriesOnlyLocal.map { CategoryLine(R.string.category_only_on_this_device_x, it) } +
        review.categoriesOnlyRemote.map { CategoryLine(R.string.category_only_in_the_backup_x, it) } +
        review.categoriesRenamed.map { CategoryLine(R.string.category_renamed_x_x, it.first, it.second) }

private data class CategoryLine(val res: Int, val first: String, val second: String? = null) {
    @Composable
    fun resolve(): String = if (second == null) stringResource(res, first) else stringResource(res, first, second)
}

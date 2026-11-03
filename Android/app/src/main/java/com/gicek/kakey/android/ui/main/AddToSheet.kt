package com.gicek.kakey.android.ui.main

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.CreateNewFolder
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.gicek.kakey.android.R
import com.gicek.kakey.android.core.Account
import com.gicek.kakey.android.core.AccountCategory
import com.gicek.kakey.android.ui.LocalStore
import kotlinx.coroutines.launch

/**
 * "Add to" category bottom sheet (it replaced a second-level panel in the long-press menu, which couldn't scroll well with
 * many categories). A Material 3 `ModalBottomSheet` with a drag handle that rests at half height, scrolls its list inside,
 * and drags up to full height; on tablets it is centered and width-limited like the detail sheet.
 * A fixed header row (doesn't scroll with the list): "New Category" on the left (opens the existing category name dialog; the
 * new category includes this account and is already checked), and "Save" on the right; below it, category rows (joined ones
 * in the accent color with a checkmark).
 * Checks are staged in the sheet and committed once on "Save"
 * ([com.gicek.kakey.android.domain.VaultStore.setAccountCategories]); swiping down, tapping the scrim or going back
 * discards them. Unchecking the current category while inside it and saving removes the account from that category.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AddToCategoriesSheet(account: Account, onNewCategory: () -> Unit, onDismiss: () -> Unit) {
    val store = LocalStore.current
    val state by store.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false)
    // Staged check changes: untouched categories show the actual current membership (so a newly created one is checked)
    val staged = remember { mutableStateMapOf<String, Boolean>() }
    fun checked(category: AccountCategory) = staged[category.id] ?: (account.id in category.accountIds)

    fun save() {
        store.setAccountCategories(account.id, state.categories.filter(::checked).map { it.id }.toSet())
        scope.launch { sheetState.hide() }.invokeOnCompletion { onDismiss() }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        dragHandle = { SheetTopBar(onNewCategory = onNewCategory, onSave = ::save) },
    ) {
        Column(Modifier.fillMaxWidth().navigationBarsPadding()) {
            LazyColumn(contentPadding = PaddingValues(vertical = 8.dp), modifier = Modifier.fillMaxWidth().weight(1f, fill = false)) {
                items(state.categories, key = { it.id }) { category ->
                    val member = checked(category)
                    DropdownMenuItem(
                        text = {
                            Text(
                                category.name,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                color = if (member) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                            )
                        },
                        leadingIcon = {
                            Icon(
                                Icons.Outlined.Folder,
                                null,
                                tint = if (member) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        },
                        trailingIcon = {
                            if (member) Icon(Icons.Outlined.Check, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                        },
                        onClick = { staged[category.id] = !member },
                        contentPadding = PaddingValues(horizontal = 24.dp),
                    )
                }
            }
        }
    }
}

/**
 * The sheet's top bar is the drag handle row: "New Category" on the left, "Save" on the right, the handle centered, all on
 * one line with no divider below and no icon on "New Category". The whole row is still draggable.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SheetTopBar(onNewCategory: () -> Unit, onSave: () -> Unit) {
    Box(Modifier.fillMaxWidth().padding(horizontal = 12.dp)) {
        BottomSheetDefaults.DragHandle(Modifier.align(Alignment.TopCenter))
        TextButton(onClick = onNewCategory, modifier = Modifier.align(Alignment.CenterStart)) {
            Text(stringResource(R.string.new_category), maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        TextButton(onClick = onSave, modifier = Modifier.align(Alignment.CenterEnd)) { Text(stringResource(R.string.save)) }
    }
}

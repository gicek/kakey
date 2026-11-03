package com.gicek.kakey.android.ui.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.CreateNewFolder
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.DragHandle
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.gicek.kakey.android.R
import com.gicek.kakey.android.core.AccountCategory
import com.gicek.kakey.android.ui.LocalStore
import com.gicek.kakey.android.ui.components.Segmented
import com.gicek.kakey.android.ui.main.CategoryNameDialog
import com.gicek.kakey.android.ui.main.CategoryPrompt
import com.gicek.kakey.android.ui.main.DeleteCategoryDialog
import com.gicek.kakey.android.ui.main.LocalNavigator
import com.gicek.kakey.android.ui.main.ReorderController
import com.gicek.kakey.android.ui.main.ReorderOverlay
import com.gicek.kakey.android.ui.main.dragHandle
import com.gicek.kakey.android.ui.main.reorderHost
import com.gicek.kakey.android.ui.main.reorderable
import com.gicek.kakey.android.ui.theme.Motion

/**
 * Category management: tap to rename, delete on the right, hold the handle to drag-reorder, add at the bottom right. Deleting
 * a category keeps its accounts.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CategoryManagerScreen() {
    val store = LocalStore.current
    val state by store.state.collectAsStateWithLifecycle()
    val navigator = LocalNavigator.current
    var prompt by remember { mutableStateOf<CategoryPrompt?>(null) }
    var pendingDelete by remember { mutableStateOf<AccountCategory?>(null) }
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()
    // The footnote at the end of the list isn't reorderable: swap targets are limited to the first categories.size items
    val controller = remember(listState) {
        ReorderController.forList(listState, scope, onMove = store::moveCategory, onDrop = store::commitOrder) { state.categories.size }
    }

    Scaffold(
        containerColor = Segmented.background,
        topBar = {
            TopAppBar(
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Segmented.background),
                title = { Text(stringResource(R.string.manage_categories)) },
                navigationIcon = {
                    IconButton(onClick = navigator::pop) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, stringResource(R.string.back)) }
                },
            )
        },
        floatingActionButton = {
            ExtendedFloatingActionButton(
                onClick = { prompt = CategoryPrompt.New() },
                icon = { Icon(Icons.Outlined.CreateNewFolder, null) },
                text = { Text(stringResource(R.string.new_category)) },
            )
        },
    ) { padding ->
        Box(Modifier.padding(padding).fillMaxSize().reorderHost(controller)) {
            LazyColumn(
                state = listState,
                contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 120.dp),
                verticalArrangement = Arrangement.spacedBy(Segmented.Gap),
                modifier = Modifier.fillMaxSize(),
            ) {
                itemsIndexed(state.categories, key = { _, category -> category.id }) { index, category ->
                    CategoryItem(
                        category,
                        handle = Modifier.dragHandle(controller, category.id),
                        onDelete = { pendingDelete = category },
                        modifier = Modifier
                            .animateItem(placementSpec = Motion.shift())
                            .reorderable(controller, category.id)
                            .clip(Segmented.shape(index, state.categories.size))
                            .clickable { prompt = CategoryPrompt.Rename(category) },
                    )
                }
                item {
                    Text(
                        stringResource(
                            if (state.categories.isEmpty()) {
                                R.string.no_categories_yet_create_one_then
                            } else {
                                R.string.tap_a_category_to_rename_it_2b2c
                            },
                        ),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(16.dp),
                    )
                }
            }
            // Overlay following the finger while dragging (the row in the list stays as a faded placeholder)
            ReorderOverlay(controller) { key ->
                state.categories.firstOrNull { it.id == key }?.let { CategoryItem(it, onDelete = null) }
            }
        }
    }
    prompt?.let { CategoryNameDialog(it) { prompt = null } }
    pendingDelete?.let { DeleteCategoryDialog(it) { pendingDelete = null } }
}

/** Category row: drag handle on the left, name and account count, delete on the right (the overlay has no delete button). */
@Composable
private fun CategoryItem(category: AccountCategory, onDelete: (() -> Unit)?, modifier: Modifier = Modifier, handle: Modifier = Modifier) {
    ListItem(
        leadingContent = {
            Icon(Icons.Outlined.DragHandle, stringResource(R.string.drag_to_reorder), handle)
        },
        headlineContent = { Text(category.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        supportingContent = { Text("${category.accountIds.size}") },
        trailingContent = {
            if (onDelete != null) {
                IconButton(onClick = onDelete) { Icon(Icons.Outlined.Delete, stringResource(R.string.delete_category)) }
            }
        },
        colors = ListItemDefaults.colors(containerColor = Segmented.item),
        modifier = modifier,
    )
}

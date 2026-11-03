package com.gicek.kakey.android.ui.main

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.CreateNewFolder
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Inventory2
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.QrCodeScanner
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.PermanentDrawerSheet
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.adaptive.currentWindowAdaptiveInfoV2
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.window.core.layout.WindowSizeClass
import com.gicek.kakey.android.DemoVault
import com.gicek.kakey.android.R
import com.gicek.kakey.android.core.Account
import com.gicek.kakey.android.core.VaultSection
import com.gicek.kakey.android.domain.VaultState
import com.gicek.kakey.android.ui.LocalSnackbar
import com.gicek.kakey.android.ui.LocalStore
import com.gicek.kakey.android.ui.add.LocalAddFlow
import com.gicek.kakey.android.ui.components.Segmented
import com.gicek.kakey.android.ui.components.rememberNow
import com.gicek.kakey.android.ui.detail.AccountDetailSheet
import com.gicek.kakey.android.ui.theme.Motion

/**
 * Main screen.
 * - Phone (compact width): a search bar at the top (with an overflow menu on the right), a category filter strip, a
 *   single-column list, and "Add" at the bottom right.
 * - Tablet: accounts in a card grid (two columns in portrait, three in landscape); on wide screens (≥ 840dp) "All" and each
 *   category are pinned on the left.
 * Rows / cards: tap to copy, long-press for the menu, long-press then drag to reorder (affects only the current section; no
 * reordering while searching). There is no separate reorder mode or swipe-to-delete; delete through the long-press menu or
 * the detail view. Details open from the long-press menu as a bottom sheet.
 */
@Composable
fun HomeScreen() {
    val store = LocalStore.current
    val state by store.state.collectAsStateWithLifecycle()
    val sizeClass = currentWindowAdaptiveInfoV2().windowSizeClass
    val wide = sizeClass.isWidthAtLeastBreakpoint(WindowSizeClass.WIDTH_DP_EXPANDED_LOWER_BOUND)
    val grid = sizeClass.isWidthAtLeastBreakpoint(WindowSizeClass.WIDTH_DP_MEDIUM_LOWER_BOUND)

    var detailId by rememberSaveable { mutableStateOf<String?>(null) }
    var addToId by rememberSaveable { mutableStateOf<String?>(null) }
    var pendingDelete by remember { mutableStateOf<Account?>(null) }
    var prompt by remember { mutableStateOf<CategoryPrompt?>(null) }
    var fabExpanded by rememberSaveable { mutableStateOf(false) }

    val actions = AccountActions(
        showDetail = { detailId = it.id },
        delete = { pendingDelete = it },
        newCategory = { prompt = CategoryPrompt.New(it.id) },
        toggleCategory = { account, category -> store.toggleAccount(account.id, category.id) },
        removeFromSection = state.sectionCategory?.let { category -> { account -> store.toggleAccount(account.id, category.id) } },
        addTo = { addToId = it.id },
        sectionCategory = state.sectionCategory,
    )
    LaunchedEffect(state.accounts.isNotEmpty()) {
        // Debug screenshots: open the first account's detail or the add menu (DemoVault.screen is always null in Release)
        if (state.accounts.isEmpty()) return@LaunchedEffect
        when (DemoVault.screen) {
            "detail" -> detailId = state.accounts.first().id
            "add" -> fabExpanded = true
        }
        DemoVault.clearScreen()
    }

    Row(Modifier.fillMaxSize()) {
        if (wide) {
            Sidebar(state, onNewCategory = { prompt = CategoryPrompt.New() })
        }
        HomeContent(
            state = state,
            grid = grid,
            showChips = !wide,
            actions = actions,
            fabExpanded = fabExpanded,
            onFabExpandedChange = { fabExpanded = it },
        )
    }

    detailId?.let { id ->
        state.account(id)?.let { AccountDetailSheet(it, onDismiss = { detailId = null }) } ?: run { detailId = null }
    }
    addToId?.let { id ->
        state.account(id)?.let { account ->
            AddToCategoriesSheet(account, onNewCategory = { prompt = CategoryPrompt.New(account.id) }, onDismiss = { addToId = null })
        } ?: run { addToId = null }
    }
    prompt?.let { CategoryNameDialog(it) { prompt = null } }
    pendingDelete?.let { account ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text(stringResource(R.string.delete_x, account.issuer)) },
            text = { Text(stringResource(R.string.this_cant_be_undone_make_sure)) },
            confirmButton = {
                TextButton(onClick = {
                    store.delete(account)
                    pendingDelete = null
                }) {
                    Text(stringResource(R.string.delete), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { pendingDelete = null }) { Text(stringResource(R.string.cancel)) } },
        )
    }
}

@Composable
private fun HomeContent(
    state: VaultState,
    grid: Boolean,
    showChips: Boolean,
    actions: AccountActions,
    fabExpanded: Boolean,
    onFabExpandedChange: (Boolean) -> Unit,
) {
    val store = LocalStore.current
    val sectionTitle = state.sectionCategory?.name ?: stringResource(R.string.all)
    Box(Modifier.fillMaxHeight()) {
        Scaffold(
            containerColor = Segmented.background,
            topBar = {
                Column(Modifier.statusBarsPadding()) {
                    SearchBarRow(state)
                    if (showChips && state.accounts.isNotEmpty()) SectionChips(state)
                }
            },
            snackbarHost = { SnackbarHost(LocalSnackbar.current) },
            modifier = Modifier.fillMaxHeight(),
        ) { padding ->
            val now = rememberNow()
            val accounts = state.visibleAccounts
            // Search results aren't a complete section, so they can't be reordered
            val canReorder = state.searchText.isEmpty() && accounts.size > 1
            Box(Modifier.padding(padding).fillMaxSize()) {
                when {
                    state.accounts.isEmpty() -> EmptyVault()
                    accounts.isEmpty() && state.searchText.isNotBlank() -> EmptyMessage(
                        Icons.Outlined.Search,
                        stringResource(R.string.no_matching_accounts),
                        null,
                    )
                    accounts.isEmpty() -> EmptyMessage(
                        Icons.Outlined.Folder,
                        stringResource(R.string.no_accounts_in_x_yet, sectionTitle),
                        stringResource(R.string.long_press_an_account_and_choose),
                    )
                    grid -> {
                        val gridState = rememberLazyGridState()
                        val scope = rememberCoroutineScope()
                        val controller = remember(gridState) {
                            ReorderController.forGrid(gridState, scope, onMove = store::move, onDrop = store::commitOrder)
                        }
                        Box(Modifier.fillMaxSize().reorderHost(controller)) {
                            LazyVerticalGrid(
                                columns = GridCells.Adaptive(300.dp),
                                state = gridState,
                                contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 120.dp),
                                horizontalArrangement = Arrangement.spacedBy(12.dp),
                                verticalArrangement = Arrangement.spacedBy(12.dp),
                            ) {
                                items(accounts, key = { it.id }) { account ->
                                    AccountCard(
                                        account,
                                        now,
                                        actions,
                                        reorder = controller.takeIf { canReorder },
                                        // Rows making way slide once without bouncing; see Motion.shift
                                        modifier = Modifier.animateItem(placementSpec = Motion.shift()).reorderable(controller, account.id),
                                    )
                                }
                            }
                            ReorderOverlay(controller) { key ->
                                accounts.firstOrNull { it.id == key }?.let { AccountCard(it, now, actions, interactive = false) }
                            }
                        }
                    }
                    else -> {
                        val listState = rememberLazyListState()
                        val scope = rememberCoroutineScope()
                        val controller = remember(listState) {
                            ReorderController.forList(listState, scope, onMove = store::move, onDrop = store::commitOrder)
                        }
                        // Segmented list: the whole group is one segmented card with large outer corners, small inner corners
                        // and thin gaps between rows
                        Box(Modifier.fillMaxSize().reorderHost(controller)) {
                            LazyColumn(
                                state = listState,
                                contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 120.dp),
                                verticalArrangement = Arrangement.spacedBy(Segmented.Gap),
                            ) {
                                itemsIndexed(accounts, key = { _, account -> account.id }) { index, account ->
                                    AccountRow(
                                        account,
                                        now,
                                        actions,
                                        reorder = controller.takeIf { canReorder },
                                        modifier = Modifier
                                            .animateItem(placementSpec = Motion.shift())
                                            .reorderable(controller, account.id)
                                            .clip(Segmented.shape(index, accounts.size))
                                            .background(Segmented.item),
                                    )
                                }
                            }
                            ReorderOverlay(controller) { key ->
                                accounts.firstOrNull { it.id == key }?.let {
                                    AccountRow(it, now, actions, interactive = false, modifier = Modifier.background(Segmented.item))
                                }
                            }
                        }
                    }
                }
            }
        }
        AddFabMenu(
            expanded = fabExpanded,
            onExpandedChange = onFabExpandedChange,
            modifier = Modifier.align(Alignment.BottomEnd),
        )
    }
}

/** Top search bar: a pill-shaped field with the overflow menu on the right (Settings, Lock Now, Manage Categories). */
@Composable
private fun SearchBarRow(state: VaultState) {
    val store = LocalStore.current
    val navigator = LocalNavigator.current
    var menu by remember { mutableStateOf(false) }
    Surface(
        shape = CircleShape,
        color = Segmented.item,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).height(56.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(start = 16.dp, end = 4.dp)) {
            Icon(Icons.Outlined.Search, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Box(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                if (state.searchText.isEmpty()) {
                    Text(
                        stringResource(R.string.search_services_or_accounts),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                    )
                }
                BasicTextField(
                    value = state.searchText,
                    onValueChange = store::setSearchText,
                    singleLine = true,
                    textStyle = MaterialTheme.typography.bodyLarge.copy(color = MaterialTheme.colorScheme.onSurface),
                    cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            if (state.searchText.isNotEmpty()) {
                IconButton(onClick = {
                    store.setSearchText("")
                }) { Icon(Icons.Outlined.Close, contentDescription = stringResource(R.string.clear_search)) }
            }
            Box {
                IconButton(onClick = { menu = true }) { Icon(Icons.Outlined.MoreVert, contentDescription = stringResource(R.string.more)) }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.settings)) },
                        leadingIcon = { Icon(Icons.Outlined.Settings, null) },
                        onClick = {
                            menu = false
                            navigator.push(Route.Settings)
                        },
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.lock_now)) },
                        leadingIcon = { Icon(Icons.Outlined.Lock, null) },
                        onClick = {
                            menu = false
                            store.lock()
                        },
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.manage_categories)) },
                        leadingIcon = { Icon(Icons.Outlined.Tune, null) },
                        onClick = {
                            menu = false
                            navigator.push(Route.Categories)
                        },
                    )
                }
            }
        }
    }
}

/** Category filter strip: "All" and each category, ending with an entry to category management. */
@Composable
private fun SectionChips(state: VaultState) {
    val store = LocalStore.current
    val navigator = LocalNavigator.current
    LazyRow(
        contentPadding = PaddingValues(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.padding(bottom = 4.dp),
    ) {
        item {
            FilterChip(
                selected = state.section == VaultSection.All,
                onClick = { store.setSection(VaultSection.All) },
                label = { Text(stringResource(R.string.all)) },
            )
        }
        items(state.categories, key = { it.id }) { category ->
            FilterChip(
                selected = state.section == VaultSection.Category(category.id),
                onClick = { store.setSection(VaultSection.Category(category.id)) },
                label = { Text(category.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
            )
        }
        item {
            AssistChip(
                onClick = { navigator.push(Route.Categories) },
                label = { Text(stringResource(R.string.manage)) },
                leadingIcon = { Icon(Icons.Outlined.Tune, null, Modifier.size(18.dp)) },
            )
        }
    }
}

/** Wide-screen sidebar: "All" and each category (with counts), New Category, and Settings and Lock at the bottom. */
@Composable
private fun Sidebar(state: VaultState, onNewCategory: () -> Unit) {
    val store = LocalStore.current
    val navigator = LocalNavigator.current
    PermanentDrawerSheet(Modifier.width(280.dp), drawerContainerColor = Segmented.background) {
        Column(Modifier.fillMaxHeight().statusBarsPadding().padding(horizontal = 12.dp)) {
            Text("Kakey", style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(horizontal = 16.dp, vertical = 20.dp))
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
                NavigationDrawerItem(
                    label = { Text(stringResource(R.string.all)) },
                    icon = { Icon(Icons.Outlined.Inventory2, null) },
                    badge = { Text("${state.accounts.size}") },
                    selected = state.section == VaultSection.All,
                    onClick = { store.setSection(VaultSection.All) },
                )
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(start = 16.dp, top = 16.dp)) {
                    Text(
                        stringResource(R.string.categories),
                        style = MaterialTheme.typography.titleSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.weight(1f),
                    )
                    IconButton(onClick = { navigator.push(Route.Categories) }) {
                        Icon(Icons.Outlined.Edit, contentDescription = stringResource(R.string.manage_categories))
                    }
                }
                state.categories.forEach { category ->
                    NavigationDrawerItem(
                        label = { Text(category.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                        icon = { Icon(Icons.Outlined.Folder, null) },
                        badge = { Text("${category.accountIds.size}") },
                        selected = state.section == VaultSection.Category(category.id),
                        onClick = { store.setSection(VaultSection.Category(category.id)) },
                    )
                }
                NavigationDrawerItem(
                    label = { Text(stringResource(R.string.new_category)) },
                    icon = { Icon(Icons.Outlined.CreateNewFolder, null) },
                    selected = false,
                    onClick = onNewCategory,
                )
            }
            HorizontalDivider(Modifier.padding(vertical = 8.dp))
            NavigationDrawerItem(
                label = { Text(stringResource(R.string.settings)) },
                icon = { Icon(Icons.Outlined.Settings, null) },
                selected = false,
                onClick = { navigator.push(Route.Settings) },
            )
            NavigationDrawerItem(
                label = { Text(stringResource(R.string.lock_now)) },
                icon = { Icon(Icons.Outlined.Lock, null) },
                selected = false,
                onClick = store::lock,
                modifier = Modifier.padding(bottom = 12.dp),
            )
        }
    }
}

@Composable
private fun EmptyVault() {
    val addFlow = LocalAddFlow.current
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(Icons.Outlined.QrCodeScanner, null, Modifier.size(56.dp), tint = MaterialTheme.colorScheme.primary)
        Spacer(Modifier.height(16.dp))
        Text(stringResource(R.string.no_2fa_accounts_yet), style = MaterialTheme.typography.titleLarge, textAlign = TextAlign.Center)
        Spacer(Modifier.height(8.dp))
        Text(
            stringResource(R.string.scan_the_qr_code_from_a),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(24.dp))
        Button(onClick = addFlow.scan) {
            Icon(Icons.Outlined.QrCodeScanner, null, Modifier.size(18.dp))
            Text(stringResource(R.string.scan_qr_code), Modifier.padding(start = 8.dp))
        }
        OutlinedButton(onClick = addFlow.enterKey, modifier = Modifier.padding(top = 8.dp)) {
            Text(stringResource(R.string.enter_setup_key))
        }
    }
}

@Composable
private fun EmptyMessage(icon: ImageVector, title: String, description: String?) {
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(icon, null, Modifier.size(48.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(12.dp))
        Text(title, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
        description?.let {
            Text(
                it,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }
    }
}

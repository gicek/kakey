// Files are organized by screen: both category dialogs and their shared CategoryPrompt live here, so the file name doesn't match a class
@file:Suppress("MatchingDeclarationName")

package com.gicek.kakey.android.ui.main

import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardCapitalization
import com.gicek.kakey.android.R
import com.gicek.kakey.android.core.AccountCategory
import com.gicek.kakey.android.core.UiText
import com.gicek.kakey.android.core.VaultException
import com.gicek.kakey.android.core.text
import com.gicek.kakey.android.ui.LocalStore
import com.gicek.kakey.android.ui.components.KakeyTextField

/**
 * Category name input: create (optionally adding an account to it) or rename. An invalid name shows the reason under the field
 * without closing.
 */
sealed interface CategoryPrompt {
    data class New(val addingAccountId: String? = null) : CategoryPrompt
    data class Rename(val category: AccountCategory) : CategoryPrompt
}

@Composable
fun CategoryNameDialog(prompt: CategoryPrompt, onDismiss: () -> Unit) {
    val store = LocalStore.current
    var name by remember { mutableStateOf((prompt as? CategoryPrompt.Rename)?.category?.name.orEmpty()) }
    var error by remember { mutableStateOf<UiText?>(null) }
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }

    fun commit() {
        try {
            when (prompt) {
                is CategoryPrompt.New -> {
                    val category = store.createCategory(name)
                    prompt.addingAccountId?.let { store.toggleAccount(it, category.id) }
                }
                is CategoryPrompt.Rename -> store.renameCategory(prompt.category.id, name)
            }
            onDismiss()
        } catch (exception: VaultException) {
            error = exception.text
        }
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(if (prompt is CategoryPrompt.Rename) R.string.rename else R.string.new_category)) },
        text = {
            KakeyTextField(
                value = name,
                onValueChange = {
                    name = it
                    error = null
                },
                label = stringResource(R.string.category_name),
                isError = error != null,
                supportingText = error?.text(),
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
                modifier = Modifier.focusRequester(focus),
            )
        },
        confirmButton = {
            TextButton(onClick = ::commit, enabled = name.isNotBlank()) {
                Text(stringResource(if (prompt is CategoryPrompt.Rename) R.string.done else R.string.create))
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

/** Confirmation before deleting a category: only the category itself is deleted; its accounts stay in "All". */
@Composable
fun DeleteCategoryDialog(category: AccountCategory, onDismiss: () -> Unit) {
    val store = LocalStore.current
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.delete_the_category_x, category.name)) },
        text = { Text(pluralStringResource(R.plurals.the_x_accounts_in_it_wont, category.accountIds.size, category.accountIds.size)) },
        confirmButton = {
            TextButton(onClick = {
                store.deleteCategory(category.id)
                onDismiss()
            }) { Text(stringResource(R.string.delete_category)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

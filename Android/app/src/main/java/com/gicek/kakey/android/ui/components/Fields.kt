package com.gicek.kakey.android.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import com.gicek.kakey.android.R
import com.gicek.kakey.android.core.Core
import com.gicek.kakey.core.CorePasswordStrength

/**
 * The app-wide text field: outlined style, 16dp corners (medium shape scale) and the same container color as segmented cards,
 * so it reads clearly on any background. Every text input (including password fields) goes through here, so the style is
 * defined in one place.
 */
@Composable
fun KakeyTextField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    modifier: Modifier = Modifier,
    placeholder: String? = null,
    supportingText: String? = null,
    isError: Boolean = false,
    enabled: Boolean = true,
    singleLine: Boolean = true,
    minLines: Int = 1,
    maxLines: Int = if (singleLine) 1 else Int.MAX_VALUE,
    textStyle: TextStyle = LocalTextStyle.current,
    visualTransformation: VisualTransformation = VisualTransformation.None,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    keyboardActions: KeyboardActions = KeyboardActions.Default,
    trailingIcon: (@Composable () -> Unit)? = null,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        placeholder = placeholder?.let { { Text(it) } },
        supportingText = supportingText?.let { { Text(it) } },
        isError = isError,
        enabled = enabled,
        singleLine = singleLine,
        minLines = minLines,
        maxLines = maxLines,
        textStyle = textStyle,
        visualTransformation = visualTransformation,
        keyboardOptions = keyboardOptions,
        keyboardActions = keyboardActions,
        trailingIcon = trailingIcon,
        shape = MaterialTheme.shapes.medium,
        colors = OutlinedTextFieldDefaults.colors(
            focusedContainerColor = Segmented.item,
            unfocusedContainerColor = Segmented.item,
            disabledContainerColor = Segmented.item,
            errorContainerColor = Segmented.item,
        ),
        modifier = modifier.fillMaxWidth(),
    )
}

/**
 * Password field: hidden by default, with a trailing button to toggle visibility. The password is not kept in saveable state
 * (never written to the Bundle on process recreation).
 */
@Composable
fun PasswordField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    modifier: Modifier = Modifier,
    isError: Boolean = false,
    enabled: Boolean = true,
    imeAction: ImeAction = ImeAction.Done,
    onDone: () -> Unit = {},
) {
    var visible by remember { mutableStateOf(false) }
    KakeyTextField(
        value = value,
        onValueChange = onValueChange,
        label = label,
        isError = isError,
        enabled = enabled,
        visualTransformation = if (visible) VisualTransformation.None else PasswordVisualTransformation(),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = imeAction, autoCorrectEnabled = false),
        keyboardActions = KeyboardActions(onDone = { onDone() }, onGo = { onDone() }),
        trailingIcon = {
            IconButton(onClick = { visible = !visible }) {
                Icon(
                    if (visible) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility,
                    contentDescription = stringResource(if (visible) R.string.hide_password else R.string.show_password),
                )
            }
        },
        modifier = modifier,
    )
}

/**
 * Set a master password (shared by first run, master password change and export-file restore): entered twice, with a strength
 * bar and rule hints; rules live in the core.
 */
@Composable
fun NewPasswordFields(
    password: String,
    onPasswordChange: (String) -> Unit,
    confirmation: String,
    onConfirmationChange: (String) -> Unit,
    enabled: Boolean = true,
    label: String = stringResource(R.string.new_password),
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        // While typing or pasting, keep only allowed characters (digits, ASCII letters, ASCII symbols) and drop the rest
        // (rules live in the core)
        PasswordField(
            password,
            { onPasswordChange(Core.filterPasswordInput(it)) },
            label,
            enabled = enabled,
            imeAction = ImeAction.Next,
        )
        PasswordStrengthBar(password, Modifier.fillMaxWidth())
        PasswordRequirement(password)
        val mismatch = confirmation.isNotEmpty() && confirmation != password
        PasswordField(
            confirmation,
            { onConfirmationChange(Core.filterPasswordInput(it)) },
            stringResource(R.string.enter_again),
            isError = mismatch,
            enabled = enabled,
        )
        if (mismatch) {
            Text(
                stringResource(R.string.passwords_do_not_match),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.error,
            )
        }
    }
}

/**
 * The line under the new-password strength bar (shared by master and export passwords): under 8 characters shows a gray
 * requirement; long enough but weak shows a red explanation, since weak passwords are rejected (rules in the core); nothing
 * otherwise.
 */
@Composable
fun PasswordRequirement(password: String) {
    when {
        password.length < Core.minPasswordLength -> Text(
            stringResource(R.string.at_least_8_characters),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Core.evaluatePassword(password) == CorePasswordStrength.WEAK -> Text(
            stringResource(R.string.too_easy_to_crack_use_a),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.error,
        )
    }
}

/**
 * Confirmation before submitting a "fair" strength password (weak passwords are rejected outright): master and export
 * passwords share the same text, and submission continues only if the user picks "Use Anyway".
 */
@Composable
fun FairPasswordDialog(onConfirm: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.password_isnt_strong_enough)) },
        text = { Text(stringResource(R.string.a_strong_password_is_recommended_it)) },
        // The primary action is "choose a stronger password", with "Use Anyway" demoted to secondary (matching Apple's default button)
        confirmButton = { Button(onClick = onDismiss) { Text(stringResource(R.string.choose_stronger_password)) } },
        dismissButton = { TextButton(onClick = onConfirm) { Text(stringResource(R.string.use_anyway)) } },
    )
}

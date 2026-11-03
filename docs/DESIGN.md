# Kakey Interaction Design

> Baseline for interaction, settings, and persistence on all platforms; update it with any such change. Scope: [PROJECT](PROJECT.md); security: [SECURITY](SECURITY.md); status: [VALIDATION](VALIDATION.md). Check mobile demo vault screenshots against it (`make ios-screenshots`, `make android-screenshots`).

## Responsibilities

- The core owns normalization, deduplication, search, category and password rules, unlock delays, error classes, sync decisions, and conflict comparison; this document covers each platform's structure and flows.
- Mac: main window, menu bar panel, shortcuts, screen capture scanning, AppleScript. Mobile: one job per screen, all starting from the list.

## Shared Rules

- **Codes**: Atkinson Hyperlegible Mono semibold, only for codes (fallback: system monospaced). One line; names truncate first. The countdown turns red (Mac) or orange (mobile) in the last 5 seconds.
- **Copying**: Tap a row or card. Mac shows "Copied" beside the code (in its place in the menu bar panel); iOS shows a "Copied" toast at the bottom; Android relies on the system confirmation and flashes the row.
- **Badges**: The core's monogram (initials of the first two words, or the first three characters) on one of eight colors chosen by a deterministic hash.
- **New passwords** (create vault, change master password, export, new master password when restoring from an export):
  - Rules come from the core ([SECURITY](SECURITY.md)). Printable ASCII only (other characters dropped as typed or pasted), at most 128 characters. Unlock and import fields aren't filtered.
  - Strength: "Weak", "Fair", "Strong", "Very Strong". "Weak" disables the button. Submitting at "Fair" shows "Password Isn’t Strong Enough" with "Use Anyway" and the default "Choose Stronger Password".
  - Hints sit under their field in reserved space, so nothing moves. Confirmation is checked as you type: no hint while it is a prefix of the new password, a hint as soon as one character is wrong, and a hint on leaving the field if incomplete.
  - With both fields valid, Return triggers the primary button. A failed submission shows its reason under the password field until the password changes.
- **After changing the master password**: With backup on, Kakey syncs and waits ("Updating Backup"). On failure: "Backup not updated" (the new password is in use; the backup still uses the old one).
- **Unlock delays**: Only wrong passwords count; other failures are reported directly.
- **Categories**: "All" first, then user categories (name, count); create, rename, delete, reorder. Names: trimmed, non-empty, at most 40 characters, unique ignoring case. An account can be in several. Deleting keeps the accounts; the confirmation states how many. An empty category shows "No accounts in “X” yet" and how to add some. Each list keeps its own order.
- **Adding inside a category**: New accounts join "All" and the current category, except backup imports (the file's categories) and Mac menu bar or shortcut scans ("All" only).
- **Deduplication**: Shared by adding and importing. A duplicate shows "Account already exists"; an all-duplicate import shows "All accounts in this file already exist".
- **Errors**: Scan and import error classes come from the core; user cancellation shows nothing. Wording lives in the String Catalog.
- **Confirmation**: Deleting an account or category, resetting, turning off backup, unencrypted connections, trusting a certificate.
- **Appearance and language**: Native controls, semantic colors, brand blue accent. Unsupported languages fall back to English; switching applies immediately. Copy rules: [LOCALIZATION](LOCALIZATION.md).

## Settings

| Setting | Mac | iOS / iPadOS | Android | Values and rules |
|---|---|---|---|---|
| Appearance | System | System | System | Light / Dark / System |
| Language | System | System | System (per-app language) | System / English / Simplified Chinese / Traditional Chinese |
| Auto-lock | 5 minutes | 5 minutes | 5 minutes | 1 / 5 / 30 minutes; see below |
| Biometric unlock | Touch ID | Face ID / Touch ID | Strong biometrics | Chosen in onboarding (on when supported). An invalid stored key needs the master password to re-enable |
| Delay after wrong passwords | On (turning off needs verification) | Always on | Always on | Curve in the core |
| Backup location | Not set | Not set | Not set | One at a time |
| Home layout | Cards | — | — | List / Cards (toolbar) |
| Menu bar icon | Shown | — | — | Can't be hidden along with the Dock icon |
| Menu bar accounts | All | — | — | "All" or one category ("All" if it's gone) |
| Dock icon | Only when the main window is open | — | — | "Always Show" / "Only When Main Window Is Open" / "Never Show" |
| Launch at login, background launch only | Off | — | — | Background launch: no main window at launch |
| Global shortcuts | ⌘⌥Z menu bar, ⌘⌥X main window, ⌘⌥A scan screen | — | — | Clearable; apply immediately |
| Third-party plugin interface | Off | — | — | See "External Automation" |

**Auto-lock** counts from the last activity: unlocking, then any touch, click, key press, or scroll in the app. Backgrounding or closing the window isn't activity; if time ran out meanwhile, Kakey locks on return. Device lock locks immediately (Mac: sleep, display off, screen lock, screen saver, user switch; iOS: lock with a passcode; Android: screen off). Changing the duration re-checks against the last activity. Android names biometrics by hardware: "fingerprint" (fingerprint only), "face" (face only), otherwise "biometrics".

## Core Flows

### First Launch

- Welcome: "Protect your 2FA with Kakey" · "Start fresh" · "Restore a backup".
- **Start fresh**: "Set master password", biometrics switch, "Create Vault", and a warning that without the master password, local and backup data can't be decrypted.
- **Restore a backup**: Sources: iCloud, this build's cloud storage, "Other Folder", "Kakey Exported File".
  - Cloud storage uses the connect screen. No backup: "No secure Kakey backup was found in X."; services with folder choice add "Choose Folder".
  - Found: "Backup found", source ("From X" / "From a backup folder" / "From an exported file"), password, biometrics switch, "Unlock & Continue". The ciphertext stays in memory until the original master password opens it; then Kakey saves cloud credentials, writes the vault, and enables the location. If credentials can't be saved, the restore fails and leaves no vault.
  - From an export: "Export Password" with "Use as Master Password" on (turn off to set another). Creates a vault from the file's accounts and categories, with no backup location. Other files show "This file isn’t a Kakey export".
  - After a backup is found, "Change Location" (Mac) or back returns to the location list.

### Locking and Unlocking

- Lock screen: "Kakey is locked" · password · "Unlock" · biometric unlock when on (Mac: "Use Touch ID or enter your master password to unlock"; Android names the sensor, as in "Unlock with fingerprint", and keeps a wrong password in the field).
- Locking is a Hard Lock: clears accounts and keys from memory, closes sheets and dialogs, drops queued external requests.
- Biometrics prompt automatically only on the first lock screen after launch; later locks show the unlock screen with the password focused. Canceling biometrics stops the automatic prompt.
- With biometrics on, a master password unlock saves a device-protected vault key. If it becomes invalid, Kakey falls back to the master password and asks to re-enable biometrics.
- A damaged vault file with an intact snapshot offers "Restore Last Good Copy" (confirm, then master password).
- A wrong master password shows only "Incorrect master password"; any delay countdown appears under the field.

### Backup and Sync

- **Location**: One at a time. Kakey syncs when a location is set or changed, after unlocking, and after saves (edits within 2 seconds combine). iCloud also syncs on silent push (deferred until unlock). "Back Up Now" makes the same decision as automatic sync; a backup changed elsewhere since the last sync becomes a conflict, never an overwrite.
- **Remote folder**: A folder with a Kakey backup, or an empty one (hidden files ignored). "Use “Kakey” Folder" opens or creates `Kakey` in the current folder. Restoring accepts only folders with a backup.
- **This device's key only**: Enabling a location first runs a read-only check and refuses a backup this device's key can't open ("The backup here can’t be opened with this vault’s key."). A remote that changed since the last sync and can't be opened sets "Backup Can’t Be Opened": no upload, download, conflict, or overwrite by "Back Up Now"; only "Restore from Backup" with that backup's password, which replaces the local vault and stays unlocked. An unchanged remote isn't checked, so uploads continue after a local password change.
- **Conflicts**: "Resolve Conflict" shows each side's account count, modified time, and device, and groups "Only on this device" ("Only on this Mac"), "Only in the backup", "Different on both sides" (secrets flagged, never shown); category additions and renames are listed separately. Each choice states its effect:
  - "Merge Both" (default): keeps all accounts; one-sided deletions come back. For each differing account, pick a side (default: the newer save).
  - "Keep This Device’s Copy" ("Keep This Mac’s Copy"): overwrites the backup; counts what the backup loses, gains, and changes.
  - "Use the Backup’s Copy": replaces the local vault; counts what this device loses, gains, and changes; doesn't lock.
  - "Decide Later": leaves the conflict open.
- **Status and history**: Location, account or path, last sync, and the actions that apply ("Back Up Now", "Resolve Conflict", "Restore from Backup"). Conflict orange; failures and "Backup Can’t Be Opened" red. Plain HTTP shows "Unencrypted connection"; a pinned certificate, "Certificate not verified". History keeps 50 entries (Android shows 10): direction, result ("Uploaded" / "Downloaded" / "No changes" / failure), location, trigger, other-device note, time, size. Automatic syncs with no difference aren't recorded; pending states record their outcome once handled.
- **Turning off and switching**: Needs confirmation. Leaving cloud storage revokes authorization in the background (best effort) and deletes local credentials; the remote backup stays. iCloud offers "Turn Off and Keep Backup" and "Turn Off and Delete iCloud Backup" (all devices; on failure Kakey explains and stays on).

### Connecting Cloud Storage

- **Connect screen** (iOS sheet, Android full-height bottom sheet): pairing graphic (Kakey, locked link, service icon) with "Only the encrypted vault is stored in X." (restore: "Kakey only reads your encrypted backup from X.") · form or access scope · three steps that double as progress.
- **Dropbox / OneDrive / Google Drive**: Scope defaults to "Kakey Folder Only" ("Apps › Kakey" or "My Drive › Kakey", created on first access). A build with a full-access key adds "Any Folder", stating that Kakey can read and write the whole drive. Sign-in uses a system browser session; on mobile an installed Dropbox app authorizes first. Closing sign-in returns to the form silently. The app folder enables right after sign-in; "Any Folder" goes to folder selection. Expired sign-in: "Sign in again to keep syncing".
- **WebDAV**: address, username, password; connecting lists the root once. **Nextcloud**: address only; browser sign-in with a waiting state and "Open Browser Again", continuing automatically; back to the form after 10 minutes.
- **Address and certificate**: Scheme optional; a bare IP gets `http://`, a bare domain `https://`. `http://` asks to "Use Unencrypted Connection". An untrusted certificate (such as a self-signed NAS) shows "The server’s certificate can’t be verified" with its SHA-256 fingerprint and "Trust This Certificate". If it later changes, sync fails and asks to set up the location again; no one-click re-trust.

## Mac

### Main Window

- Minimum 880×620. Onboarding and the lock screen have no title (transparent title bar).
- Toolbar: lock · list/cards toggle · search ("Search accounts or sites") · add. ⌘F search, ⌘N add. Search covers names in the selected section; Return copies the first result; Esc clears.
- Sidebar: "Accounts" › "All" (count) · "Categories" + · categories (count). Create via "+" or right-clicking empty space, naming in place; right-click for "Rename" / "Delete Category"; drag to reorder. Bottom: "Export / Import" · "Backup & Sync" (location icon; dot when on: green OK, orange conflict, red failure) · "Settings".
- List row: badge · names · fixed-width code · ring. Cards: adaptive grid, at least 210 pt wide.
- Click copies; hover shows a "Details" info button. Context menu: "Copy code" · "Add to" › categories, "New Category" · "Remove from “X”" (in a category) · "Details" · "Show QR Code" · "Delete".
- Drag to reorder: a stand-in follows the pointer; edges auto-scroll; release inside saves once; outside or Esc reverts.
- Onboarding: left panel with an illustration animation (static with Reduce Motion), name, three security points; right side holds the step (back chevron; restore locations in two columns); footer: primary button only.

### Menu Bar Panel

- Non-activating panel, 310 pt wide (Liquid Glass on macOS 26): search ("Search accounts") · up to 9 rows · status line · footer. Takes keys on open; an outside click or Esc closes it and returns focus to the previous app. Locked: the list blurs under an unlock form.
- After unlocking, search is focused. Click copies; ↑↓ move the highlight; Return copies it (typing highlights the first result).
- Footer: screen capture · scope menu (centered, only with categories) · menu: "Lock" (unlocked only), "Main Window", "Settings", "Quit". The icon's context menu also switches scope ("Show Accounts").
- Closing clears the search, highlight, messages, and unsubmitted password, and pauses countdowns.
- Before onboarding: "Get started with Kakey" and "Open Main Window"; the scan shortcut shows "Set up Kakey first".

### Settings Window

- System Settings style; sidebar: General, Security, Shortcuts, Advanced.
- Locked: Security and Advanced show only "Unlock Kakey to change these settings". Turning off the wrong-password delay and resetting require Touch ID or the system password on the spot.
- Touch ID availability is re-checked when Kakey becomes active. Becoming available while unlocked saves the key at once; becoming unavailable hides the control and keeps the preference.

### Sheets

Add Account, Account Details, Export / Import, Backup & Sync, and Change Master Password share a header (title, mode picker); footers differ.

- **Add Account**: "Scan QR Code" (default) · "Enter Key" · "Paste Links". Scan sources "Select on Screen", "Choose Images", "Use Camera" merge results; multi-part Google migration codes accumulate. Denied camera access opens System Settings. "Paste Links": one `otpauth://` or migration link per line; accepts dropped text or text files. Errors: a red line at the footer's left.
- **Account Details**: large code (click copies) · names (saved by "Done") · category checkmarks (immediate) · "Algorithm", "Added via", "Date Added". "Show Secret" and "Show QR Code" need Touch ID or the system password. Footer: "Delete Account" · "Cancel" · "Done".
- **Export / Import**: "Encrypted Export" (search, "Select All", "Select by Category", strength meter) / "Batch Import" (Kakey export or plain / v3 encrypted Authenticator JSON, picked or dropped). Results: a line at the footer's left (green, secondary, red).
- **Backup & Sync**: off: "Backup is off", "Set Up". On: status card (location, account, "Back Up Now", "Last synced X") and "Backup History"; footer "Change" · "Turn Off Backup" · "Done". Conflicts switch to the conflict view ("This Mac" and "Backup" cards, groups, per-account picker; footer "Decide Later" · "Apply"). Location picker: "Other Folder" ("iCloud Drive or a folder synced by another app"; a parent folder uses its `Kakey/`); iCloud disabled without the capability ("Not available in this build of Kakey").
- **Change Master Password**: "Current Master Password", "New Password", "Confirm New Password"; errors as notices in the content.

### Screen Capture Scanning

Shared by Add Account, the menu bar button, and the shortcut.

- Without Screen Recording permission: "Kakey Needs Permission"; "Open System Settings" attaches a drag guide card to System Settings (drag the app icon into the list); capture continues once granted. Closing the window cancels.
- Locked: Kakey finishes recognition, shows "QR code recognized. Unlock first.", then prompts for Touch ID. Choosing the password opens the main window lock screen; the account is imported after unlocking.

### External Automation

- Alfred `kk <query>`: search calls AppleScript `find accounts` (masked list, no codes, no verification). Return calls `copy code`, which always requires Touch ID or the system password; Alfred shows the code in a notification. Locked: Touch ID prompts directly; only choosing the password brings the main window forward, and the copy completes after unlocking.
- Guidance items: not running, "Press Enter to open Kakey" (search doesn't launch it); switch off, "Press Enter to open Kakey, then turn it on in Settings → Advanced"; Automation denied, "Press Enter to open System Settings and allow Alfred to control Kakey".
- Fixed workflow text is English; results and notifications follow the system language or the workflow variable `kakey_language`.
- On quit, Kakey closes any open sheet first.

## iOS / iPadOS

Compact width: phone layout. Regular width: split layout.

- **List (compact)**: section menu centered in the navigation bar ("All", categories, "Manage"); top right "+" and "⋯" ("Settings", "Lock Now", "Edit"); system search bar. Row: badge · names · large code · ring. Tap copies (haptics); swipe left deletes; long press: "Copy Code", "Account Details", "Add to", "Remove from “X”", "Delete". "Edit" reorders the current section, not while searching. "Manage" opens "Manage Categories".
- **List (regular)**: `NavigationSplitView` sidebar ("All", categories with counts, "New Category"; "Settings" and "Lock Now" at the bottom) · card grid (three columns from 820 pt, else two). Toolbar: search · "+" · "⋯" ("Settings", "Lock Now"). Touch and hold a card to drag; release saves. Keyboard: ⌘F search, ⌘N enter key, ⌘, settings, ⌘L lock. Dropped images or otpauth text are scanned.
- **Adding**: "Scan QR Code" (migration codes continue once complete), "Choose from Photos", "Paste Setup Link", "Enter Setup Key" ("Advanced Options": algorithm, digits, period), "Import Backup File". Results go to a confirmation screen ("Parsed", "Unable to parse") and insert together; backup files import directly.
- **Details** (sheet): large code · names · "Categories" · "Algorithm", "Added via", "Date Added" · "Show Secret", "Export QR Code" (biometrics or passcode) · "Delete This Account".
- **Settings** (sheet): "Security" (biometrics, hidden when unsupported; "Auto-Lock"; "Change Master Password") · "Data" ("Sync & Backup": location, status, actions, "Backup History", "Stop Syncing"; export; import) · "Appearance" (with language) · version with core version, "Reset App" (after confirmation, biometrics or passcode; without a passcode, confirmation only).
- **Platform rules**: While unlocked, the app switcher and background show a privacy cover (a window over sheets); leaving the foreground hides revealed secrets. Copies go only to the local pasteboard and expire. Text, including codes, scales with Dynamic Type. iPhone is portrait only; iPad supports all orientations, Split View, and Stage Manager.

## Android Phones and Tablets

Material 3 with dynamic color, edge-to-edge, predictive back, Expressive shapes and motion.

- **List (phone)**: no app bar; search bar with "⋮" (settings, "Lock Now", "Manage Categories") · category chips ("All", categories, "Manage") · accounts in one segmented card.
  - Tap copies (clip marked sensitive, haptics).
  - Long press opens the menu at the touch point; moving without lifting closes it and starts reordering; release saves once. While searching, long press only opens the menu. Menu: copy, details, "Add to" (bottom sheet), "Remove from “X”", delete.
  - "+" (bottom right) expands over a scrim: "Scan QR Code", "Choose from Photos", "Enter Setup Key", "Import Backup File".
- **List (tablet)**: card grid from 600 dp; from 840 dp a permanent sidebar replaces the chips.
- **Adding**: full-screen scanner (switch to photos), "Choose from Photos" (multi-select), "Enter Setup Key" ("Paste otpauth" / "Manual Entry"; "Advanced Options"), "Import Backup File". Confirmation matches iOS.
- **Details** (bottom sheet): large code (tap copies) · names (edit, then "Done") · category chips · parameters, "Added via", date added · "Show Secret", "Export QR Code" (system verification) · "Delete This Account".
- **Category management**: rename on tap, delete, drag to reorder, "New Category".
- **Settings** (grouped cards): Security (biometrics, hidden without strong biometrics; auto-lock; master password) · "Sync & Backup" (location, status, actions, "Stop Syncing") · "Backup History" (last 10) · Data (export, import, "Reset App") · Appearance (with language) · About.
- **Platform rules**: Material theme colors plus warning orange and success green; badges use the shared palette. dp/sp follow system font scaling. Codes and countdowns never morph. `FLAG_SECURE` is on while the home screen (list and any details sheet) shows. Reset App, after confirmation, requires BiometricPrompt (biometrics or screen lock); with neither, confirmation only.

## Persistence

| Content | Mac | iOS / iPadOS | Android |
|---|---|---|---|
| Vault and snapshot | `~/Library/Application Support/Kakey/vault.json`, `vault.last-known-good.json` | Same in the container's `Library/Application Support/Kakey/` (`.completeFileProtection`) | Same in `files/Kakey/` |
| Biometric key | `biometric-key.json`, same folder (Secure Enclave wrapped) | Keychain | `noBackupFilesDir/Kakey/biometric-key.bin` (Keystore wrapped) |
| Cloud credentials | `cloud-connection.json`, same folder (Secure Enclave wrapped) | Keychain | `noBackupFilesDir/Kakey/cloud-connection.bin` (Keystore encrypted) |
| Backup history | `backup-history.json`, same folder | `backup-history.json`, same folder | `files/Kakey/backup-history.json` |
| Preferences | `UserDefaults.standard` | `UserDefaults` | DataStore |

- Accounts, order, and categories live only in the encrypted payload. Preferences hold only the non-sensitive settings above plus sync markers and the wrong-password count and delay (the menu bar scope is a category ID). History records only time, direction, source, location, device name, size.
- A backup location holds only `vault.kakeyvault` (encrypted envelope) and `vault.metadata.json` (device name, time); iCloud uses one CloudKit private database record (see [TECHNICAL](TECHNICAL.md)).
- The Mac automation filter index (account ID, service, account name) is memory-only: refreshed after vault writes and unlocks, kept through a Hard Lock, cleared on reset or quit.
- Reset deletes the data folder and credentials; remote backups are untouched.

### Limitations

- With the biometric key invalid or unavailable, unlocking needs the master password.
- iCloud needs an iCloud sign-in and a development team in the build; the system decides when pushes arrive. Folder locations depend on their sync client, so transfers aren't immediate.
- A Mac build without a Developer ID certificate is ad-hoc signed and runs only where it was built.

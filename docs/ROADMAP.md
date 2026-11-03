# Kakey Roadmap

> Phases and direction, without dates. Scope and non-goals are in [PROJECT](PROJECT.md), status in [VALIDATION](VALIDATION.md), and near-term work and tech debt in [PLAN](PLAN.md). Shipped features are in the [README](../README.md) and each component's CHANGELOG.

## Phases

| Phase | Status | Deliverables |
|---|---|---|
| Core features | Implemented | Rust shared core; Mac, iOS / iPadOS, and Android apps; backup and sync to all locations with conflict comparison and merging. See the [PROJECT](PROJECT.md) feature matrix |
| **Cross-platform verification (current)** | In progress | All cross-platform and on-device checks pass |
| First public release (Mac) | Not started | Public repository and a notarized Mac download |
| Phase 1: Recovery and security | Partly shipped | Recovery center, configurable clipboard clearing, automatic hiding of sensitive content |
| Phase 2: Import and account management | Not started | Import preview, bulk management, encrypted notes, recently deleted |
| Phase 3: Efficiency and diagnostics | Not started | Advanced search, health check, time diagnostics, menu bar customization |

### Cross-Platform Verification: Exit Criteria

- Each platform creates a vault and exports it; the other two import it, and accounts, categories, and codes match.
- Mac and iPhone sync through iCloud (same Apple Account): a change on one is fetched by the other through a push; alternating offline changes cause a conflict, and each of the three resolutions gives a consistent result on both devices.
- All three platforms sync and restore through the same WebDAV / Nextcloud folder, and, with developer keys configured, through Dropbox, OneDrive, and Google Drive. Android and Mac restore from each other through a synced folder (a cloud drive app or Syncthing).
- After one device changes the master password, the other shows "Backup Can’t Be Opened", and "Restore from Backup" with the new password succeeds.
- Biometric unlock, auto-lock and device-lock locking, the privacy screen / `FLAG_SECURE`, and the sensitive clipboard are verified on real devices for each platform.
- iPhone, iPad, and Android phones and tablets are checked against DESIGN once in light and dark appearance and in all three languages.
- The cross-platform items pending in VALIDATION are cleared, and the baseline docs match the implementation.

### First Public Release (Mac): Exit Criteria

iOS and Android stay development builds; their store release is decided separately (see "Under Consideration").

- Cross-platform verification is complete.
- The repository is public, with CI passing on `main` and private vulnerability reporting enabled.
- The Mac release build is stripped ([PLAN](PLAN.md) #5) and ships the full license texts of its third-party components (#4).
- A Developer ID signed, notarized DMG from `make mac-release` opens on another Mac without a Gatekeeper block, including offline ([VALIDATION](VALIDATION.md)).
- Every cloud provider enabled in the release build has passed its provider review ([DEVELOPMENT](DEVELOPMENT.md)); a provider that hasn't is left out of the release build's developer keys.
- The download location is linked from the README, and the Mac CHANGELOG's `[Unreleased]` section becomes the release version.

## Later Phases

Each item ships, is tested, and can be rolled back on its own, on all three platforms together unless marked otherwise.

### Phase 1: Recovery and Security

- **Vault recovery center**: Mac and iOS already restore the last good copy from the lock screen; Android still needs that entry ([PLAN](PLAN.md) #2). Remaining everywhere: show the snapshot's time and account count; keep the current damaged file before restoring; cover tests for the correct password, a wrong password, a damaged snapshot, and a failed restore write.
- **Configurable clipboard clearing**: clearing times are currently fixed (one period for codes, 60 seconds for secrets and URIs). Target: off / 15 / 30 / 60 seconds, default 30 seconds; one policy for the main window, the menu bar, and mobile; clear only while the clipboard still holds what Kakey wrote; on lock or quit, clear anything Kakey still owns.
- **Automatic hiding of sensitive content**: shipped on mobile. Remaining on the Mac: hide secrets and QR codes as soon as the window loses focus, locks, or closes, and verify identity again to show them.

### Phase 2: Import and Account Management

- **Import preview and conflict handling**: before saving, sort entries into new, duplicate, invalid, and unsupported, with reasons; let the user select entries and fix names, then commit once; canceling writes nothing.
- **Bulk management**: select multiple accounts to add to or remove from a category, export, or delete; destructive actions show how many accounts are affected and ask for confirmation; one in-memory change, one save.
- **Encrypted notes**: an optional note per account, stored only in the encrypted payload; export, import, sync, deduplication, and conflict comparison all handle the field.
- **Recently deleted**: deleted accounts go to a trash inside the encrypted vault for 30 days, where they can be restored or deleted permanently; automatic cleanup runs only while unlocked and after a successful save; exports exclude deleted accounts by default. Design it together with deletion records for sync merging, so that an account deleted on one side doesn't reappear after a merge.

### Phase 3: Efficiency and Diagnostics

- **Advanced search and keyboard control**: local filter syntax such as `issuer:` and `category:`; sort by recently added or by service name; arrow keys to select, Return to copy; no unencrypted persistent index.
- **Vault health check**: look for invalid secrets, duplicate accounts, unusual periods, and empty names; show the state of biometrics, auto-lock, the backup location, and the last successful backup; confirm each fix and create a snapshot first.
- **Time accuracy diagnostics**: show the current TOTP time step and time remaining; when the system clock jumps noticeably, suggest checking automatic date and time; no network time sync.
- **Menu bar quick action customization** (Mac only): the default action and default scope for clicking the menu bar icon, without revealing account names or codes while locked.

## Under Consideration

Ideas only, not scheduled:

- **`cloudset` as its own project**: move it to a separate repository with its own CI and releases. The crate already builds and tests on its own without the host; the steps are in `Core/crates/cloudset/RELEASING.md`. Remaining prerequisite: at least three OAuth providers (Dropbox, OneDrive, Google Drive) verified against the real services. Creating the repository and publishing to crates.io are public actions that need separate confirmation.
- **Mobile store release**: App Store and Google Play signing, review materials, and privacy disclosures, to be decided separately.

## Pending Separate Review

These would change the data model or the security boundary. Each needs an approved proposal (`docs/<TOPIC>.md`) before it can enter a phase:

- **HOTP**: requires a persisted counter and handling for incrementing after copy, failed writes, and counter conflicts across devices. First define the counter commit semantics, the rollback strategy, and the sync merge rules.
- **Recovery key bundle**: a recovery key, generated once and kept offline, that can unlock the vault. It changes the envelope and key management model; threat modeling and a revocation plan come first.

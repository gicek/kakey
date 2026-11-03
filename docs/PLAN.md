# Kakey Work Plan

> A working draft: the current batch, known issues, and tech debt. It can change at any time and isn't a scope commitment. Scope is in [PROJECT](PROJECT.md), phases in [ROADMAP](ROADMAP.md), and status in [VALIDATION](VALIDATION.md).

## Current Batch: Cross-Platform Verification

- Test cross-platform behavior against the cross-platform exit criteria in [ROADMAP](ROADMAP.md): export and import, iCloud, WebDAV / Nextcloud, Dropbox / OneDrive / Google Drive (developer keys required), and synced folders.
- Clear the pending items in VALIDATION one by one; group the items that need a real device (biometrics, camera, iCloud, device lock) by platform.
- Get iOS device and TestFlight signing working (tech debt #9).
- Fix issues found during verification on each platform, and update CHANGELOG and VALIDATION.

## Known Issues and Tech Debt

Both tables share one numbering. Numbers are stable IDs and are never reused. When an item is resolved, delete its row and record the outcome in the matching CHANGELOG or commit message.

### Known Issues

Issues users can notice, or that block the first public release.

| # | Issue | Risk | Direction |
|---|---|---|---|
| 1 | Apple platforms store the wrong-password delay as a deadline (wall clock), so moving the system clock forward skips it; Android uses a monotonic clock | Weakens rate limiting of local brute-force attempts | Change the shared `UnlockLockout` to store total seconds plus a monotonic start, matching Android |
| 2 | Android keeps `vault.last-known-good.json` on every write but has no UI to restore it; Mac and iOS offer "Restore Last Good Copy" on the lock screen | A damaged vault on Android can't be recovered in the app | Add the same lock screen entry on Android, reading the snapshot through the core |
| 3 | Only Mac onboarding follows the new-password confirmation rule in [DESIGN](DESIGN.md); Mac "Change Master Password" and export, iOS, and Android don't | Inconsistent behavior; layout jumps while typing | Apply the Mac onboarding behavior (`PasswordConfirmation` with a reserved-height `FieldMessage`) wherever a new password is set |
| 4 | The apps don't ship the license texts of their third-party components: the Apple apps bundle only the font's OFL text, and Android bundles none | MIT and Apache-2.0 require the license text in binary distributions; blocks the first public release | Generate an acknowledgements file from `THIRD_PARTY_NOTICES.md` and the license texts at build time, bundle it on all platforms, and link it from Settings → About |
| 5 | Mac Release builds aren't stripped (the executable is about 10 MB, about 5.4 MB after `strip -x`) | Larger download; blocks the first public release | Enable `DEPLOYMENT_POSTPROCESSING` / `STRIP_INSTALLED_PRODUCT` in the Release configuration |

### Tech Debt

| # | Debt | Risk | Direction |
|---|---|---|---|
| 6 | `make alfred-workflow` generates `Kakey.alfredworkflow` into the source tree at `Apple/Mac/Resources/` (gitignored), which is then bundled as a resource | Breaks "output goes only to Build/"; building directly in Xcode can bundle a stale or missing file | Generate it in a build phase script into DerivedData and copy it into the bundle |
| 7 | All Apple tests use XCTest | New tests should use Swift Testing | Write new tests with Swift Testing; migrate old tests as they change |
| 8 | The Mac `VaultStore` is only split into extension files by concern; the lock session, account repository, sync, and preferences still share one set of state | Large change surface, hard to test in isolation | Split it into unit-testable components while keeping it the UI's single source of truth |
| 9 | iOS device and TestFlight signing isn't verified | On-device features (iCloud, push, biometrics) and distribution are untested | During cross-platform verification, set `DEVELOPMENT_TEAM` and get `make ios-device-install` working |
| 10 | Android's Expressive motion, FAB menu, and button groups are built in-house from the spec (these APIs are still internal in stable Material 3) | Details may differ from the official implementation | Switch to the official components once Material 3 makes the APIs public |
| 11 | Icon export depends on Pillow in a local `.venv`; there's no in-repo SVG → PNG renderer, and keeping the two master layers consistent is manual | Forgetting to re-render the PNG after a logo change exports the old image | Use system tools (`sips` / Core Image), or render the SVG directly in the script |
| 12 | The Mac screen recording guide card follows the System Settings window by sampling every 120 ms (there's no public notification for another process's window moves) | Bounded polling: correct, but not event-driven | Replace it once a usable event source is found |
| 13 | The language list is hard-coded in more than ten places (Makefile, Android resource generator, Info.plist, `L10n.swift`, Android `LanguageMode`, the Alfred scripts, screenshot scripts) | Adding a language easily misses a place | Derive the lists from `LANGS` or the String Catalog at build time; see [LOCALIZATION](LOCALIZATION.md) for the current checklist |

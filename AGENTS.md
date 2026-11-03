# Kakey Repository Rules

These rules guide the development, testing, and release of the whole project. `CLAUDE.md` only references this file.

## Project Profile

| Dimension | Value |
|---|---|
| Client platforms | macOS, iOS (including iPad), Android (including tablets) |
| Shared core | `Core/` (Rust; UniFFI generates the Swift and Kotlin bindings) |
| Server side | None. Only the backup location a user enables talks to the network (iCloud, WebDAV, Nextcloud, Dropbox, OneDrive, Google Drive) |
| Distribution | Mac: direct download, Developer ID signed and notarized (ad-hoc signed when no certificate is configured). iOS and Android: development builds for now |
| UI languages | `en` (source), `zh-Hans`, `zh-Hant` |
| Minimum OS | macOS 14 (Apple silicon only); iOS / iPadOS 17; Android 13 (API 33) |
| License | MIT. The repository is public: don't commit keys, internal addresses, or personal config |

## Documents

| Content | Location |
|---|---|
| Introduction, shipped features, quick start | `README.md` (current state only: no history, tech debt, or plans) |
| Scope, non-goals, product decisions | `docs/PROJECT.md` |
| Interaction, settings and defaults, persistence | `docs/DESIGN.md` |
| Stack, layers, data contracts, test strategy | `docs/TECHNICAL.md` |
| Security rules and limits | `docs/SECURITY.md` |
| Phases (commitment) · current batch and tech debt (draft) | `docs/ROADMAP.md` · `docs/PLAN.md` |
| Verified and pending-verification status | `docs/VALIDATION.md` |
| Toolchain, build, release | `docs/DEVELOPMENT.md` |
| Localization contract and glossary | `docs/LOCALIZATION.md` |
| Topic designs | `docs/<TOPIC>.md` while a proposal is open; once implemented, fold it into the docs above and delete it |
| Platform-specific implementation | `Core/docs/`, `Apple/Mac/docs/`, `Apple/iOS/docs/`, `Android/docs/` (`TECHNICAL.md`) |
| User-visible changes | Each component's `docs/CHANGELOG.md`, by version (Keep a Changelog) |
| Behavior baseline shared by all platforms | `Core/golden/` |

Current-state documents describe the project as it is: rewrite text when things change instead of appending history, and give decisions a reason; git history and the changelogs record when things changed. Precedence when documents conflict: PROJECT → DESIGN → TECHNICAL / SECURITY → ROADMAP. Read them in that order before changing scope, interaction, or architecture, and fix the lower document in the same change.

## Scope

The current scope is the shipped feature set in README plus the current and later phases in `docs/ROADMAP.md`; ROADMAP's wording is the acceptance criterion.

**Out of scope** (change `docs/PROJECT.md` and `docs/ROADMAP.md` and get approval first): a Kakey account or app server sync, telemetry, browser extensions and web autofill, system-level one-time code autofill, home screen / desktop widgets, an Apple Watch client, in-app update checks, and proprietary code algorithms such as Steam or Battle.net. HOTP and recovery key bundles need their own review and must not be added along the way.

## Fixed Names

| Item | Name |
|---|---|
| Core workspace | `Core/`: `kakey-core` (pure logic), `kakey-ffi` (UniFFI boundary), `cloudset` (cloud storage protocols, independent of Kakey), `uniffi-bindgen` (tool); Kotlin binding package `com.gicek.kakey.core` |
| Xcode project | `Apple/Kakey.xcodeproj`, generated from `Apple/project.yml` |
| macOS | Target and scheme `Kakey` (`Apple/Mac`), tests `KakeyTests` (`Apple/Mac/Tests`); URL scheme `kakey://`; AppleScript dictionary `Apple/Mac/Resources/Kakey.sdef` |
| iOS / iPadOS | Target and scheme `KakeyMobile` (`Apple/iOS`, tests `Apple/iOS/Tests`); product and module name `Kakey` |
| Apple shared code | `Apple/Shared/` (models, core wrapper `Services/CoreBridge.swift`, `L10n`, String Catalog); platform-only code stays in `Apple/Mac/` or `Apple/iOS/` |
| Android | `Android/`, single module `:app`; Kotlin package `com.gicek.kakey.android` (`core/`, `domain/`, `data/`, `platform/`, `ui/<feature>/`) |
| Bundle ID / applicationId | `com.gicek.kakey` on every platform. Apple tests run in the `Test` configuration with test host `com.gicek.kakey.testhost`; don't make it match the app, or single-instance handling blocks the tests |

Design masters live in `design/`. App icons, brand icons, and DMG art are exported from them with `make icons`; never edit the exported files by hand.

## Build Output

- Build, test, run, and release through the root `Makefile`; `make help` lists every command.
- All caches and products go in `Build/<component>/` (layout in `docs/DEVELOPMENT.md`). Don't add `.build`, `DerivedData`, `dist`, `target`, `.gradle`, or `build` in the source tree. `make clean` deletes `Build/` and any stray output.
- Logs written by make targets go to `Build/Logs/`. Ad-hoc logs, scripts, and screenshots from manual or AI work go to `Build/Scratch/`, never to the `Build/` root or the source tree.
- Machine-private config goes in `local.mk` (template `local.mk.example`); cloud backup developer keys go in `cloud-keys.toml` (template `cloud-keys.example.toml`). Neither is committed.
- `Apple/project.yml` is the source of the Xcode project. After changing targets, build settings, source paths, or package dependencies, run `make project` and commit the generated project. Don't edit `project.pbxproj` by hand.
- The version is defined only in `Apple/project.yml` (`MARKETING_VERSION`, and `CURRENT_PROJECT_VERSION` bumped with `make bump-build` on release); Android reads the same values.
- After every code change, build the full product with `make mac` (or the matching platform target), not just a syntax check. Don't launch the app unless asked.

## Architecture Rules

- **Core logic lives once, in `Core/`**: TOTP, Base32, otpauth and migration code parsing, field normalization and deduplication, category rules, vault and export encryption, Authenticator import, search and masking, password rules, unlock delays, sync decisions and conflict merging, and cloud storage protocols. Platforms do only IO (files, HTTP execution, CloudKit), Keychain / Keystore, biometrics, camera, clipboard, and UI; their services are thin wrappers.
- **No migration code before the first public release**: stored values, file formats, and settings keys accept only the current form. Anything unreadable falls back to its default or is treated as corrupt. A format change updates the golden samples in the same commit.
- **Golden vector discipline**: `Core/golden/` is the behavior baseline that Rust and every platform test read. Changing observable behavior updates the implementation, the golden entries, and `Core/docs/CHANGELOG.md` in the same commit. Never edit golden files just to make a test pass.
- Changing the `kakey-ffi` interface regenerates the bindings in the same commit, and every platform must still build. The FFI boundary never panics; slow calls such as Argon2id run off the main thread.
- Apple: MVVM. View (SwiftUI) → `VaultStore` / `MobileVaultStore` (the single source of truth) → Services. The AppKit shell only assembles `NSStatusItem`, `NSPanel`, and the settings window. Swift 6 strict concurrency: UI types are `@MainActor`, background work uses `Task` and async/await, no new GCD.
- Android: `VaultStore` (StateFlow) is the single source of truth; `data/` and `platform/` are injected through interfaces.
- Inject clocks, storage, and system services through interfaces so failure paths are testable. Prefer native components and system semantic colors; don't hard-code colors; check both light and dark appearance.

## Security

- Before touching encryption, key derivation, locking, import / export, sync, networking, or automation interfaces, read `docs/SECURITY.md` and check each rule. Any relaxation is justified in SECURITY and in the commit message.
- The master password and TOTP secrets never reach disk in plaintext and never appear in logs. Only the backup module sends network requests, only to the storage the user chose, and cloud storage requests are built only by the core. Don't add any other network feature.
- Keys, signing material, notarization credentials, and `cloud-keys.toml` are never committed.
- Computational parameters read from files (KDF parameters, entry counts, and so on) pass an upper-bound check first; the limits are core constants listed in SECURITY.
- Pin versions when adding a dependency, and update `THIRD_PARTY_NOTICES.md` in the same change (plus the stack table in `docs/TECHNICAL.md` when a dependency is added or removed). Don't copy, link, or derive from GPL code. After adding or upgrading a Rust dependency, run `make core-audit`; record ignored advisories in `Core/deny.toml` with a reason and date.

## Localization

- All user-visible text goes through `L10n.tr` / `L10n.format` (Android: `R.string`) with the English source string as the key. Contract, style, and glossary: `docs/LOCALIZATION.md`.
- `Apple/Shared/Resources/Localizable.xcstrings` is the single source for all three languages; Android `strings.xml` is generated into `Build/` and isn't committed. Add or remove strings in all three languages in the same commit.
- `make test-mac`, `test-ios`, and `test-android` run `scripts/i18n-guard.py` first. A guard failure is a test failure; don't skip it.

## Tests and Definition of Done

- Logic changes (TOTP, parsing, encryption, locking, deduplication, categories) get Rust tests in `Core/`; platforms test only their wrappers and integration. Run `make test` before committing.
- **Tests never touch the real Keychain / Keystore, UserDefaults / DataStore, or system state**: inject in-memory implementations. Anything that needs a real device or manual check goes into `docs/VALIDATION.md` as pending.
- Judge success by the tool's result line (`** TEST SUCCEEDED **` / `** TEST FAILED **`, `BUILD SUCCESSFUL` / `BUILD FAILED`), not by the exit code after a pipe.
- Interaction or persistence changes update `docs/DESIGN.md`; protocol or data contract changes update `docs/TECHNICAL.md`. For string-only changes, run the matching `make test-<platform>`.

## AI Collaboration

- Don't commit unless explicitly asked. One logical change per commit, Conventional Commits `<type>(<scope>): <summary>` in imperative mood; the build must pass first.
- Proposals that change product scope, the security model, or architecture start as `docs/<TOPIC>.md` registered in ROADMAP, and are implemented only after approval.
- Record the reason for decisions, removals, and default changes.
- When confidence is low or something is ambiguous, list the options and let the user choose.
- Suggest a cleanup pass to the user at natural checkpoints: when a feature or a PLAN batch is finished, or after a long stretch of changes. Cover architecture drift, code defects and tech debt, a review of recently shipped features, doc tightening, and folding implemented topic docs into the baseline docs. Propose the items; don't start the cleanup without approval.

## Project-Specific Decisions

- **The Mac target is `Kakey`, not `KakeyMac`**: renaming it would change the module name and the shipped app's process name.
- **All platforms share one bundle ID** (`com.gicek.kakey`, no `.mac` suffix).
- **A few String Catalog keys are semantic**: core error codes (`err.*`, `otp.err.*`) and backup history source keys (`icloud.hist.*`, `icloud.manual_backup`). The core returns only the key, and renaming a history key would make existing history entries unreadable.
- **No local Swift package**: a SwiftPM `binaryTarget` can only reference paths inside the package, while build products must stay in `Build/`. `project.yml` links `Build/Core/apple/KakeyCore.xcframework` directly and compiles the generated bindings into the app targets.
- **`make mac` doesn't regenerate the Xcode project**: the xcodeproj is committed so different XcodeGen versions don't rewrite it on every build. CI regenerates it with a pinned version and fails on any difference.
- **`Apple/Mac/Resources/Kakey.alfredworkflow` is generated inside the source tree** (gitignored; `make clean` removes it) because it is bundled as an app resource. Registered as tech debt.
- **Android instrumented tests touch the app's real sandbox** (`make test-android-device`): they run inside the app process on a device, so they use the real `files/Kakey/`, DataStore, and Keystore. This is the only exception to the test isolation rule; it covers UI flows only, clears the sandbox through the app's reset path before and after each test, and isn't part of `make test` or CI. Details in `Android/docs/TECHNICAL.md`.

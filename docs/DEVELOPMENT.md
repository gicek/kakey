# Kakey Development Guide

> From clone to build, test, signing, and release. Run every command from the repository root. Repository rules are in [AGENTS](../AGENTS.md); verification status is in [VALIDATION](VALIDATION.md).

## Requirements

An Apple silicon Mac is the recommended development machine. The Apple apps need one, and the Makefile and the Android JVM tests assume a macOS host (the tests load the macOS build of the core).

| Tool | Version | Used for |
|---|---|---|
| macOS + Xcode | Apple silicon; Xcode 26.5 | Building and testing both Apple apps (CI uses `macos-26` with Xcode 26.5) |
| Rust | Pinned by `Core/rust-toolchain.toml` (1.97.1 plus four cross-compilation targets) | The shared core. Once [rustup](https://rustup.rs) is installed, the first cargo run installs the toolchain |
| cargo-deny | 0.20.2 (`cargo install cargo-deny --locked --version 0.20.2`) | The license check in `make test-core` (skipped locally when missing, always run in CI) and `make core-audit` |
| XcodeGen | 2.45.4 (`brew install xcodegen`) | Only for `make project` after editing `Apple/project.yml` |
| JDK | 21 (`brew install openjdk@21`) | Android. The Makefile uses `JDK_HOME`, then `JAVA_HOME`, then Homebrew's `openjdk@21` |
| Android SDK / NDK | Platform 37 (package `platforms;android-37.0`), build-tools 36; the NDK is the highest version in the SDK or `ANDROID_NDK_HOME` (CI uses 29.0.14206865) | Android. The SDK location comes from `ANDROID_HOME`, default `~/Library/Android/sdk` |
| cargo-ndk | 4.1.2 (`cargo install cargo-ndk --locked --version 4.1.2`) | Building the core `.so` for Android |
| Python 3 | Ships with macOS | Build, test, and localization scripts use only the standard library |
| `.venv` (optional) | `requirements-dev.txt` pins Pillow, dmgbuild, and their dependencies | Only for `make icons` and Mac DMG packaging: `python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt` |

You only need the tools for the platform you work on: Xcode and Rust for Mac / iOS; Rust, the JDK, the SDK / NDK, and cargo-ndk for Android.

## First Build

```sh
make mac             # Build/macOS/Debug/Kakey.app
make ios-simulator   # iOS simulator build
make android         # Build/Android/Debug/Kakey-<version>.apk
make test            # all tests
```

Each platform target builds the core automatically. Without `cloud-keys.toml` everything still builds; Dropbox, OneDrive, and Google Drive are just hidden (see "Cloud Developer Keys").

## Common Commands

`make help` lists every target by component. The descriptions come from the `## comment` at the end of each target line, and `##@` lines are group headings; follow the same pattern when adding a target. Common ones:

| Command | What it does |
|---|---|
| `make build` / `make test` | Build all components / run all tests (core, Mac, iOS, Android). Run `make test` before every commit |
| `make mac` / `make mac-run` | Mac Debug build / build and launch |
| `make ios-simulator-run` | Build and run in the simulator (`IOS_SIMULATOR='<name>'` overrides the default first iPhone) |
| `make ios-device-install` | Install on a physical device (needs `DEVELOPMENT_TEAM`; `DEVICE=<identifier>` picks one device, see `xcrun devicectl list devices`) |
| `make android-install` | Build and install on the connected device (`SERIAL=<serial>`) |
| `make test-android-device` | Android instrumented tests (need a device; not part of `make test` or CI; see [Android TECHNICAL](../Android/docs/TECHNICAL.md)) |
| `make ios-screenshots` / `make android-screenshots` | Capture each screen × light/dark × three languages from the Debug demo vault (on iOS, `DEVICES=iphone\|ipad` captures one device type) |
| `make core-audit` | RustSec advisory check (needs network). Run it after adding or upgrading a Rust dependency |
| `make cloud-config` | Validate `cloud-keys.toml` and print the OAuth callback URLs to register |
| `make icons` | Export app icons, brand icons, and DMG art from `design/` (see "Icons") |
| `make project` / `make bump-build` | Regenerate the Xcode project / increment the build number |
| `make clean` | Delete `Build/` and stray build output in the source tree |

- Builds pass `-quiet` by default. For full output, run `make mac XCODEBUILD_FLAGS=`.
- The core always builds in Release: in Debug, the 64 MiB Argon2id takes several seconds.

## Working in Xcode and Android Studio

- Xcode: run `make alfred-workflow core-apple` before opening `Apple/Kakey.xcodeproj` (scheme `Kakey` or `KakeyMobile`). GUI builds use the default DerivedData and don't interfere with command-line builds.
- Android Studio: run `make core-android` before opening `Android/`.
- Don't edit `project.pbxproj` by hand. After changing `Apple/project.yml`, run `make project` and commit the generated project.

## Tests

- Judge results only by the result line: `** TEST SUCCEEDED **` / `** TEST FAILED **`, or `BUILD SUCCESSFUL` / `BUILD FAILED` for Gradle.
- `make test-mac` / `test-ios` / `test-android` run the localization guard `scripts/i18n-guard.py` first (see [LOCALIZATION](LOCALIZATION.md)).
- Mac and iOS tests always use the `Test` configuration (host bundle ID `com.gicek.kakey.testhost`), so they run even while Kakey is open. Tests are always ad-hoc signed, without iCloud.
- If you suspect the Gradle cache on Android, add `GRADLE_ARGS=--rerun-tasks`.

Style checks run with the tests and fail on any warning:

- Swift: `swift-format` (bundled with Xcode), rules in the root `.swift-format`. `make lint-swift` runs before `test-mac` / `test-ios`. To fix automatically: `xcrun swift-format format -i --recursive Apple/Mac Apple/iOS Apple/Shared`.
- Kotlin: ktlint (`Android/.editorconfig`; fix automatically with `make android-format`), detekt (`Android/detekt.yml` lists only the differences from the default config; individual exceptions use `@Suppress` with a reason), and Android Lint (warnings fail the build, no baseline; checks that don't apply are disabled in `Android/app/lint.xml` with a reason). Reports go to `Build/Android/Gradle/app/reports/`.

## Build Output

Everything goes under `Build/`, one directory per component; `make clean` deletes it along with any stray output in the source tree. The `Debug/` and `Release/` directories hold only the finished product. For Apple platforms that is a relative symlink to the app inside DerivedData, so Launch Services sees a single copy of the app.

```text
Build/
  Core/          target/ (cargo)  apple/ (KakeyCore.xcframework, KakeyCore.swift)  android/ (jniLibs/, kotlin/, host/)
  macOS/         Debug/Kakey.app  Release/Kakey.app  Dist/Kakey-<version>.dmg (.env)  DerivedData/  Tests/
  iOS/           Simulator/Debug/Kakey.app  Device/Debug/Kakey.app  (each with DerivedData/, Simulator/ also Tests/)
  Android/       Debug/Kakey-<version>.apk  Release/Kakey-<version>.{apk,aab}, -mapping.txt  Gradle/ (Gradle output and reports)
  Screenshots/   ios/  android/
  Logs/          logs written by make targets
  Scratch/       ad-hoc files from manual work; safe to delete
```

The Mac release build's dSYM is next to the app in `Build/macOS/DerivedData/Build/Products/Release/`.

## Local Configuration

Copy `local.mk.example` to `local.mk` (not committed). Every setting is optional; with none of them, you can still build, test, and run locally:

| Variable | Purpose |
|---|---|
| `CODE_SIGN_IDENTITY` | Developer ID Application certificate name (`Developer ID Application: <Name> (<TEAMID>)`). When unset, the Mac app is ad-hoc signed and only runs on the build machine |
| `NOTARY_PROFILE` | Keychain profile name saved by `xcrun notarytool store-credentials`. When set, the release is notarized and stapled; requires `CODE_SIGN_IDENTITY` |
| `MAC_DEVELOPMENT_TEAM` | Team ID for Mac signing. When set, Mac builds include the iCloud and push entitlements |
| `DEVELOPMENT_TEAM` | Team ID for iOS device and TestFlight signing. When set, device builds include iCloud and push |
| `ANDROID_KEYSTORE`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | Android release signing. Keep the keystore outside the repository |

### iCloud and Signing

iCloud and push are restricted entitlements that must be signed with a provisioning profile, so only builds with a development team enable them. The Makefile overrides the `KAKEY_*` variables from `Apple/project.yml` on the command line, switching to a development certificate, `KakeyICloud.entitlements`, and the container `iCloud.com.gicek.kakey`. It also writes the container to `KakeyICloudContainer` in Info.plist, which the app reads to decide whether iCloud is available. Debug builds use the CloudKit Development environment; Release builds use Production.

One-time setup (Apple Developer → Certificates, Identifiers & Profiles; `xcodebuild` can create profiles automatically but can't enable capabilities on an App ID):

1. Identifiers → iCloud Containers: create `iCloud.com.gicek.kakey`.
2. Identifiers → App IDs: explicit `com.gicek.kakey`, with iCloud (Include CloudKit support) and Push Notifications checked.
3. In that App ID's iCloud configuration, select the container `iCloud.com.gicek.kakey`.
4. `make mac` / `make ios-device` create the profiles automatically. Confirm the container and `aps-environment` with `codesign -d --entitlements - Build/macOS/Debug/Kakey.app`.

In CloudKit Console, the Development schema is created automatically on the first save (record type `Vault`). Before a release, run "Deploy Schema Changes" to Production, or writes from release builds fail.

### Cloud Developer Keys

Dropbox, OneDrive, and Google Drive need a public client registered in each provider's console (PKCE only, no client secret). Copy `cloud-keys.example.toml` to `cloud-keys.toml` in the repository root (gitignored), then run `make cloud-config` to validate it and print the callback URLs to register. Without this file, those three providers are hidden on all platforms; WebDAV and Nextcloud are unaffected.

- **Dropbox** (App Console): Scoped access, App folder type, named Kakey. Permissions `files.metadata.read`, `files.content.read`, `files.content.write`, `account_info.read`. Put the App key in `dropbox.app_key`. To allow any folder, create a second app of type Full Dropbox and put its key in `full_app_key`.
- **Microsoft** (Entra app registration): audience "Accounts in any organizational directory and personal Microsoft accounts". Platform "Mobile and desktop applications", with the redirect URI `msal<client id>://auth` printed by `make cloud-config`. Turn on "Allow public client flows". Delegated permissions `offline_access`, `User.Read`, `Files.ReadWrite.AppFolder` (plus `Files.ReadWrite` when `full_access = true`); none need admin consent.
- **Google** (Google Cloud Console): enable the Google Drive API. Add `.../auth/drive.file` to the OAuth consent screen (plus the restricted `.../auth/drive` when `full_access = true`), and add your account as a test user while testing. Under Credentials, create an OAuth client of type "iOS" with Bundle ID `com.gicek.kakey`, and put the client ID (`<digits>-<letters>.apps.googleusercontent.com`) in `google.client_id`. Mac, iOS, and Android share this one client; the callback is `com.googleusercontent.apps.<id>:/oauth2redirect`, printed by `make cloud-config` (Google doesn't allow custom schemes for Android-type clients).

Before a public release, each provider needs approval:

- **Dropbox**: development mode allows at most 50 users; beyond that the app needs Production approval, and the Full Dropbox app behind "Any Folder" needs its own review.
- **Microsoft**: publisher verification, or the consent screen shows the app as unverified.
- **Google**: a home page and privacy policy URL on the consent screen, and brand verification; until then the app is limited to 100 test users and shown as unverified. `drive` ("Any Folder") is a restricted scope that needs an annual third-party CASA security assessment, so `full_access` stays off by default and open only to test users until then.

The Makefile passes the file path to the core build through `KAKEY_CLOUD_CONFIG`, and the callback schemes in the Android manifest and iOS Info.plist are generated from the same file. Plain cargo or Xcode builds don't set this variable, so every OAuth provider is hidden, and `cargo test` doesn't depend on local keys.

## Icons

The masters live in `design/`. Exported results are committed; never edit the asset catalogs, `mipmap-*`, or `design/dmg/` by hand:

- `design/logo/`: SVG sources (`kakey-logo-1024-transparent.svg` for the mark, `kakey-logo-background.svg` for the full-bleed background, `kakey-logo-1024-menubar.svg` for the menu bar template) and the 1024 px PNGs the export scripts actually read (`kakey-logo-1024-background.png`, `kakey-logo-1024-transparent.png`). The repository has no SVG-to-PNG renderer: after editing an SVG, re-export the PNG with a vector tool and commit it. The menu bar template is copied as SVG.
- `design/brands/`: brand icons for backup locations (24×24 viewBox, only `<path>` elements with `fill`).
- `design/dmg/`: the DMG window background and volume icon (exported).

`make icons` (needs `.venv`) runs each platform's `scripts/export-app-icon.py` (Mac rounded plate and every size; iOS AppIcon without alpha and the transparent BrandMark; Android adaptive icon foreground and monochrome layer), then `Apple/Mac/scripts/export-dmg-art.py` and `scripts/export-brand-icons.py` (which generates `Apple/Shared/Resources/Brands.xcassets` and the Android `res/drawable/brand_*.xml`).

## Versioning

`MARKETING_VERSION` (semantic) and `CURRENT_PROJECT_VERSION` (build number) are defined only in `Apple/project.yml`. Info.plist references the variables, and Android reads `versionName` / `versionCode` from the same place. Run `make bump-build` before a release. The core version (`Core/Cargo.toml`) is separate; see [TECHNICAL](TECHNICAL.md).

## Releasing the Mac App (Maintainers)

The distribution is a DMG: volume name `Kakey`, containing `Kakey.app` and an alias to `/Applications`. `Apple/Mac/scripts/make-dmg.sh` builds it with dmgbuild (UDZO, HFS+) and writes the window layout straight into `.DS_Store`, so it needs no Finder automation permission. The window size and icon positions are in `dmg-settings.py` and must match the background drawn by `export-dmg-art.py`.

- `make mac-dist`: Release build plus DMG, signed the same way as `make mac`. For trying an install locally.
- `make mac-release`: `make test` → `make bump-build` → build and sign → DMG (signed and timestamped when `CODE_SIGN_IDENTITY` is set) → notarize and staple the DMG when `NOTARY_PROFILE` is set (only the outer DMG is submitted; the notary service registers the app inside it too) → write the `.env`.

`local.mk` decides how the app is signed:

| Configuration | Result |
|---|---|
| `CODE_SIGN_IDENTITY` + `MAC_DEVELOPMENT_TEAM` | Archived and exported with `developer-id`, with iCloud (Production) and push. Use this for public releases |
| `CODE_SIGN_IDENTITY` only | Release build re-signed with Developer ID and the Hardened Runtime, without iCloud (re-signing can't keep restricted entitlements) |
| Neither | Ad-hoc; runs only on the build machine |

Before a release, move `[Unreleased]` in `Apple/Mac/docs/CHANGELOG.md` into a version section, check README "Features", and tag `v<MARKETING_VERSION>`. Publish the DMG to the chosen download location and link it from the README.

## Releasing the Android App (Maintainers)

`make android-release` builds the release APK and AAB (R8 plus resource shrinking; the merged manifest goes through the network permission check first):

- `Build/Android/Release/Kakey-<version>.apk`: for installing locally to verify (`adb install -r`).
- `Build/Android/Release/Kakey-<version>.aab`: for store upload.
- `Build/Android/Release/Kakey-<version>-mapping.txt`: the R8 mapping; keep it with each release.

Signing reads the four `ANDROID_*` variables from `local.mk` and passes them as Gradle properties; nothing goes into committed files. Without them, the build is signed with the debug keystore and prints a notice. Such a build is only for local verification and must not be distributed.

Steps: `make test` → `make test-android-device` → `make bump-build` → `make android-release` → on a real device, create a vault, add an account, lock and unlock → move `[Unreleased]` in `Android/docs/CHANGELOG.md` into a version section → upload the AAB manually. CI runs `make android-release` on every run, so R8 stripping JNA or the bindings shows up there.

iOS has no release process yet.

## Troubleshooting

- Edited `Apple/project.yml` without running `make project`: builds still use the old project, and the CI `project` job fails. If your local XcodeGen version differs from CI, `make project` may rewrite the whole `project.pbxproj`; switch to 2.45.4 first.
- The Mac app must be launched as a `.app`: drag and drop, the URL scheme, and single-instance handling depend on the bundle's Info.plist.
- `make test-android-device` ends with Gradle uninstalling the app. Run `make android-install` before continuing manual checks.

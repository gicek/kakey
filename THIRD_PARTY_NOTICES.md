# Third-Party Notices

This file lists every third-party dependency Kakey uses and its license. When a dependency changes, update its version, license, source, purpose, and removal plan here; when one is added or removed, also update the tech stack table in [`docs/TECHNICAL.md`](docs/TECHNICAL.md). Unless noted otherwise, no source code has been modified.

## KeyboardShortcuts

- Source: https://github.com/sindresorhus/KeyboardShortcuts
- Pinned version: 3.0.1 (revision `49c3fc04ea827f816df67843bfcc57286b47ff06`), declared in `Apple/project.yml` as `exactVersion: "3.0.1"` and fixed by `Package.resolved`
- Integration: Swift Package Manager
- License: MIT (© Sindre Sorhus)
- Purpose: registration, recording UI, and persistence for the three global shortcuts (open the menu bar panel, open the main app, scan a QR code from the screen)
- Platforms: macOS
- Removal plan: used only in `Apple/Mac/Services/AppShortcutNames.swift`, `AppShortcutListener.swift`, `Apple/Mac/Views/PreferencesView.swift`, and `VaultStore`; can be replaced with an implementation based on Carbon `RegisterEventHotKey`

## Atkinson Hyperlegible Mono (Font)

- Source: https://github.com/googlefonts/atkinson-hyperlegible-next-mono (distributed through the Google Fonts repository as `ofl/atkinsonhyperlegiblemono`)
- Pinned version: the variable font `AtkinsonHyperlegibleMono[wght].ttf` (weight axis 200–800) from upstream commit `154d50362016cc3e873eb21d242cd0772384c8f9`, committed as `Apple/Shared/Resources/Fonts/AtkinsonHyperlegibleMono-Variable.ttf`, SHA-256 `5ce8b1698d1ded7dff2178c1a3ad159470085a58ea239e8b2cb88f4fb4a6f646`
- Integration: the font file is bundled with the apps; the Apple apps also bundle the full license text `AtkinsonHyperlegibleMono-OFL.txt`
- License: SIL Open Font License 1.1 (Copyright 2020-2024 The Atkinson Hyperlegible Mono Project Authors). It may be distributed with software; the font is not sold on its own, and a modified version may not use the Reserved Font Name
- Purpose: digits of verification codes only, to make 0/O, 1/l, 3/8, and 6/8 easier to tell apart; the font is unmodified
- Platforms: Mac, iOS / iPadOS, Android (the same file)
- Removal plan: on Apple, used only in `Apple/Shared/Utilities/CodeFont.swift`; after the font file is deleted, `CodeFont` falls back to the system monospaced font

## Backup Location Brand Marks

- Source: the iCloud, Dropbox, and Nextcloud shapes come from Simple Icons 11.15.0 (https://github.com/simple-icons/simple-icons, `icons/icloud.svg`, `dropbox.svg`, `nextcloud.svg`) with only brand colors added. The OneDrive mark (a two-tone cloud) and the Google Drive mark (a three-color triangle) are drawn by Kakey; the Simple Icons OneDrive shape is not used because it is under the Microsoft Fluent assets license
- Integration: masters committed in `design/brands/` and exported by `scripts/export-brand-icons.py` to `Apple/Shared/Resources/Brands.xcassets` and the Android `res/drawable/brand_*.xml`
- License: the Simple Icons shapes are CC0 1.0. The marks are trademarks of Apple, Dropbox, Microsoft, Google, and Nextcloud, used only to identify the corresponding service in the backup location list; no partnership or endorsement is implied
- Purpose: location icons in the backup location list, the connection screen, and the status card
- Platforms: Mac, iOS / iPadOS, Android (Android has no iCloud)
- Removal plan: used only in `Apple/Shared/Utilities/SyncLocationIcon.swift` and the Android `SyncLocationIcon`; delete the assets and switch back to SF Symbols / Material icons

## Development Tools (Not Shipped With Any App)

### Pillow

- Source: https://github.com/python-pillow/Pillow
- Pinned version: 13.0.0 (`requirements-dev.txt`, installed in `.venv/` at the repository root; see [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) for the install command)
- Integration: pip
- License: MIT-CMU (Pillow's variant of HPND)
- Purpose: the three `scripts/export-app-icon.py` scripts under `Apple/Mac`, `Apple/iOS`, and `Android` rasterize the PNG masters in `design/logo/`, round the corners, composite shadows, and export every icon size. `Apple/Mac/scripts/export-dmg-art.py` generates the DMG window background and volume icon. The results are committed; building, testing, packaging, and running never need Pillow
- Platforms: none (only `make icons` on a developer machine)
- Removal plan: those four scripts are the only users; rewrite them with system tools such as `sips` / Core Image and remove it

### dmgbuild, ds_store, mac_alias

- Source: https://github.com/dmgbuild/dmgbuild, https://github.com/dmgbuild/ds_store, https://github.com/dmgbuild/mac_alias
- Pinned versions: dmgbuild 1.6.7, ds_store 1.3.3, mac_alias 2.2.3 (`requirements-dev.txt`, installed in `.venv/` at the repository root)
- Integration: pip
- License: MIT (© Alastair Houghton)
- Purpose: `Apple/Mac/scripts/make-dmg.sh` uses dmgbuild to create the DMG and write the volume's `.DS_Store` directly (background, window size, icon positions, volume icon), without Finder AppleScript, so results are reproducible. The other two are dependencies of dmgbuild. Its badge feature (which needs pyobjc) is not used; `export-dmg-art.py` precomposes the volume icon in `design/dmg/`
- Platforms: none (only `make mac-dist` and `make mac-release` on a developer machine; the DMG contains only the `.DS_Store` it writes, none of its code)
- Removal plan: `make-dmg.sh` and `dmg-settings.py` are the only users; switch back to `hdiutil create` plus Finder AppleScript layout and remove them

### ktlint and ktlint-gradle

- Source: https://github.com/pinterest/ktlint, https://github.com/JLLeitschuh/ktlint-gradle
- Pinned versions: ktlint 1.8.0 (`ktlint-engine` in `libs.versions.toml`, passed explicitly to the plugin), Gradle plugin `org.jlleitschuh.gradle.ktlint` 14.2.0
- Integration: Gradle plugin
- License: MIT (ktlint © Pinterest; ktlint-gradle © Jonathan Leitschuh)
- Purpose: Kotlin style checks in `make test-android` (`ktlintCheck`) and automatic fixes in `make android-format`; rules in `Android/.editorconfig`
- Platforms: none (build time only, not in the APK)
- Removal plan: remove the plugin and `ktlint {}` blocks from both `build.gradle.kts` files, `Android/.editorconfig`, and the two Makefile calls

### detekt

- Source: https://github.com/detekt/detekt
- Pinned version: 1.23.8 (Gradle plugin `io.gitlab.arturbosch.detekt`, same version)
- Integration: Gradle plugin; `detekt-formatting` is not installed, since ktlint handles formatting
- License: Apache-2.0 (© detekt contributors)
- Purpose: Kotlin static analysis in `make test-android` (`:app:detekt`); the config `Android/detekt.yml` records only the differences from the default
- Platforms: none (build time only, not in the APK)
- Removal plan: remove the plugin and `detekt {}` block from `app/build.gradle.kts`, `Android/detekt.yml`, the `@Suppress` annotations that name detekt rules, and the Makefile call

## Android (`Android/`)

Versions are pinned in `Android/gradle/libs.versions.toml` and fetched by Gradle from Google Maven / Maven Central.

### AndroidX and Jetpack Compose

- Source: https://developer.android.com/jetpack/androidx (AOSP)
- Pinned versions: Compose BOM 2026.09.00 (ui, material3), material3-adaptive 1.3.0, material-icons-extended 1.7.8, activity-compose 1.13.0, lifecycle 2.11.0 (runtime-compose, process), fragment 1.5.4, core-ktx 1.19.1, core-splashscreen 1.2.0, navigation3 1.2.0 (runtime, ui), biometric 1.1.0, CameraX 1.6.2 (camera2, lifecycle, view; camera-video is excluded so its transitive dependencies don't add network permissions), datastore-preferences 1.3.0, documentfile 1.1.0
- License: Apache-2.0 (© The Android Open Source Project)
- Purpose: UI (Compose, Material 3, adaptive layout, navigation), biometrics, camera preview and frame capture, settings storage, and sync folder access (SAF)
- Platforms: Android
- Removal plan: all part of the official Android stack; replacing any one affects only the matching UI or the `data/` and `platform/` packages in `Android/app`

### kotlinx.coroutines

- Source: https://github.com/Kotlin/kotlinx.coroutines
- Pinned version: 1.11.0 (android; tests also use coroutines-test)
- License: Apache-2.0 (© JetBrains)
- Purpose: running slow calls such as Argon2id in the background, and state flows
- Platforms: Android
- Removal plan: the official Kotlin coroutines library; no replacement planned

### ZXing Core

- Source: https://github.com/zxing/zxing
- Pinned version: 3.5.4
- License: Apache-2.0 (© ZXing authors)
- Purpose: QR code recognition in camera frames and photos, and QR code generation for a single account; runs on device, with no dependency on Google Play services or ML Kit
- Platforms: Android
- Removal plan: used in `QrImageDecoder` / `QrCodeImage` in `platform/Platform.kt` and the scanner screen's frame capture function

### JNA

- Source: https://github.com/java-native-access/jna
- Pinned version: 5.19.1 (aar in the app, jar in JVM unit tests)
- License: dual-licensed LGPL-2.1-or-later and Apache-2.0; Kakey uses it under Apache-2.0
- Purpose: the UniFFI-generated Kotlin bindings call the Rust core through JNA
- Platforms: Android
- Removal plan: comes with UniFFI's Kotlin backend; switching to another FFI mechanism means replacing the generated bindings too

### OkHttp and Okio

- Source: https://github.com/square/okhttp, https://github.com/square/okio
- Pinned versions: OkHttp 5.5.0 (`okhttp`, Android artifact `okhttp-android`); Okio 3.18.1 (brought in by OkHttp, which also raises the 3.17.0 that DataStore depends on to this version)
- License: Apache-2.0 (© Square, Inc.)
- Purpose: the HTTP executor for cloud storage backup, `data/cloud/OkHttpExecutor.kt` (`HttpURLConnection` doesn't support WebDAV `PROPFIND` / `MKCOL`). It only executes requests built by the core; it doesn't follow redirects, store cookies, or use a cache
- Platforms: Android
- Removal plan: used only in `OkHttpExecutor` (which implements `HttpExecutor` from `domain/Ports.kt`); a replacement HTTP client must keep the same contract, verified by `OkHttpExecutorTest`

### Build and Test Only (Not Shipped With the App)

- Android Gradle Plugin 9.4.1, Kotlin 2.4.21 (including the Compose compiler plugin), Gradle 9.7.1 (wrapper committed): Apache-2.0
- JUnit 4.13.2: EPL-1.0, JVM unit tests only
- org.json 20250517: Public Domain, JVM unit tests only, in place of the android.jar stub
- MockWebServer (`mockwebserver3`) 5.5.0: Apache-2.0, JVM unit tests only, to verify `OkHttpExecutor`
- AndroidX Test runner / rules 1.7.0, ext junit 1.3.0, espresso-core 3.7.0, Compose ui-test-junit4 (version from the Compose BOM): Apache-2.0, instrumented tests (`src/androidTest`) only

## Shared Rust Core (`Core/`)

`Core/Cargo.lock` pins the versions below. `cargo deny check licenses` in `make test-core` checks them against the allowlist in `Core/deny.toml` (GPL, AGPL, and LGPL are denied). Run `cargo deny list` for the full license list of transitive dependencies.

### RustCrypto Cryptography Crates

- Source: https://github.com/RustCrypto
- Pinned versions: `argon2` 0.6.0, `aes-gcm` 0.11.1, `aes` 0.9.3, `cbc` 0.2.1, `hmac` 0.13.0, `sha1` 0.11.0, `sha2` 0.11.0, `md-5` 0.11.0 (and their dependencies `password-hash`, `cipher`, `aead`, `digest`, and others)
- Integration: Cargo
- License: MIT or Apache-2.0, at your option (© RustCrypto Developers)
- Purpose:
  - Vault: Argon2id derivation + AES-256-GCM
  - TOTP: HMAC-SHA1 / SHA256 / SHA512
  - Authenticator v3 import: Argon2id and PHC verification, CryptoJS-style AES-256-CBC + MD5
- Platforms: Mac, iOS / iPadOS, Android
- Removal plan: calls are concentrated in `vault.rs`, `totp.rs`, and `authenticator.rs` in `kakey-core`. A replacement must pass `Core/golden/kdf.json` and `vault.json`, or existing vaults won't unlock

### UniFFI

- Source: https://github.com/mozilla/uniffi-rs
- Pinned version: 0.32.2
- Integration: Cargo (runtime glue in `kakey-ffi`; `uniffi-bindgen` generates the Swift / Kotlin bindings)
- License: MPL-2.0 (© Mozilla Foundation). A file-level weak copyleft; Kakey doesn't modify its source, only links the runtime and uses the generated bindings
- Purpose: the FFI between the Rust core and Swift / Kotlin
- Platforms: Mac, iOS / iPadOS, Android
- Removal plan: the boundary is only in `crates/kakey-ffi`; replacing it with a hand-written C ABI means updating each platform's wrapper layer too

### Formats, Text, and Foundation Crates

- Pinned versions:
  - Serialization and encoding: `serde` 1.0.229, `serde_json` 1.0.151, `base64` 0.23.1, `data-encoding` 2.11.1
  - IDs, time, and URLs: `uuid` 1.26.1, `time` 0.3.55, `url` 2.5.8, `percent-encoding` 2.3.2
  - Migration codes and text: `prost` 0.14.4, `unicode-normalization` 0.1.25, `caseless` 0.2.2
  - System randomness and memory: `getrandom` 0.4.3, `zeroize` 1.9.0
  - Error types: `thiserror` 2.0.21
- Integration: Cargo
- License: MIT or Apache-2.0 (`caseless` is MIT; the Unicode data dependencies of `url` and `percent-encoding` are Unicode-3.0)
- Purpose:
  - Encoding and decoding the on-disk JSON
  - Parsing otpauth URLs and migration code protobufs
  - Unicode normalization and case folding for search
  - The system CSPRNG, and zeroing secrets in memory
- Platforms: Mac, iOS / iPadOS, Android
- Removal plan: all internal to `kakey-core` and absent from the FFI interface; each can be replaced on its own and verified against golden

### Password Strength Estimation: zxcvbn

- Source: https://github.com/shssoichiro/zxcvbn-rs (a Rust port of Dropbox's zxcvbn)
- Pinned version: `zxcvbn` 3.1.1 (`default-features = false`, without the builder); transitive dependencies `fancy-regex` 0.18.0, `regex` 1.13.1 (with `regex-automata` 0.4.18, `regex-syntax` 0.8.11, `aho-corasick` 1.1.5, `memchr` 2.8.3), `itertools` 0.14.0, `lazy_static` 1.5.1, and `time` (same version as above)
- Integration: Cargo
- License: MIT (zxcvbn and its built-in dictionaries; `fancy-regex`); the other transitive dependencies are MIT or Apache-2.0, and `aho-corasick` / `memchr` are Unlicense or MIT
- Purpose: strength rating for the master password and export passwords (common passwords, English words, keyboard patterns, sequences, dates, repeats). It is the single standard for strength; passwords are evaluated only in memory
- Platforms: Mac, iOS / iPadOS, Android (compiled into the core)
- Removal plan: called only from `evaluate` in `kakey-core/src/password.rs`; after switching to another estimator, recompute golden `password.json`

### Dependencies of the `cloudset` Cloud Storage Component

- Pinned versions: `quick-xml` 0.42.0 (and its dependency `memchr` 2.8.3), `httpdate` 1.0.3; the rest (`serde`, `serde_json`, `base64`, `url`, `percent-encoding`, `sha2`, `thiserror`, `zeroize`) match the versions above, and `sha2` also computes the OAuth PKCE challenge
- Integration: Cargo (`Core/crates/cloudset`)
- License: `quick-xml` is MIT (© Johann Tuffe and quick-xml contributors); `httpdate` is MIT or Apache-2.0 (© Pyfisch); `memchr` is MIT or Unlicense, used under MIT
- Purpose:
  - `quick-xml`: parsing WebDAV `PROPFIND` 207 Multi-Status responses (DOCTYPE is rejected and custom entities are not expanded)
  - `httpdate`: parsing the HTTP date in `getlastmodified`
- Platforms: Mac, iOS / iPadOS, Android (linked through `kakey-ffi`)
- Removal plan: XML parsing is only in `cloudset/src/multistatus.rs` and date parsing only in its `set_prop`; verify a replacement with `cloudset/golden/multistatus.json` and `tests/`

### Build Dependencies of `kakey-ffi`

- Pinned version: `toml` 1.1.6 (and its dependencies `toml_parser`, `toml_datetime`, `serde_spanned`, `winnow`, `indexmap`); UniFFI already pulls in the same version
- Integration: Cargo `build-dependencies` (`Core/crates/kakey-ffi/build.rs`)
- License: MIT or Apache-2.0
- Purpose: reads the developer's `cloud-keys.toml` (OAuth public client IDs) at build time. It runs only in the build script and is not linked into the output
- Platforms: none (build time only)
- Removal plan: the file format is simple enough for a hand-written parser; compare against the validation in `make cloud-config` and `build.rs`

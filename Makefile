SHELL := /bin/bash
.DEFAULT_GOAL := help

PRODUCT := Kakey
CONFIGURATION ?= Debug
BUILD_ROOT := $(CURDIR)/Build

# Local developer configuration (not committed; template: local.mk.example)
-include local.mk

# Developer keys for cloud backup (see docs/DEVELOPMENT.md): when the file exists its path is passed to the core build;
# otherwise this is empty and all OAuth providers are hidden. The file appearing or disappearing changes this environment
# variable, which makes kakey-ffi's build.rs regenerate.
CLOUD_CONFIG := $(wildcard $(CURDIR)/cloud-keys.toml)

# UI languages (BCP-47, source language first), matching docs/LOCALIZATION.md
LANGS := en,zh-Hans,zh-Hant
# The three localization guards (scripts/i18n-guard.py). --min-files is set from the actual source size so a broken path
# cannot pass silently. No .pyc files: the guard imports android_strings.py from its own directory, which would otherwise
# leave scripts/__pycache__ in the source tree.
I18N_GUARD := PYTHONDONTWRITEBYTECODE=1 python3 scripts/i18n-guard.py --langs "$(LANGS)"
# Icon export and DMG packaging need Pillow / dmgbuild from .venv (versions in requirements-dev.txt; development only, see
# docs/DEVELOPMENT.md)
ICON_PYTHON := $(CURDIR)/.venv/bin/python3
ICON_SCRIPTS := Apple/Mac/scripts/export-app-icon.py Apple/Mac/scripts/export-dmg-art.py Apple/iOS/scripts/export-app-icon.py Android/scripts/export-app-icon.py scripts/export-brand-icons.py

# --- Apple ---
APPLE_PROJECT := Apple/$(PRODUCT).xcodeproj
MAC_APP_DIR := Apple/Mac
# The Mac target / scheme is named after the product, not KakeyMac (see AGENTS.md)
MAC_SCHEME := $(PRODUCT)
MAC_BUILD_ROOT := $(BUILD_ROOT)/macOS
# Xcode keeps intermediates and the real product in DerivedData. Build/<platform>/<CONFIGURATION>/ holds only a relative
# symlink to the product: one real copy, so Launch Services, the URL scheme, AppleScript and TCC see a single app.
MAC_APP := $(MAC_BUILD_ROOT)/$(CONFIGURATION)/$(PRODUCT).app
MAC_DIST := $(MAC_BUILD_ROOT)/Dist
# The version is defined only by MARKETING_VERSION in Apple/project.yml; do not duplicate it here.
VERSION := $(shell grep -m1 'MARKETING_VERSION' Apple/project.yml | sed 's/[^0-9.]*//g')
# Builds default to -quiet to cut noise. Tests do not, because -quiet swallows the ** TEST SUCCEEDED / FAILED ** result
# line, which is what decides success. For full build output: make mac XCODEBUILD_FLAGS=
XCODEBUILD_FLAGS ?= -quiet
XCODEBUILD_TEST_FLAGS ?=
# Tests always use the Test configuration (a copy of Debug whose test host bundle ID is com.gicek.kakey.testhost), so a
# running Kakey does not make the test host quit through the single-instance logic.
TEST_CONFIGURATION := Test
# CloudKit container for iCloud backup (see docs/DEVELOPMENT.md); enabled only in builds with a development team
ICLOUD_CONTAINER := iCloud.com.gicek.kakey
# Mac signing: when local.mk sets MAC_DEVELOPMENT_TEAM, sign with a development certificate and automatic provisioning
# and add the iCloud backup and push entitlements (see docs/DEVELOPMENT.md); otherwise stay ad-hoc without iCloud. Tests
# get no signing overrides, so the test host is always ad-hoc.
ifneq ($(strip $(MAC_DEVELOPMENT_TEAM)),)
MAC_SIGNING_FLAGS := -allowProvisioningUpdates -allowProvisioningDeviceRegistration KAKEY_DEVELOPMENT_TEAM="$(MAC_DEVELOPMENT_TEAM)" \
	KAKEY_MAC_SIGN_IDENTITY="Apple Development" KAKEY_MAC_ENTITLEMENTS=Mac/KakeyICloud.entitlements \
	KAKEY_ICLOUD_CONTAINER=$(ICLOUD_CONTAINER)
MAC_SIGNING_HINT := echo "Hint: signing failures usually mean the App ID does not have iCloud and push enabled yet (see docs/DEVELOPMENT.md). For a temporary ad-hoc build: make mac MAC_DEVELOPMENT_TEAM=";
else
MAC_SIGNING_FLAGS :=
MAC_SIGNING_HINT :=
endif
# Signing / notarization settings read by release.sh (can live in local.mk). Passed only when non-empty: xcodebuild
# treats an empty environment value as a build setting, which would override the project's ad-hoc signing.
RELEASE_ENV := $(if $(strip $(CODE_SIGN_IDENTITY)),CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)",) \
	$(if $(strip $(NOTARY_PROFILE)),NOTARY_PROFILE="$(NOTARY_PROFILE)",) \
	$(if $(strip $(MAC_DEVELOPMENT_TEAM)),MAC_DEVELOPMENT_TEAM="$(MAC_DEVELOPMENT_TEAM)" ICLOUD_CONTAINER="$(ICLOUD_CONTAINER)",)

# --- Core (shared Rust core) ---
CORE_BUILD_ROOT := $(BUILD_ROOT)/Core
# Output goes to Build/Core/target; not set in .cargo/config.toml, where a relative path would resolve against the
# calling directory
CARGO := cd Core && CARGO_TARGET_DIR="$(CORE_BUILD_ROOT)/target" cargo

# --- iOS / iPadOS (one target: KakeyMobile) ---
MOBILE_SCHEME := KakeyMobile
SIM_BUILD_ROOT := $(BUILD_ROOT)/iOS/Simulator
DEVICE_BUILD_ROOT := $(BUILD_ROOT)/iOS/Device
# Defaults to the first available iPhone simulator instead of a hard-coded model; override with IOS_SIMULATOR='<name>'.
# Uses ${shell ...} because make pairs parentheses inside $(...), and the '(' in the pattern would look unclosed.
IOS_SIMULATOR ?= ${shell xcrun simctl list devices available 2>/dev/null | grep -m1 -o 'iPhone [^(]*' | sed 's/ *$$//'}
IOS_BUNDLE_ID := com.gicek.kakey
# The device signing team comes from DEVELOPMENT_TEAM in local.mk, which also adds the iCloud and push entitlements.
# Redirect scheme for authorization through the official Dropbox app: generated from cloud-keys.toml into the URL Types
# of the iOS Info.plist.
IOS_CLOUD_FLAGS := $(shell PYTHONDONTWRITEBYTECODE=1 python3 scripts/cloud-config.py --xcode-settings "$(CURDIR)/cloud-keys.toml")
ifneq ($(strip $(DEVELOPMENT_TEAM)),)
IOS_SIGNING_FLAGS := -allowProvisioningUpdates KAKEY_DEVELOPMENT_TEAM="$(DEVELOPMENT_TEAM)" \
	KAKEY_IOS_ENTITLEMENTS=iOS/KakeyICloud.entitlements KAKEY_ICLOUD_CONTAINER=$(ICLOUD_CONTAINER)
else
IOS_SIGNING_FLAGS :=
endif

# --- Android (one app for phones and tablets) ---
ANDROID_BUILD_ROOT := $(BUILD_ROOT)/Android
# Gradle's own output (build directories, project cache, Kotlin sessions) stays under Gradle/; the APK and AAB are copied
# to Debug/ and Release/ next to it with the version in the file name.
GRADLE_BUILD_ROOT := $(ANDROID_BUILD_ROOT)/Gradle
# JDK 21: JDK_HOME -> JAVA_HOME -> Homebrew openjdk@21, with a clear error if none is found
ANDROID_JAVA_HOME := $(or $(JDK_HOME),$(JAVA_HOME),$(wildcard /opt/homebrew/opt/openjdk@21))
# The project-level cache and Kotlin session directories default to the source tree, so point them at Build/Android/
# explicitly (the kotlin directory must be an absolute path). GRADLE_ENV is set per target (instrumented tests pass
# ANDROID_SERIAL) and goes after the cd so it applies to gradlew.
GRADLEW = cd Android && $(GRADLE_ENV) JAVA_HOME="$(ANDROID_JAVA_HOME)" ./gradlew --console=plain \
	--project-cache-dir "$(GRADLE_BUILD_ROOT)/.gradle" -Pkotlin.project.persistent.dir="$(GRADLE_BUILD_ROOT)/.kotlin" $(GRADLE_ARGS)
GRADLE_OUTPUTS := $(GRADLE_BUILD_ROOT)/app/outputs
ANDROID_APK := $(ANDROID_BUILD_ROOT)/Debug/$(PRODUCT)-$(VERSION).apk
ANDROID_RELEASE_DIR := $(ANDROID_BUILD_ROOT)/Release
ANDROID_PACKAGE := com.gicek.kakey
# Release signing comes from local.mk (ANDROID_KEYSTORE and three more; template: local.mk.example) and is passed as Gradle
# properties only when set. Otherwise Gradle signs with the debug keystore and warns that the build is for local install
# only (the counterpart of Mac ad-hoc signing). Key material is never committed.
ANDROID_SIGNING_PROPS := $(if $(strip $(ANDROID_KEYSTORE)),-PkakeyKeystore="$(ANDROID_KEYSTORE)" \
	-PkakeyKeystorePassword="$(ANDROID_KEYSTORE_PASSWORD)" -PkakeyKeyAlias="$(ANDROID_KEY_ALIAS)" -PkakeyKeyPassword="$(ANDROID_KEY_PASSWORD)",)
# Device for instrumented tests and installs: SERIAL=<serial>; when unset, exactly one device must be connected
ANDROID_SERIAL_ENV := $(if $(strip $(SERIAL)),ANDROID_SERIAL="$(SERIAL)",)

# Logs written by make targets; ad-hoc files from manual work go to Build/Scratch/ (see AGENTS.md)
LOG_ROOT := $(BUILD_ROOT)/Logs

# Points Build/<platform>/<CONFIGURATION>/<name> at a product inside DerivedData with a relative symlink.
# $(call link_product,<product path>,<link path>)
define link_product
	@test -e "$(1)" || { echo "Build product missing: $(1)"; exit 1; }
	@mkdir -p "$(dir $(2))" && rm -rf "$(2)" && ln -s "$$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$(1)" "$(dir $(2))")" "$(2)"
	@echo "$(2) -> $(1)"
endef

BUILD_TARGETS := core mac ios-simulator android
TEST_TARGETS := test-core test-mac test-ios test-android

.PHONY: help build test clean project icons lint-swift \
	core test-core core-audit core-apple core-android cloud-config \
	alfred-workflow mac mac-run test-mac mac-dist mac-release bump-build \
	ios-simulator ios-simulator-run ios-device ios-device-install test-ios ios-screenshots \
	android android-install test-android android-format test-android-device android-release android-screenshots

# Help is generated from the trailing "## description" on target lines, grouped by "##@ title" lines; Make variables in
# descriptions are not expanded.
help:
	@echo "$(PRODUCT) build commands (version $(VERSION), CONFIGURATION=$(CONFIGURATION))"
	@awk 'BEGIN { FS = ":.*## " } \
		/^##@ / { printf "\n%s\n", substr($$0, 5); next } \
		/^[a-zA-Z0-9_-]+:.*## / { printf "  make %-22s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

##@ General

build: $(BUILD_TARGETS) ## Build all components: core mac ios-simulator android

test: $(TEST_TARGETS) ## Run all tests: test-core test-mac test-ios test-android

clean: ## Delete Build/ and stray build output in the source tree
	@test "$(BUILD_ROOT)" = "$(CURDIR)/Build" || { echo "Unexpected BUILD_ROOT: $(BUILD_ROOT)"; exit 1; }
	rm -rf "$(BUILD_ROOT)"
	@# Fallback: output that should never be in the source tree. A build-time generated resource; output directories left
	@# by running xcodebuild, cargo or ./gradlew directly with default or relative paths; Python bytecode from running
	@# scripts by hand.
	rm -rf "$(CURDIR)/build" "$(CURDIR)/dist" "$(MAC_APP_DIR)/Resources/$(PRODUCT).alfredworkflow" \
		"$(CURDIR)/Apple/Build" "$(CURDIR)/Apple/build" "$(CURDIR)/Core/target" \
		"$(CURDIR)/Android/.gradle" "$(CURDIR)/Android/.kotlin" "$(CURDIR)/Android/app/build" "$(CURDIR)/Android/build"
	find scripts Apple Android Core -name __pycache__ -type d -prune -exec rm -rf {} +

# XcodeGen's output depends on whether the generated Alfred workflow and core bindings exist, so make sure both do (an
# empty bindings placeholder is enough; make core-apple replaces it). A clean checkout then generates the same project.
project: ## Generate the Xcode project from Apple/project.yml (needs xcodegen)
	@command -v xcodegen >/dev/null || { echo "XcodeGen missing: brew install xcodegen"; exit 1; }
	@test -e "$(MAC_APP_DIR)/Resources/$(PRODUCT).alfredworkflow" || $(MAKE) --no-print-directory alfred-workflow
	@mkdir -p "$(CORE_BUILD_ROOT)/apple" && { test -e "$(CORE_BUILD_ROOT)/apple/KakeyCore.swift" || : > "$(CORE_BUILD_ROOT)/apple/KakeyCore.swift"; }
	cd Apple && xcodegen generate --quiet

# Increment CFBundleVersion before every distribution. The build number is defined only in project.yml, so regenerate
# the project afterwards. Not agvtool: it only edits project.pbxproj, which the next make project overwrites.
bump-build: ## Increment CURRENT_PROJECT_VERSION in Apple/project.yml and regenerate the project (all platforms)
	@current=$$(grep -m1 'CURRENT_PROJECT_VERSION' Apple/project.yml | sed 's/[^0-9]*//g'); \
	test -n "$$current" || { echo "Could not read CURRENT_PROJECT_VERSION from Apple/project.yml"; exit 1; }; \
	next=$$((current + 1)); \
	sed -i '' "s/CURRENT_PROJECT_VERSION: $$current\$$/CURRENT_PROJECT_VERSION: $$next/" Apple/project.yml; \
	echo "CURRENT_PROJECT_VERSION: $$current -> $$next"
	$(MAKE) project

# Icons are exported only from the masters in design/logo/; never edit the asset catalogs by hand (see AGENTS.md).
# Pillow lives in .venv at the repo root (gitignored) and is not shipped with the app.
icons: ## Export app icons, brand icons and DMG background / volume icon from design/ (needs Pillow in .venv)
	@test -x "$(ICON_PYTHON)" || { echo ".venv missing: python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt (see docs/DEVELOPMENT.md)"; exit 1; }
	@PYTHONDONTWRITEBYTECODE=1 "$(ICON_PYTHON)" -c 'import PIL' 2>/dev/null || { echo "Pillow missing from .venv: .venv/bin/pip install -r requirements-dev.txt"; exit 1; }
	@for script in $(ICON_SCRIPTS); do PYTHONDONTWRITEBYTECODE=1 "$(ICON_PYTHON)" "$$script" || exit 1; done

# Rules are in .swift-format at the repo root. Part of the test-mac / test-ios gate: any warning fails the tests.
# Auto-fix: xcrun swift-format format -i --recursive Apple/Mac Apple/iOS Apple/Shared
lint-swift: ## swift-format lint for Apple/Mac, iOS and Shared (runs before test-mac / test-ios)
	@xcrun --find swift-format >/dev/null 2>&1 || { echo "This Xcode does not include swift-format (bundled since Xcode 16)"; exit 1; }
	xcrun swift-format lint --strict --recursive Apple/Mac Apple/iOS Apple/Shared

##@ Core (shared Rust core)

core: ## Build the shared Rust core (Core/)
	@command -v cargo >/dev/null || { echo "Rust toolchain missing: https://rustup.rs"; exit 1; }
	$(CARGO) build --workspace

test-core: ## fmt + clippy + unit and golden tests + cloudset standalone build + cargo-deny license check
	@command -v cargo >/dev/null || { echo "Rust toolchain missing: https://rustup.rs"; exit 1; }
	$(CARGO) fmt --all --check
	$(CARGO) clippy --locked --workspace --all-targets -- -D warnings
	$(CARGO) test --locked --workspace
	@# cloudset is a generic component: kakey-* and uniffi must not appear in its dependency graph (docs/TECHNICAL.md)
	@if $(CARGO) tree --locked -p cloudset -e normal,build --prefix none | grep -Eq '^(kakey-|uniffi)'; then \
		echo "cloudset depends on kakey-* or uniffi, which violates its independence constraint"; exit 1; fi
	@# ...and it must build and pass its tests copied out of the workspace, ready to become its own repository (ROADMAP)
	@mkdir -p "$(LOG_ROOT)"
	Core/scripts/cloudset-standalone.sh "$(CORE_BUILD_ROOT)/cloudset-standalone" > "$(LOG_ROOT)/cloudset-standalone.log" 2>&1 \
		|| { tail -40 "$(LOG_ROOT)/cloudset-standalone.log"; exit 1; }
	@if command -v cargo-deny >/dev/null; then cd Core && cargo deny check licenses bans; \
	else echo "cargo-deny not installed; skipping the license check locally (CI runs it; install: cargo install cargo-deny)"; fi

# The advisory database is fetched over the network, so this stays out of test-core, which must work offline. CI runs it
# every time; run it locally after upgrading dependencies.
core-audit: ## cargo-deny check for known RustSec advisories (fetches the database; runs in CI every time)
	@command -v cargo-deny >/dev/null || { echo "cargo-deny missing: cargo install cargo-deny --locked"; exit 1; }
	cd Core && cargo deny check advisories

# Output is not replaced when unchanged, so Xcode does not rebuild
core-apple: ## Package KakeyCore.xcframework and Swift bindings into Build/Core/apple/ (Apple targets depend on it)
	@command -v cargo >/dev/null || { echo "Rust toolchain missing: https://rustup.rs"; exit 1; }
	CORE_BUILD_ROOT="$(CORE_BUILD_ROOT)" KAKEY_CLOUD_CONFIG="$(CLOUD_CONFIG)" Core/scripts/build-apple.sh

# Cross-compiled with cargo-ndk; output is not replaced when unchanged
core-android: ## Package the Android core .so, Kotlin bindings and host core for JVM tests into Build/Core/android/
	@command -v cargo >/dev/null || { echo "Rust toolchain missing: https://rustup.rs"; exit 1; }
	CORE_BUILD_ROOT="$(CORE_BUILD_ROOT)" KAKEY_CLOUD_CONFIG="$(CLOUD_CONFIG)" Core/scripts/build-android.sh

cloud-config: ## Validate cloud-keys.toml (cloud backup developer keys) and print the OAuth callback URLs to register
	@PYTHONDONTWRITEBYTECODE=1 python3 scripts/cloud-config.py cloud-keys.toml

##@ macOS

# Packages the .alfredworkflow (scripts + icons + info.plist) at build time; see Apple/Mac/scripts/build-alfred-workflow.py.
# Runs before builds and tests so every build uses the current scripts and icons.
alfred-workflow: ## Generate Apple/Mac/Resources/Kakey.alfredworkflow (mac / test-mac depend on it)
	python3 $(MAC_APP_DIR)/scripts/build-alfred-workflow.py

mac: alfred-workflow core-apple ## Build Build/macOS/<CONFIGURATION>/Kakey.app (CONFIGURATION=Release for a release build)
	xcodebuild $(XCODEBUILD_FLAGS) -project "$(APPLE_PROJECT)" -scheme "$(MAC_SCHEME)" \
	    -configuration "$(CONFIGURATION)" -destination 'platform=macOS,arch=arm64' \
	    -derivedDataPath "$(MAC_BUILD_ROOT)/DerivedData" $(MAC_SIGNING_FLAGS) build \
	    || { $(MAC_SIGNING_HINT) exit 1; }
	$(call link_product,$(MAC_BUILD_ROOT)/DerivedData/Build/Products/$(CONFIGURATION)/$(PRODUCT).app,$(MAC_APP))

mac-run: mac ## Build, verify the signature and open the Mac app
	@test -x "$(MAC_APP)/Contents/MacOS/$(PRODUCT)" || { echo "Build output missing: $(MAC_APP)"; exit 1; }
	codesign --verify --deep --strict "$$(cd "$(MAC_APP)" && pwd -P)"
	open "$(MAC_APP)"

test-mac: alfred-workflow core-apple lint-swift ## Localization guards + Mac unit tests
	$(I18N_GUARD) --platform apple --extra Apple/Shared --root Apple/Mac --min-files 40
	xcodebuild $(XCODEBUILD_TEST_FLAGS) -project "$(APPLE_PROJECT)" -scheme "$(MAC_SCHEME)" \
	    -configuration "$(TEST_CONFIGURATION)" -destination 'platform=macOS,arch=arm64' \
	    -derivedDataPath "$(MAC_BUILD_ROOT)/Tests/DerivedData" test

# For local test installs: signed like make mac (development certificate with MAC_DEVELOPMENT_TEAM, otherwise ad-hoc),
# so it only opens on this machine or registered devices
mac-dist: ## Release build packaged as a DMG in Build/macOS/Dist/ (needs .venv; no tests, build bump or notarization)
	$(MAKE) mac CONFIGURATION=Release
	$(MAC_APP_DIR)/scripts/make-dmg.sh "$$(cd "$(MAC_BUILD_ROOT)/Release/$(PRODUCT).app" && pwd -P)" "$(MAC_DIST)/$(PRODUCT)-$(VERSION).dmg"

mac-release: ## Release: tests + build bump + Release build + signing + DMG + notarization (Apple/Mac/scripts/release.sh)
	$(RELEASE_ENV) $(MAC_APP_DIR)/scripts/release.sh

##@ iOS / iPadOS

ios-simulator: core-apple ## Build the simulator app Build/iOS/Simulator/<CONFIGURATION>/Kakey.app
	xcodebuild $(XCODEBUILD_FLAGS) -project "$(APPLE_PROJECT)" -scheme "$(MOBILE_SCHEME)" \
	    -configuration "$(CONFIGURATION)" -destination 'generic/platform=iOS Simulator' \
	    -derivedDataPath "$(SIM_BUILD_ROOT)/DerivedData" $(IOS_CLOUD_FLAGS) build
	$(call link_product,$(SIM_BUILD_ROOT)/DerivedData/Build/Products/$(CONFIGURATION)-iphonesimulator/Kakey.app,$(SIM_BUILD_ROOT)/$(CONFIGURATION)/Kakey.app)

ios-simulator-run: ios-simulator ## Build, boot the simulator, install and run (override with IOS_SIMULATOR='<name>')
	@test -n "$(IOS_SIMULATOR)" || { echo "No iPhone simulator available: install one in Xcode > Settings > Components, or set IOS_SIMULATOR='<name>'"; exit 1; }
	xcrun simctl boot "$(IOS_SIMULATOR)" 2>/dev/null || true
	open -a Simulator
	xcrun simctl bootstatus "$(IOS_SIMULATOR)" -b
	xcrun simctl install "$(IOS_SIMULATOR)" "$$(cd "$(SIM_BUILD_ROOT)/$(CONFIGURATION)/Kakey.app" && pwd -P)"
	xcrun simctl launch --terminate-running-process "$(IOS_SIMULATOR)" "$(IOS_BUNDLE_ID)"

ios-device: core-apple ## Build for physical devices (needs DEVELOPMENT_TEAM in local.mk)
	@test -n "$(strip $(DEVELOPMENT_TEAM))" || { echo "Set DEVELOPMENT_TEAM in local.mk"; exit 1; }
	xcodebuild $(XCODEBUILD_FLAGS) -project "$(APPLE_PROJECT)" -scheme "$(MOBILE_SCHEME)" \
	    -configuration "$(CONFIGURATION)" -destination 'generic/platform=iOS' \
	    -derivedDataPath "$(DEVICE_BUILD_ROOT)/DerivedData" $(IOS_SIGNING_FLAGS) $(IOS_CLOUD_FLAGS) build
	$(call link_product,$(DEVICE_BUILD_ROOT)/DerivedData/Build/Products/$(CONFIGURATION)-iphoneos/Kakey.app,$(DEVICE_BUILD_ROOT)/$(CONFIGURATION)/Kakey.app)

# Device names may contain spaces and parentheses, so devices are identified by the UUID in devicectl's output; only
# "available (paired)" devices are installed to
ios-device-install: ios-device ## Build and install on every connected paired device (DEVICE=<identifier> for just one)
	@ids="$(DEVICE)"; \
	if [ -z "$$ids" ]; then ids=$$(xcrun devicectl list devices 2>/dev/null | grep -E 'available \(paired\)|connected' | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}'); fi; \
	test -n "$$ids" || { echo "No connected paired devices (xcrun devicectl list devices)"; exit 1; }; \
	for id in $$ids; do xcrun devicectl device install app --device "$$id" "$$(cd "$(DEVICE_BUILD_ROOT)/$(CONFIGURATION)/Kakey.app" && pwd -P)"; done

test-ios: core-apple lint-swift ## Localization guards + iOS simulator tests
	@test -n "$(IOS_SIMULATOR)" || { echo "No iPhone simulator available"; exit 1; }
	$(I18N_GUARD) --platform apple --extra Apple/Shared --root Apple/iOS --min-files 25
	xcodebuild $(XCODEBUILD_TEST_FLAGS) -project "$(APPLE_PROJECT)" -scheme "$(MOBILE_SCHEME)" \
	    -configuration "$(TEST_CONFIGURATION)" -destination 'platform=iOS Simulator,name=$(IOS_SIMULATOR)' \
	    -derivedDataPath "$(SIM_BUILD_ROOT)/Tests/DerivedData" $(IOS_CLOUD_FLAGS) test

# Only Debug builds include the demo vault (DemoVault); DEVICES=iphone|ipad captures a single device type
ios-screenshots: ## Demo vault screenshots: iPhone / iPad × screens × light/dark × 3 languages, to Build/Screenshots/ios/
	$(MAKE) ios-simulator CONFIGURATION=Debug
	Apple/iOS/scripts/screenshots.sh "$$(cd "$(SIM_BUILD_ROOT)/Debug/Kakey.app" && pwd -P)" "$(BUILD_ROOT)/Screenshots/ios"

##@ Android

android: core-android ## Build the debug APK Build/Android/Debug/Kakey-<version>.apk
	@test -n "$(ANDROID_JAVA_HOME)" || { echo "JDK 21 missing: brew install openjdk@21, or set JDK_HOME"; exit 1; }
	$(GRADLEW) :app:assembleDebug
	@mkdir -p "$(dir $(ANDROID_APK))" && cp "$(GRADLE_OUTPUTS)/apk/debug/app-debug.apk" "$(ANDROID_APK)"
	@echo "APK: $(ANDROID_APK)"

android-install: android ## Build and install on the single connected device or emulator (pick one with SERIAL=<serial>)
	adb $(if $(SERIAL),-s $(SERIAL),) install -r "$(ANDROID_APK)"

# Judge by Gradle's BUILD SUCCESSFUL / BUILD FAILED; if you suspect stale caches, use GRADLE_ARGS=--rerun-tasks.
# Static checks run in the same Gradle invocation: ktlint (rules in Android/.editorconfig, auto-fix with
# make android-format), detekt (Android/detekt.yml) and Android Lint (warnings fail, no baseline, disabled checks in
# Android/app/lint.xml). Reports go to Build/Android/Gradle/app/reports/.
test-android: core-android ## Localization guards + ktlint + detekt + Android Lint + JVM unit tests (host core via JNA)
	@test -n "$(ANDROID_JAVA_HOME)" || { echo "JDK 21 missing: brew install openjdk@21, or set JDK_HOME"; exit 1; }
	$(I18N_GUARD) --platform android --root Android/app/src/main --min-files 25
	$(GRADLEW) ktlintCheck :app:detekt :app:lintDebug :app:testDebugUnitTest

android-format: ## Auto-fix Kotlin formatting with ktlint (rules in Android/.editorconfig)
	@test -n "$(ANDROID_JAVA_HOME)" || { echo "JDK 21 missing: brew install openjdk@21, or set JDK_HOME"; exit 1; }
	$(GRADLEW) ktlintFormat

# Instrumented tests run in the app's sandbox on the device (each test clears it through the app's own reset before and
# after). Not part of make test, since they need a connected device. Judge by BUILD SUCCESSFUL / FAILED; reports go to
# Build/Android/Gradle/app/reports/androidTests/connected/
test-android-device: GRADLE_ENV := $(ANDROID_SERIAL_ENV)
test-android-device: core-android ## Instrumented UI flow tests on a connected device / emulator (SERIAL=<serial>; not in make test)
	@test -n "$(ANDROID_JAVA_HOME)" || { echo "JDK 21 missing: brew install openjdk@21, or set JDK_HOME"; exit 1; }
	@test -n "$(SERIAL)" || test "$$(adb devices | awk 'NR > 1 && $$2 == "device"' | wc -l)" -eq 1 || { echo "No device, or more than one, is connected: pick one with SERIAL=<serial> (adb devices)"; exit 1; }
	$(GRADLEW) :app:connectedDebugAndroidTest

# Release: R8 shrinking + signing; the APK is for local install checks, the AAB for store upload
android-release: core-android ## Release APK, AAB and R8 mapping in Build/Android/Release/ (signed with ANDROID_KEYSTORE from local.mk, else debug keystore, local only)
	@test -n "$(ANDROID_JAVA_HOME)" || { echo "JDK 21 missing: brew install openjdk@21, or set JDK_HOME"; exit 1; }
	$(GRADLEW) $(ANDROID_SIGNING_PROPS) :app:assembleRelease :app:bundleRelease
	@mkdir -p "$(ANDROID_RELEASE_DIR)"
	cp "$(GRADLE_OUTPUTS)/apk/release/app-release.apk" "$(ANDROID_RELEASE_DIR)/$(PRODUCT)-$(VERSION).apk"
	cp "$(GRADLE_OUTPUTS)/bundle/release/app-release.aab" "$(ANDROID_RELEASE_DIR)/$(PRODUCT)-$(VERSION).aab"
	cp "$(GRADLE_OUTPUTS)/mapping/release/mapping.txt" "$(ANDROID_RELEASE_DIR)/$(PRODUCT)-$(VERSION)-mapping.txt"
	@ls -1 "$(ANDROID_RELEASE_DIR)"
	@if [ -z "$(strip $(ANDROID_KEYSTORE))" ]; then \
		echo "Note: ANDROID_KEYSTORE is not configured (local.mk), so these builds are signed with the debug keystore. They are for local install checks only, not for distribution or store upload."; fi

android-screenshots: android ## Demo vault screenshots: connected phone / tablet × screens × light/dark × 3 languages, to Build/Screenshots/android/
	Android/scripts/screenshots.sh "$(ANDROID_APK)" "$(BUILD_ROOT)/Screenshots/android"

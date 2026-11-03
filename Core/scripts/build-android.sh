#!/usr/bin/env bash
# Builds the core shared library and UniFFI Kotlin bindings for Android (called by make core-android).
#
# Outputs (replaced only when their contents change, so Gradle does not recompile every time):
#   $CORE_BUILD_ROOT/android/jniLibs/arm64-v8a/libkakey_ffi.so   packaged into the app (cargo-ndk, minSdk 33)
#   $CORE_BUILD_ROOT/android/kotlin/com/gicek/kakey/core/kakey_ffi.kt   generated Kotlin bindings (JNA)
#   $CORE_BUILD_ROOT/android/host/libkakey_ffi.dylib   the same core, loaded by JVM unit tests on this machine (macOS arm64)
#
# Rust is always built in release mode: Argon2id (64 MiB) takes seconds in debug.
set -euo pipefail

CORE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
: "${CORE_BUILD_ROOT:?CORE_BUILD_ROOT is required (passed in by the Makefile)}"
export CARGO_TARGET_DIR="$CORE_BUILD_ROOT/target"
OUTPUT="$CORE_BUILD_ROOT/android"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/kakey-core-android.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

# NDK: the environment variable wins; otherwise the highest version installed in the SDK
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
  ANDROID_NDK_HOME="$(ls -d "$SDK"/ndk/* 2>/dev/null | sort -V | tail -1 || true)"
fi
[ -d "${ANDROID_NDK_HOME:-}" ] || { echo "Android NDK not found: install it under $SDK/ndk/ or set ANDROID_NDK_HOME"; exit 1; }
export ANDROID_NDK_HOME
command -v cargo-ndk >/dev/null || { echo "cargo-ndk is missing: cargo install cargo-ndk"; exit 1; }

cd "$CORE_DIR"
cargo ndk --platform 33 -t arm64-v8a -o "$STAGE/jniLibs" build --quiet --locked -p kakey-ffi --release
MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --quiet --locked -p kakey-ffi --release --target aarch64-apple-darwin
HOST_LIB="$CARGO_TARGET_DIR/aarch64-apple-darwin/release/libkakey_ffi.dylib"

cargo run --quiet --locked -p uniffi-bindgen -- generate \
  --library "$HOST_LIB" --language kotlin --out-dir "$STAGE/kotlin" >/dev/null

replace_if_changed() {
  mkdir -p "$(dirname "$2")"
  if ! cmp -s "$1" "$2"; then
    cp "$1" "$2"
    echo "Updated ${2#"$CORE_BUILD_ROOT"/}"
  fi
}
replace_if_changed "$STAGE/jniLibs/arm64-v8a/libkakey_ffi.so" "$OUTPUT/jniLibs/arm64-v8a/libkakey_ffi.so"
replace_if_changed "$STAGE/kotlin/com/gicek/kakey/core/kakey_ffi.kt" "$OUTPUT/kotlin/com/gicek/kakey/core/kakey_ffi.kt"
replace_if_changed "$HOST_LIB" "$OUTPUT/host/libkakey_ffi.dylib"

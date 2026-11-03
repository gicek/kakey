#!/usr/bin/env bash
# Builds KakeyCore.xcframework and the UniFFI Swift bindings for Apple platforms (called by make core-apple).
#
# Outputs (replaced only when their contents change, so Xcode does not recompile the bindings on every build):
#   $CORE_BUILD_ROOT/apple/KakeyCore.xcframework   static libraries for macOS arm64, iOS arm64, and iOS Simulator arm64
#   $CORE_BUILD_ROOT/apple/KakeyCore.swift         generated Swift bindings (compiled into the app targets that use them)
#
# Rust is always built in release mode: Argon2id (64 MiB) takes seconds in debug, which makes unlocking unusable.
set -euo pipefail

CORE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
: "${CORE_BUILD_ROOT:?CORE_BUILD_ROOT is required (passed in by the Makefile)}"
export CARGO_TARGET_DIR="$CORE_BUILD_ROOT/target"
TARGETS=(aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim)
OUTPUT="$CORE_BUILD_ROOT/apple"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/kakey-core-apple.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

cd "$CORE_DIR"
for target in "${TARGETS[@]}"; do
  # Match the Xcode project's deployment targets to avoid "built for newer version" link warnings
  MACOSX_DEPLOYMENT_TARGET=14.0 IPHONEOS_DEPLOYMENT_TARGET=17.0 \
    cargo build --quiet --locked -p kakey-ffi --release --target "$target"
done

# Library mode: generate the bindings from the interface metadata in the compiled library
cargo run --quiet --locked -p uniffi-bindgen -- generate \
  --library "$CARGO_TARGET_DIR/aarch64-apple-darwin/release/libkakey_ffi.dylib" \
  --language swift --out-dir "$STAGE/swift" >/dev/null

mkdir -p "$STAGE/headers"
cp "$STAGE/swift/kakey_ffiFFI.h" "$STAGE/headers/"
cp "$STAGE/swift/kakey_ffiFFI.modulemap" "$STAGE/headers/module.modulemap"

args=()
for target in "${TARGETS[@]}"; do
  args+=(-library "$CARGO_TARGET_DIR/$target/release/libkakey_ffi.a" -headers "$STAGE/headers")
done
xcodebuild -create-xcframework "${args[@]}" -output "$STAGE/KakeyCore.xcframework" >/dev/null

mkdir -p "$OUTPUT"
if ! cmp -s "$STAGE/swift/kakey_ffi.swift" "$OUTPUT/KakeyCore.swift"; then
  cp "$STAGE/swift/kakey_ffi.swift" "$OUTPUT/KakeyCore.swift"
  echo "Updated $OUTPUT/KakeyCore.swift"
fi
# Detect xcframework changes by hashing the static libraries and headers (Info.plist ordering can differ between runs)
fingerprint() {
  find "$1" -type f \( -name '*.a' -o -name '*.h' -o -name '*.modulemap' \) -print0 | sort -z | xargs -0 shasum | awk '{print $1}' | shasum | awk '{print $1}'
}
if [ ! -d "$OUTPUT/KakeyCore.xcframework" ] || [ "$(fingerprint "$STAGE/KakeyCore.xcframework")" != "$(fingerprint "$OUTPUT/KakeyCore.xcframework")" ]; then
  rm -rf "$OUTPUT/KakeyCore.xcframework"
  cp -R "$STAGE/KakeyCore.xcframework" "$OUTPUT/KakeyCore.xcframework"
  echo "Updated $OUTPUT/KakeyCore.xcframework"
fi

#!/usr/bin/env bash
# Packages Kakey.app into a distributable DMG. When opened, the window shows Kakey on the left and an Applications alias on the
# right, with a background suggesting "encrypted as you drag it in"; the mounted volume icon is the system disk icon plus the
# Kakey logo.
#
# Usage: Apple/Mac/scripts/make-dmg.sh <Kakey.app> <output.dmg>
#
# Environment:
#   CODE_SIGN_IDENTITY  When set, signs the DMG with this Developer ID certificate (with a secure timestamp, as notarization
#                       requires); when unset the DMG is unsigned, and the app's own signature is unaffected.
#
# The background and volume icon are read from design/dmg/ (exported and checked in by make icons). Requires dmgbuild in the repo
# root .venv (version in requirements-dev.txt; setup in docs/DEVELOPMENT.md).
# Notarization and stapling are done by the caller (release.sh) on the signed DMG: notarizing the outermost container covers the
# app inside it.
set -euo pipefail

APP_PATH="${1:?usage: make-dmg.sh <Kakey.app> <output.dmg>}"
DMG_PATH="${2:?usage: make-dmg.sh <Kakey.app> <output.dmg>}"
VOLUME_NAME="Kakey"

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/Apple/Mac/scripts"
PYTHON="$ROOT_DIR/.venv/bin/python3"
INSTALL_HINT="python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt"

test -d "$APP_PATH" || { echo "error: $APP_PATH not found" >&2; exit 1; }
test -x "$PYTHON" || { echo "error: .venv is missing: $INSTALL_HINT" >&2; exit 1; }
PYTHONDONTWRITEBYTECODE=1 "$PYTHON" -c 'import dmgbuild' 2>/dev/null \
  || { echo "error: dmgbuild is missing from .venv: .venv/bin/pip install -r requirements-dev.txt" >&2; exit 1; }
ART_DIR="$ROOT_DIR/design/dmg"
for f in background.png background@2x.png volume.icns; do
  test -f "$ART_DIR/$f" || { echo "error: design/dmg/$f is missing; run make icons first" >&2; exit 1; }
done
codesign --verify --deep --strict "$APP_PATH"

DMG_DIR="$(dirname "$DMG_PATH")"
mkdir -p "$DMG_DIR"
rm -f "$DMG_PATH"
PYTHONDONTWRITEBYTECODE=1 "$PYTHON" -m dmgbuild -s "$SCRIPT_DIR/dmg-settings.py" \
  -D app="$APP_PATH" -D art="$ART_DIR" "$VOLUME_NAME" "$DMG_PATH" >/dev/null

if [ -n "${CODE_SIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --sign "$CODE_SIGN_IDENTITY" "$DMG_PATH"
  codesign --verify --strict "$DMG_PATH"
fi

hdiutil verify -quiet "$DMG_PATH"
echo "$DMG_PATH"

#!/usr/bin/env bash
# iPhone / iPad simulator screenshots (make ios-screenshots) using the demo vault (Debug builds only): every screen x light/dark x
# language.
#
# Usage: Apple/iOS/scripts/screenshots.sh <app path> <output dir> [screens] [languages] [appearances]
#   Screens: list category categories detail detail-categories settings manual review lock onboarding
#   Languages: zh-Hans en zh-Hant; appearances: light dark
# Devices: DEVICES="iphone ipad" (default both) picks which to capture; IPHONE_SIMULATOR / IPAD_SIMULATOR choose the simulator,
# defaulting to the first available iPhone / iPad on this machine.
set -euo pipefail

APP="$1"
OUT="$2"
SCREENS="${3:-list category categories detail detail-categories settings manual review lock onboarding}"
LANGUAGES="${4:-zh-Hans en zh-Hant}"
APPEARANCES="${5:-light dark}"
BUNDLE_ID="com.gicek.kakey"
IPHONE="${IPHONE_SIMULATOR:-$(xcrun simctl list devices available | grep -m1 'iPhone' | grep -oE '[0-9A-F-]{36}')}"
IPAD="${IPAD_SIMULATOR:-$(xcrun simctl list devices available | grep -m1 'iPad' | grep -oE '[0-9A-F-]{36}')}"
mkdir -p "$OUT"

prepare() {
  local device="$1"
  xcrun simctl boot "$device" 2>/dev/null || true
  xcrun simctl bootstatus "$device" -b >/dev/null
  xcrun simctl status_bar "$device" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 2>/dev/null || true
  xcrun simctl install "$device" "$APP"
}

shoot() {
  local device="$1" slug="$2" screen="$3" language="$4" appearance="$5"
  local args=(-KakeyDemoVault YES -AppleLanguages "($language)")
  case "$screen" in
    lock) args+=(-KakeyDemoLocked YES) ;;
    onboarding) args+=(-KakeyDemoEmpty YES) ;;
    list) ;;
    *) args+=(-KakeyDemoScreen "$screen") ;;
  esac
  xcrun simctl ui "$device" appearance "$appearance"
  xcrun simctl terminate "$device" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl launch "$device" "$BUNDLE_ID" "${args[@]}" >/dev/null
  # Wait for the Argon2id unlock and UI animations to finish
  sleep 8
  xcrun simctl io "$device" screenshot "$OUT/$slug-$screen-$appearance-$language.png" >/dev/null 2>&1
  echo "$slug-$screen-$appearance-$language.png"
}

for pair in "iphone:$IPHONE" "ipad:$IPAD"; do
  slug="${pair%%:*}"
  device="${pair#*:}"
  case " ${DEVICES:-iphone ipad} " in *" $slug "*) ;; *) continue ;; esac
  [ -n "$device" ] || { echo "No $slug simulator available, skipping"; continue; }
  prepare "$device"
  for language in $LANGUAGES; do
    for appearance in $APPEARANCES; do
      for screen in $SCREENS; do
        shoot "$device" "$slug" "$screen" "$language" "$appearance"
      done
    done
  done
done

#!/usr/bin/env bash
# Demo vault screenshots (Debug builds only; counterpart of Apple/iOS/scripts/screenshots.sh):
# every connected device / emulator x screen x light/dark appearance x three languages, as PNGs in the directory given as
# the second argument.
# Usage: Android/scripts/screenshots.sh <app-debug.apk> <output dir> [screens]
#   Screens: list detail add settings categories manual lock onboarding
set -euo pipefail

APK="$1"
OUT="$2"
SCREENS="${3:-list detail add settings categories manual lock onboarding}"
PACKAGE=com.gicek.kakey
ACTIVITY=$PACKAGE/com.gicek.kakey.android.MainActivity
mkdir -p "$OUT"

devices=$(adb devices | awk 'NR > 1 && $2 == "device" { print $1 }')
[ -n "$devices" ] || { echo "No connected device or emulator (start one first with emulator -avd <name>)"; exit 1; }

for serial in $devices; do
  adb="adb -s $serial"
  width=$($adb shell wm size | grep -oE '[0-9]+x[0-9]+' | tail -1 | cut -dx -f1)
  slug=$([ "${width:-0}" -ge 1600 ] && echo tablet || echo phone)
  $adb install -r "$APK" >/dev/null
  # Turn off the stylus handwriting intro the emulator shows on first input so it does not cover the UI
  $adb shell settings put secure stylus_handwriting_enabled 0 || true
  for language in en zh-Hans zh-Hant; do
    $adb shell cmd locale set-app-locales "$PACKAGE" --locales "$language" >/dev/null
    for appearance in no yes; do
      $adb shell cmd uimode night "$appearance" >/dev/null
      mode=$([ "$appearance" = yes ] && echo dark || echo light)
      for screen in $SCREENS; do
        args=(--ez kakey.demo true)
        case "$screen" in
          lock) args+=(--ez kakey.demo.locked true) ;;
          onboarding) args+=(--ez kakey.demo.empty true) ;;
          list) ;;
          *) args+=(--es kakey.demo.screen "$screen") ;;
        esac
        $adb shell am force-stop "$PACKAGE"
        $adb shell am start -W -n "$ACTIVITY" "${args[@]}" >/dev/null
        # Wait for the Argon2id unlock and UI animations to finish
        sleep 7
        $adb exec-out screencap -p > "$OUT/$slug-$screen-$mode-$language.png"
        echo "$slug-$screen-$mode-$language.png"
      done
    done
  done
  $adb shell cmd uimode night no >/dev/null
  $adb shell cmd locale set-app-locales "$PACKAGE" --locales "" >/dev/null || true
done

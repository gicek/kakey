#!/usr/bin/env bash
# Release build, signing, DMG packaging and (optionally) notarization.
#
# Usage (from the repo root):
#   make mac-release        # recommended: signing / notarization settings can live in local.mk
#   Apple/Mac/scripts/release.sh
#
# Environment:
#   CODE_SIGN_IDENTITY   Developer ID Application certificate name; ad-hoc signing when unset (local use only)
#   MAC_DEVELOPMENT_TEAM Development team ID; together with CODE_SIGN_IDENTITY, uses "archive + Developer ID export", where
#                        automatic signing generates a Developer ID provisioning profile that includes iCloud backup and push
#                        (see docs/DEVELOPMENT.md)
#   ICLOUD_CONTAINER     CloudKit container (passed in by the Makefile)
#   NOTARY_PROFILE       Keychain profile name saved with `xcrun notarytool store-credentials`;
#                        when set, the DMG is submitted for notarization and stapled. Requires an Apple Developer account.
#
# Outputs:
#   Build/macOS/Release/Kakey.app            symlink to the release build of the app
#   Build/macOS/Dist/Kakey-<version>.dmg      distributable disk image (signed when CODE_SIGN_IDENTITY is set; notarized and
#                                             stapled when NOTARY_PROFILE is set)
#   Build/macOS/Dist/Kakey-<version>.env      version, build number, file name and sha256, for verification when uploading
set -euo pipefail

# This script lives in Apple/Mac/scripts/; three levels up is the repo root.
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT_DIR"

VERSION="$(grep -m1 'MARKETING_VERSION' Apple/project.yml | sed 's/[^0-9.]*//g')"
# A symlink to the real product (in DerivedData, or in Export/ for the Developer ID export); APP_PATH is resolved below.
APP_LINK="$ROOT_DIR/Build/macOS/Release/Kakey.app"
DIST_DIR="$ROOT_DIR/Build/macOS/Dist"
DMG_PATH="$DIST_DIR/Kakey-$VERSION.dmg"
ENV_PATH="$DIST_DIR/Kakey-$VERSION.env"

if [ -n "${NOTARY_PROFILE:-}" ] && [ -z "${CODE_SIGN_IDENTITY:-}" ]; then
  # Fail before running tests and bumping the build number, so nothing runs for nothing.
  echo "error: notarization requires Developer ID signing; set CODE_SIGN_IDENTITY as well" >&2
  exit 1
fi

if ! PYTHONDONTWRITEBYTECODE=1 "$ROOT_DIR/.venv/bin/python3" -c 'import dmgbuild' 2>/dev/null; then
  echo "error: building the DMG requires dmgbuild in .venv: python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt" >&2
  exit 1
fi

echo "==> Running tests"
make test

echo "==> Bumping the build number (CFBundleVersion)"
make bump-build

if [ -n "${CODE_SIGN_IDENTITY:-}" ] && [ -n "${MAC_DEVELOPMENT_TEAM:-}" ]; then
  # iCloud and push are restricted entitlements that must be signed with a Developer ID provisioning profile. Re-signing directly
  # with codesign drops the profile, so the app is archived and then exported by Xcode as Developer ID (automatic signing generates
  # the profile). CloudKit uses the Production environment.
  ARCHIVE_PATH="$ROOT_DIR/Build/macOS/Kakey.xcarchive"
  EXPORT_DIR="$ROOT_DIR/Build/macOS/Export"
  EXPORT_OPTIONS="$ROOT_DIR/Build/macOS/ExportOptions.plist"
  echo "==> Archiving the release app (v$VERSION, with iCloud)"
  make alfred-workflow core-apple
  rm -rf "$ARCHIVE_PATH"
  # xcodebuild would treat CODE_SIGN_IDENTITY from the environment as a build setting, so drop it; the export step decides the
  # signing identity.
  env -u CODE_SIGN_IDENTITY xcodebuild -quiet -project Apple/Kakey.xcodeproj -scheme Kakey -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$ROOT_DIR/Build/macOS/DerivedData" \
    -archivePath "$ARCHIVE_PATH" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    KAKEY_DEVELOPMENT_TEAM="$MAC_DEVELOPMENT_TEAM" KAKEY_MAC_SIGN_IDENTITY="Apple Development" \
    KAKEY_MAC_ENTITLEMENTS=Mac/KakeyICloud.entitlements KAKEY_ICLOUD_CONTAINER="${ICLOUD_CONTAINER:?}" archive

  echo "==> Exporting as Developer ID"
  cat >"$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$MAC_DEVELOPMENT_TEAM</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST
  rm -rf "$EXPORT_DIR"
  env -u CODE_SIGN_IDENTITY xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$EXPORT_DIR" -allowProvisioningUpdates
  APP_PATH="$EXPORT_DIR/Kakey.app"
  mkdir -p "$(dirname "$APP_LINK")"
  rm -rf "$APP_LINK"
  ln -s ../Export/Kakey.app "$APP_LINK"
  codesign --verify --deep --strict "$APP_PATH"
  if ! codesign -d --entitlements - "$APP_PATH" 2>/dev/null | grep -q "Production"; then
    echo "error: the exported app has no Production iCloud entitlement" >&2
    exit 1
  fi
else
  echo "==> Building the release app (v$VERSION)"
  make mac CONFIGURATION=Release MAC_DEVELOPMENT_TEAM=
  APP_PATH="$(cd "$APP_LINK" && pwd -P)"
  if [ -n "${CODE_SIGN_IDENTITY:-}" ]; then
    echo "==> Re-signing with Developer ID ($CODE_SIGN_IDENTITY); MAC_DEVELOPMENT_TEAM is not set, so this build has no iCloud backup"
    codesign --force --options runtime \
      --timestamp --entitlements Apple/Mac/Kakey.entitlements \
      --sign "$CODE_SIGN_IDENTITY" "$APP_PATH"
  else
    echo "CODE_SIGN_IDENTITY is not set; keeping the ad-hoc signature (no iCloud backup). This build works on this Mac; distributing it requires Developer ID signing + notarization."
  fi
fi

echo "==> Packaging the DMG"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}" Apple/Mac/scripts/make-dmg.sh "$APP_PATH" "$DMG_PATH"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  # Notarize only the outermost DMG: the notary service checks and records the app inside, and once the ticket is stapled to the
  # DMG, mounting offline still passes Gatekeeper.
  echo "==> Submitting for notarization (profile: $NOTARY_PROFILE)"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "==> Stapling the notarization ticket"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"
fi

BUILD_NUMBER="$(grep -m1 'CURRENT_PROJECT_VERSION' Apple/project.yml | sed 's/[^0-9]*//g')"
cat >"$ENV_PATH" <<ENV
VERSION=$VERSION
BUILD=$BUILD_NUMBER
FILE=$(basename "$DMG_PATH")
SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
SIGNED=$([ -n "${CODE_SIGN_IDENTITY:-}" ] && echo yes || echo no)
NOTARIZED=$([ -n "${NOTARY_PROFILE:-}" ] && echo yes || echo no)
ENV

echo "==> Done"
echo "$DMG_PATH"
cat "$ENV_PATH"

#!/bin/bash
# Builds an unsigned .ipa for attaching to a GitHub release, alongside the
# source archive. Unsigned means: no code signing identity, no provisioning
# profile -- the .app (and its embedded frameworks) ship byte-for-byte as
# Xcode built them, un-notarized and un-codesigned. It will NOT install on a
# real device or in a simulator as-is; it exists so the build artifact for a
# given tag is auditable/reproducible without requiring the signing team's
# certificate, and so it can be re-signed downstream if needed.
#
# Usage: Scripts/build-unsigned-ipa.sh [output-dir]
set -euo pipefail

SRCROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-$SRCROOT/build}"

mkdir -p "$OUT_DIR"
ARCHIVE_PATH=$(mktemp -d)/Fellship-unsigned.xcarchive
WORK_DIR=$(mktemp -d)
# A dedicated DerivedData path, not the one used for normal (signed) builds
# and tests in this project. Sharing it is what bit us once already: Xcode's
# incremental build system reused a previously-signed binary instead of
# rebuilding unsigned, since CODE_SIGNING_ALLOWED isn't part of its cache key.
DERIVED_DATA=$(mktemp -d)

echo "Archiving unsigned build (isolated DerivedData)..."
xcodebuild -project "$SRCROOT/Fellship.xcodeproj" -scheme Fellship \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  clean archive

APP_PATH="$ARCHIVE_PATH/Products/Applications/Fellship.app"
if [ ! -d "$APP_PATH" ]; then
  echo "error: expected .app not found at $APP_PATH" >&2
  exit 1
fi

# Confirm it's genuinely unsigned before shipping it as such. codesign exits
# non-zero for the "not signed at all" case -- under `set -o pipefail` that
# poisons a piped `if` condition's exit status even when grep itself matched,
# so capture the output first and grep it separately.
codesign_output=$(codesign -dv "$APP_PATH" 2>&1 || true)
if echo "$codesign_output" | grep -q "is not signed at all"; then
  echo "Confirmed unsigned."
else
  echo "error: archive appears to be signed; refusing to publish as 'unsigned'" >&2
  echo "$codesign_output" >&2
  exit 1
fi

MARKETING_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Info.plist")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Info.plist")
IPA_NAME="Fellship-v${MARKETING_VERSION}-${BUILD_NUMBER}-unsigned.ipa"

mkdir -p "$WORK_DIR/Payload"
cp -R "$APP_PATH" "$WORK_DIR/Payload/"
( cd "$WORK_DIR" && zip -qr "$IPA_NAME" Payload )
mv "$WORK_DIR/$IPA_NAME" "$OUT_DIR/$IPA_NAME"
rm -rf "$WORK_DIR" "$(dirname "$ARCHIVE_PATH")" "$DERIVED_DATA"

echo "Built: $OUT_DIR/$IPA_NAME"

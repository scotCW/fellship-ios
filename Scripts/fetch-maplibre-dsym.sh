#!/bin/bash
# Archive-only build step: MapLibre ships as a precompiled binary xcframework
# (via SPM) with no bundled dSYM, which trips an App Store Connect warning
# ("The archive did not include a dSYM for the MapLibre.framework...").
# MapLibre Native's GitHub releases DO publish a matching dSYM as a separate
# asset at the same version tag — this fetches it, verifies its UUID against
# the framework binary actually linked into this build, and only then copies
# it into the archive's dSYMs folder. If anything doesn't line up (no
# network, version drift, UUID mismatch) this fails soft: it warns and exits
# 0, leaving the archive exactly as it would have been without this script.
set -uo pipefail

if [ -z "${DWARF_DSYM_FOLDER_PATH:-}" ]; then
  exit 0
fi

FRAMEWORK_BINARY="${CODESIGNING_FOLDER_PATH}/Frameworks/MapLibre.framework/MapLibre"
if [ ! -f "$FRAMEWORK_BINARY" ]; then
  echo "note: MapLibre.framework not found at expected path, skipping dSYM fetch"
  exit 0
fi

RESOLVED="${SRCROOT}/Fellship.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
VERSION=$(/usr/bin/python3 -c "
import json
try:
    d = json.load(open('$RESOLVED'))
    for p in d['pins']:
        if p['identity'] == 'maplibre-gl-native-distribution':
            print(p['state']['version'])
            break
except Exception:
    pass
")

if [ -z "$VERSION" ]; then
  echo "warning: could not determine MapLibre version from Package.resolved; skipping dSYM fetch"
  exit 0
fi

EXPECTED_UUID=$(dwarfdump --uuid "$FRAMEWORK_BINARY" | awk '{print $2}' | head -1)
if [ -z "$EXPECTED_UUID" ]; then
  echo "warning: could not read MapLibre.framework's UUID; skipping dSYM fetch"
  exit 0
fi

DEST="${DWARF_DSYM_FOLDER_PATH}/MapLibre.framework.dSYM"
if [ -d "$DEST" ]; then
  EXISTING_UUID=$(dwarfdump --uuid "$DEST" 2>/dev/null | awk '{print $2}' | head -1)
  if [ "$EXISTING_UUID" == "$EXPECTED_UUID" ]; then
    echo "MapLibre dSYM already present with matching UUID ($EXPECTED_UUID)"
    exit 0
  fi
fi

CACHE_DIR="${HOME}/Library/Caches/Fellship/maplibre-dsym"
mkdir -p "$CACHE_DIR"
ZIP_PATH="${CACHE_DIR}/MapLibre_ios_device.framework.dSYM-${VERSION}.zip"
URL="https://github.com/maplibre/maplibre-native/releases/download/ios-v${VERSION}/MapLibre_ios_device.framework.dSYM.zip"

if [ ! -f "$ZIP_PATH" ]; then
  echo "Fetching MapLibre dSYM for version ${VERSION}"
  if ! curl -sL --fail -o "$ZIP_PATH" "$URL"; then
    echo "warning: could not download MapLibre dSYM from $URL (no network, or this version has no matching release asset). Archive will keep Apple's standard missing-dSYM warning for MapLibre.framework."
    rm -f "$ZIP_PATH"
    exit 0
  fi
fi

EXTRACT_DIR=$(mktemp -d)
unzip -q "$ZIP_PATH" -d "$EXTRACT_DIR"
SRC_DSYM=$(find "$EXTRACT_DIR" -iname "*.dSYM" -maxdepth 2 | head -1)
if [ -z "$SRC_DSYM" ]; then
  echo "warning: downloaded MapLibre dSYM archive did not contain a .dSYM bundle; skipping"
  rm -rf "$EXTRACT_DIR"
  exit 0
fi

DOWNLOADED_UUID=$(dwarfdump --uuid "$SRC_DSYM" | awk '{print $2}' | head -1)
if [ "$DOWNLOADED_UUID" != "$EXPECTED_UUID" ]; then
  echo "warning: downloaded MapLibre dSYM UUID ($DOWNLOADED_UUID) does not match the linked MapLibre.framework UUID ($EXPECTED_UUID) -- not installing it. The pinned version's release tag naming may not line up; check manually."
  rm -rf "$EXTRACT_DIR"
  exit 0
fi

rm -rf "$DEST"
cp -R "$SRC_DSYM" "$DEST"
rm -rf "$EXTRACT_DIR"
echo "Installed MapLibre.framework.dSYM (UUID $EXPECTED_UUID) into archive"

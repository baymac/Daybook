#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="${DAYBOOK_BUILD_DIR:-$ROOT/.build}"
APP="${DAYBOOK_APP_PATH:-$BUILD/Daybook.app}"
mkdir -p "$BUILD" "$(dirname "$APP")"
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"

ensure_not_running() {
  local running
  running=$(/bin/ps -axo comm= | /usr/bin/awk -v executable="$APP/Contents/MacOS/Daybook" \
    '$0 == executable { found=1 } END { if (found) print "yes" }')
  if [ -n "$running" ]; then
    echo "Quit Daybook before replacing this app. The running app was not changed." >&2
    exit 1
  fi
}

ensure_not_running
PACKAGE_ROOT="$(mktemp -d "$BUILD/package.XXXXXX")"
trap 'rm -rf "$PACKAGE_ROOT"' EXIT
STAGED_APP="$PACKAGE_ROOT/Daybook.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 \
  "$ROOT"/Sources/Daybook/*.swift -lsqlite3 -o "$STAGED_APP/Contents/MacOS/Daybook"
cp "$ROOT/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 \
  "$ROOT/Sources/VideoBridge/VideoBridge.swift" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
  -Xlinker "$ROOT/Sources/VideoBridge/Info.plist" \
  -o "$STAGED_APP/Contents/MacOS/DaybookVideoBridge"
codesign --force --sign - --identifier local.daybook.video.bridge --options runtime \
  --entitlements "$ROOT/Sources/VideoBridge/Bridge.entitlements" \
  "$STAGED_APP/Contents/MacOS/DaybookVideoBridge"
cp -R "$ROOT/Extension" "$STAGED_APP/Contents/Resources/VideoExtension"
if [ -f "$ROOT/Resources/Daybook.icns" ]; then
  cp "$ROOT/Resources/Daybook.icns" "$STAGED_APP/Contents/Resources/Daybook.icns"
fi
codesign --force --sign - --options runtime --entitlements "$ROOT/Resources/Daybook.entitlements" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

# Check again in case the app was opened during compilation. Publish a complete
# signed bundle; never truncate/re-sign an executable that another process maps.
ensure_not_running
if [ -e "$APP" ]; then mv "$APP" "$PACKAGE_ROOT/previous.app"; fi
if ! mv "$STAGED_APP" "$APP"; then
  if [ -e "$PACKAGE_ROOT/previous.app" ]; then mv "$PACKAGE_ROOT/previous.app" "$APP"; fi
  exit 1
fi
echo "Built $APP"

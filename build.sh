#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="${DAYBOOK_BUILD_DIR:-$ROOT/.build}"
APP="${DAYBOOK_APP_PATH:-$BUILD/Daybook.app}"
SIGNING_IDENTITY="${DAYBOOK_SIGNING_IDENTITY:--}"
SIGNING_OPTIONS=(--options runtime)
if [ "$SIGNING_IDENTITY" != - ]; then SIGNING_OPTIONS+=(--timestamp); fi
mkdir -p "$BUILD" "$(dirname "$APP")"
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"

ensure_not_running() {
  local running
  running=""
  while IFS= read -r executable; do
    if [ "$executable" = "$APP/Contents/MacOS/Daybook" ] || [ "$executable" -ef "$APP/Contents/MacOS/Daybook" ]; then
      running=yes
      break
    fi
  done < <(/bin/ps -axo comm= | /usr/bin/awk '/\/Contents\/MacOS\/Daybook$/')
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
for ARCH in arm64 x86_64; do
  SLICE="$PACKAGE_ROOT/$ARCH"
  mkdir -p "$SLICE"
  swiftc -swift-version 5 -O -parse-as-library -target "$ARCH-apple-macosx14.0" \
    "$ROOT"/Sources/Daybook/*.swift -lsqlite3 -o "$SLICE/Daybook"
  swiftc -swift-version 5 -O -target "$ARCH-apple-macosx14.0" \
    "$ROOT/Sources/VideoBridge/VideoBridge.swift" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
    -Xlinker "$ROOT/Sources/VideoBridge/Info.plist" \
    -o "$SLICE/DaybookVideoBridge"
done
lipo -create "$PACKAGE_ROOT/arm64/Daybook" "$PACKAGE_ROOT/x86_64/Daybook" \
  -output "$STAGED_APP/Contents/MacOS/Daybook"
lipo -create "$PACKAGE_ROOT/arm64/DaybookVideoBridge" "$PACKAGE_ROOT/x86_64/DaybookVideoBridge" \
  -output "$STAGED_APP/Contents/MacOS/DaybookVideoBridge"
cp "$ROOT/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
codesign --force --sign "$SIGNING_IDENTITY" --identifier local.daybook.video.bridge "${SIGNING_OPTIONS[@]}" \
  --entitlements "$ROOT/Sources/VideoBridge/Bridge.entitlements" \
  "$STAGED_APP/Contents/MacOS/DaybookVideoBridge"
cp -R "$ROOT/Extension" "$STAGED_APP/Contents/Resources/VideoExtension"
# Local pairing material must never become part of an app or release archive.
rm -f "$STAGED_APP/Contents/Resources/VideoExtension/local-pairing.json"
cp -R "$STAGED_APP/Contents/Resources/VideoExtension" "$PACKAGE_ROOT/Daybook-Helper"
/usr/bin/ditto -c -k --keepParent "$PACKAGE_ROOT/Daybook-Helper" "$STAGED_APP/Contents/Resources/Daybook-Helper.zip"
HELPER_SHA=$(/usr/bin/shasum -a 256 "$STAGED_APP/Contents/Resources/Daybook-Helper.zip" | /usr/bin/awk '{print $1}')
/usr/libexec/PlistBuddy -c "Add :DaybookHelperSHA256 string $HELPER_SHA" "$STAGED_APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/Daybook.icns" ]; then
  cp "$ROOT/Resources/Daybook.icns" "$STAGED_APP/Contents/Resources/Daybook.icns"
fi
codesign --force --sign "$SIGNING_IDENTITY" "${SIGNING_OPTIONS[@]}" --entitlements "$ROOT/Resources/Daybook.entitlements" "$STAGED_APP"
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

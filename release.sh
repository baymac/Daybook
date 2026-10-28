#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="${DAYBOOK_BUILD_DIR:-$ROOT/.build}"
APP="${DAYBOOK_APP_PATH:-$BUILD/Daybook.app}"
NOTARY_PROFILE="${DAYBOOK_NOTARY_PROFILE:-}"
if [ -n "$NOTARY_PROFILE" ] && [ "${DAYBOOK_SIGNING_IDENTITY:--}" = - ]; then
  echo "Notarization requires DAYBOOK_SIGNING_IDENTITY with a Developer ID Application certificate." >&2
  exit 1
fi
"$ROOT/build.sh"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
for EXECUTABLE in Daybook DaybookVideoBridge; do
  /usr/bin/lipo "$APP/Contents/MacOS/$EXECUTABLE" -verify_arch arm64 x86_64
done
RELEASE="$BUILD/release"
mkdir -p "$RELEASE"
STAGE="$(mktemp -d "$BUILD/dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
notarize() {
  local artifact="$1" result="$2"
  /usr/bin/xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" --wait \
    --output-format json > "$result"
  /usr/bin/python3 - "$result" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get("status") != "Accepted":
    raise SystemExit("Apple did not accept this submission. Review the notarization result before publishing.")
PY
}
if [ -n "$NOTARY_PROFILE" ]; then
  echo "Submitting the signed app to Apple…"
  /usr/bin/ditto -c -k --keepParent "$APP" "$STAGE/Daybook.zip"
  notarize "$STAGE/Daybook.zip" "$RELEASE/app-notarization.json"
  /usr/bin/xcrun stapler staple "$APP"
  /usr/bin/xcrun stapler validate "$APP"
fi
/usr/bin/ditto "$APP" "$STAGE/Daybook.app"
rm -f "$STAGE/Daybook.zip"
ln -s /Applications "$STAGE/Applications"
/usr/bin/hdiutil create -volname Daybook -srcfolder "$STAGE" -format UDZO -ov "$RELEASE/Daybook-v$VERSION-universal.dmg"
if [ "${DAYBOOK_SIGNING_IDENTITY:--}" != - ]; then
  /usr/bin/codesign --force --sign "$DAYBOOK_SIGNING_IDENTITY" --timestamp "$RELEASE/Daybook-v$VERSION-universal.dmg"
fi
if [ -n "$NOTARY_PROFILE" ]; then
  echo "Submitting the installer to Apple…"
  notarize "$RELEASE/Daybook-v$VERSION-universal.dmg" "$RELEASE/dmg-notarization.json"
  /usr/bin/xcrun stapler staple "$RELEASE/Daybook-v$VERSION-universal.dmg"
  /usr/bin/xcrun stapler validate "$RELEASE/Daybook-v$VERSION-universal.dmg"
  /usr/sbin/spctl --assess --type execute --verbose "$APP"
else
  echo "This build is not notarized. Set DAYBOOK_SIGNING_IDENTITY and DAYBOOK_NOTARY_PROFILE for an Apple-notarized release."
fi
cp "$APP/Contents/Resources/Daybook-Helper.zip" "$RELEASE/Daybook-Helper.zip"
(
  cd "$RELEASE"
  /usr/bin/shasum -a 256 "Daybook-v$VERSION-universal.dmg" Daybook-Helper.zip > SHA256SUMS.txt
)
echo "Release files: $RELEASE"

#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="${DAYBOOK_BUILD_DIR:-$ROOT/.build/tests}"
mkdir -p "$BUILD"
swiftc -swift-version 5 "$ROOT/Sources/Daybook/Store.swift" "$ROOT/Sources/Daybook/Playback.swift" "$ROOT/Tests/StoreTests.swift" -lsqlite3 -o "$BUILD/store-tests"
"$BUILD/store-tests"
swiftc -swift-version 5 "$ROOT/Sources/Daybook/Store.swift" "$ROOT/Sources/Daybook/Playback.swift" "$ROOT/Sources/Daybook/Analytics.swift" "$ROOT/Tests/AnalyticsTests.swift" -lsqlite3 -o "$BUILD/analytics-tests"
"$BUILD/analytics-tests"
swiftc -swift-version 5 "$ROOT/Sources/Daybook/Store.swift" "$ROOT/Sources/Daybook/Playback.swift" "$ROOT/Tests/PlaybackTests.swift" -lsqlite3 -o "$BUILD/playback-tests"
"$BUILD/playback-tests"
node --test "$ROOT/Tests/VideoExtensionTests.cjs"
python3 "$ROOT/Tests/BuildScriptTests.py"
python3 "$ROOT/Tests/BridgeInstallerTests.py"

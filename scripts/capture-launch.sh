#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"
SIMULATOR_ID="$(cat build/simulator-id.txt)"
APP_PATH="$PROJECT_ROOT/build/simulator/Build/Products/Debug-iphonesimulator/MetaCine.app"
test -f "$APP_PATH/MetaCine"

# XCTest may use a cloned device, so install on the original selected simulator.
xcrun simctl boot "$SIMULATOR_ID" 2>/dev/null || true
xcrun simctl bootstatus "$SIMULATOR_ID" -b
xcrun simctl install "$SIMULATOR_ID" "$APP_PATH"
xcrun simctl launch "$SIMULATOR_ID" app.metacine.ios
sleep 3
mkdir -p build/screenshots
xcrun simctl io "$SIMULATOR_ID" screenshot build/screenshots/first-launch.png

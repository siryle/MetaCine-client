#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"
node scripts/generate-project.mjs

SIMULATOR_ID="${SIMULATOR_ID:-$(xcrun simctl list devices available --json | python3 -c '
import json, sys
data = json.load(sys.stdin)
devices = [
    device
    for runtime, values in data["devices"].items() if ".iOS-" in runtime
    for device in values
    if device.get("isAvailable") and device["name"].startswith("iPhone")
]
if not devices:
    sys.exit("No available iPhone simulator. Install an iOS simulator runtime in Xcode.")
print(devices[0]["udid"])
')}"

mkdir -p build
printf '%s\n' "$SIMULATOR_ID" > build/simulator-id.txt

xcodebuild \
    -project MetaCine.xcodeproj \
    -scheme MetaCine \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
    -parallel-testing-enabled NO \
    -derivedDataPath build/simulator \
    -resultBundlePath "build/TestResults-${TEST_RUN_ID:-$(date +%s)}.xcresult" \
    CODE_SIGNING_ALLOWED=NO \
    test

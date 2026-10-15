#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

VERSION="${APP_VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
OUTPUT_DIR="$PROJECT_ROOT/dist"
DERIVED_DATA="$PROJECT_ROOT/build/device"
PACKAGE_ROOT="$PROJECT_ROOT/build/ipa-package"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "APP_VERSION must be a three-part numeric version, for example 1.0.0." >&2
    exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "BUILD_NUMBER must be numeric." >&2
    exit 1
fi

node scripts/generate-project.mjs
mkdir -p "$OUTPUT_DIR" "$PACKAGE_ROOT/Payload"

xcodebuild \
    -project MetaCine.xcodeproj \
    -scheme MetaCine \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY= \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    build

APP_PATH="$DERIVED_DATA/Build/Products/Release-iphoneos/MetaCine.app"
test -f "$APP_PATH/MetaCine"
test -f "$APP_PATH/Info.plist"

# Use a fresh staging tree, including when a build is repeated locally.
if [[ -d "$PACKAGE_ROOT/Payload/MetaCine.app" ]]; then
    rm -rf "$PACKAGE_ROOT/Payload/MetaCine.app"
fi
ditto "$APP_PATH" "$PACKAGE_ROOT/Payload/MetaCine.app"
find "$PACKAGE_ROOT/Payload" -type d -name _CodeSignature -prune -exec rm -rf {} +
find "$PACKAGE_ROOT/Payload" -name embedded.mobileprovision -delete

IPA_PATH="$OUTPUT_DIR/MetaCine-${VERSION}-unsigned.ipa"
if [[ -f "$IPA_PATH" ]]; then rm "$IPA_PATH"; fi
(
    cd "$PACKAGE_ROOT"
    /usr/bin/zip -qry "$IPA_PATH" Payload
)
unzip -tq "$IPA_PATH"
(
    cd "$OUTPUT_DIR"
    shasum -a 256 "$(basename "$IPA_PATH")" > "$(basename "$IPA_PATH").sha256"
)
echo "Built unsigned IPA: $IPA_PATH"

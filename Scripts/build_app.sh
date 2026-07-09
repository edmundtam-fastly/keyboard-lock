#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="KeyboardLock"
BUNDLE_ID="com.edmundtam.keyboardlock"
BUILD_CONFIG="release"
SIGNING_IDENTITY="KeyboardLock Local Dev"

swift build -c "${BUILD_CONFIG}"

BIN_PATH=".build/${BUILD_CONFIG}/${APP_NAME}"
APP_DIR="build/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}"
cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"

cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Personal use</string>
</dict>
</plist>
PLIST

if security find-identity -v -p codesigning | grep -q "${SIGNING_IDENTITY}"; then
    codesign --force --deep --sign "${SIGNING_IDENTITY}" "${APP_DIR}"
else
    echo "Warning: signing identity '${SIGNING_IDENTITY}' not found — falling back to ad-hoc signing."
    echo "Run ./Scripts/setup_signing_identity.sh once so Accessibility/Input Monitoring grants survive rebuilds."
    codesign --force --deep --sign - "${APP_DIR}"
fi

echo "Built ${APP_DIR}"
echo "Run with: open \"${APP_DIR}\""

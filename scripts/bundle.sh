#!/usr/bin/env bash
set -euo pipefail

APP_NAME="SnowDesktop"
APP_DIR=".build/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
PLIST_PATH="${CONTENTS_DIR}/Info.plist"
BUNDLE_ID="dev.snowdesktop.app"
MIN_SYSTEM_VERSION="14.0"

swift build -c release

BIN_PATH="$(swift build --show-bin-path -c release)"
EXECUTABLE_PATH="${BIN_PATH}/${APP_NAME}"

if [[ ! -f "${EXECUTABLE_PATH}" ]]; then
  echo "Executable not found: ${EXECUTABLE_PATH}" >&2
  exit 1
fi

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}"

cp "${EXECUTABLE_PATH}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

cat > "${PLIST_PATH}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MIN_SYSTEM_VERSION}</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

echo "${APP_DIR}"

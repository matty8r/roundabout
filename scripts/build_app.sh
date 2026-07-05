#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP_NAME="Breadcrumbs"
APP_PATH="${APP_NAME}.app"
BINARY_PATH=".build/${CONFIG}/${APP_NAME}"

echo "Building (${CONFIG})..."
swift build -c "${CONFIG}"

echo "Assembling ${APP_PATH}..."
rm -rf "${APP_PATH}"
mkdir -p "${APP_PATH}/Contents/MacOS"
cp "${BINARY_PATH}" "${APP_PATH}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${APP_PATH}/Contents/Info.plist"

echo "Ad-hoc signing..."
codesign --force --deep --sign - "${APP_PATH}"

echo "Done: ${APP_PATH}"

#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP_NAME="Roundabout"
APP_PATH="${APP_NAME}.app"
BINARY_PATH=".build/${CONFIG}/${APP_NAME}"

echo "Building (${CONFIG})..."
swift build -c "${CONFIG}"

echo "Assembling ${APP_PATH}..."
rm -rf "${APP_PATH}"
mkdir -p "${APP_PATH}/Contents/MacOS" "${APP_PATH}/Contents/Resources"
cp "${BINARY_PATH}" "${APP_PATH}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${APP_PATH}/Contents/Info.plist"

# AppIcon.svg (full-color, with the blue disc) is rendered below into an .icns for the
# Finder/Login-Items/About-panel surfaces, which need a raster icon rather than a vector
# one. MenuBarIcon.svg (arrows only, no disc) is bundled as-is and loaded directly at
# runtime by StatusItemController as a template image for the status item glyph — a filled
# disc doesn't read well as a small monochrome menu bar icon the way it does as an app icon.
cp "Resources/AppIcon.svg" "${APP_PATH}/Contents/Resources/AppIcon.svg"
cp "Resources/MenuBarIcon.svg" "${APP_PATH}/Contents/Resources/MenuBarIcon.svg"

echo "Generating app icon..."
ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
mkdir -p "${ICONSET_DIR}"
# (pixel size : iconset filename) pairs iconutil requires — rasterizing straight from the
# SVG at each target size (rather than downsampling one master PNG) keeps edges crisp at
# every size, since sips renders the vector source fresh each time.
ICON_SIZES=(
    "16:icon_16x16.png"
    "32:icon_16x16@2x.png"
    "32:icon_32x32.png"
    "64:icon_32x32@2x.png"
    "128:icon_128x128.png"
    "256:icon_128x128@2x.png"
    "256:icon_256x256.png"
    "512:icon_256x256@2x.png"
    "512:icon_512x512.png"
    "1024:icon_512x512@2x.png"
)
for entry in "${ICON_SIZES[@]}"; do
    px="${entry%%:*}"
    name="${entry#*:}"
    sips -s format png -z "${px}" "${px}" "Resources/AppIcon.svg" --out "${ICONSET_DIR}/${name}" >/dev/null
done
iconutil -c icns "${ICONSET_DIR}" -o "${APP_PATH}/Contents/Resources/${APP_NAME}.icns"
rm -rf "$(dirname "${ICONSET_DIR}")"

if [ "${CONFIG}" = "release" ]; then
    # Ad-hoc signing (used for debug below) has no stable Team ID, so Gatekeeper/TCC
    # treat every rebuild as a new identity — fine for the inner dev loop, but
    # distribution needs a real identity: Developer ID + Hardened Runtime + a secure
    # timestamp are all mandatory prerequisites for notarization (see scripts/release.sh,
    # which drives this CONFIG=release path and then notarizes/staples the result).
    echo "Signing with Developer ID (release)..."
    codesign --force --options runtime --timestamp \
        --sign "Developer ID Application: Matthew Silas (CG3Q63736Q)" \
        --entitlements "Resources/Roundabout.entitlements" \
        "${APP_PATH}"
else
    echo "Ad-hoc signing..."
    codesign --force --deep --sign - "${APP_PATH}"
fi

echo "Done: ${APP_PATH}"

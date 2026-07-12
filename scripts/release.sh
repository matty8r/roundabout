#!/bin/bash
# Builds, signs, notarizes, staples, and packages a distributable Roundabout.dmg.
# Requires: a "Developer ID Application" certificate in Keychain (see build_app.sh),
# and notarization credentials stored under the "roundabout-notary" keychain profile —
# set up once via:
#   xcrun notarytool store-credentials "roundabout-notary" \
#       --apple-id "you@example.com" --team-id "CG3Q63736Q"
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Roundabout"
APP_PATH="${APP_NAME}.app"
NOTARY_PROFILE="roundabout-notary"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DMG_NAME="${APP_NAME}-${VERSION}.dmg"

echo "== Building release =="
./scripts/build_app.sh release

# The notary service only accepts a zip/dmg/pkg upload, not a raw .app — but the ticket
# it grants is tied to the app's own code signature, so stapling straight to the .app
# (rather than only to the eventual DMG) means the app stays Gatekeeper-trusted even if
# someone copies it out of the DMG, re-zips it, or it's distributed some other way later.
echo "== Zipping for notarization submission =="
ZIP_DIR="$(mktemp -d)"
ZIP_PATH="${ZIP_DIR}/${APP_NAME}.zip"
ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"

echo "== Submitting to Apple notary service (this can take a few minutes) =="
SUBMIT_OUTPUT="$(xcrun notarytool submit "${ZIP_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait)"
echo "${SUBMIT_OUTPUT}"
SUBMISSION_ID="$(echo "${SUBMIT_OUTPUT}" | awk '/id:/{print $2; exit}')"

if ! echo "${SUBMIT_OUTPUT}" | grep -q "status: Accepted"; then
    echo "Notarization failed — fetching log..."
    xcrun notarytool log "${SUBMISSION_ID}" --keychain-profile "${NOTARY_PROFILE}"
    exit 1
fi

echo "== Stapling notarization ticket to ${APP_PATH} =="
xcrun stapler staple "${APP_PATH}"
xcrun stapler validate "${APP_PATH}"

echo "== Building ${DMG_NAME} (custom layout) =="
rm -f "${DMG_NAME}"

# Rendered fresh each release, same pattern build_app.sh uses for AppIcon.svg — 1:1 pixel
# size (660x400) matching the window's point dimensions exactly. Tried 2x (1320x800) first
# for Retina crispness, but Finder does not scale-fit a DMG background image to the window;
# it draws it at native pixel size, so the 2x version rendered twice as large as the window
# and put the arrow roughly 40 points lower than the icons instead of centered between them.
BACKGROUND_PNG="$(mktemp -d)/background.png"
sips -s format png -z 400 660 "Resources/DMGBackground.svg" --out "${BACKGROUND_PNG}" >/dev/null

STAGING="$(mktemp -d)/dmg-staging"
mkdir -p "${STAGING}/.background"
cp -R "${APP_PATH}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"
cp "${BACKGROUND_PNG}" "${STAGING}/.background/background.png"

# A plain `hdiutil create -format UDZO` straight from the staging folder (the old approach)
# produces a read-only image with no way to set Finder window/icon layout afterward — that
# has to happen on a writable, mounted volume first, which then gets converted to the final
# compressed read-only image as a separate step below.
TMP_DMG="$(mktemp -d)/tmp-${APP_NAME}.dmg"
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGING}" -ov -fs HFS+ -format UDRW -size 100m "${TMP_DMG}"

# A stale mount from an interrupted previous run would make hdiutil auto-rename this one to
# "Roundabout 1", breaking the `tell disk "Roundabout"` reference below.
if [ -d "/Volumes/${APP_NAME}" ]; then
    hdiutil detach "/Volumes/${APP_NAME}" -force || true
fi
hdiutil attach "${TMP_DMG}" -readwrite -noverify -noautoopen

# Positions/bounds are in the same 660x400 point space DMGBackground.svg's own comment
# describes — app icon left, Applications alias right, arrow in the gap between them.
# The close/open/update dance is a long-standing Finder quirk: view options set on a
# window that's already open don't reliably redraw without being forced to reopen.
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "${APP_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 520}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 96
        set background picture of theViewOptions to file ".background:background.png"
        set position of item "${APP_NAME}.app" of container window to {180, 190}
        set position of item "Applications" of container window to {480, 190}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

hdiutil detach "/Volumes/${APP_NAME}"
hdiutil convert "${TMP_DMG}" -format UDZO -ov -o "${DMG_NAME}"

echo "== Verifying Gatekeeper acceptance =="
spctl --assess --type execute --verbose "${APP_PATH}"

# A second, version-agnostic copy so the download link on branchesthreads.com can point at
# /releases/latest/download/Roundabout.dmg forever — GitHub's "latest" redirect resolves by
# release recency, but the asset *filename* in that URL must be identical release to release,
# which a version-embedded name like Roundabout-0.1.dmg can't provide on its own.
cp "${DMG_NAME}" "${APP_NAME}.dmg"

echo "Done: ${DMG_NAME} (plus ${APP_NAME}.dmg, a copy for the stable /releases/latest/download/ URL)"
echo ""
echo "To publish this release:"
echo "  git tag v${VERSION} && git push origin v${VERSION}"
echo "  gh release create v${VERSION} ${DMG_NAME} ${APP_NAME}.dmg --repo matty8r/roundabout --title \"Roundabout ${VERSION}\" --notes \"...\""

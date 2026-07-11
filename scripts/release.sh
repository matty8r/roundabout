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

echo "== Building ${DMG_NAME} =="
rm -f "${DMG_NAME}"
STAGING="$(mktemp -d)/dmg-staging"
mkdir -p "${STAGING}"
cp -R "${APP_PATH}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGING}" -ov -format UDZO "${DMG_NAME}"

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

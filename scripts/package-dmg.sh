#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

bash scripts/package.sh
APP="dist/DansWriter.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
case "$VERSION" in
  *[!0-9.]*|"") echo "Invalid release version" >&2; exit 1 ;;
esac
DMG="dist/DansWriter-${VERSION}-arm64.dmg"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/danswriter-dmg.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

# Only the distributable bundle enters the image. Drafts and credentials live
# outside it and are never collected by this script.
ditto "$APP" "$STAGE/DansWriter.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Install.txt" <<'INSTALL'
DansWriter for Apple silicon

Drag DansWriter into Applications. Requires macOS 13 or later.
To update, quit DansWriter and replace the app. Writing files are stored separately.

See the release notes for signing and Apple notarisation status.
INSTALL
hdiutil create -volname DansWriter -srcfolder "$STAGE" -format UDZO -ov "$DMG"
if [ "${DANSWRITER_SIGN_IDENTITY:--}" != "-" ]; then
  codesign --force --timestamp --sign "$DANSWRITER_SIGN_IDENTITY" "$DMG"
fi
hdiutil verify "$DMG"
(cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo DANSWRITER_DMG_VERIFIED

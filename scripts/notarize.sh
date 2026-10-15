#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DANSWRITER_SIGN_IDENTITY:?Set the installed Developer ID identity}"
: "${DANSWRITER_NOTARY_PROFILE:?Set the saved notarytool profile name}"
if [ "$DANSWRITER_SIGN_IDENTITY" = "-" ]; then
  echo "Notarisation requires Developer ID signing" >&2; exit 1
fi
bash scripts/package.sh
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/danswriter-notary.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
umask 077
ditto -c -k --keepParent dist/DansWriter.app "$STAGE/DansWriter.zip"
xcrun notarytool submit "$STAGE/DansWriter.zip" --keychain-profile "$DANSWRITER_NOTARY_PROFILE" --wait --timeout 30m --output-format json > "$STAGE/app-result.json"
python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["status"] == "Accepted" else "Apple did not accept the app")' "$STAGE/app-result.json"
xcrun stapler staple dist/DansWriter.app
xcrun stapler validate dist/DansWriter.app
bash scripts/create-dmg.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/DansWriter.app/Contents/Info.plist)
DMG="dist/DansWriter-${VERSION}-arm64.dmg"
xcrun notarytool submit "$DMG" --keychain-profile "$DANSWRITER_NOTARY_PROFILE" --wait --timeout 30m --output-format json > "$STAGE/dmg-result.json"
python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["status"] == "Accepted" else "Apple did not accept the DMG")' "$STAGE/dmg-result.json"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
codesign --verify --deep --strict dist/DansWriter.app
spctl --assess --type execute --verbose=2 dist/DansWriter.app
(cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo DANSWRITER_NOTARIZATION_VERIFIED

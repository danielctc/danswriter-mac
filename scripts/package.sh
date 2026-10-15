#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product DansWriter -Xswiftc -debug-prefix-map -Xswiftc "$PWD=." -Xswiftc -file-prefix-map -Xswiftc "$PWD=."
swift build -c release --product WriteOnLauncher -Xcc "-fdebug-prefix-map=$PWD=."
APP="dist/DansWriter.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DansWriter "$APP/Contents/MacOS/DansWriter"
cp -R .build/release/DansWriter_WriteOnApp.bundle "$APP/Contents/Resources/"
cp .build/release/WriteOnLauncher "$APP/Contents/MacOS/WriteOnLauncher"
cp scripts/Info.plist "$APP/Contents/Info.plist"
if [ -f scripts/AppIcon.icns ]; then
  cp scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
chmod 755 "$APP/Contents/MacOS/DansWriter"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
# Remove build-machine debug paths before signing the final payload.
/usr/bin/strip -S "$APP/Contents/MacOS/DansWriter" "$APP/Contents/MacOS/WriteOnLauncher"
IDENTITY="${DANSWRITER_SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
  /usr/bin/codesign --force --sign - "$APP/Contents/MacOS/WriteOnLauncher"
  /usr/bin/codesign --force --sign - "$APP"
else
  /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/MacOS/WriteOnLauncher"
  /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
/usr/bin/codesign --verify --strict "$APP"
test -x "$APP/Contents/MacOS/DansWriter"
/usr/bin/file "$APP/Contents/MacOS/DansWriter" | /usr/bin/grep -q 'Mach-O'
echo WRITE_ON_PACKAGE_VERIFIED

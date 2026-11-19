#!/bin/zsh
# Builds "Papiro.app" into build.noindex/. Usage: ./build.sh
# The app is assembled and signed in a temporary folder outside iCloud Drive: iCloud keeps adding Finder
# attributes to bundles on the Desktop, and codesign refuses a bundle that carries them.
# Both folders end in ".noindex", so Spotlight skips them: otherwise every build leaves another "Papiro"
# in the list of apps, and the copy on the Desktop shows there next to the installed one.
set -e
cd "$(dirname "$0")"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
APP="$TMP/build.noindex/Papiro.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos26.0" -module-name Papiro \
  Sources/*.swift -o "$APP/Contents/MacOS/Papiro" -framework AppKit -framework PDFKit
cp Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"      # English and Turkish texts
xattr -cr "$APP"
codesign --force --deep -s - "$APP"
mkdir -p build.noindex
rm -rf build.noindex/Papiro.app
ditto "$APP" build.noindex/Papiro.app
echo "built build.noindex/Papiro.app"

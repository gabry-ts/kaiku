#!/usr/bin/env bash
# Builds the app and packages it as build/Kaiku-<version>.dmg, with a link to
# /Applications for drag-and-drop install. Uses only tools that ship with macOS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Kaiku.app"
NAME="Kaiku"

"$ROOT/scripts/build-app.sh"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DMG="$ROOT/build/$NAME-$VERSION.dmg"
STAGING="$ROOT/build/dmg-staging"

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/$NAME.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create -quiet -volname "$NAME $VERSION" -srcfolder "$STAGING" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"
rm -rf "$STAGING"

hdiutil verify -quiet "$DMG"
echo "Built $DMG ($(du -h "$DMG" | cut -f1 | xargs))"

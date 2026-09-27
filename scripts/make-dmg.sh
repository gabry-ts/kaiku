#!/usr/bin/env bash
# Builds the app and packages it as build/Kaiku-<version>.dmg, with a background,
# an /Applications drop link, and the same signing identity as the app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Kaiku.app"
NAME="Kaiku"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"

if ! command -v create-dmg >/dev/null 2>&1; then
    echo "create-dmg not found. Install it with: brew install create-dmg" >&2
    exit 1
fi

"$ROOT/scripts/build-app.sh"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DMG="$ROOT/build/$NAME-$VERSION.dmg"
STAGING="$ROOT/build/dmg-staging"

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/$NAME.app"

CREATE_DMG_ARGS=(
    --volname "$NAME $VERSION"
    --background "$ROOT/Resources/dmg/background.png"
    --window-size 600 400
    --icon-size 128
    --icon "$NAME.app" 150 190
    --app-drop-link 450 190
    --hide-extension "$NAME.app"
    --no-internet-enable
)

# create-dmg fails if the target already exists.
rm -f "$DMG"
create-dmg "${CREATE_DMG_ARGS[@]}" "$DMG" "$STAGING"
rm -rf "$STAGING"

# Signed separately (rather than via create-dmg's --codesign) so the same
# ad-hoc/Developer ID logic as build-app.sh applies here too.
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force -s - "$DMG"
else
    codesign --force --timestamp -s "$SIGN_IDENTITY" "$DMG"
fi

hdiutil verify -quiet "$DMG"
echo "Built $DMG ($(du -h "$DMG" | cut -f1 | xargs))"

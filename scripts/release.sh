#!/usr/bin/env bash
# Builds, signs, packages, notarizes and staples a Kaiku release, then generates the
# Sparkle appcast for it. Used by .github/workflows/release.yml; runnable locally with
# the same environment variables and network access, but real notarization credentials
# are required, so local verification should stop at scripts/make-dmg.sh instead.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Kaiku.app"
NAME="Kaiku"
REPO="gabry-ts/kaiku"
SPARKLE_VERSION="${SPARKLE_VERSION:-2.10.0}"

: "${SIGN_IDENTITY:=Developer ID Application}"
: "${ASC_API_KEY_PATH:?Set ASC_API_KEY_PATH to the App Store Connect API .p8 key file path}"
: "${ASC_API_KEY_ID:?Set ASC_API_KEY_ID (App Store Connect API key ID)}"
: "${ASC_API_ISSUER_ID:?Set ASC_API_ISSUER_ID (App Store Connect API issuer ID)}"
: "${SPARKLE_ED_KEY_FILE:?Set SPARKLE_ED_KEY_FILE to the Sparkle EdDSA private key file path}"
export SIGN_IDENTITY

"$ROOT/scripts/make-dmg.sh"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DMG="$ROOT/build/$NAME-$VERSION.dmg"

echo "Notarizing $DMG..."
xcrun notarytool submit "$DMG" --wait \
    --key "$ASC_API_KEY_PATH" --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID"
xcrun stapler staple "$DMG"

echo "Generating the Sparkle appcast..."
TOOLS_DIR="$ROOT/build/sparkle-tools"
if [[ ! -x "$TOOLS_DIR/bin/generate_appcast" ]]; then
    rm -rf "$TOOLS_DIR"
    mkdir -p "$TOOLS_DIR"
    curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
        -o "$ROOT/build/sparkle-tools.tar.xz"
    tar -xf "$ROOT/build/sparkle-tools.tar.xz" -C "$TOOLS_DIR"
fi

# A single-item feed: only this release's dmg goes in, since SUFeedURL always points
# at "latest". generate_appcast picks up release notes from a same-named .md/.html file.
APPCAST_INPUT="$ROOT/build/appcast-input"
rm -rf "$APPCAST_INPUT"
mkdir -p "$APPCAST_INPUT"
cp "$DMG" "$APPCAST_INPUT/"
for ext in md html; do
    NOTES="$ROOT/docs/release-notes/$VERSION.$ext"
    [[ -f "$NOTES" ]] && cp "$NOTES" "$APPCAST_INPUT/$NAME-$VERSION.$ext"
done

"$TOOLS_DIR/bin/generate_appcast" \
    --ed-key-file "$SPARKLE_ED_KEY_FILE" \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
    --embed-release-notes \
    "$APPCAST_INPUT"

cp "$APPCAST_INPUT/appcast.xml" "$ROOT/build/appcast.xml"
echo "Release ready: $DMG and $ROOT/build/appcast.xml"

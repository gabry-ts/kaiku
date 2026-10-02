#!/usr/bin/env bash
# Builds build/Kaiku.app (release, universal, signed).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Kaiku.app"
EXEC_NAME="Kaiku"

# Signing identity: a Developer ID Application certificate (codesign resolves it by
# prefix, so the team name/hash suffix can be omitted), or "-" for an ad-hoc local
# build when no certificate is installed.
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"

cd "$ROOT"
"$ROOT/scripts/build-whisper.sh"
WHISPER_BIN="$ROOT/vendor/whisper-bin"

# Universal binary (Apple silicon + Intel).
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}" --product "$EXEC_NAME"
BIN_DIR="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/$EXEC_NAME" "$APP/Contents/MacOS/$EXEC_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Sparkle.framework (universal, built by SwiftPM next to the executable) for auto-updates.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
ditto "$BIN_DIR/Sparkle.framework" "$SPARKLE"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$EXEC_NAME"

# Partiti UI's built-in strings live in its SwiftPM resource bundle, which lands next to the
# binary. The library looks for it in Contents/Resources, where codesign accepts it; it holds
# no code and is sealed with the app's own signature.
PARTITI_BUNDLE="$BIN_DIR/PartitiUI_PartitiUI.bundle"
if [[ ! -d "$PARTITI_BUNDLE" ]]; then
    echo "error: PartitiUI_PartitiUI.bundle not found in $BIN_DIR" >&2
    exit 1
fi
ditto "$PARTITI_BUNDLE" "$APP/Contents/Resources/PartitiUI_PartitiUI.bundle"

# Bundled whisper.cpp command line tool, server (live transcription) and license notice.
cp "$WHISPER_BIN/whisper-cli" "$APP/Contents/MacOS/whisper-cli"
cp "$WHISPER_BIN/whisper-server" "$APP/Contents/MacOS/whisper-server"
{
    echo "Kaiku includes whisper.cpp $(cat "$WHISPER_BIN/.tag") (https://github.com/ggml-org/whisper.cpp),"
    echo "distributed under the MIT License:"
    echo
    cat "$WHISPER_BIN/LICENSE-whisper.cpp"
} > "$APP/Contents/Resources/ThirdPartyNotices.txt"

# --- Signing -------------------------------------------------------------------
# Ad-hoc builds (SIGN_IDENTITY=-) have no certificate, so they can't get a secure
# timestamp. Everything else is always signed with a hardened runtime and a
# timestamp, per Apple's notarization requirements.
CODESIGN=(codesign --force --options runtime)
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    CODESIGN+=(--timestamp=none)
else
    CODESIGN+=(--timestamp)
fi
CODESIGN+=(-s "$SIGN_IDENTITY")

# Sign inside-out, never with --deep: Sparkle's XPC services and helper tools first,
# then the framework itself, then the vendored whisper tools, then the app last.
"${CODESIGN[@]}" "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
"${CODESIGN[@]}" "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
"${CODESIGN[@]}" "$SPARKLE/Versions/B/Autoupdate"
"${CODESIGN[@]}" "$SPARKLE/Versions/B/Updater.app"
"${CODESIGN[@]}" "$SPARKLE"

# whisper-cli and whisper-server only link Apple frameworks (no vendored dylibs) and embed
# their Metal shaders at build time, so they need no entitlements beyond the hardened runtime.
"${CODESIGN[@]}" "$APP/Contents/MacOS/whisper-cli"
"${CODESIGN[@]}" "$APP/Contents/MacOS/whisper-server"

# Every build needs the audio-input and calendars entitlements, or the hardened runtime
# silently denies microphone and calendar access. Ad-hoc builds also need
# com.apple.security.cs.disable-library-validation: two independently ad-hoc signed
# binaries have no Team ID to compare, so hardened runtime library validation would
# otherwise refuse to load Sparkle.framework. A real Developer ID build doesn't need
# it: the app and the framework share the same real Team ID and validate normally.
ENTITLEMENTS="$ROOT/Resources/Kaiku.entitlements"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    ENTITLEMENTS="$ROOT/Resources/Kaiku-adhoc.entitlements"
fi
"${CODESIGN[@]}" --entitlements "$ENTITLEMENTS" "$APP"

codesign --verify --strict --verbose "$APP"
lipo -info "$APP/Contents/MacOS/$EXEC_NAME"

echo "Built $APP (signed with \"$SIGN_IDENTITY\")"

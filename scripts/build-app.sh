#!/usr/bin/env bash
# Builds build/mc.Rofone.app (release, universal, ad-hoc signed).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/mc.Rofone.app"
EXEC_NAME="McRofone"

cd "$ROOT"
"$ROOT/scripts/build-whisper.sh"
WHISPER_BIN="$ROOT/vendor/whisper-bin"

# Universal binary (Apple silicon + Intel).
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}" --product "$EXEC_NAME"
BIN_DIR="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXEC_NAME" "$APP/Contents/MacOS/$EXEC_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Bundled whisper.cpp command line tool and its license notice.
cp "$WHISPER_BIN/whisper-cli" "$APP/Contents/MacOS/whisper-cli"
{
    echo "mc.Rofone includes whisper.cpp $(cat "$WHISPER_BIN/.tag") (https://github.com/ggml-org/whisper.cpp),"
    echo "distributed under the MIT License:"
    echo
    cat "$WHISPER_BIN/LICENSE-whisper.cpp"
} > "$APP/Contents/Resources/ThirdPartyNotices.txt"

codesign --force -s - "$APP/Contents/MacOS/whisper-cli"
codesign --force --deep -s - "$APP"
codesign --verify --deep --strict --verbose "$APP"
lipo -info "$APP/Contents/MacOS/$EXEC_NAME"

echo "Built $APP"

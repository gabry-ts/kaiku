#!/usr/bin/env bash
# Builds build/mc.Rofone.app (release, ad-hoc signed).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/mc.Rofone.app"
EXEC_NAME="McRofone"

cd "$ROOT"
swift build -c release --product "$EXEC_NAME"
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXEC_NAME" "$APP/Contents/MacOS/$EXEC_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep -s - "$APP"
codesign --verify --verbose "$APP"

echo "Built $APP"

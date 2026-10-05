#!/usr/bin/env bash
# Builds whisper.xcframework (Metal, all Apple platforms) from a pinned whisper.cpp release
# using the project's official build-xcframework.sh. The iOS app links it from iOS/vendor.
# Output: iOS/vendor/whisper.xcframework
set -euo pipefail

WHISPER_TAG="${WHISPER_TAG:-v1.9.4}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor"
SRC="$VENDOR/whisper.cpp"
OUT="$VENDOR/whisper.xcframework"
STAMP="$VENDOR/.xcframework-tag"
LOG="$VENDOR/whisper-xcframework.log"

if ! command -v cmake >/dev/null 2>&1; then
    echo "cmake not found. Install it with: brew install cmake" >&2
    exit 1
fi

if [[ -d "$OUT" && -f "$STAMP" && "$(cat "$STAMP")" == "$WHISPER_TAG" ]]; then
    echo "whisper.xcframework $WHISPER_TAG already built at $OUT"
    exit 0
fi

mkdir -p "$VENDOR"
if [[ ! -d "$SRC/.git" ]]; then
    git clone --quiet --depth 1 --branch "$WHISPER_TAG" https://github.com/ggml-org/whisper.cpp "$SRC"
elif [[ "$(git -C "$SRC" describe --tags --exact-match 2>/dev/null || true)" != "$WHISPER_TAG" ]]; then
    git -C "$SRC" fetch --quiet --depth 1 origin tag "$WHISPER_TAG"
    git -C "$SRC" checkout --quiet "$WHISPER_TAG"
fi

echo "Building whisper.xcframework $WHISPER_TAG (slow, all Apple platforms)..."
: > "$LOG"
if ! (cd "$SRC" && rm -rf build-apple && bash build-xcframework.sh) >>"$LOG" 2>&1; then
    tail -n 40 "$LOG" >&2
    echo "whisper.xcframework build failed, full log: $LOG" >&2
    exit 1
fi

rm -rf "$OUT"
cp -R "$SRC/build-apple/whisper.xcframework" "$OUT"
echo "$WHISPER_TAG" > "$STAMP"
echo "Built $OUT ($WHISPER_TAG)"

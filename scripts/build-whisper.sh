#!/usr/bin/env bash
# Builds self-contained, universal (arm64 + x86_64) whisper-cli and whisper-server from a
# pinned whisper.cpp release: static libraries, Metal library embedded in the binaries.
# Output: vendor/whisper-bin/{whisper-cli,whisper-server} and vendor/whisper-bin/LICENSE-whisper.cpp
set -euo pipefail

WHISPER_TAG="${WHISPER_TAG:-v1.9.4}"
DEPLOYMENT_TARGET="14.2"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor"
SRC="$VENDOR/whisper.cpp"
OUT="$VENDOR/whisper-bin"
STAMP="$OUT/.tag"

if ! command -v cmake >/dev/null 2>&1; then
    echo "cmake not found. Install it with: brew install cmake" >&2
    exit 1
fi

if [[ -x "$OUT/whisper-cli" && -x "$OUT/whisper-server" && -f "$STAMP" && "$(cat "$STAMP")" == "$WHISPER_TAG" ]]; then
    echo "whisper.cpp $WHISPER_TAG already built at $OUT"
    exit 0
fi

mkdir -p "$VENDOR"
if [[ ! -d "$SRC/.git" ]]; then
    git clone --quiet --depth 1 --branch "$WHISPER_TAG" https://github.com/ggml-org/whisper.cpp "$SRC"
elif [[ "$(git -C "$SRC" describe --tags --exact-match 2>/dev/null || true)" != "$WHISPER_TAG" ]]; then
    git -C "$SRC" fetch --quiet --depth 1 origin tag "$WHISPER_TAG"
    git -C "$SRC" checkout --quiet "$WHISPER_TAG"
fi

# Compiler output of the third-party sources goes to a log, shown only on failure.
LOG="$VENDOR/whisper-build.log"
: > "$LOG"
run_logged() {
    if ! "$@" >>"$LOG" 2>&1; then
        tail -n 40 "$LOG" >&2
        echo "whisper.cpp build failed, full log: $LOG" >&2
        exit 1
    fi
}

build_arch() {
    local arch="$1"
    local dir="$VENDOR/whisper-build-$arch"
    run_logged cmake -S "$SRC" -B "$dir" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DBUILD_SHARED_LIBS=OFF \
        -DGGML_NATIVE=OFF \
        -DGGML_METAL=ON \
        -DGGML_METAL_EMBED_LIBRARY=ON \
        -DGGML_BLAS=ON \
        -DGGML_OPENMP=OFF \
        -DWHISPER_BUILD_TESTS=OFF \
        -DWHISPER_BUILD_SERVER=ON \
        -DWHISPER_SDL2=OFF \
        -DWHISPER_CURL=OFF
    run_logged cmake --build "$dir" --config Release --target whisper-cli whisper-server -j "$(sysctl -n hw.ncpu)"
}

# Built per architecture and merged with lipo: ggml selects CPU features per arch.
echo "Building whisper.cpp $WHISPER_TAG (arm64, x86_64)..."
build_arch arm64
build_arch x86_64
mkdir -p "$OUT"
# whisper-server keeps the model loaded for live transcription during a call.
for tool in whisper-cli whisper-server; do
    lipo -create "$VENDOR/whisper-build-arm64/bin/$tool" "$VENDOR/whisper-build-x86_64/bin/$tool" -output "$OUT/$tool"
    strip -x "$OUT/$tool"
    lipo -info "$OUT/$tool"
    if otool -L "$OUT/$tool" | grep -E '^\s' | grep -v -E '^\s+(/usr/lib/|/System/Library/)'; then
        echo "$tool links libraries outside the system" >&2
        exit 1
    fi
done
cp "$SRC/LICENSE" "$OUT/LICENSE-whisper.cpp"
echo "$WHISPER_TAG" > "$STAMP"
echo "Built $OUT/whisper-cli and $OUT/whisper-server ($WHISPER_TAG)"

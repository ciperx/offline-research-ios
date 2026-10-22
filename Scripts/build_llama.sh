#!/usr/bin/env bash
# Build llama.cpp as a single static library for iOS device + simulator.
#
# Why a static library instead of SwiftPM: the GGUF runtime is C/C++ with a Metal
# shader embedded as a byte array (GGML_METAL_EMBED_LIBRARY), and merging the ggml
# component libs with libtool keeps the Xcode project free of any package resolution.
#
#   ./Scripts/build_llama.sh              # Metal + Accelerate (default)
#   ./Scripts/build_llama.sh --cpu-only   # CPU only (no Metal, works on any Mac)
#   ./Scripts/build_llama.sh --clean      # wipe build/ first
#
# Output:
#   vendor/llama/include/llama.h, ggml*.h
#   vendor/llama/lib/ios/libllamaios.a        (arm64, iphoneos)
#   vendor/llama/lib/sim/libllamaios.a        (arm64 + x86_64, iphonesimulator)
#   vendor/llama/VERSION                      (pinned tag + commit sha actually built)

set -euo pipefail

LLAMA_TAG="${LLAMA_TAG:-v0.7.0}"
IOS_MIN="${IOS_MIN:-16.0}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/vendor/llama.cpp"
OUT="$ROOT/vendor/llama"
BUILD="$ROOT/vendor/build"
CPU_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --cpu-only) CPU_ONLY=1 ;;
    --clean) rm -rf "$BUILD" "$OUT" ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1${2:+ ($2)}" >&2; exit 1; }; }
need cmake "brew install cmake"
need git
need xcrun "install Xcode"
need libtool

echo "==> llama.cpp $LLAMA_TAG"
mkdir -p "$ROOT/vendor"
if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 --branch "$LLAMA_TAG" https://github.com/ggml-org/llama.cpp "$SRC"
else
  git -C "$SRC" fetch --depth 1 origin "refs/tags/$LLAMA_TAG:refs/tags/$LLAMA_TAG" || true
  git -C "$SRC" checkout -q "$LLAMA_TAG"
fi
COMMIT="$(git -C "$SRC" rev-parse HEAD)"
echo "    commit $COMMIT"

COMMON_FLAGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DBUILD_SHARED_LIBS=OFF
  -DLLAMA_BUILD_TESTS=OFF
  -DLLAMA_BUILD_EXAMPLES=OFF
  -DLLAMA_BUILD_SERVER=OFF
  -DLLAMA_BUILD_TOOLS=OFF
  -DLLAMA_CURL=OFF
  -DGGML_NATIVE=OFF
  -DGGML_OPENMP=OFF
  -DGGML_CCACHE=OFF
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO
  -DCMAKE_XCODE_ATTRIBUTE_ENABLE_BITCODE=NO
)

if [ "$CPU_ONLY" -eq 1 ]; then
  COMMON_FLAGS+=(-DGGML_METAL=OFF -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=Apple)
  echo "    backend: CPU + Accelerate"
else
  COMMON_FLAGS+=(-DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=Apple)
  echo "    backend: Metal + Accelerate + CPU"
fi

build_sdk() {
  local sdk="$1" archs="$2" dir="$3"
  echo "==> configuring $sdk ($archs)"
  cmake -S "$SRC" -B "$BUILD/$dir" -G Xcode \
    "${COMMON_FLAGS[@]}" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$sdk" \
    -DCMAKE_OSX_ARCHITECTURES="$archs" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
    > "$BUILD/$dir.log" 2>&1 || { echo "cmake configure failed; see $BUILD/$dir.log" >&2; tail -80 "$BUILD/$dir.log" >&2; exit 1; }

  echo "==> building $sdk"
  cmake --build "$BUILD/$dir" --config Release -- \
    -sdk "$sdk" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
    >> "$BUILD/$dir.log" 2>&1 || { echo "build failed; see $BUILD/$dir.log" >&2; tail -80 "$BUILD/$dir.log" >&2; exit 1; }
}

mkdir -p "$BUILD" "$OUT/lib/ios" "$OUT/lib/sim" "$OUT/include"

build_sdk iphoneos       arm64          build-ios
build_sdk iphonesimulator "arm64;x86_64" build-sim

merge() {
  local dir="$1" out="$2"
  local libs
  # Every ggml component and llama itself; order does not matter for a static archive.
  mapfile -t libs < <(find "$BUILD/$dir" -name '*.a' -path '*Release*' -type f | sort -u)
  if [ "${#libs[@]}" -eq 0 ]; then
    echo "no static libraries found under $BUILD/$dir" >&2
    exit 1
  fi
  echo "==> merging ${#libs[@]} archives -> $out"
  libtool -static -o "$out" "${libs[@]}"
}

merge build-ios "$OUT/lib/ios/libllamaios.a"
merge build-sim "$OUT/lib/sim/libllamaios.a"

echo "==> headers"
cp "$SRC/include/llama.h" "$OUT/include/"
cp "$SRC"/ggml/include/*.h "$OUT/include/"

{
  echo "tag=$LLAMA_TAG"
  echo "commit=$COMMIT"
  echo "backend=$([ "$CPU_ONLY" -eq 1 ] && echo cpu || echo metal)"
  echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "ios_min=$IOS_MIN"
} > "$OUT/VERSION"

echo
echo "done:"
ls -lh "$OUT/lib/ios/libllamaios.a" "$OUT/lib/sim/libllamaios.a"
xcrun lipo -info "$OUT/lib/ios/libllamaios.a" || true
xcrun lipo -info "$OUT/lib/sim/libllamaios.a" || true

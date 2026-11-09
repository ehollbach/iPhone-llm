#!/usr/bin/env bash
# Cross-compiles systemone-cli (from kneejerk) for iOS 12 and later: arm64, CPU only, ARMv8.0 baseline.
# Needs a Mac with Xcode, cmake, and KNEEJERK_DIR pointing at a kneejerk checkout with chat mode.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
kneejerk="${KNEEJERK_DIR:?set KNEEJERK_DIR to a kneejerk checkout with chat mode (see README)}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
build="$here/build/ios"

if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    echo "no iPhoneOS SDK: install Xcode, or set DEVELOPER_DIR to it" >&2
    exit 1
fi

# GGML_CPU_ARM_ARCH=armv8-a: the A7 has no dot product and no fp16 arithmetic.
# GGML_ACCELERATE=OFF: ggml asks Accelerate for the new LAPACK headers, iOS 16.4 and later.
# Below an iOS 13 target, kneejerk weak-links libc++ (std::filesystem is missing on iOS 12).
cmake -S "$kneejerk" -B "$build" \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 -DCMAKE_EXE_LINKER_FLAGS=-Wl,-dead_strip \
    -DGGML_NATIVE=OFF -DGGML_CPU_ARM_ARCH=armv8-a \
    -DGGML_METAL=OFF -DGGML_ACCELERATE=OFF -DGGML_BLAS=OFF -DGGML_OPENMP=OFF
cmake --build "$build" --target systemone-cli -j "$(sysctl -n hw.ncpu)"

mkdir -p "$here/build/bin"
cp "$build/systemone-cli.app/systemone-cli" "$here/build/bin/systemone-cli"
codesign -f -s - "$here/build/bin/systemone-cli" # ad-hoc signature
echo "built $here/build/bin/systemone-cli"

#!/bin/bash
# Build the project QEMU fork with HVF, slirp management, and vmnet bridging.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$HERE/qemu"
BUILD="$HERE/out/qemu-fork-vmnet-build"
PYTHON_BIN="${PYTHON:-python3}"
NINJA_BIN="${NINJA:-$HERE/out/qemu-tools-bin/ninja}"

fail() {
    echo "build-qemu-vmnet: $*" >&2
    exit 1
}

[ -x "$SOURCE/configure" ] ||
    fail "QEMU submodule is unavailable; initialize $SOURCE"
PYTHON_BIN="$(command -v "$PYTHON_BIN")" ||
    fail "Python is not executable: ${PYTHON:-python3}"
if [ -n "${NINJA:-}" ]; then
    NINJA_BIN="$(command -v "$NINJA_BIN")" ||
        fail "ninja is unavailable: $NINJA"
elif [ ! -x "$NINJA_BIN" ]; then
    NINJA_BIN="$(command -v ninja)" ||
        fail "ninja is unavailable; set NINJA to an executable"
fi
[ -x "$NINJA_BIN" ] || fail "ninja is not executable: $NINJA_BIN"

mkdir -p "$BUILD"
cd "$BUILD"
"$SOURCE/configure" \
    --python="$PYTHON_BIN" \
    --ninja="$NINJA_BIN" \
    --target-list=aarch64-softmmu \
    --without-default-features \
    --enable-hvf \
    --enable-fdt=internal \
    --enable-vvfat \
    --enable-slirp \
    --enable-vmnet
"$NINJA_BIN" -C "$BUILD" qemu-system-aarch64

"$BUILD/qemu-system-aarch64" -M none -netdev help |
    grep -qx 'vmnet-bridged' ||
    fail "built QEMU does not expose vmnet-bridged"
echo "vmnet-enabled QEMU is ready: $BUILD/qemu-system-aarch64"

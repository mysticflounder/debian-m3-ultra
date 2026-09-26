#!/bin/bash
# Cross-build only: never installs, boots, or connects to a target.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REV=4184923ffb2dff079b384d6a32cc02142aa14572
MODE=${1:-patched}
case "$MODE" in baseline|patched) ;; *) echo 'Usage: build-m1n1-cpu-offline.sh [baseline|patched]' >&2; exit 2 ;; esac
TOOLS="$ROOT/scratch/m1n1-build-tools"
ARCHIVE="$ROOT/scratch/m1n1-cpu-audit/source.tar.gz"
MAKE="$TOOLS/make-4.4.1/make"
RUST_SYSROOT=$(rustc --print sysroot)
RUST_BIN="$RUST_SYSROOT/lib/rustlib/aarch64-apple-darwin/bin"
TARGET_SYSROOT="$TOOLS/rust-std-1.95.0-aarch64-unknown-none-softfloat/rust-std-aarch64-unknown-none-softfloat"
PATCHES=(
    "$ROOT/patches/m1n1/0001-expand-cpu-capacity-and-fix-bounds.patch"
    "$ROOT/patches/m1n1/0002-free-pruned-cpus-after-handoff.patch"
)

if [[ $(uname -s) != Darwin || $(uname -m) != arm64 ]]; then
    echo 'This build recipe is validated only on Apple-arm64 macOS.' >&2
    exit 1
fi
if [[ $(rustc --version) != 'rustc 1.95.0 (59807616e 2026-04-14)' ]]; then
    echo 'Expected Rust 1.95.0 matching the staged cross-target component.' >&2
    exit 1
fi
for tool in "$MAKE" "$RUST_BIN/rust-lld" "$RUST_BIN/rust-objcopy" /usr/bin/clang; do
    [[ -x "$tool" ]] || { echo "Missing tool: $tool" >&2; exit 1; }
done
[[ -d "$TARGET_SYSROOT/lib/rustlib/aarch64-unknown-none-softfloat/lib" ]] || {
    echo 'Missing project-local bare-metal Rust standard library component.' >&2; exit 1;
}
[[ -d "$TOOLS/cargo-home" ]] || { echo 'Populate the project-local Cargo cache first.' >&2; exit 1; }
ACTUAL_SHA=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
[[ "$ACTUAL_SHA" == 6425983260ab96d55c36fdaab3b456830c3bd80f06b7759a61ed2bcca924d973 ]] || {
    echo 'Pinned m1n1 archive checksum mismatch.' >&2; exit 1;
}

# Keep outputs and logs even on failure. Never reuse or clean another build.
BUILD_DIR=$(mktemp -d "$ROOT/scratch/m1n1-firmware-$MODE.XXXXXX")
printf 'Build directory: %s\n' "$BUILD_DIR"
tar -xf "$ARCHIVE" -C "$BUILD_DIR"
SOURCE="$BUILD_DIR/m1n1-$REV"
if [[ "$MODE" == patched ]]; then
    for cpu_patch in "${PATCHES[@]}"; do
        (cd "$SOURCE" && patch -p1 --batch --forward -i "$cpu_patch") >> "$BUILD_DIR/patch.log" 2>&1
    done
    shasum -a 256 "${PATCHES[@]}" > "$BUILD_DIR/PATCH_SHA256SUMS"
fi

export CARGO_HOME="$TOOLS/cargo-home"
export CARGO_NET_OFFLINE=true
export CARGO_TARGET_AARCH64_UNKNOWN_NONE_SOFTFLOAT_RUSTFLAGS="--sysroot=$TARGET_SYSROOT"
export M1N1_VERSION_TAG="$REV-local-cpu-$MODE"
export PATH="$RUST_SYSROOT/bin:$PATH"

if ! "$MAKE" -C "$SOURCE" -j8 USE_CLANG=1 TOOLCHAIN=/usr/bin/ \
    LLDDIR="$RUST_BIN/" \
    CC='/usr/bin/clang --target=aarch64-none-elf' \
    AS='/usr/bin/clang --target=aarch64-none-elf' \
    LD="$RUST_BIN/rust-lld -flavor gnu" OBJCOPY="$RUST_BIN/rust-objcopy" \
    CARGO_FLAGS='--offline --locked' V=1 > "$BUILD_DIR/build.log" 2>&1; then
    tail -n 20 "$BUILD_DIR/build.log"
    echo "Build failed; complete log: $BUILD_DIR/build.log" >&2
    exit 1
fi
shasum -a 256 "$SOURCE/build/m1n1.elf" "$SOURCE/build/m1n1-raw.elf" \
    "$SOURCE/build/m1n1.macho" "$SOURCE/build/m1n1.bin" > "$BUILD_DIR/SHA256SUMS"
printf 'Offline %s build passed. Artifacts: %s/build\n' "$MODE" "$SOURCE"
cat "$BUILD_DIR/SHA256SUMS"

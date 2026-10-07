#!/bin/bash
# Comparison builds only: never installs, boots, or connects to a target.
# Upstream contains native T6032 dispatch; these artifacts are NOT boot-approved.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REV=2460b604c6f016956ead711823605eea840c602e
ARCHIVE_SHA=aa0ffbeb7ae9cc0eb7a5653f44474e26f826809cf7f0564f8deb395d25203b01
MODE=${1:-baseline}
INCLUDE_INPUT_GUARDS=false
case "$MODE" in
    # Reuse the complete top-down prefix; restore the artifact mode below.
    payload-input-guards) MODE=topdown-guards; INCLUDE_INPUT_GUARDS=true ;;
    baseline|adt|input-guards|smp-guards|memory-guards|cpufreq-guards|adt-bounds|aic-guards|boot-guards|hv-guards|cpufreq-busy|board-handoff|payload-guards|topdown-guards) ;;
    *) echo 'Usage: build-m1n1-upstream-offline.sh [baseline|adt|input-guards|smp-guards|memory-guards|cpufreq-guards|adt-bounds|aic-guards|boot-guards|hv-guards|cpufreq-busy|board-handoff|payload-guards|topdown-guards|payload-input-guards]' >&2; exit 2 ;;
esac
ARCHIVE="$ROOT/scratch/m1n1-upstream-audit/source-$REV.tar.gz"
TOOLS="$ROOT/scratch/m1n1-build-tools"
MAKE="$TOOLS/make-4.4.1/make"
RUST_SYSROOT=$(rustc --print sysroot)
RUST_BIN="$RUST_SYSROOT/lib/rustlib/aarch64-apple-darwin/bin"
TARGET_SYSROOT="$TOOLS/rust-std-1.95.0-aarch64-unknown-none-softfloat/rust-std-aarch64-unknown-none-softfloat"
PATCHES=(
    "$ROOT/patches/m1n1/0020-check-adt-copy-length-before-write.patch"
    "$ROOT/patches/m1n1/0021-fix-adt-property-view-length.patch"
)
if [[ "$MODE" == input-guards || "$MODE" == smp-guards || "$MODE" == memory-guards || "$MODE" == cpufreq-guards || "$MODE" == adt-bounds || "$MODE" == aic-guards || "$MODE" == boot-guards || "$MODE" == hv-guards || "$MODE" == cpufreq-busy || "$MODE" == board-handoff || "$MODE" == payload-guards || "$MODE" == topdown-guards ]]; then
    PATCHES=("$ROOT/patches/m1n1/upstream-2460b60/0019-validate-aic-init-metadata.patch" "${PATCHES[@]}")
fi
if [[ "$MODE" == smp-guards || "$MODE" == memory-guards || "$MODE" == cpufreq-guards || "$MODE" == adt-bounds || "$MODE" == aic-guards || "$MODE" == boot-guards || "$MODE" == hv-guards || "$MODE" == cpufreq-busy || "$MODE" == board-handoff || "$MODE" == payload-guards || "$MODE" == topdown-guards ]]; then
    # Base startup/index subset. memory-guards appends MCC/mapping protection
    # below; DVFS adaptation and native qualification remain separate.
    REVIEW_PATCHES="$ROOT/patches/m1n1/upstream-2460b60"
    PATCHES=(
        "$REVIEW_PATCHES/0001-fix-half-open-cpu-bounds.patch"
        "$REVIEW_PATCHES/0003-guard-secondary-start-prerequisites.patch"
        "$REVIEW_PATCHES/0004-abort-on-secondary-start-timeout.patch"
        "$REVIEW_PATCHES/0005-t6032-cpu-start-masks.patch"
        "$REVIEW_PATCHES/0006-preflight-t6032-cpu-inventory.patch"
        "$REVIEW_PATCHES/0007-propagate-t6032-cpu-start-failures.patch"
        "$REVIEW_PATCHES/0017-validate-smp-api-cpu-indices.patch"
        "$REVIEW_PATCHES/0018-validate-mmu-hv-cpu-indices.patch"
        "${PATCHES[@]}"
        "$REVIEW_PATCHES/0022-contain-t6032-stop-reset-state.patch"
    )
fi
if [[ "$MODE" == memory-guards || "$MODE" == cpufreq-guards || "$MODE" == adt-bounds || "$MODE" == aic-guards || "$MODE" == boot-guards || "$MODE" == hv-guards || "$MODE" == cpufreq-busy || "$MODE" == board-handoff || "$MODE" == payload-guards || "$MODE" == topdown-guards ]]; then
    PATCHES+=(
        "$REVIEW_PATCHES/0008-validate-t6032-mcc-layout.patch"
        "$REVIEW_PATCHES/0009-preflight-t6032-carveout-removal.patch"
        "$REVIEW_PATCHES/0010-guard-t6032-runtime-mappings.patch"
        "$REVIEW_PATCHES/0012-decode-t6032-tz-relative-origin.patch"
        "$REVIEW_PATCHES/0013-check-t6032-tz-plane-consistency.patch"
        "$REVIEW_PATCHES/0014-reject-uninitialized-t6032-mmu-entry.patch"
        "$REVIEW_PATCHES/0016-protect-smp-shared-mappings.patch"
    )
fi
if [[ "$MODE" == cpufreq-guards || "$MODE" == adt-bounds || "$MODE" == aic-guards || "$MODE" == boot-guards || "$MODE" == hv-guards || "$MODE" == cpufreq-busy || "$MODE" == board-handoff || "$MODE" == payload-guards || "$MODE" == topdown-guards ]]; then
    PATCHES+=(
        "$REVIEW_PATCHES/0011-propagate-t6032-cpufreq-failures.patch"
        "$REVIEW_PATCHES/0023-contain-t6032-cpufreq-cluster-failures.patch"
    )
fi
if [[ "$MODE" == adt-bounds || "$MODE" == aic-guards || "$MODE" == boot-guards || "$MODE" == hv-guards || "$MODE" == cpufreq-busy || "$MODE" == board-handoff || "$MODE" == payload-guards || "$MODE" == topdown-guards ]]; then
    PATCHES+=(
        "$REVIEW_PATCHES/0024-check-adt-physical-spans.patch"
        "$REVIEW_PATCHES/0025-check-adt-boot-relocation.patch"
    )
fi

if [[ "$MODE" == aic-guards || "$MODE" == boot-guards || "$MODE" == hv-guards || "$MODE" == cpufreq-busy || "$MODE" == board-handoff || "$MODE" == payload-guards || "$MODE" == topdown-guards ]]; then
    PATCHES+=("$REVIEW_PATCHES/0026-bound-aic-register-aperture.patch")
fi

if [[ "$MODE" == boot-guards || "$MODE" == hv-guards || "$MODE" == cpufreq-busy || "$MODE" == board-handoff || "$MODE" == payload-guards || "$MODE" == topdown-guards ]]; then
    PATCHES+=("$REVIEW_PATCHES/0027-stop-on-aic-init-failure.patch")
fi

if [[ "$MODE" == hv-guards || "$MODE" == cpufreq-busy || "$MODE" == board-handoff || "$MODE" == payload-guards || "$MODE" == topdown-guards ]]; then
    PATCHES+=("$REVIEW_PATCHES/0028-bound-hv-aic-tracing.patch")
fi

if [[ "$MODE" == cpufreq-busy || "$MODE" == board-handoff || "$MODE" == payload-guards || "$MODE" == topdown-guards ]]; then
    PATCHES+=("$REVIEW_PATCHES/0029-drain-t6032-pstate-busy.patch")
fi

if [[ "$MODE" == board-handoff || "$MODE" == payload-guards || "$MODE" == topdown-guards ]]; then
    PATCHES+=("$REVIEW_PATCHES/0030-free-cpu-map-pruning-list.patch")
fi

if [[ "$MODE" == payload-guards || "$MODE" == topdown-guards ]]; then
    PATCHES+=("$REVIEW_PATCHES/0031-bound-payload-decompression.patch")
fi

if [[ "$MODE" == topdown-guards ]]; then
    PATCHES+=("$REVIEW_PATCHES/0032-coordinate-top-down-reservations.patch")
fi

if [[ "$INCLUDE_INPUT_GUARDS" == true ]]; then
    PATCHES+=("$REVIEW_PATCHES/0033-bound-compressed-input-and-consumption.patch")
    MODE=payload-input-guards
fi

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
[[ "$ACTUAL_SHA" == "$ARCHIVE_SHA" ]] || {
    echo 'Reviewed upstream archive checksum mismatch.' >&2; exit 1;
}

# Retain each independent worktree and all logs; do not clean or reuse a build.
BUILD_DIR=$(mktemp -d "$ROOT/scratch/m1n1-upstream-$MODE.XXXXXX")
printf 'Build directory: %s\n' "$BUILD_DIR"
tar -xf "$ARCHIVE" -C "$BUILD_DIR"
SOURCE="$BUILD_DIR/m1n1-$REV"
if [[ "$MODE" != baseline ]]; then
    for adt_patch in "${PATCHES[@]}"; do
        (cd "$SOURCE" && patch -p1 --batch --forward --fuzz=0 -i "$adt_patch") \
            >> "$BUILD_DIR/patch.log" 2>&1
    done
    shasum -a 256 "${PATCHES[@]}" > "$BUILD_DIR/PATCH_SHA256SUMS"
fi

export CARGO_HOME="$TOOLS/cargo-home"
export CARGO_NET_OFFLINE=true
export CARGO_TARGET_AARCH64_UNKNOWN_NONE_SOFTFLOAT_RUSTFLAGS="--sysroot=$TARGET_SYSROOT"
export M1N1_VERSION_TAG="$REV-review-$MODE-offline"
export PATH="$RUST_SYSROOT/bin:$PATH"

if ! "$MAKE" -C "$SOURCE" -j8 all USE_CLANG=1 TOOLCHAIN=/usr/bin/ \
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
printf 'Offline upstream %s build passed. Artifacts: %s/build\n' "$MODE" "$SOURCE"
printf 'Comparison artifacts only: native execution is not approved.\n'
if [[ "$MODE" == smp-guards ]]; then
    printf 'MCC, SMP mapping/readiness and DVFS guards are not included yet.\n'
elif [[ "$MODE" == memory-guards ]]; then
    printf 'DVFS failure propagation is not adapted; hardware contracts remain unqualified.\n'
elif [[ "$MODE" == cpufreq-guards ]]; then
    printf 'DVFS failure containment is included; raw states, physical inputs and hardware contracts remain unqualified.\n'
fi
cat "$BUILD_DIR/SHA256SUMS"

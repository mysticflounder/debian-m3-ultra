#!/bin/bash
# Isolated diagnostic build only: no VM launch, disk installation or native boot.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REV=602042bf29f6efde39cfb5fdd9289bf4854bc0c5
ARCHIVE="$ROOT/scratch/linux-kernel-j575d-602042bf/linux-602042bf.tar.gz"
ARCHIVE_SHA=3e99c1827e7be840e3e560d912db6832a1802e316605f36526126b312ec9cd15
BUILDER=sha256:1cc5bb4ef152a16785acce551084a41c973be8d0c9c7718524f67cd9d7d78121
MODE=${1:-config}
case "$MODE" in
    config|image) ;;
    *) echo 'Usage: build-linux-j575d-offline.sh [config|image]' >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then
    echo 'Unexpected extra arguments' >&2
    exit 2
fi
for tool in docker tar shasum awk; do
    command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
test -f "$ARCHIVE" || { echo "Missing pinned archive: $ARCHIVE" >&2; exit 1; }
printf '%s  %s\n' "$ARCHIVE_SHA" "$ARCHIVE" | shasum -a 256 -c -
test "$(docker image inspect "$BUILDER" --format '{{.Os}}/{{.Architecture}}')" = linux/arm64

OUT=$(mktemp -d "$ROOT/scratch/linux-j575d-kernel.XXXXXX")
printf 'Retained build workspace: %s\n' "$OUT"
mkdir "$OUT/source" "$OUT/build"
tar -tzf "$ARCHIVE" > "$OUT/archive-files.txt"
awk -v prefix="linux-$REV/" '
    index($0, prefix) != 1 || $0 ~ /(^|\/)\.\.(\/|$)/ { bad=1; print }
    END { exit bad }
' "$OUT/archive-files.txt"
tar -xzf "$ARCHIVE" -C "$OUT/source" --strip-components=1
cp "$ROOT/configs/linux-j575d-ram-serial.fragment" "$OUT/input.fragment"
cp "$0" "$OUT/build-recipe.sh"
printf 'revision=%s\narchive_sha256=%s\nbuilder=%s\nmode=%s\n' \
    "$REV" "$ARCHIVE_SHA" "$BUILDER" "$MODE" > "$OUT/build-inputs.txt"

# No network, devices, Docker socket, host credentials or privileged capabilities.
# Only the dedicated build directory is a writable host mount.
set +e
docker run --rm --pull=never --network=none --read-only --cap-drop=ALL \
    --security-opt=no-new-privileges --pids-limit=512 --cpus=8 --memory=16g \
    --tmpfs /tmp:rw,nosuid,nodev,size=2g \
    --mount "type=bind,source=$OUT/source,target=/src,readonly" \
    --mount "type=bind,source=$OUT/build,target=/out" \
    --mount "type=bind,source=$OUT/input.fragment,target=/input/fragment,readonly" \
    --env KBUILD_BUILD_USER=debian-m3 --env KBUILD_BUILD_HOST=isolated-builder \
    --env KBUILD_BUILD_VERSION=1 --env KBUILD_BUILD_TIMESTAMP=2026-10-07T00:24:23Z \
    --workdir /out --entrypoint /bin/bash "$BUILDER" -c '
set -euxo pipefail
uname -m
gcc --version | head -n 1
make --version | head -n 1
dpkg-query -W build-essential bison flex bc libssl-dev libelf-dev cpio
make -C /src O=/out ARCH=arm64 defconfig
cp /out/.config /out/arm64-defconfig.config
/src/scripts/kconfig/merge_config.sh -m -O /out /out/.config /input/fragment
make -C /src O=/out ARCH=arm64 olddefconfig
while IFS= read -r requirement; do
    case "$requirement" in CONFIG_*=*) grep -Fx "$requirement" /out/.config ;; esac
done < /input/fragment
for symbol in ARM64_16K_PAGES SMP OF OF_EARLY_FLATTREE COMMON_CLK PM_GENERIC_DOMAINS RESET_CONTROLLER REGMAP MFD_SYSCON SERIAL_CORE_CONSOLE SERIAL_EARLYCON DEVTMPFS; do
    grep -Fx "CONFIG_${symbol}=y" /out/.config
done
cpu_limit=$(sed -n "s/^CONFIG_NR_CPUS=//p" /out/.config)
test "$cpu_limit" -ge 32
make -s -C /src O=/out ARCH=arm64 kernelrelease
if test "$1" = image; then
    make -C /src O=/out ARCH=arm64 -j8 Image apple/t6032-j575d.dtb
fi
' build-linux-j575d "$MODE" > "$OUT/build.log" 2>&1
BUILD_RC=$?
set -e
printf '%s\n' "$BUILD_RC" > "$OUT/build.exit"
if [[ "$BUILD_RC" -ne 0 ]]; then
    tail -n 16 "$OUT/build.log" >&2
    echo "Build failed; retained evidence: $OUT" >&2
    exit "$BUILD_RC"
fi
ARTIFACTS=("$OUT/input.fragment" "$OUT/build-recipe.sh" "$OUT/build/.config" \
    "$OUT/build/arm64-defconfig.config" "$OUT/build.log" "$OUT/build.exit")
if [[ "$MODE" == image ]]; then
    ARTIFACTS+=("$OUT/build/arch/arm64/boot/Image" \
        "$OUT/build/arch/arm64/boot/dts/apple/t6032-j575d.dtb" "$OUT/build/vmlinux")
fi
shasum -a 256 "${ARTIFACTS[@]}" > "$OUT/SHA256SUMS"
echo "PASS: $MODE; native-target 16 KiB config, required built-ins, CPU capacity >=32"
echo "Retained evidence: $OUT"
echo 'Scope: build only, not native boot approval or physical SoC validation'

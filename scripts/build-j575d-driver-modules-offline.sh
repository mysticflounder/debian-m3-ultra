#!/bin/bash
# Build/package only. Never install, boot, mount devices or change the base build.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BASE="$ROOT/scratch/linux-j575d-kernel.HdzQNm"
BUILDER=sha256:1cc5bb4ef152a16785acce551084a41c973be8d0c9c7718524f67cd9d7d78121
REV=602042bf29f6efde39cfb5fdd9289bf4854bc0c5
CONFIG_SHA=19ef0607ca8b74c6ec5bd68ae376a85febd3ba1ac3da92d9bb47da9da9ac864c
IMAGE_SHA=ad9b573e66738d13d7758619809cc7e8ff09cf9498e23ccec352dfe42b285f50
if [[ $# -ne 0 ]]; then
    echo 'Usage: build-j575d-driver-modules-offline.sh' >&2
    exit 2
fi
for tool in docker cp shasum; do command -v "$tool" >/dev/null; done
for input in .config vmlinux.o vmlinux.symvers System.map arch/arm64/boot/Image; do
    test -f "$BASE/build/$input"
done
printf '%s  %s\n' "$CONFIG_SHA" "$BASE/build/.config" \
    "$IMAGE_SHA" "$BASE/build/arch/arm64/boot/Image" | shasum -a 256 -c -
test "$(docker image inspect "$BUILDER" --format '{{.Os}}/{{.Architecture}}')" = linux/arm64

OUT=$(mktemp -d "$ROOT/scratch/j575d-driver-modules.XXXXXX")
mkdir "$OUT/build" "$OUT/package" "$OUT/metadata"
echo "Retained module build workspace: $OUT"
# APFS copy-on-write keeps the original evidence immutable without duplicating
# the physical storage for the complete 1.5 GiB prepared kernel build.
cp -cR "$BASE/build/." "$OUT/build/"
cp "$0" "$OUT/build-recipe.sh"
printf 'revision=%s\nbuilder=%s\nbase=%s\nconfig_sha256=%s\nimage_sha256=%s\n' \
    "$REV" "$BUILDER" "$BASE" "$CONFIG_SHA" "$IMAGE_SHA" > "$OUT/build-inputs.txt"

set +e
docker run --rm --pull=never --network=none --read-only --cap-drop=ALL \
    --security-opt=no-new-privileges --pids-limit=512 --cpus=8 --memory=16g \
    --tmpfs /tmp:rw,nosuid,nodev,size=2g \
    --mount "type=bind,source=$BASE/source,target=/src,readonly" \
    --mount "type=bind,source=$OUT/build,target=/out" \
    --mount "type=bind,source=$OUT/package,target=/package" \
    --mount "type=bind,source=$OUT/metadata,target=/metadata" \
    --env KBUILD_BUILD_USER=debian-m3 --env KBUILD_BUILD_HOST=isolated-builder \
    --env KBUILD_BUILD_VERSION=1 --env KBUILD_BUILD_TIMESTAMP=2026-10-07T00:24:23Z \
    --workdir /out --entrypoint /bin/bash "$BUILDER" -c '
set -euxo pipefail
uname -m
gcc --version | head -n 1
make --version | head -n 1
modinfo --version
depmod --version
modules=(
    drivers/soc/apple/apple-mailbox.ko
    drivers/soc/apple/apple-rtkit.ko
    drivers/soc/apple/apple-sart.ko
    drivers/nvme/host/nvme-core.ko
    drivers/nvme/host/nvme-apple.ko
    drivers/iommu/apple-dart.ko
)
# A single top-level invocation lets modpost see all cross-directory providers.
make -C /src O=/out ARCH=arm64 -j8 "${modules[@]}"
test -s /out/Module.symvers
release=$(cat /out/include/config/kernel.release)
printf "%s\n" "$release" > /metadata/kernel-release.txt
target="/package/lib/modules/$release"
mkdir -p "$target"
: > /package/modules.load
: > "$target/modules.order"
for builtin in modules.builtin modules.builtin.modinfo; do
    cp "/out/$builtin" "$target/$builtin"
done
for module in "${modules[@]}"; do
    test -s "/out/$module"
    mkdir -p "$target/kernel/$(dirname "$module")"
    cp "/out/$module" "$target/kernel/$module"
    printf "/lib/modules/%s/kernel/%s\n" "$release" "$module" >> /package/modules.load
    printf "kernel/%s\n" "$module" >> "$target/modules.order"
    modinfo "/out/$module" > "/metadata/$(basename "$module").modinfo"
    readelf -h "/out/$module" > "/metadata/$(basename "$module").elf-header"
    grep -F "Machine:                           AArch64" "/metadata/$(basename "$module").elf-header"
    test "$(modinfo -F vermagic "/out/$module" | cut -d " " -f 1)" = "$release"
done
depmod -e -F /out/System.map -b /package "$release" > /metadata/depmod.stdout 2> /metadata/depmod.stderr
cat /metadata/depmod.stderr
test ! -s /metadata/depmod.stderr
test -s "$target/modules.dep"
test -s "$target/modules.alias"
test "$(wc -l < /package/modules.load)" -eq 6
printf "Module package: %s\n" "$release"
' > "$OUT/build.log" 2>&1
BUILD_RC=$?
set -e
printf '%s\n' "$BUILD_RC" > "$OUT/build.exit"
if [[ "$BUILD_RC" -ne 0 ]]; then
    tail -n 16 "$OUT/build.log" >&2
    echo "Module build failed; evidence retained at $OUT" >&2
    exit "$BUILD_RC"
fi
# The prepared kernel and both copies of its config/Image must remain identical.
for build in "$BASE/build" "$OUT/build"; do
    printf '%s  %s\n' "$CONFIG_SHA" "$build/.config" \
        "$IMAGE_SHA" "$build/arch/arm64/boot/Image" | shasum -a 256 -c -
done
find "$OUT/package" "$OUT/metadata" -type f -print0 | \
    sort -z | xargs -0 shasum -a 256 > "$OUT/PACKAGE_SHA256SUMS"
shasum -a 256 "$OUT/build-recipe.sh" "$OUT/build-inputs.txt" \
    "$OUT/build.log" "$OUT/build.exit" "$OUT/build/Module.symvers" > "$OUT/SHA256SUMS"
echo 'PASS: six arm64 modules built together, dependency metadata generated'
echo "Module package: $OUT/package"
echo 'Scope: build/package only; no native probe or hardware compatibility claim'

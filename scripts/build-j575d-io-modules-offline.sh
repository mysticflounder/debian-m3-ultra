#!/bin/bash
# Build/package only. Never install, boot, mount devices or change the base build.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BASE="$ROOT/scratch/linux-j575d-kernel.HdzQNm"
FRAGMENT="$ROOT/configs/linux-j575d-io-modules.fragment"
BUILDER=sha256:1cc5bb4ef152a16785acce551084a41c973be8d0c9c7718524f67cd9d7d78121
REV=602042bf29f6efde39cfb5fdd9289bf4854bc0c5
CONFIG_SHA=19ef0607ca8b74c6ec5bd68ae376a85febd3ba1ac3da92d9bb47da9da9ac864c
IMAGE_SHA=ad9b573e66738d13d7758619809cc7e8ff09cf9498e23ccec352dfe42b285f50
VMLINUX_O_SHA=c374260adf8be4dfd7e73a0be79f2136e6a939fa5a5ab7bad840ec19c310faf5
SYSTEM_MAP_SHA=f8013c17497ce293cad4d01be6723173cffb5a0e325f86e2890c9cecb9d69a59
VMLINUX_SYMVERS_SHA=2be09f0907b6c19975e4defbbcfc5e6ec232c07d291205f71c3cb107e1054b0e

if [[ $# -ne 0 ]]; then
    echo 'Usage: build-j575d-io-modules-offline.sh' >&2
    exit 2
fi
for tool in docker cp shasum; do
    command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
for input in .config vmlinux.o vmlinux.symvers System.map arch/arm64/boot/Image; do
    test -f "$BASE/build/$input"
done
printf '%s  %s\n' "$CONFIG_SHA" "$BASE/build/.config" \
    "$IMAGE_SHA" "$BASE/build/arch/arm64/boot/Image" \
    "$VMLINUX_O_SHA" "$BASE/build/vmlinux.o" \
    "$SYSTEM_MAP_SHA" "$BASE/build/System.map" \
    "$VMLINUX_SYMVERS_SHA" "$BASE/build/vmlinux.symvers" | shasum -a 256 -c -
test -f "$FRAGMENT"
test "$(docker image inspect "$BUILDER" --format '{{.Os}}/{{.Architecture}}')" = linux/arm64

OUT=$(mktemp -d "$ROOT/scratch/j575d-io-modules.XXXXXX")
mkdir "$OUT/build" "$OUT/package" "$OUT/metadata" "$OUT/input"
echo "Retained I/O module build workspace: $OUT"
# APFS copy-on-write keeps the original evidence immutable without duplicating
# the physical storage for the complete prepared kernel build.
cp -cR "$BASE/build/." "$OUT/build/"
cp "$FRAGMENT" "$OUT/input/io-modules.fragment"
cp "$0" "$OUT/build-recipe.sh"
printf 'revision=%s\nbuilder=%s\nbase=%s\nfragment=%s\nconfig_sha256=%s\nimage_sha256=%s\nvmlinux_o_sha256=%s\nsystem_map_sha256=%s\nvmlinux_symvers_sha256=%s\n' \
    "$REV" "$BUILDER" "$BASE" "$FRAGMENT" "$CONFIG_SHA" "$IMAGE_SHA" \
    "$VMLINUX_O_SHA" "$SYSTEM_MAP_SHA" "$VMLINUX_SYMVERS_SHA" > "$OUT/build-inputs.txt"

set +e
docker run --rm --pull=never --network=none --read-only --cap-drop=ALL \
    --security-opt=no-new-privileges --pids-limit=512 --cpus=8 --memory=16g \
    --tmpfs /tmp:rw,nosuid,nodev,size=2g \
    --mount "type=bind,source=$BASE/source,target=/src,readonly" \
    --mount "type=bind,source=$OUT/build,target=/out" \
    --mount "type=bind,source=$OUT/package,target=/package" \
    --mount "type=bind,source=$OUT/metadata,target=/metadata" \
    --mount "type=bind,source=$OUT/input/io-modules.fragment,target=/input/io-modules.fragment,readonly" \
    --env KBUILD_BUILD_USER=debian-m3 --env KBUILD_BUILD_HOST=isolated-builder \
    --env KBUILD_BUILD_VERSION=1 --env KBUILD_BUILD_TIMESTAMP=2026-10-08T00:00:00Z \
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
    drivers/pci/controller/pcie-apple.ko
    drivers/pinctrl/pinctrl-apple-gpio.ko
    # CONFIG_I2C_APPLE expands to these two Makefile objects; together they
    # are the logical i2c-apple target (platform depends on core exports).
    drivers/i2c/busses/i2c-pasemi-core.ko
    drivers/i2c/busses/i2c-pasemi-platform.ko
    drivers/soc/apple/apple-tunable.ko
    drivers/phy/apple/phy-apple-atc.ko
    drivers/usb/typec/typec.ko
    drivers/usb/typec/tcpm/tcpm.ko
    drivers/usb/typec/tcpm/tcpci.ko
    drivers/usb/typec/tipd/tps6598x.ko
    drivers/net/ethernet/aquantia/atlantic/atlantic.ko
)

cp /out/.config /tmp/base.config
/src/scripts/kconfig/merge_config.sh -m -O /out /out/.config /input/io-modules.fragment
make -C /src O=/out ARCH=arm64 olddefconfig
cp /out/.config /metadata/resolved.config
cmp /out/.config /metadata/resolved.config
/src/scripts/diffconfig /tmp/base.config /out/.config > /metadata/config.diff
/src/scripts/diffconfig -m /tmp/base.config /out/.config | LC_ALL=C sort > /metadata/config.diff.merge
printf "%s\n" \
    "CONFIG_APPLE_TUNABLE=m" \
    "CONFIG_AQTION=m" \
    "CONFIG_NET_VENDOR_AQUANTIA=y" \
    "CONFIG_PHY_APPLE_ATC=m" | LC_ALL=C sort > /tmp/expected-config.diff
cmp /tmp/expected-config.diff /metadata/config.diff.merge
for requirement in \
    CONFIG_APPLE_TUNABLE=m CONFIG_AQTION=m \
    CONFIG_NET_VENDOR_AQUANTIA=y CONFIG_PHY_APPLE_ATC=m; do
    grep -Fx "$requirement" /out/.config
done

# A single top-level invocation lets modpost see all cross-directory providers.
make -C /src O=/out ARCH=arm64 -j8 "${modules[@]}"
test -s /out/Module.symvers
release=$(cat /out/include/config/kernel.release)
test "$release" = 7.3.0-rc6
printf "%s\n" "$release" > /metadata/kernel-release.txt
target="/package/lib/modules/$release"
mkdir -p "$target"
for builtin in modules.builtin modules.builtin.modinfo; do
    cp "/out/$builtin" "$target/$builtin"
done

# Copy the requested modules and recursively locate their Kbuild-reported
# module dependencies. Missing dependency objects are a hard build failure.
declare -A seen=()
queue=("${modules[@]}")
closure=()
for ((index = 0; index < ${#queue[@]}; index++)); do
    rel="${queue[index]}"
    [[ -n "${seen[$rel]+yes}" ]] && continue
    seen[$rel]=1
    test -s "/out/$rel"
    closure+=("$rel")
    depends=$(modinfo -F depends "/out/$rel" || true)
    depends=${depends//,/ }
    for dep in $depends; do
        dep_path=$(find /out -type f \( -name "$dep.ko" -o -name "${dep//_/-}.ko" \) -print -quit)
        test -n "$dep_path" || { echo "missing built module dependency: $dep for $rel" >&2; exit 1; }
        queue+=("${dep_path#/out/}")
    done
done

: > "$target/modules.order"
for rel in "${closure[@]}"; do
    dest="$target/kernel/$rel"
    mkdir -p "$(dirname "$dest")"
    cp "/out/$rel" "$dest"
    printf "kernel/%s\n" "$rel" >> "$target/modules.order"
    tag=${rel//\//__}
    modinfo "/out/$rel" > "/metadata/$tag.modinfo"
    readelf -h "/out/$rel" > "/metadata/$tag.elf-header"
    grep -F "Machine:                           AArch64" "/metadata/$tag.elf-header"
    test "$(modinfo -F vermagic "/out/$rel" | cut -d " " -f 1)" = "$release"
done

depmod -e -F /out/System.map -b /package "$release" > /metadata/depmod.stdout 2> /metadata/depmod.stderr
test ! -s /metadata/depmod.stderr
test -s "$target/modules.dep"
test -s "$target/modules.alias"

: > /metadata/modprobe-show-depends.txt
for rel in "${modules[@]}"; do
    name=${rel##*/}
    name=${name%.ko}
    modprobe --show-depends --dirname /package --set-version "$release" "$name" \
        >> /metadata/modprobe-show-depends.txt
done
alias=pci:v00001D6Ad000004C0sv0000106Bsd00000223bc02sc00i00
modprobe --show-depends --dirname /package --set-version "$release" "$alias" \
    > /metadata/aqc113-alias.show-depends
grep -F "/atlantic.ko" /metadata/aqc113-alias.show-depends
awk "\$1 == \"insmod\" { path = \$2; sub(\"^/package\", \"\", path); print path }" \
    /metadata/modprobe-show-depends.txt | awk "!seen[\$0]++" > /package/modules.load
test "$(wc -l < /package/modules.load)" -ge "${#modules[@]}"
while IFS= read -r path; do
    case "$path" in
        /lib/modules/"$release"/kernel/*.ko) ;;
        *) echo "invalid generated module path: $path" >&2; exit 1 ;;
    esac
    test -s "/package$path"
done < /package/modules.load
for rel in "${modules[@]}"; do
    grep -Fx "/lib/modules/$release/kernel/$rel" /package/modules.load
done

printf "source_revision=%s\n" 602042bf29f6efde39cfb5fdd9289bf4854bc0c5 > /metadata/provenance.txt
printf "builder=%s\n" sha256:1cc5bb4ef152a16785acce551084a41c973be8d0c9c7718524f67cd9d7d78121 >> /metadata/provenance.txt
sha256sum /out/.config /out/arch/arm64/boot/Image /out/vmlinux.o /out/System.map /out/vmlinux.symvers \
    /out/Module.symvers >> /metadata/provenance.txt
printf "module_count=%s\n" "${#closure[@]}" >> /metadata/provenance.txt
printf "PASS: resolved four-symbol I/O overlay, 16 logical goals (17 .ko outputs; I2C_APPLE core/platform), dependency metadata generated\n"
' > "$OUT/build.log" 2>&1
BUILD_RC=$?
set -e
printf '%s\n' "$BUILD_RC" > "$OUT/build.exit"
if [[ "$BUILD_RC" -ne 0 ]]; then
    tail -n 20 "$OUT/build.log" >&2
    echo "I/O module build failed; evidence retained at $OUT" >&2
    exit "$BUILD_RC"
fi

# The baseline config remains the recorded config; the clone deliberately has
# the four-symbol overlay and is checked against its retained resolved copy.
printf '%s  %s\n' "$CONFIG_SHA" "$BASE/build/.config" | shasum -a 256 -c -
cmp "$OUT/build/.config" "$OUT/metadata/resolved.config"
# All built-in ABI inputs must remain identical in both workspaces.
for build in "$BASE/build" "$OUT/build"; do
    printf '%s  %s\n' "$IMAGE_SHA" "$build/arch/arm64/boot/Image" \
        "$VMLINUX_O_SHA" "$build/vmlinux.o" \
        "$SYSTEM_MAP_SHA" "$build/System.map" \
        "$VMLINUX_SYMVERS_SHA" "$build/vmlinux.symvers" | shasum -a 256 -c -
done
printf '%s  %s\n' "$(shasum -a 256 "$FRAGMENT" | awk '{print $1}')" "$OUT/input/io-modules.fragment" | shasum -a 256 -c -
find "$OUT/package" "$OUT/metadata" -type f -print0 | \
    sort -z | xargs -0 shasum -a 256 > "$OUT/PACKAGE_SHA256SUMS"
shasum -a 256 "$OUT/build-recipe.sh" "$OUT/build-inputs.txt" \
    "$OUT/input/io-modules.fragment" "$OUT/build.log" "$OUT/build.exit" \
    "$OUT/build/Module.symvers" "$OUT/metadata/config.diff" \
    "$OUT/metadata/config.diff.merge" "$OUT/metadata/resolved.config" > "$OUT/SHA256SUMS"
echo 'PASS: I/O modules built from isolated four-symbol overlay; Image/ABI preserved'
echo "I/O module package: $OUT/package"
echo 'Scope: build/package only; ATC/T6031 compatibility, runtime tunables, Type-C DT gaps, and native/physical probe remain unproven'

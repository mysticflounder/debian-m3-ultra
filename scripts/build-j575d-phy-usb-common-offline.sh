#!/bin/bash
# Offline build/package only. Never install or boot; leave the base immutable.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BASE="$ROOT/scratch/linux-j575d-kernel.HdzQNm"
FRAGMENT="$ROOT/configs/linux-j575d-usb-drivers.fragment"
PATCH_DIR="$ROOT/patches/linux/j575d-602042bf"
EVIDENCE="$ROOT/scratch/j575d-usb-common-build-2026-10-08"
BUILDER=sha256:1cc5bb4ef152a16785acce551084a41c973be8d0c9c7718524f67cd9d7d78121
REV=602042bf29f6efde39cfb5fdd9289bf4854bc0c5
CONFIG_SHA=19ef0607ca8b74c6ec5bd68ae376a85febd3ba1ac3da92d9bb47da9da9ac864c
IMAGE_SHA=ad9b573e66738d13d7758619809cc7e8ff09cf9498e23ccec352dfe42b285f50
VMLINUX_O_SHA=c374260adf8be4dfd7e73a0be79f2136e6a939fa5a5ab7bad840ec19c310faf5
SYSTEM_MAP_SHA=f8013c17497ce293cad4d01be6723173cffb5a0e325f86e2890c9cecb9d69a59
VMLINUX_SYMVERS_SHA=2be09f0907b6c19975e4defbbcfc5e6ec232c07d291205f71c3cb107e1054b0e
patches=(
    0001-apple-spmi-ace3-transactions-and-irqs.patch
    0002-apple-atcphy-m3-generation-support.patch
    0003-typec-tipd-common-core-and-ace3.patch
    0004-apple-atcphy-m3-fabric-calibration.patch
    0005-apple-atcphy-m3-usb-common-calibration.patch
    0007-spmi-apple-fifo-recovery-register.patch
)
mkdir -p "$EVIDENCE"
if [[ $# -ne 0 ]]; then
    echo 'Usage: build-j575d-phy-usb-common-offline.sh' >&2
    exit 2
fi
for tool in docker cp shasum patch; do
    command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
printf '%s  %s\n' "$CONFIG_SHA" "$BASE/build/.config" \
    "$IMAGE_SHA" "$BASE/build/arch/arm64/boot/Image" \
    "$VMLINUX_O_SHA" "$BASE/build/vmlinux.o" \
    "$SYSTEM_MAP_SHA" "$BASE/build/System.map" \
    "$VMLINUX_SYMVERS_SHA" "$BASE/build/vmlinux.symvers" | shasum -a 256 -c -
test -f "$FRAGMENT"
for name in "${patches[@]}"; do test -s "$PATCH_DIR/$name"; done
test "$(docker image inspect "$BUILDER" --format '{{.Os}}/{{.Architecture}}')" = linux/arm64

OUT=$(mktemp -d "$ROOT/scratch/j575d-phy-usb-common.XXXXXX")
mkdir "$OUT/source" "$OUT/build" "$OUT/package" "$OUT/metadata" "$OUT/input"
echo "Retained USB/ACE3 USB-common workspace: $OUT"
# APFS copy-on-write: neither source patches nor config/build touch the baseline.
cp -cR "$BASE/source/." "$OUT/source/"
cp -cR "$BASE/build/." "$OUT/build/"
cp "$FRAGMENT" "$OUT/input/usb-drivers.fragment"
cp "$0" "$OUT/build-recipe.sh"
for name in "${patches[@]}"; do
    cp "$PATCH_DIR/$name" "$OUT/input/$name"
    patch --batch --forward --fuzz=0 -p0 -d "$OUT/source" \
        -i "$OUT/input/$name" > "$OUT/metadata/$name.apply.log" 2>&1
done
printf 'revision=%s\nbuilder=%s\nbase=%s\nconfig_sha256=%s\nimage_sha256=%s\nvmlinux_o_sha256=%s\nsystem_map_sha256=%s\nvmlinux_symvers_sha256=%s\n' \
    "$REV" "$BUILDER" "$BASE" "$CONFIG_SHA" "$IMAGE_SHA" "$VMLINUX_O_SHA" \
    "$SYSTEM_MAP_SHA" "$VMLINUX_SYMVERS_SHA" > "$OUT/build-inputs.txt"
printf 'fragment=%s\nfragment_sha256=%s\npatch_directory=%s\n' \
    "$FRAGMENT" "$(shasum -a 256 "$FRAGMENT" | awk '{print $1}')" "$PATCH_DIR" \
    >> "$OUT/build-inputs.txt"
for name in "${patches[@]}"; do
    printf 'patch=%s\npatch_sha256=%s\n' "$PATCH_DIR/$name" \
        "$(shasum -a 256 "$PATCH_DIR/$name" | awk '{print $1}')" >> "$OUT/build-inputs.txt"
done
# Record all transformed source files, not only modules or their aliases; include the 0004/0005 binding.
for rel in \
    drivers/spmi/spmi-apple-controller.c drivers/spmi/Kconfig \
    drivers/phy/apple/atc.c Documentation/devicetree/bindings/phy/apple,atcphy.yaml \
    drivers/usb/typec/tipd/Kconfig drivers/usb/typec/tipd/Makefile \
    drivers/usb/typec/tipd/core.c drivers/usb/typec/tipd/tps6598x.h \
    drivers/usb/typec/tipd/i2c.c drivers/usb/typec/tipd/spmi.c; do
    shasum -a 256 "$OUT/source/$rel" >> "$OUT/metadata/patched-source.sha256"
done
BINDING_SHA=$(shasum -a 256 "$OUT/source/Documentation/devicetree/bindings/phy/apple,atcphy.yaml" | awk '{print $1}')
printf 'binding_patched_source=%s\nbinding_patched_source_sha256=%s\n' \
    'Documentation/devicetree/bindings/phy/apple,atcphy.yaml' "$BINDING_SHA" >> "$OUT/build-inputs.txt"
printf '%s  %s\n' "$BINDING_SHA" \
    "$OUT/source/Documentation/devicetree/bindings/phy/apple,atcphy.yaml" > "$OUT/metadata/patched-binding.sha256"

set +e
docker run --rm --pull=never --network=none --read-only --cap-drop=ALL \
    --security-opt=no-new-privileges --pids-limit=512 --cpus=8 --memory=16g \
    --tmpfs /tmp:rw,nosuid,nodev,size=2g \
    --mount "type=bind,source=$OUT/source,target=/src,readonly" \
    --mount "type=bind,source=$OUT/build,target=/out" \
    --mount "type=bind,source=$OUT/package,target=/package" \
    --mount "type=bind,source=$OUT/metadata,target=/metadata" \
    --mount "type=bind,source=$OUT/input/usb-drivers.fragment,target=/input/usb-drivers.fragment,readonly" \
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
    drivers/i2c/busses/i2c-pasemi-core.ko
    drivers/i2c/busses/i2c-pasemi-platform.ko
    drivers/soc/apple/apple-tunable.ko
    drivers/phy/apple/phy-apple-atc.ko
    drivers/usb/typec/typec.ko
    drivers/usb/typec/tcpm/tcpm.ko
    drivers/usb/typec/tcpm/tcpci.ko
    drivers/usb/typec/tipd/tps6598x.ko
    drivers/net/ethernet/aquantia/atlantic/atlantic.ko
    drivers/spmi/spmi-apple-controller.ko
    drivers/usb/typec/tipd/tps6598x-core.ko
    drivers/usb/typec/tipd/sn201202x.ko
)
cp /out/.config /tmp/base.config
/src/scripts/kconfig/merge_config.sh -m -O /out /out/.config /input/usb-drivers.fragment
make -C /src O=/out ARCH=arm64 olddefconfig
cp /out/.config /metadata/resolved.config
/src/scripts/diffconfig /tmp/base.config /out/.config > /metadata/config.diff
/src/scripts/diffconfig -m /tmp/base.config /out/.config | LC_ALL=C sort > /metadata/config.diff.merge
printf "%s\n" CONFIG_APPLE_TUNABLE=m CONFIG_AQTION=m CONFIG_NET_VENDOR_AQUANTIA=y \
    CONFIG_PHY_APPLE_ATC=m CONFIG_TYPEC_TPS6598X_CORE=m CONFIG_TYPEC_SN201202X=m \
    | LC_ALL=C sort > /tmp/expected-config.diff
cmp /tmp/expected-config.diff /metadata/config.diff.merge
for requirement in CONFIG_SPMI=y CONFIG_SPMI_APPLE=m CONFIG_IRQ_DOMAIN_HIERARCHY=y \
    CONFIG_TYPEC=m CONFIG_TYPEC_TPS6598X=m CONFIG_TYPEC_TPS6598X_CORE=m \
    CONFIG_TYPEC_SN201202X=m CONFIG_PHY_APPLE_ATC=m; do
    grep -Fx "$requirement" /out/.config
done
# One top-level invocation lets modpost resolve cross-directory module exports.
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
declare -A seen=()
queue=("${modules[@]}")
closure=()
for ((index = 0; index < ${#queue[@]}; index++)); do
    rel="${queue[index]}"
    [[ -n "${seen[$rel]+yes}" ]] && continue
    seen[$rel]=1
    test -s "/out/$rel"
    closure+=("$rel")
    depends=$(modinfo -F depends "/out/$rel")
    depends=${depends//,/ }
    for dep in $depends; do
        dep_path=$(find /out -type f \( -name "$dep.ko" -o -name "${dep//_/-}.ko" \) -print -quit)
        test -n "$dep_path" || { echo "missing dependency: $dep for $rel" >&2; exit 1; }
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
    modprobe --show-depends --dirname /package --set-version "$release" "${name%.ko}" \
        >> /metadata/modprobe-show-depends.txt
done
for pair in "apple,t8122-atcphy:phy-apple-atc" "apple,t6031-atcphy:phy-apple-atc" "apple,sn201202x:sn201202x"; do
    compat=${pair%:*}
    module=${pair#*:}
    modprobe --show-depends --dirname /package --set-version "$release" "of:N*T*C$compat" \
        > "/metadata/$module-alias.show-depends"
    grep -F "/$module.ko" "/metadata/$module-alias.show-depends"
done
awk "\$1 == \"insmod\" { path = \$2; sub(\"^/package\", \"\", path); print path }" \
    /metadata/modprobe-show-depends.txt | awk "!seen[\$0]++" > /package/modules.load
test "$(wc -l < /package/modules.load)" -ge "${#modules[@]}"
while IFS= read -r path; do test -s "/package$path"; done < /package/modules.load
for rel in "${modules[@]}"; do
    grep -Fx "/lib/modules/$release/kernel/$rel" /package/modules.load
done
printf "source_revision=%s\nbuilder=%s\nmodule_count=%s\n" \
    602042bf29f6efde39cfb5fdd9289bf4854bc0c5 \
    sha256:1cc5bb4ef152a16785acce551084a41c973be8d0c9c7718524f67cd9d7d78121 \
    "${#closure[@]}" > /metadata/provenance.txt
sha256sum /out/.config /out/arch/arm64/boot/Image /out/vmlinux.o /out/System.map \
    /out/vmlinux.symvers /out/Module.symvers >> /metadata/provenance.txt
printf "PASS: complete USB/ACE3 module closure built and dependency/alias metadata generated\n"
' > "$OUT/build.log" 2>&1
BUILD_RC=$?
set -e
printf '%s\n' "$BUILD_RC" > "$OUT/build.exit"
if [[ "$BUILD_RC" -ne 0 ]]; then
    tail -n 20 "$OUT/build.log" >&2
    echo "USB/ACE3 USB-common build failed; evidence retained at $OUT" >&2
    exit "$BUILD_RC"
fi
printf '%s  %s\n' "$CONFIG_SHA" "$BASE/build/.config" | shasum -a 256 -c -
cmp "$OUT/build/.config" "$OUT/metadata/resolved.config"
for build in "$BASE/build" "$OUT/build"; do
    printf '%s  %s\n' "$IMAGE_SHA" "$build/arch/arm64/boot/Image" \
        "$VMLINUX_O_SHA" "$build/vmlinux.o" "$SYSTEM_MAP_SHA" "$build/System.map" \
        "$VMLINUX_SYMVERS_SHA" "$build/vmlinux.symvers" | shasum -a 256 -c -
done
cmp "$FRAGMENT" "$OUT/input/usb-drivers.fragment"
for name in "${patches[@]}"; do cmp "$PATCH_DIR/$name" "$OUT/input/$name"; done
find "$OUT/package" "$OUT/metadata" -type f -print0 | \
    sort -z | xargs -0 shasum -a 256 > "$OUT/PACKAGE_SHA256SUMS"
shasum -a 256 "$OUT/build-recipe.sh" "$OUT/build-inputs.txt" "$OUT/input/usb-drivers.fragment" \
    "$OUT/input/"*.patch "$OUT/metadata/patched-source.sha256" \
    "$OUT/metadata/patched-binding.sha256" "$OUT/build.log" "$OUT/build.exit" "$OUT/build/Module.symvers" \
    > "$OUT/SHA256SUMS"
echo 'PASS: USB/ACE3 USB-common module-only overlay built; original Image and built-in ABI preserved'
echo "USB/ACE3 USB-common package: $OUT/package"
 echo "Build log: $OUT/build.log"
echo 'Scope: build/package only; USB-common DT/tunables, physical probe and native qualification pending'

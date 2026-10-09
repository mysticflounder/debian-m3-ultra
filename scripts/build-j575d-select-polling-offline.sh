#!/bin/bash
# Build the opt-in SN201202X select-polling prototype without touching the
# prepared Linux tree, host firmware, disks, or a running machine.  The
# baseline receipt is intentionally bounded to the affected source, kernel
# ABI/configuration, image, and original TIPD module closure.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BASE="$ROOT/scratch/j575d-phy-usb-common.W3594q"
PREREQ="$ROOT/patches/linux/j575d-602042bf/0004-apple-spmi-and-ace3-bindings.patch"
PATCH="$ROOT/patches/linux/j575d-602042bf/0006-typec-tipd-experimental-select-polling.patch"
BUILDER="sha256:1cc5bb4ef152a16785acce551084a41c973be8d0c9c7718524f67cd9d7d78121"
REV=602042bf29f6efde39cfb5fdd9289bf4854bc0c5
RELEASE=7.3.0-rc6
MODULES=(
    drivers/usb/typec/tipd/tps6598x.ko
    drivers/usb/typec/tipd/tps6598x-core.ko
    drivers/usb/typec/tipd/sn201202x.ko
)
SOURCES=(
    Documentation/devicetree/bindings/spmi/apple,spmi.yaml
    Documentation/devicetree/bindings/usb/apple,sn201202x.yaml
    drivers/usb/typec/tipd/spmi.c
    drivers/usb/typec/tipd/tps6598x.h
)
BASE_SOURCES=(
    Documentation/devicetree/bindings/spmi/apple,spmi.yaml
    drivers/usb/typec/tipd/spmi.c
    drivers/usb/typec/tipd/tps6598x.h
)
BOUNDED_BASE_FILES=(
    source/Documentation/devicetree/bindings/spmi/apple,spmi.yaml
    source/drivers/usb/typec/tipd/spmi.c
    source/drivers/usb/typec/tipd/tps6598x.h
    build/.config
    build/Module.symvers
    build/vmlinux.symvers
    build/arch/arm64/boot/Image
    build/drivers/usb/typec/tipd/tps6598x.ko
    build/drivers/usb/typec/tipd/tps6598x-core.ko
    build/drivers/usb/typec/tipd/sn201202x.ko
)

if [[ $# -ne 0 ]]; then
    echo "Usage: $(basename "$0")" >&2
    exit 2
fi
for tool in docker cp shasum patch sort cmp awk sed; do
    command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
for path in "$BASE/source" "$BASE/build" "$BASE/build/.config" \
            "$BASE/build/Module.symvers" "$PREREQ" "$PATCH"; do
    test -e "$path" || { echo "Missing required input: $path" >&2; exit 1; }
done
for rel in "${BASE_SOURCES[@]}"; do
    test -f "$BASE/source/$rel" || {
        echo "Prepared source is missing patch target: $BASE/source/$rel" >&2
        echo "The optional patch requires its binding/source closure before this build can run." >&2
        exit 1
    }
done
test "$(docker image inspect "$BUILDER" --format '{{.Os}}/{{.Architecture}}')" = linux/arm64

OUT=$(mktemp -d "$ROOT/scratch/j575d-select-polling-offline.XXXXXX")
mkdir "$OUT/source" "$OUT/build" "$OUT/package" "$OUT/metadata" "$OUT/input"
echo "Retained select-polling workspace: $OUT"

snapshot_bounded() {
    local root=$1 output=$2 rel
    : > "$output"
    for rel in "${BOUNDED_BASE_FILES[@]}"; do
        test -f "$root/$rel" || { echo "Missing bounded input: $root/$rel" >&2; exit 1; }
        shasum -a 256 "$root/$rel" >> "$output"
    done
}

snapshot_bounded "$BASE" "$OUT/metadata/base-inputs.before.sha256"
cp "$BASE/build/Module.symvers" "$OUT/metadata/base.Module.symvers"
cp -cR "$BASE/source/." "$OUT/source/"
cp -cR "$BASE/build/." "$OUT/build/"
cp "$PREREQ" "$OUT/input/0004-apple-spmi-and-ace3-bindings.patch"
cp "$PATCH" "$OUT/input/0006-typec-tipd-experimental-select-polling.patch"
cmp "$PREREQ" "$OUT/input/0004-apple-spmi-and-ace3-bindings.patch"
cmp "$PATCH" "$OUT/input/0006-typec-tipd-experimental-select-polling.patch"
cp "$0" "$OUT/build-recipe.sh"
patch --batch --forward --fuzz=0 -p0 -d "$OUT/source" \
    -i "$OUT/input/0004-apple-spmi-and-ace3-bindings.patch" \
    > "$OUT/metadata/0004.apply.log" 2>&1
patch --batch --forward --fuzz=0 -p0 -d "$OUT/source" \
    -i "$OUT/input/0006-typec-tipd-experimental-select-polling.patch" \
    > "$OUT/metadata/0006.apply.log" 2>&1

printf 'revision=%s\nbuilder=%s\nbase=%s\nprerequisite_patch=%s\nprerequisite_patch_sha256=%s\npatch=%s\npatch_sha256=%s\n' \
    "$REV" "$BUILDER" "$BASE" "$PREREQ" "$(shasum -a 256 "$PREREQ" | awk '{print $1}')" \
    "$PATCH" "$(shasum -a 256 "$PATCH" | awk '{print $1}')" \
    > "$OUT/build-inputs.txt"
printf 'base_inputs_sha256_manifest=%s\n' \
    "$OUT/metadata/base-inputs.before.sha256" \
    >> "$OUT/build-inputs.txt"
for rel in "${SOURCES[@]}"; do
    shasum -a 256 "$OUT/source/$rel" >> "$OUT/metadata/patched-source.sha256"
done
{
    sed -n "s/^patching file '\(.*\)'$/\1/p" "$OUT/metadata/0004.apply.log"
    sed -n "s/^patching file '\(.*\)'$/\1/p" "$OUT/metadata/0006.apply.log"
} | sort -u > "$OUT/metadata/source.changed"
printf '%s\n' "${SOURCES[@]}" | sort -u > "$OUT/metadata/source.expected-changed"
cmp "$OUT/metadata/source.changed" "$OUT/metadata/source.expected-changed"

set +e
docker run --rm --pull=never --network=none --read-only --cap-drop=ALL \
    --security-opt=no-new-privileges --pids-limit=512 --cpus=8 --memory=16g \
    --tmpfs /tmp:rw,nosuid,nodev,size=2g \
    --mount "type=bind,source=$OUT/source,target=/src,readonly" \
    --mount "type=bind,source=$OUT/build,target=/out" \
    --mount "type=bind,source=$OUT/package,target=/package" \
    --mount "type=bind,source=$OUT/metadata,target=/metadata" \
    --env KBUILD_BUILD_USER=debian-m3 --env KBUILD_BUILD_HOST=isolated-builder \
    --env KBUILD_BUILD_VERSION=1 --env KBUILD_BUILD_TIMESTAMP=2026-10-09T00:00:00Z \
    --workdir /out --entrypoint /bin/bash "$BUILDER" -c '
set -euxo pipefail
uname -m
gcc --version | head -n 1
make --version | head -n 1
modinfo --version
test "$(cat /out/include/config/kernel.release)" = 7.3.0-rc6
build_modules=(
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
# One top-level invocation is required: in-tree modpost resolves the
# cross-directory Type-C exports only when the full prepared closure is built.
make -C /src O=/out ARCH=arm64 -j8 "${build_modules[@]}"
test -s /out/Module.symvers
printf "source_revision=%s\nbuilder=%s\nbase_module_symvers=%s\n" \
    602042bf29f6efde39cfb5fdd9289bf4854bc0c5 \
    sha256:1cc5bb4ef152a16785acce551084a41c973be8d0c9c7718524f67cd9d7d78121 \
    /metadata/base.Module.symvers > /metadata/provenance.txt
printf "modpost_closure_count=%s\n" "${#build_modules[@]}" >> /metadata/provenance.txt
sha256sum /out/Module.symvers >> /metadata/provenance.txt
for rel in "${build_modules[@]}"; do
    test -s "/out/$rel"
done
release=$(cat /out/include/config/kernel.release)
target="/package/lib/modules/$release/kernel"
for rel in \
    drivers/usb/typec/tipd/tps6598x.ko \
    drivers/usb/typec/tipd/tps6598x-core.ko \
    drivers/usb/typec/tipd/sn201202x.ko; do
    test -s "/out/$rel"
    mkdir -p "$target/$(dirname "$rel")"
    cp "/out/$rel" "$target/$rel"
    modinfo "/out/$rel" > "/metadata/${rel//\//__}.modinfo"
    readelf -h "/out/$rel" > "/metadata/${rel//\//__}.elf-header"
    grep -F "Machine:                           AArch64" "/metadata/${rel//\//__}.elf-header"
    test "$(modinfo -F vermagic "/out/$rel" | cut -d " " -f 1)" = "$release"
    printf "%s  %s\n" "$(sha256sum "/out/$rel" | cut -d " " -f 1)" "$rel" \
        >> /metadata/changed-modules.sha256
done
grep -F "spmi_register_zero_write" /metadata/base.Module.symvers
grep -F "spmi_register_read" /metadata/base.Module.symvers
printf "select_polling_modules=3\n" >> /metadata/provenance.txt
printf "PASS: select-polling tipd modules built and linked against the prepared Module.symvers\n"
' > "$OUT/build.log" 2>&1
BUILD_RC=$?
set -e
printf '%s\n' "$BUILD_RC" > "$OUT/build.exit"
if [[ "$BUILD_RC" -ne 0 ]]; then
    tail -n 30 "$OUT/build.log" >&2
    echo "select-polling build failed; evidence retained at $OUT" >&2
    exit "$BUILD_RC"
fi

snapshot_bounded "$BASE" "$OUT/metadata/base-inputs.after.sha256"
cmp "$OUT/metadata/base-inputs.before.sha256" "$OUT/metadata/base-inputs.after.sha256"
cmp "$BASE/build/.config" "$OUT/build/.config"
cmp "$BASE/build/Module.symvers" "$OUT/metadata/base.Module.symvers"
for rel in "${MODULES[@]}"; do
    test -s "$OUT/build/$rel"
done
find "$OUT/package" "$OUT/metadata" -type f -print0 | sort -z | xargs -0 shasum -a 256 > "$OUT/PACKAGE_SHA256SUMS"
shasum -a 256 "$OUT/build-recipe.sh" "$OUT/build-inputs.txt" \
    "$OUT/input/0004-apple-spmi-and-ace3-bindings.patch" \
    "$OUT/input/0006-typec-tipd-experimental-select-polling.patch" \
    "$OUT/metadata/patched-source.sha256" "$OUT/metadata/source.changed" \
    "$OUT/build.log" "$OUT/build.exit" "$OUT/build/Module.symvers" \
    "$OUT/metadata/changed-modules.sha256" > "$OUT/SHA256SUMS"
echo 'PASS: select-polling offline module overlay built; base source/build invariance verified'
echo "Select-polling package: $OUT/package"
echo "Build log: $OUT/build.log"
echo 'Scope: offline module build/linkage validation only; DT hardware behavior and native qualification remain unproven'

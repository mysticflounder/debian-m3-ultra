#!/bin/bash
# Build-only diagnostic initramfs; never boot, launch, mount, or install.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILDER=sha256:1cc5bb4ef152a16785acce551084a41c973be8d0c9c7718524f67cd9d7d78121
SRC="$ROOT/tools/j575d-ram-init.c"
MODULE_PACKAGE=

if [[ $# -eq 2 && "$1" == --module-package ]]; then
    test -d "$2" || { echo "Module package is not a directory: $2" >&2; exit 2; }
    MODULE_PACKAGE=$(cd -- "$2" && pwd -P)
elif [[ $# -ne 0 ]]; then
    echo "Usage: $0 [--module-package DIRECTORY]" >&2
    exit 2
fi

for tool in docker shasum awk; do
    command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
test -f "$SRC" || { echo "Missing source: $SRC" >&2; exit 1; }
test "$(docker image inspect "$BUILDER" --format '{{.Os}}/{{.Architecture}}')" = linux/arm64

OUT=$(mktemp -d "$ROOT/scratch/j575d-initramfs.XXXXXX")
mkdir "$OUT/input" "$OUT/output"
cp "$SRC" "$OUT/input/j575d-ram-init.c"
cp "$0" "$OUT/input/build-recipe.sh"
printf 'builder=%s\nsource_sha256=%s\n' "$BUILDER" \
    "$(shasum -a 256 "$SRC" | awk '{print $1}')" > "$OUT/build-inputs.txt"
if [[ -n "$MODULE_PACKAGE" ]]; then
    printf 'module_package=%s\n' "$MODULE_PACKAGE" >> "$OUT/build-inputs.txt"
else
    printf 'module_package=none\n' >> "$OUT/build-inputs.txt"
fi

DOCKER_MOUNTS=(
    --mount "type=bind,source=$OUT/input,target=/input,readonly"
    --mount "type=bind,source=$OUT/output,target=/out"
)
BUILD_MODE=ram-only
if [[ -n "$MODULE_PACKAGE" ]]; then
    DOCKER_MOUNTS+=(
        --mount "type=bind,source=$MODULE_PACKAGE,target=/module-package,readonly"
    )
    BUILD_MODE=module-package
fi

set +e
docker run --rm --pull=never --network=none --read-only --cap-drop=ALL \
    --security-opt=no-new-privileges --pids-limit=128 --cpus=2 --memory=2g \
    --tmpfs /tmp:rw,nosuid,nodev,size=512m \
    "${DOCKER_MOUNTS[@]}" \
    --workdir /out --entrypoint /bin/bash "$BUILDER" -c '
set -euxo pipefail
gcc -static -O2 -std=c11 -D_GNU_SOURCE -Wall -Wextra -Werror \
    -Wl,-z,max-page-size=0x10000 -o /out/init /input/j575d-ram-init.c
readelf -h /out/init > /out/readelf-header.txt
readelf -W -l /out/init > /out/readelf-programs.txt
grep -F "Class:                             ELF64" /out/readelf-header.txt
grep -F "Machine:                           AArch64" /out/readelf-header.txt
if grep -q " INTERP " /out/readelf-programs.txt; then
    echo "INTERP program header is forbidden for static /init" >&2
    exit 1
fi
load_count=$(awk "\$1 == \"LOAD\" {print \$NF}" /out/readelf-programs.txt | tee /out/load-alignments.txt | wc -l)
test "$load_count" -gt 0
while IFS= read -r align; do test "$((align))" -ge 16384; done < /out/load-alignments.txt
mkdir -p /out/rootfs/dev /out/rootfs/proc /out/rootfs/sys /out/rootfs/run
if test "$1" = module-package; then
    test -f /module-package/modules.load
    module_release=
    module_count=0
    while IFS= read -r module_path || test -n "$module_path"; do
        test -z "$module_path" && continue
        case "$module_path" in
            /lib/modules/*/kernel/*.ko) ;;
            *) echo "modules.load entry is not an absolute kernel module path: $module_path" >&2; exit 1 ;;
        esac
        release_path=${module_path#/lib/modules/}
        release=${release_path%%/kernel/*}
        test -n "$release"
        if test -z "$module_release"; then
            module_release=$release
        else
            test "$module_release" = "$release"
        fi
        test -f "/module-package$module_path"
        module_count=$((module_count + 1))
    done < /module-package/modules.load
    test "$module_count" -gt 0
    test -f "/module-package/lib/modules/$module_release/modules.dep"
    test -f "/module-package/lib/modules/$module_release/modules.alias"
    mkdir -p /out/rootfs/lib
    cp /module-package/modules.load /out/rootfs/modules.load
    cp -a /module-package/lib/modules /out/rootfs/lib/modules
fi
cp /out/init /out/rootfs/init
find /out/rootfs -exec touch -d @0 {} +
(cd /out/rootfs && find . -print0 | sort -z | cpio --null --reproducible --quiet -o -H newc > /out/initramfs.cpio)
gzip -n -f /out/initramfs.cpio
gzip -t /out/initramfs.cpio.gz
gzip -dc /out/initramfs.cpio.gz | cpio --quiet -it > /out/archive-list.txt
grep -Fx "init" /out/archive-list.txt
if test "$1" = module-package; then
    grep -Fx "modules.load" /out/archive-list.txt
    grep -F "lib/modules/" /out/archive-list.txt
fi
' build-j575d-initramfs "$BUILD_MODE" > "$OUT/build.log" 2>&1
BUILD_RC=$?
set -e
printf '%s\n' "$BUILD_RC" > "$OUT/build.exit"
if [[ "$BUILD_RC" -ne 0 ]]; then
    tail -n 20 "$OUT/build.log" >&2
    echo "Build failed; retained evidence: $OUT" >&2
    exit "$BUILD_RC"
fi
ARTIFACTS=("$OUT/input/j575d-ram-init.c" "$OUT/input/build-recipe.sh" \
    "$OUT/output/init" "$OUT/output/initramfs.cpio.gz" \
    "$OUT/output/readelf-header.txt" "$OUT/output/readelf-programs.txt" \
    "$OUT/output/load-alignments.txt" "$OUT/output/archive-list.txt" \
    "$OUT/build-inputs.txt" "$OUT/build.log" "$OUT/build.exit")
shasum -a 256 "${ARTIFACTS[@]}" > "$OUT/SHA256SUMS"
echo "PASS: static AArch64 initramfs; LOAD alignment >=16 KiB; build-only"
echo "Retained evidence: $OUT"

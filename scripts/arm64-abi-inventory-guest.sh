#!/bin/bash
# Guest-side ABI source inventory only.  This deliberately does not compile
# or execute an ABI test; it transports bounded, allowlisted source files.
set -euo pipefail
export LC_ALL=C

fail() {
    printf '\nM3_ABI_INVENTORY_FAIL reason=%s\n' "$1"
    exit 1
}

[ "$#" -eq 2 ] || fail arguments
cpus=$1
token=$2
[ "$cpus" = 1 ] || fail cpus
case "$token" in ''|*[!a-zA-Z0-9-]*) fail token;; esac
[ "$(uname -m)" = aarch64 ] || fail architecture
[ "$(getconf _NPROCESSORS_ONLN)" = 1 ] || fail online-cpus
[ "$(cat /sys/devices/system/cpu/online)" = 0 ] || fail online-map

mkdir -p /mnt/abi-inventory-build
mount -o ro,noload /dev/vdb /mnt/abi-inventory-build
trap 'rc=$?; set +e; umount /mnt/abi-inventory-build 2>/dev/null || true; [ "$rc" -eq 0 ] || printf "M3_ABI_INVENTORY_FAIL reason=command-failed\n"; exit "$rc"' EXIT
[ "$(blockdev --getro /dev/vdb)" = 1 ] || fail source-not-readonly
findmnt -n -o OPTIONS /mnt/abi-inventory-build | grep -qw ro || fail mount-not-readonly

sources=()
for candidate in /mnt/abi-inventory-build/linux-asahi-*; do
    [ ! -L "$candidate" ] && [ -d "$candidate" ] && sources+=("$candidate")
done
[ "${#sources[@]}" = 1 ] || fail source-tree
source_root=${sources[0]}
if [ -d "$source_root/debian/build/source_none" ]; then
    source_root="$source_root/debian/build/source_none"
fi
selftests="$source_root/tools/testing/selftests"
[ -d "$selftests" ] || fail selftests-root

abi_dir="$selftests/arm64/abi"
[ -d "$abi_dir" ] || fail abi-root
[ -f "$abi_dir/hwcap.c" ] || fail missing-hwcap

names=(Makefile ptrace.c syscall-abi.c syscall-abi-asm.S syscall-abi.h tpidr2.c hwcap.c kselftest.h lib.mk)
paths=(
    "$abi_dir/Makefile"
    "$abi_dir/ptrace.c"
    "$abi_dir/syscall-abi.c"
    "$abi_dir/syscall-abi-asm.S"
    "$abi_dir/syscall-abi.h"
    "$abi_dir/tpidr2.c"
    "$abi_dir/hwcap.c"
    "$selftests/kselftest.h"
    "$selftests/lib.mk"
)

total_bytes=0
for i in "${!names[@]}"; do
    name=${names[$i]}
    path=${paths[$i]}
    [ -f "$path" ] && [ ! -L "$path" ] || fail "missing-$name"
    bytes=$(stat -c '%s' "$path") || fail "stat-$name"
    case "$bytes" in ''|*[!0-9]*) fail "size-$name";; esac
    [ "$bytes" -le 131072 ] || fail "file-too-large-$name"
    total_bytes=$((total_bytes + bytes))
    [ "$total_bytes" -le 524288 ] || fail inventory-too-large
done

# The leading newline prevents an existing serial-console escape sequence or
# shell prompt from being mistaken for the first exact inventory marker.
for i in "${!names[@]}"; do
    name=${names[$i]}
    path=${paths[$i]}
    bytes=$(stat -c '%s' "$path")
    digest=$(sha256sum "$path" | awk '{print $1}')
    case "$digest" in ''|*[!0-9a-f]*) fail "hash-$name";; esac
    [ "${#digest}" -eq 64 ] || fail "hash-$name"
    printf '\nM3_ABI_FILE_BEGIN name=%s sha256=%s bytes=%s\n' "$name" "$digest" "$bytes"
    base64 "$path"
    printf 'M3_ABI_FILE_END name=%s\n' "$name"
done

boot=$(cat /proc/sys/kernel/random/boot_id)
identity="pid=$$ boot=$boot cpus=$cpus"
printf '\nM3_SELFTEST_READY token=%s %s\n' "$token" "$identity"
IFS= read -r command
[ "$command" = "GO $token" ] || fail go

printf 'M3_SELFTEST_BEGIN token=%s cpu=0 test=hwcap\n' "$token"
printf 'TAP version 13\n1..1\nok 1 source_inventory_collected\n# Totals: pass:1 fail:0 xfail:0 xpass:0 skip:0 error:0\n'
printf 'M3_SELFTEST_END token=%s cpu=0 status=0\n' "$token"
printf 'M3_SELFTEST_DONE token=%s cpus=1\n' "$token"

IFS= read -r command
[[ "$command" =~ ^VERIFY\ [0-9a-f]{48}$ ]] || fail verify
nonce=${command#VERIFY }
[ "$(cat /proc/sys/kernel/random/boot_id)" = "$boot" ] || fail boot-changed
printf 'M3_SELFTEST_PASS nonce=%s %s\n' "$nonce" "$identity"
IFS= read -r command
[ "$command" = POWEROFF ] || fail poweroff
umount /mnt/abi-inventory-build
trap - EXIT
sync
exec /sbin/poweroff

#!/bin/bash
# Runs only inside a disposable Linux guest; never invoke this on the host.
set -euo pipefail
export LC_ALL=C
unset KSFT_TAP_LEVEL
fail() { printf '\nM3_SELFTEST_FAIL reason=%s\n' "$1"; exit 1; }
trap 'fail command-failed' ERR
[ "$#" -eq 2 ] || fail arguments
cpus=$1; token=$2
case "$cpus" in 1|8|16|24|32) ;; *) fail cpus;; esac
case "$token" in ''|*[!a-zA-Z0-9-]*) fail token;; esac
[ "$(uname -m)" = aarch64 ] || fail architecture
[ "$(getconf _NPROCESSORS_ONLN)" = "$cpus" ] || fail online-cpus
[ "$(cat /sys/devices/system/cpu/online)" = "0-$((cpus-1))" ] ||
    { [ "$cpus" = 1 ] && [ "$(cat /sys/devices/system/cpu/online)" = 0 ]; } || fail online-map
boot=$(cat /proc/sys/kernel/random/boot_id)
identity="pid=$$ boot=$boot cpus=$cpus"
ulimit -c 0
mkdir -p /mnt/selftest-build
mount -o ro,noload /dev/vdb /mnt/selftest-build
sources=()
for candidate in /mnt/selftest-build/linux-asahi-*; do
    [ ! -d "$candidate" ] || sources+=("$candidate")
done
[ "${#sources[@]}" = 1 ] && [ -d "${sources[0]}" ] || fail source-tree
source_root=${sources[0]}
if [ -d "$source_root/debian/build/source_none" ]; then
    source_root="$source_root/debian/build/source_none"
fi
selftests="$source_root/tools/testing/selftests"
test_source="$selftests/arm64/abi/hwcap.c"
if [ ! -f "$test_source" ]; then
    test_source="$selftests/arm64/hwcap/hwcap.c"
fi
[ -f "$test_source" ] && [ -f "$selftests/kselftest.h" ] || fail missing-hwcap
work=$(mktemp -d /root/m3-kselftest.XXXXXX)
mkdir -p "$work/arm64/abi"
cp "$test_source" "$work/arm64/abi/hwcap.c"
cp "$selftests/kselftest.h" "$work/kselftest.h"
printf '\nM3_SELFTEST_SOURCE path=%s\n' "$test_source"
sha256sum "$test_source" "$selftests/kselftest.h"
grep '^#include' "$test_source"
sed -n '1,80p' "$(dirname "$test_source")/Makefile"
uname -a
cc --version | head -1
# Match the kernel tools header environment without modifying upstream source.
# Userspace UAPI headers alone do not provide linux/compiler.h.
[ -f "$source_root/tools/include/linux/compiler.h" ] || fail missing-tools-headers
cc -O2 -Wall -Wextra -I"$work" -I"$selftests" -I"$source_root/tools/include" \
    -o "$work/hwcap" "$work/arm64/abi/hwcap.c"
sha256sum "$work/hwcap"
printf '\nM3_SELFTEST_READY token=%s %s\n' "$token" "$identity"
IFS= read -r command
[ "$command" = "GO $token" ] || fail go
for ((cpu=0; cpu<cpus; cpu++)); do
    printf 'M3_SELFTEST_BEGIN token=%s cpu=%s test=hwcap\n' "$token" "$cpu"
    status=0
    taskset -c "$cpu" timeout --signal=TERM --kill-after=2 30 "$work/hwcap" || status=$?
    printf 'M3_SELFTEST_END token=%s cpu=%s status=%s\n' "$token" "$cpu" "$status"
    [ "$status" = 0 ] || fail test-exit
done
printf 'M3_SELFTEST_DONE token=%s cpus=%s\n' "$token" "$cpus"
IFS= read -r command
nonce=${command#VERIFY }
[[ "$command" =~ ^VERIFY\ [0-9a-f]{48}$ ]] || fail verify
[ "$(cat /proc/sys/kernel/random/boot_id)" = "$boot" ] || fail boot-changed
printf 'M3_SELFTEST_PASS nonce=%s %s\n' "$nonce" "$identity"
IFS= read -r command
[ "$command" = POWEROFF ] || fail poweroff
umount /mnt/selftest-build
sync
exec /sbin/poweroff

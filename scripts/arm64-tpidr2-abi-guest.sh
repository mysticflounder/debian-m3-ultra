#!/bin/bash
# Guest-side bounded arm64 tpidr2 ABI smoke test.
# The source is compiled unmodified, then run only as nobody with no_new_privs.
set -euo pipefail
export LC_ALL=C
# kselftest.h suppresses its TAP header when this variable is inherited.
unset KSFT_TAP_LEVEL

fail() {
    printf '\nM3_TPIDR2_ABI_FAIL reason=%s\n' "$1"
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

mkdir -p /mnt/tpidr2-abi-build
mount -o ro,noload /dev/vdb /mnt/tpidr2-abi-build
trap 'rc=$?; set +e; umount /mnt/tpidr2-abi-build 2>/dev/null || true; [ "$rc" -eq 0 ] || printf "M3_TPIDR2_ABI_FAIL reason=command-failed\n"; exit "$rc"' EXIT
[ "$(blockdev --getro /dev/vdb)" = 1 ] || fail source-not-readonly
findmnt -n -o OPTIONS /mnt/tpidr2-abi-build | grep -qw ro || fail mount-not-readonly

sources=()
for candidate in /mnt/tpidr2-abi-build/linux-asahi-*; do
    [ ! -L "$candidate" ] && [ -d "$candidate" ] && sources+=("$candidate")
done
[ "${#sources[@]}" = 1 ] || fail source-tree
source_tree=${sources[0]}
[ "$(basename "$source_tree")" = linux-asahi-7.1.10-1 ] || fail source-version
source_root=$source_tree
if [ -d "$source_root/debian/build/source_none" ]; then
    source_root="$source_root/debian/build/source_none"
fi
selftests="$source_root/tools/testing/selftests"
tpidr2_source="$selftests/arm64/abi/tpidr2.c"
tpidr2_makefile="$selftests/arm64/abi/Makefile"
tpidr2_header="$selftests/kselftest.h"
[ -f "$tpidr2_source" ] && [ ! -L "$tpidr2_source" ] || fail tpidr2-source
[ -f "$tpidr2_makefile" ] && [ ! -L "$tpidr2_makefile" ] || fail tpidr2-makefile
[ -f "$tpidr2_header" ] && [ ! -L "$tpidr2_header" ] || fail kselftest-header
[ -f "$source_root/tools/include/nolibc/nolibc.h" ] && [ ! -L "$source_root/tools/include/nolibc/nolibc.h" ] || fail nolibc-header

work=$(mktemp -d /root/m3-tpidr2-abi.XXXXXX)
chmod 700 "$work"
mkdir -p "$work/tools/testing/selftests/arm64/abi"
cp "$tpidr2_source" "$work/tools/testing/selftests/arm64/abi/tpidr2.c"
cp "$tpidr2_header" "$work/tools/testing/selftests/kselftest.h"

source_bytes=$(stat -c '%s' "$tpidr2_source") || fail source-stat
header_bytes=$(stat -c '%s' "$tpidr2_header") || fail header-stat
makefile_bytes=$(stat -c '%s' "$tpidr2_makefile") || fail makefile-stat
source_sha=$(sha256sum "$tpidr2_source" | awk '{print $1}') || fail source-hash
header_sha=$(sha256sum "$tpidr2_header" | awk '{print $1}') || fail header-hash
makefile_sha=$(sha256sum "$tpidr2_makefile" | awk '{print $1}') || fail makefile-hash
[ "$source_sha" = 02f47fbe9090846d28fc5562a892194ab11820b6832b61d171fd1f16c12f5485 ] || fail source-hash-pin
[ "$header_sha" = b01a128468643494316bb8f998c80a1aacd4e686c5f13446c16e09928cf9355c ] || fail header-hash-pin
[ "$makefile_sha" = 8817dddeebcd8ba6f11d069f78dd4c0ef7b4d7c19f294b35b31cad56fa887664 ] || fail makefile-hash-pin
printf '\nM3_TPIDR2_SOURCE path=%s sha256=%s bytes=%s\n' "$tpidr2_source" "$source_sha" "$source_bytes"
printf 'M3_TPIDR2_HEADER path=%s sha256=%s bytes=%s\n' "$tpidr2_header" "$header_sha" "$header_bytes"
printf 'M3_TPIDR2_MAKEFILE path=%s sha256=%s bytes=%s\n' "$tpidr2_makefile" "$makefile_sha" "$makefile_bytes"
while IFS= read -r line; do printf 'M3_TPIDR2_INCLUDE %s\n' "$line"; done < <(sed -n '/^#include/p' "$tpidr2_source")
while IFS= read -r line; do printf 'M3_TPIDR2_MAKEFILE_LINE %s\n' "$line"; done < "$tpidr2_makefile"

bin_dir=$(mktemp -d /opt/m3-tpidr2.XXXXXX)
chmod 755 "$bin_dir"
cc -fno-asynchronous-unwind-tables -fno-ident -s -Os -nostdlib \
    -static -include "$source_root/tools/include/nolibc/nolibc.h" \
    -I"$work/tools/testing/selftests" -ffreestanding -Wall \
    "$work/tools/testing/selftests/arm64/abi/tpidr2.c" \
    -o "$bin_dir/tpidr2" -lgcc \
    >"$work/compile.stdout" 2>"$work/compile.stderr" || {
        sed -n '1,60p' "$work/compile.stderr"
        fail compile
    }
chmod 755 "$bin_dir/tpidr2"
[ "$(stat -c '%u:%g:%a' "$bin_dir/tpidr2")" = '0:0:755' ] || fail binary-contract
readelf -l "$bin_dir/tpidr2" >"$work/readelf.program" 2>"$work/readelf.program.stderr" || fail readelf-program
readelf -d "$bin_dir/tpidr2" >"$work/readelf.dynamic" 2>"$work/readelf.dynamic.stderr" || fail readelf-dynamic
! grep -q 'INTERP' "$work/readelf.program" || fail dynamic-interpreter
! grep -q 'NEEDED' "$work/readelf.dynamic" || fail dynamic-needed
printf 'M3_TPIDR2_ELF static=1 interpreter=0 needed=0\n'
sha256sum "$bin_dir/tpidr2"

setpriv_bin=$(command -v setpriv) || fail setpriv-missing
id_contract=$("$setpriv_bin" --reuid 65534 --regid 65534 --clear-groups --no-new-privs id) || fail privilege-contract
case "$id_contract" in *uid=65534*gid=65534*) ;; *) fail privilege-contract;; esac
printf 'M3_TPIDR2_PRIVILEGE command=setpriv --reuid 65534 --regid 65534 --clear-groups --no-new-privs id\n'
printf 'M3_TPIDR2_PRIVILEGE_RESULT %s\n' "$id_contract"

if [ -r /proc/sys/abi/sme_default_vector_length ]; then
    sme_probe=present
    printf 'M3_TPIDR2_SME_PROBE state=present\n'
else
    [ ! -e /proc/sys/abi/sme_default_vector_length ] || fail sme-probe-unreadable
    sme_probe=absent
    printf 'M3_TPIDR2_SME_PROBE state=absent\n'
fi

boot=$(cat /proc/sys/kernel/random/boot_id)
identity="pid=$$ boot=$boot cpus=$cpus"
ulimit -c 0
printf '\nM3_SELFTEST_READY token=%s %s\n' "$token" "$identity"
IFS= read -r command
[ "$command" = "GO $token" ] || fail go
printf 'M3_SELFTEST_BEGIN token=%s cpu=0 test=tpidr2\n' "$token"

status=0
timeout --signal=TERM --kill-after=2 30 \
    "$setpriv_bin" --reuid 65534 --regid 65534 --clear-groups --no-new-privs \
    taskset -c 0 "$bin_dir/tpidr2" || status=$?
printf 'M3_SELFTEST_END token=%s cpu=0 status=%s\n' "$token" "$status"
[ "$status" = 0 ] || fail test-exit
printf 'M3_SELFTEST_DONE token=%s cpus=1\n' "$token"

IFS= read -r command
[[ "$command" =~ ^VERIFY\ [0-9a-f]{48}$ ]] || fail verify
nonce=${command#VERIFY }
[ "$(cat /proc/sys/kernel/random/boot_id)" = "$boot" ] || fail boot-changed
printf 'M3_SELFTEST_PASS nonce=%s %s\n' "$nonce" "$identity"
IFS= read -r command
[ "$command" = POWEROFF ] || fail poweroff
umount /mnt/tpidr2-abi-build
trap - EXIT
sync
exec /sbin/poweroff

#!/bin/bash
# Guest-side bounded arm64 syscall ABI smoke test.
# The source is compiled unmodified, then run only as nobody with no_new_privs.
set -euo pipefail
export LC_ALL=C
# kselftest.h suppresses its TAP header when this variable is inherited.
unset KSFT_TAP_LEVEL

fail() {
    printf '\nM3_SYSCALL_ABI_FAIL reason=%s\n' "$1"
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

mkdir -p /mnt/syscall-abi-build
mount -o ro,noload /dev/vdb /mnt/syscall-abi-build
trap 'rc=$?; set +e; umount /mnt/syscall-abi-build 2>/dev/null || true; [ "$rc" -eq 0 ] || printf "M3_SYSCALL_ABI_FAIL reason=command-failed\n"; exit "$rc"' EXIT
[ "$(blockdev --getro /dev/vdb)" = 1 ] || fail source-not-readonly
findmnt -n -o OPTIONS /mnt/syscall-abi-build | grep -qw ro || fail mount-not-readonly

sources=()
for candidate in /mnt/syscall-abi-build/linux-asahi-*; do
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
syscall_source="$selftests/arm64/abi/syscall-abi.c"
syscall_asm="$selftests/arm64/abi/syscall-abi-asm.S"
syscall_makefile="$selftests/arm64/abi/Makefile"
syscall_header="$selftests/kselftest.h"
syscall_abi_header="$selftests/arm64/abi/syscall-abi.h"
[ -f "$syscall_source" ] && [ ! -L "$syscall_source" ] || fail syscall-source
[ -f "$syscall_asm" ] && [ ! -L "$syscall_asm" ] || fail syscall-asm
[ -f "$syscall_makefile" ] && [ ! -L "$syscall_makefile" ] || fail syscall-makefile
[ -f "$syscall_header" ] && [ ! -L "$syscall_header" ] || fail kselftest-header
[ -f "$syscall_abi_header" ] && [ ! -L "$syscall_abi_header" ] || fail syscall-abi-header

work=$(mktemp -d /root/m3-syscall-abi.XXXXXX)
chmod 700 "$work"
mkdir -p "$work/arm64/abi"
cp "$syscall_source" "$work/arm64/abi/syscall-abi.c"
cp "$syscall_asm" "$work/arm64/abi/syscall-abi-asm.S"
cp "$syscall_header" "$work/kselftest.h"
cp "$syscall_abi_header" "$work/arm64/abi/syscall-abi.h"

source_bytes=$(stat -c '%s' "$syscall_source") || fail source-stat
asm_bytes=$(stat -c '%s' "$syscall_asm") || fail asm-stat
abi_header_bytes=$(stat -c '%s' "$syscall_abi_header") || fail abi-header-stat
header_bytes=$(stat -c '%s' "$syscall_header") || fail header-stat
makefile_bytes=$(stat -c '%s' "$syscall_makefile") || fail makefile-stat
source_sha=$(sha256sum "$syscall_source" | awk '{print $1}') || fail source-hash
asm_sha=$(sha256sum "$syscall_asm" | awk '{print $1}') || fail asm-hash
abi_header_sha=$(sha256sum "$syscall_abi_header" | awk '{print $1}') || fail abi-header-hash
header_sha=$(sha256sum "$syscall_header" | awk '{print $1}') || fail header-hash
makefile_sha=$(sha256sum "$syscall_makefile" | awk '{print $1}') || fail makefile-hash
[ "$source_sha" = 5b2bb4c98064b0263860cda635340c68a4169a2882698101629f94a79b1de5af ] || fail source-hash-pin
[ "$asm_sha" = 9c7e954f4273960af9043380ef1087d286238810658d36209bfb5178adde6a93 ] || fail asm-hash-pin
[ "$abi_header_sha" = 3459f9a4735b082e1716aa19741750d24faaa37b56abf17450c9170524efe423 ] || fail abi-header-hash-pin
[ "$header_sha" = b01a128468643494316bb8f998c80a1aacd4e686c5f13446c16e09928cf9355c ] || fail header-hash-pin
printf '\nM3_SYSCALL_SOURCE path=%s sha256=%s bytes=%s\n' "$syscall_source" "$source_sha" "$source_bytes"
printf 'M3_SYSCALL_ASM path=%s sha256=%s bytes=%s\n' "$syscall_asm" "$asm_sha" "$asm_bytes"
printf 'M3_SYSCALL_ABI_HEADER path=%s sha256=%s bytes=%s\n' "$syscall_abi_header" "$abi_header_sha" "$abi_header_bytes"
printf 'M3_SYSCALL_HEADER path=%s sha256=%s bytes=%s\n' "$syscall_header" "$header_sha" "$header_bytes"
printf 'M3_SYSCALL_MAKEFILE path=%s sha256=%s bytes=%s\n' "$syscall_makefile" "$makefile_sha" "$makefile_bytes"
while IFS= read -r line; do printf 'M3_SYSCALL_INCLUDE %s\n' "$line"; done < <(sed -n '/^#include/p' "$syscall_source")
while IFS= read -r line; do printf 'M3_SYSCALL_MAKEFILE_LINE %s\n' "$line"; done < "$syscall_makefile"

# Compile the exact source against the matching selftests/tool headers.  The
# binary is root-owned in a fresh 0755 directory, so UID 65534 cannot write
# or replace it while the timeout wrapper runs.
bin_dir=$(mktemp -d /opt/m3-syscall.XXXXXX)
chmod 755 "$bin_dir"
cc -D_GNU_SOURCE -O2 -Wall -Wextra \
    -I"$work" -I"$selftests" -I"$source_root/tools/include" \
    -o "$bin_dir/syscall-abi" "$work/arm64/abi/syscall-abi.c" "$work/arm64/abi/syscall-abi-asm.S" \
    >"$work/compile.stdout" 2>"$work/compile.stderr" || {
        sed -n '1,60p' "$work/compile.stderr"
        fail compile
    }
chmod 755 "$bin_dir/syscall-abi"
[ "$(stat -c '%u:%g:%a' "$bin_dir/syscall-abi")" = '0:0:755' ] || fail binary-contract
sha256sum "$bin_dir/syscall-abi"

setpriv_bin=$(command -v setpriv) || fail setpriv-missing
id_contract=$("$setpriv_bin" --reuid 65534 --regid 65534 --clear-groups --no-new-privs id) || fail privilege-contract
case "$id_contract" in *uid=65534*gid=65534*) ;; *) fail privilege-contract;; esac
printf 'M3_SYSCALL_PRIVILEGE command=setpriv --reuid 65534 --regid 65534 --clear-groups --no-new-privs id\n'
printf 'M3_SYSCALL_PRIVILEGE_RESULT %s\n' "$id_contract"

boot=$(cat /proc/sys/kernel/random/boot_id)
identity="pid=$$ boot=$boot cpus=$cpus"
ulimit -c 0
printf '\nM3_SELFTEST_READY token=%s %s\n' "$token" "$identity"
IFS= read -r command
[ "$command" = "GO $token" ] || fail go
printf 'M3_SELFTEST_BEGIN token=%s cpu=0 test=syscall-abi\n' "$token"

status=0
timeout --signal=TERM --kill-after=2 30 \
    "$setpriv_bin" --reuid 65534 --regid 65534 --clear-groups --no-new-privs \
    taskset -c 0 "$bin_dir/syscall-abi" || status=$?
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
umount /mnt/syscall-abi-build
trap - EXIT
sync
exec /sbin/poweroff

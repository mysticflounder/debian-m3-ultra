#!/bin/bash
# Guest-side bounded arm64 ptrace ABI smoke test.
# The source is compiled unmodified, then run only as nobody with no_new_privs.
set -euo pipefail
export LC_ALL=C

fail() {
    printf '\nM3_PTRACE_FAIL reason=%s\n' "$1"
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

mkdir -p /mnt/ptrace-abi-build
mount -o ro,noload /dev/vdb /mnt/ptrace-abi-build
trap 'rc=$?; set +e; umount /mnt/ptrace-abi-build 2>/dev/null || true; [ "$rc" -eq 0 ] || printf "M3_PTRACE_FAIL reason=command-failed\n"; exit "$rc"' EXIT
[ "$(blockdev --getro /dev/vdb)" = 1 ] || fail source-not-readonly
findmnt -n -o OPTIONS /mnt/ptrace-abi-build | grep -qw ro || fail mount-not-readonly

sources=()
for candidate in /mnt/ptrace-abi-build/linux-asahi-*; do
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
ptrace_source="$selftests/arm64/abi/ptrace.c"
ptrace_makefile="$selftests/arm64/abi/Makefile"
ptrace_header="$selftests/kselftest.h"
[ -f "$ptrace_source" ] && [ ! -L "$ptrace_source" ] || fail ptrace-source
[ -f "$ptrace_makefile" ] && [ ! -L "$ptrace_makefile" ] || fail ptrace-makefile
[ -f "$ptrace_header" ] && [ ! -L "$ptrace_header" ] || fail kselftest-header

work=$(mktemp -d /root/m3-ptrace-abi.XXXXXX)
chmod 700 "$work"
mkdir -p "$work/arm64/abi"
cp "$ptrace_source" "$work/arm64/abi/ptrace.c"
cp "$ptrace_header" "$work/kselftest.h"

source_bytes=$(stat -c '%s' "$ptrace_source") || fail source-stat
header_bytes=$(stat -c '%s' "$ptrace_header") || fail header-stat
makefile_bytes=$(stat -c '%s' "$ptrace_makefile") || fail makefile-stat
source_sha=$(sha256sum "$ptrace_source" | awk '{print $1}') || fail source-hash
header_sha=$(sha256sum "$ptrace_header" | awk '{print $1}') || fail header-hash
makefile_sha=$(sha256sum "$ptrace_makefile" | awk '{print $1}') || fail makefile-hash
[ "$source_sha" = c20dc561b5858671a58a909555edf47265de2b6d197420ef01ded1114ed3f575 ] || fail source-hash-pin
[ "$header_sha" = b01a128468643494316bb8f998c80a1aacd4e686c5f13446c16e09928cf9355c ] || fail header-hash-pin
printf '\nM3_PTRACE_SOURCE path=%s sha256=%s bytes=%s\n' "$ptrace_source" "$source_sha" "$source_bytes"
printf 'M3_PTRACE_HEADER path=%s sha256=%s bytes=%s\n' "$ptrace_header" "$header_sha" "$header_bytes"
printf 'M3_PTRACE_MAKEFILE path=%s sha256=%s bytes=%s\n' "$ptrace_makefile" "$makefile_sha" "$makefile_bytes"
while IFS= read -r line; do printf 'M3_PTRACE_INCLUDE %s\n' "$line"; done < <(sed -n '/^#include/p' "$ptrace_source")
while IFS= read -r line; do printf 'M3_PTRACE_MAKEFILE_LINE %s\n' "$line"; done < "$ptrace_makefile"

# Compile the exact source against the matching selftests/tool headers.  The
# binary is root-owned in a fresh 0755 directory, so UID 65534 cannot write
# or replace it while the timeout wrapper runs.
bin_dir=$(mktemp -d /opt/m3-ptrace.XXXXXX)
chmod 755 "$bin_dir"
cc -D_GNU_SOURCE -O2 -Wall -Wextra \
    -I"$work" -I"$selftests" -I"$source_root/tools/include" \
    -o "$bin_dir/ptrace" "$work/arm64/abi/ptrace.c" \
    >"$work/compile.stdout" 2>"$work/compile.stderr" || {
        sed -n '1,60p' "$work/compile.stderr"
        fail compile
    }
chmod 755 "$bin_dir/ptrace"
[ "$(stat -c '%u:%g:%a' "$bin_dir/ptrace")" = '0:0:755' ] || fail binary-contract
sha256sum "$bin_dir/ptrace"

setpriv_bin=$(command -v setpriv) || fail setpriv-missing
id_contract=$("$setpriv_bin" --reuid 65534 --regid 65534 --clear-groups --no-new-privs id) || fail privilege-contract
case "$id_contract" in *uid=65534*gid=65534*) ;; *) fail privilege-contract;; esac
printf 'M3_PTRACE_PRIVILEGE command=setpriv --reuid 65534 --regid 65534 --clear-groups --no-new-privs id\n'
printf 'M3_PTRACE_PRIVILEGE_RESULT %s\n' "$id_contract"

boot=$(cat /proc/sys/kernel/random/boot_id)
identity="pid=$$ boot=$boot cpus=$cpus"
ulimit -c 0
printf '\nM3_SELFTEST_READY token=%s %s\n' "$token" "$identity"
IFS= read -r command
[ "$command" = "GO $token" ] || fail go
printf 'M3_SELFTEST_BEGIN token=%s cpu=0 test=ptrace\n' "$token"

status=0
timeout --signal=TERM --kill-after=2 30 \
    "$setpriv_bin" --reuid 65534 --regid 65534 --clear-groups --no-new-privs \
    taskset -c 0 "$bin_dir/ptrace" || status=$?
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
umount /mnt/ptrace-abi-build
trap - EXIT
sync
exec /sbin/poweroff

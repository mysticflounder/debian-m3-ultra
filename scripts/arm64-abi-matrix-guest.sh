#!/bin/bash
# Guest half of the bounded multi-vCPU arm64 ABI matrix.
# Exact matching sources are compiled once, then each selected CPU runs both
# ABI tests as UID 65534 with no new privileges.
set -euo pipefail
export LC_ALL=C
unset KSFT_TAP_LEVEL

fail() { printf '\nM3_ABI_MATRIX_FAIL reason=%s\n' "$*" >&2; exit 1; }
[ "$#" = 2 ] || fail arguments
cpus=$1
token=$2
case "$cpus" in 1|8|16|24|32) ;; *) fail cpu-count;; esac
[[ "$token" =~ ^[A-Za-z0-9-]{1,160}$ ]] || fail token
[ "$(uname -m)" = aarch64 ] || fail architecture
online=$(getconf _NPROCESSORS_ONLN) || fail online-cpus
[ "$online" -eq "$cpus" ] || fail online-cpus
expected_online=0
[ "$cpus" -eq 1 ] || expected_online="0-$((cpus - 1))"
[ "$(cat /sys/devices/system/cpu/online)" = "$expected_online" ] || fail online-map

mkdir -p /mnt/abi-matrix-build
mount -o ro,noload /dev/vdb /mnt/abi-matrix-build
trap 'rc=$?; set +e; umount /mnt/abi-matrix-build 2>/dev/null || true; [ "$rc" -eq 0 ] || printf "M3_ABI_MATRIX_FAIL reason=command-failed\n"; exit "$rc"' EXIT
[ "$(blockdev --getro /dev/vdb)" = 1 ] || fail source-not-readonly
findmnt -n -o OPTIONS /mnt/abi-matrix-build | grep -qw ro || fail mount-not-readonly

sources=()
for candidate in /mnt/abi-matrix-build/linux-asahi-*; do
    [ ! -L "$candidate" ] && [ -d "$candidate" ] && sources+=("$candidate")
done
[ "${#sources[@]}" = 1 ] || fail source-tree
source_tree=${sources[0]}
[ "$(basename "$source_tree")" = linux-asahi-7.1.10-1 ] || fail source-version
source_root=$source_tree
[ ! -d "$source_root/debian/build/source_none" ] || source_root="$source_root/debian/build/source_none"
selftests="$source_root/tools/testing/selftests"
abi="$selftests/arm64/abi"
ptrace_source="$abi/ptrace.c"
syscall_source="$abi/syscall-abi.c"
syscall_asm="$abi/syscall-abi-asm.S"
syscall_header="$abi/syscall-abi.h"
kselftest_header="$selftests/kselftest.h"
for file in "$ptrace_source" "$syscall_source" "$syscall_asm" "$syscall_header" "$kselftest_header"; do
    [ -f "$file" ] && [ ! -L "$file" ] || fail source-file
done

sha256sum "$ptrace_source" | awk '$1 == "c20dc561b5858671a58a909555edf47265de2b6d197420ef01ded1114ed3f575" {ok=1} END {exit !ok}' || fail ptrace-source-hash
sha256sum "$syscall_source" | awk '$1 == "5b2bb4c98064b0263860cda635340c68a4169a2882698101629f94a79b1de5af" {ok=1} END {exit !ok}' || fail syscall-source-hash
sha256sum "$syscall_asm" | awk '$1 == "9c7e954f4273960af9043380ef1087d286238810658d36209bfb5178adde6a93" {ok=1} END {exit !ok}' || fail syscall-asm-hash
sha256sum "$syscall_header" | awk '$1 == "3459f9a4735b082e1716aa19741750d24faaa37b56abf17450c9170524efe423" {ok=1} END {exit !ok}' || fail syscall-abi-header-hash
sha256sum "$kselftest_header" | awk '$1 == "b01a128468643494316bb8f998c80a1aacd4e686c5f13446c16e09928cf9355c" {ok=1} END {exit !ok}' || fail kselftest-header-hash
printf 'M3_ABI_MATRIX_SOURCE name=ptrace.c sha256=%s bytes=%s\n' "$(sha256sum "$ptrace_source" | awk '{print $1}')" "$(stat -c '%s' "$ptrace_source")"
printf 'M3_ABI_MATRIX_SOURCE name=syscall-abi.c sha256=%s bytes=%s\n' "$(sha256sum "$syscall_source" | awk '{print $1}')" "$(stat -c '%s' "$syscall_source")"
printf 'M3_ABI_MATRIX_SOURCE name=syscall-abi-asm.S sha256=%s bytes=%s\n' "$(sha256sum "$syscall_asm" | awk '{print $1}')" "$(stat -c '%s' "$syscall_asm")"
printf 'M3_ABI_MATRIX_SOURCE name=syscall-abi.h sha256=%s bytes=%s\n' "$(sha256sum "$syscall_header" | awk '{print $1}')" "$(stat -c '%s' "$syscall_header")"
printf 'M3_ABI_MATRIX_SOURCE name=kselftest.h sha256=%s bytes=%s\n' "$(sha256sum "$kselftest_header" | awk '{print $1}')" "$(stat -c '%s' "$kselftest_header")"

work=$(mktemp -d /root/m3-abi-matrix.XXXXXX); chmod 700 "$work"
mkdir -p "$work/arm64/abi"
cp "$ptrace_source" "$work/arm64/abi/ptrace.c"
cp "$syscall_source" "$work/arm64/abi/syscall-abi.c"
cp "$syscall_asm" "$work/arm64/abi/syscall-abi-asm.S"
cp "$syscall_header" "$work/arm64/abi/syscall-abi.h"
cp "$kselftest_header" "$work/kselftest.h"

bin_dir=$(mktemp -d /opt/m3-abi-matrix.XXXXXX); chmod 755 "$bin_dir"
cc -D_GNU_SOURCE -O2 -Wall -Wextra -I"$work" -I"$selftests" -I"$source_root/tools/include" \
    -o "$bin_dir/ptrace" "$work/arm64/abi/ptrace.c" >"$work/ptrace.stdout" 2>"$work/ptrace.stderr" || { sed -n '1,60p' "$work/ptrace.stderr"; fail ptrace-compile; }
cc -D_GNU_SOURCE -O2 -Wall -Wextra -I"$work" -I"$selftests" -I"$source_root/tools/include" \
    -o "$bin_dir/syscall-abi" "$work/arm64/abi/syscall-abi.c" "$work/arm64/abi/syscall-abi-asm.S" >"$work/syscall.stdout" 2>"$work/syscall.stderr" || { sed -n '1,60p' "$work/syscall.stderr"; fail syscall-compile; }
chmod 755 "$bin_dir/ptrace" "$bin_dir/syscall-abi"
[ "$(stat -c '%u:%g:%a' "$bin_dir/ptrace")" = 0:0:755 ] || fail ptrace-binary-contract
[ "$(stat -c '%u:%g:%a' "$bin_dir/syscall-abi")" = 0:0:755 ] || fail syscall-binary-contract
sha256sum "$bin_dir/ptrace" "$bin_dir/syscall-abi"

setpriv_bin=$(command -v setpriv) || fail setpriv-missing
id_contract=$("$setpriv_bin" --reuid 65534 --regid 65534 --clear-groups --no-new-privs id) || fail privilege-contract
case "$id_contract" in *uid=65534*gid=65534*) ;; *) fail privilege-contract;; esac
printf '\nM3_ABI_MATRIX_PRIVILEGE_RESULT %s\n' "$id_contract"
boot=$(cat /proc/sys/kernel/random/boot_id)
identity="pid=$$ boot=$boot cpus=$cpus"
ulimit -c 0
printf '\nM3_SELFTEST_READY token=%s %s\n' "$token" "$identity"
IFS= read -r command
[ "$command" = "GO $token" ] || fail go

run_one() {
    local cpu=$1 name=$2 binary=$3 status=0
    printf 'M3_SELFTEST_BEGIN token=%s cpu=%s test=%s\n' "$token" "$cpu" "$name"
    timeout --signal=TERM --kill-after=2 30 \
        "$setpriv_bin" --reuid 65534 --regid 65534 --clear-groups --no-new-privs \
        taskset -c "$cpu" "$binary" || status=$?
    printf 'M3_SELFTEST_END token=%s cpu=%s test=%s status=%s\n' "$token" "$cpu" "$name" "$status"
    [ "$status" = 0 ] || fail "$name-cpu-$cpu-exit-$status"
}

for ((cpu=0; cpu<cpus; cpu++)); do
    run_one "$cpu" ptrace "$bin_dir/ptrace"
    run_one "$cpu" syscall-abi "$bin_dir/syscall-abi"
done
printf 'M3_SELFTEST_DONE token=%s cpus=%s\n' "$token" "$cpus"
IFS= read -r command
[[ "$command" =~ ^VERIFY\ [0-9a-f]{48}$ ]] || fail verify
nonce=${command#VERIFY }
[ "$(cat /proc/sys/kernel/random/boot_id)" = "$boot" ] || fail boot-changed
printf 'M3_SELFTEST_PASS nonce=%s %s\n' "$nonce" "$identity"
IFS= read -r command
[ "$command" = POWEROFF ] || fail poweroff
umount /mnt/abi-matrix-build
trap - EXIT
sync
exec /sbin/poweroff

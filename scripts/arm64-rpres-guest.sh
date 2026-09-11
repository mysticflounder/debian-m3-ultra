#!/bin/bash
# Build and run the standalone arm64 RPRES probe in the disposable guest.
set -euo pipefail
[ "$#" = 2 ] || exit 2

fail() {
    rc=1
    trap - EXIT
    echo "M3_RPRES_GUEST_ERROR reason=$1 rc=$rc"
    sync || true
    echo "M3_RPRES_CLEAN_SHUTDOWN_REQUESTED failure=true"
    systemctl poweroff || true
    sleep 300
    exit "$rc"
}

cpus=$1
token=$2
[ "$cpus" = 1 ] || fail cpus
case "$token" in ''|*[!a-zA-Z0-9-]*) fail token;; esac
[ "$(uname -m)" = aarch64 ] || fail architecture
[ "$(getconf _NPROCESSORS_ONLN)" = 1 ] || fail online-cpus
[ "$(cat /sys/devices/system/cpu/online)" = 0 ] || fail online-map
[ -f /root/m3-rpres-probe.c ] && [ ! -L /root/m3-rpres-probe.c ] || fail source-missing

work=$(mktemp -d /var/tmp/m3-rpres.XXXXXX)
chmod 755 "$work"
# Files disappear with the disposable overlay; no recursive guest deletion.
trap 'rc=$?; trap - EXIT; [ "$rc" -eq 0 ] || printf "M3_RPRES_GUEST_ERROR reason=command-failed rc=%s\n" "$rc"; exit "$rc"' EXIT

source_sha=$(sha256sum /root/m3-rpres-probe.c | awk '{print $1}') || fail source-hash
source_bytes=$(stat -c '%s' /root/m3-rpres-probe.c) || fail source-stat
cc -std=c11 -O2 -Wall -Wextra -Werror /root/m3-rpres-probe.c -o "$work/rpres-probe" \
    >"$work/compile.stdout" 2>"$work/compile.stderr" || {
    sed -n '1,80p' "$work/compile.stderr"
    fail compile
}
chmod 755 "$work/rpres-probe"
binary_sha=$(sha256sum "$work/rpres-probe" | awk '{print $1}') || fail binary-hash
printf '\nM3_RPRES_SOURCE sha256=%s bytes=%s\n' "$source_sha" "$source_bytes"
printf 'M3_RPRES_BINARY sha256=%s\n' "$binary_sha"

boot=$(cat /proc/sys/kernel/random/boot_id)
identity="pid=$$ boot=$boot cpus=$cpus"
ulimit -c 0
printf '\nM3_RPRES_READY token=%s %s\n' "$token" "$identity"
IFS= read -r command
[ "$command" = "GO $token" ] || fail go
printf 'M3_RPRES_BEGIN token=%s cpu=0\n' "$token"

status=0
timeout --signal=TERM --kill-after=2 30 \
    setpriv --reuid 65534 --regid 65534 --clear-groups --no-new-privs \
    "$work/rpres-probe" >"$work/probe.json" || status=$?
[ "$status" = 0 ] || fail probe-exit
[ "$(wc -l < "$work/probe.json" | tr -d ' ')" = 1 ] || fail probe-lines
printf 'M3_RPRES_END token=%s cpu=0 status=0\n' "$token"
printf 'M3_RPRES_JSON_BEGIN token=%s\n' "$token"
cat "$work/probe.json"
printf 'M3_RPRES_JSON_END token=%s\n' "$token"

IFS= read -r command
[[ "$command" =~ ^VERIFY\ [0-9a-f]{48}$ ]] || fail verify
nonce=${command#VERIFY }
[ "$(cat /proc/sys/kernel/random/boot_id)" = "$boot" ] || fail boot-changed
printf 'M3_RPRES_PASS nonce=%s %s\n' "$nonce" "$identity"
IFS= read -r command
[ "$command" = POWEROFF ] || fail poweroff
sync
exec /sbin/poweroff

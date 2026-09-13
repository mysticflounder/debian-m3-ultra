#!/bin/bash
# One disposable current-fork guest; PROBE_KIND=rpres (default) or cssc.
# Reuse the audited reboot lifecycle helpers.
set -euo pipefail
umask 077
PROBE_KIND="${PROBE_KIND:-rpres}"
case "$PROBE_KIND" in rpres|cssc) ;; *) echo 'invalid PROBE_KIND' >&2; exit 2;; esac
RPRES_HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
REUSE="$RPRES_HERE/scripts/reboot-vm.sh"
[ ! -L "$RPRES_HERE/out" ] || exit 1
mkdir -p "$RPRES_HERE/out"
RPRES_RUN="$(mktemp -d "$RPRES_HERE/out/rpres-vm.XXXXXX")"
DEFS="$RPRES_RUN/reboot-definitions.sh"
[ -f "$REUSE" ] && [ ! -L "$REUSE" ] || exit 1
reuse_hash="$(shasum -a 256 "$REUSE")"
[ "$(awk '$0 == "# Main program." {n++} END {print n+0}' "$REUSE")" = 1 ] || exit 1
awk '$0 == "# Main program." {exit} {print}' "$REUSE" > "$DEFS"
[ "$(shasum -a 256 "$REUSE")" = "$reuse_hash" ] || exit 1
QEMU="$RPRES_HERE/out/qemu-fork-pmintenclr-build/qemu-system-aarch64"
MEM=2G
SMP_LIST=1
LAUNCH_TIMEOUT=240
source "$DEFS"
RUN_DIR="$RPRES_RUN"
printf 'RPRES run: %s\n' "$RUN_DIR"
COUNT_DIR="$RUN_DIR"
HARNESS="$HERE/scripts/rpres-probe-vm.sh"
GUEST="$HERE/scripts/arm64-rpres-guest.sh"
SOURCE="$HERE/scripts/arm64-rpres-probe.c"
VALIDATOR="$HERE/scripts/validate-rpres-probe.jq"
if [ "$PROBE_KIND" = cssc ]; then
    SOURCE="$HERE/scripts/arm64-cssc-probe.c"
    VALIDATOR="$HERE/scripts/validate-cssc-probe.jq"
fi
CONTROL_STEPS=2400
OPENSSL=/usr/bin/openssl
sha256_file() {
    local output digest remainder
    output="$("$OPENSSL" dgst -sha256 -r "$1")" || return 1
    IFS=' ' read -r digest remainder <<< "$output"
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$digest"
}
wait_prefix() {
    local prefix=$1 step
    for ((step=0; step<CONTROL_STEPS; step++)); do
        if /usr/bin/grep -q '^M3_RPRES_GUEST_ERROR' "$SERIAL_LOG"; then fail guest-error; fi
        RPRES_LINE="$(tr -d '\r' < "$SERIAL_LOG" | /usr/bin/grep -F "$prefix" | /usr/bin/grep "^$prefix" || true)"
        if [ -n "$RPRES_LINE" ]; then
            case "$RPRES_LINE" in *$'\n'*) fail duplicate-marker;; esac
            wait_for_marker_count "$RPRES_LINE" 1 || fail marker
            return 0
        fi
        running_shell_job "$QPID" || fail guest-exited
        /bin/sleep 0.1
    done
    fail marker-timeout
}
[ "$#" = 0 ] && [ "$(id -u)" -ne 0 ] || fail arguments-or-host-root
for tool in "$QEMU" "$QEMU_IMG" "$TIMEOUT" "$NC" "$JQ" "$AWK" "$LSOF" "$OPENSSL"; do
    [ -x "$tool" ] && [ ! -u "$tool" ] && [ ! -g "$tool" ] || fail tool
done
validate_macos_system_ps "$PS" || fail ps
QEMU="$(realpath "$QEMU")"; QEMU_IMG="$(realpath "$QEMU_IMG")"
TIMEOUT="$(realpath "$TIMEOUT")"; NC="$(realpath "$NC")"
JQ="$(realpath "$JQ")"; AWK="$(realpath "$AWK")"
LSOF="$(realpath "$LSOF")"; OPENSSL="$(realpath "$OPENSSL")"
require_safe_input "$KVER_FILE"
KVER="$(cat "$KVER_FILE")"
case "$KVER" in ''|.|..|*/*|*[!A-Za-z0-9.+_~-]*) fail kernel-name;; esac
KERNEL="$OUT/Image-$KVER"; INITRD="$OUT/initrd.img-$KVER"
PROTECTED_NAMES=(kver kernel initrd rootfs harness guest source validator library definitions qemu qemu_img timeout nc jq awk lsof ps openssl)
PROTECTED_PATHS=("$KVER_FILE" "$KERNEL" "$INITRD" "$ROOTFS" "$HARNESS" "$GUEST" "$SOURCE" "$VALIDATOR" "$REUSE" "$DEFS" "$QEMU" "$QEMU_IMG" "$TIMEOUT" "$NC" "$JQ" "$AWK" "$LSOF" "$PS" "$OPENSSL")
for input in "${PROTECTED_PATHS[@]}"; do require_safe_input "$input"; done
mkdir "$LOCK_DIR" 2>/dev/null || fail lock
LOCK_ACQUIRED=true; LOCK_TOKEN="$$:$(date +%s):$RANDOM"; LOCK_OWNER="$LOCK_DIR/owner.$$"
printf '%s\n' "$LOCK_TOKEN" > "$LOCK_OWNER"
[ -z "$(lsof_openers "$ROOTFS")" ] || fail rootfs-open
BASELINE_SNAPSHOT="$(snapshot_protected)"; BASELINE_IDENTITIES="$(snapshot_identities)"
PROTECTED_WINDOW_STARTED=true; INPUTS_VERIFIED=true
printf '%s\n' "$BASELINE_SNAPSHOT" > "$RUN_DIR/protected-before.json"
[ "$(df -k "$RUN_DIR" | awk 'END {print $4}')" -ge 1048576 ] || fail disk-space
CURRENT_OVERLAY="$RUN_DIR/root.qcow2"; OVERLAY_PATHS+=("$CURRENT_OVERLAY")
"$QEMU_IMG" create -q -f qcow2 -F raw -b "$ROOTFS" "$CURRENT_OVERLAY"
"$QEMU_IMG" info --output=json "$CURRENT_OVERLAY" > "$RUN_DIR/overlay-info.json"
"$JQ" -e --arg root "$ROOTFS" '.format=="qcow2" and .["backing-filename"]==$root and .["backing-filename-format"]=="raw"' "$RUN_DIR/overlay-info.json" >/dev/null || fail overlay
SERIAL_FIFO="$RUN_DIR/serial.in"; SERIAL_LOG="$RUN_DIR/serial.raw.log"
QMP_FIFO="$RUN_DIR/qmp.in"; QMP_SOCKET="$RUN_DIR/qmp.sock"
QMP_LOG="$RUN_DIR/qmp.events.jsonl"; QMP_ERROR="$RUN_DIR/qmp.stderr.log"; QEMU_PID_FILE="$RUN_DIR/qemu.pid"
mkfifo -m 600 "$SERIAL_FIFO" "$QMP_FIFO"
: > "$SERIAL_LOG"; : > "$QMP_LOG"; : > "$QMP_ERROR"; : > "$QEMU_PID_FILE"
exec 8<> "$SERIAL_FIFO"; exec 9<> "$QMP_FIFO"
ARGS=(-M virt,highmem=on -accel hvf,kernel-irqchip=on -cpu host -smp 1,sockets=1,cores=1,threads=1 -m 2G
    -kernel "$KERNEL" -initrd "$INITRD"
    -append 'root=/dev/vda rootfstype=ext4 rw console=ttyAMA0 systemd.unit=multi-user.target systemd.mask=m3-build.service'
    -drive "if=virtio,file=$CURRENT_OVERLAY,format=qcow2,cache=none"
    -drive "if=virtio,file=fat:ro:$HERE/scripts,format=raw,readonly=on"
    -nic none -display none -monitor none -serial stdio -qmp "unix:$QMP_SOCKET,server=on,wait=off" -nodefaults)
"$JQ" -n --args '$ARGS.positional' -- "$QEMU" "${ARGS[@]}" > "$RUN_DIR/qemu-argv.json"
verify_protected || fail protected-before-launch
INPUTS_VERIFIED=false
ulimit -f 262144
/usr/bin/env -i PATH="$PATH" LC_ALL=C TMPDIR="$RUN_DIR" "$TIMEOUT" --foreground --signal=TERM --kill-after=10 "$LAUNCH_TIMEOUT" /bin/sh -c 'printf "%s\n" "$$" > "$1" || exit 125; shift; exec "$@"' rpres-qemu "$QEMU_PID_FILE" "$QEMU" "${ARGS[@]}" <&8 > "$SERIAL_LOG" 2>&1 &
QPID=$!; QEMU_LAUNCH_ATTEMPTED=true
for ((step=0; step<100; step++)); do [ -s "$QEMU_PID_FILE" ] && break; running_shell_job "$QPID" || break; sleep 0.05; done
require_safe_input "$QEMU_PID_FILE"; IFS= read -r QEMU_CHILD_PID < "$QEMU_PID_FILE"
capture_independent_qemu_identity || fail qemu-identity
for ((step=0; step<100; step++)); do [ -S "$QMP_SOCKET" ] && break; running_shell_job "$QPID" || break; sleep 0.05; done
[ -S "$QMP_SOCKET" ] && [ ! -L "$QMP_SOCKET" ] || fail socket
chmod 600 "$QMP_SOCKET"
[ "$(stat -f '%u:%Lp' "$QMP_SOCKET")" = "$(id -u):600" ] || fail qmp-privacy
socket_before="$(socket_identity "$QMP_SOCKET")"
"$NC" -U "$QMP_SOCKET" < "$QMP_FIFO" 8>&- 9>&- > "$QMP_LOG" 2> "$QMP_ERROR" & QMP_PID=$!
wait_for_qmp_greeting; qmp_send qmp_capabilities capabilities; wait_for_qmp_response capabilities
wait_for_marker_count "$AUTOLOGIN_MARKER" 1
token="rpres-$$-$RANDOM"
printf "stty -echo; mkdir -p /mnt/rpres-source; mount -o ro /dev/vdb1 /mnt/rpres-source && test \"\$(blockdev --getro /dev/vdb)\" = 1 && cp /mnt/rpres-source/%s /root/m3-rpres-probe.c && bash /mnt/rpres-source/arm64-rpres-guest.sh 1 %s\n" "${SOURCE##*/}" "$token" >&8
wait_prefix "M3_RPRES_READY token=$token "
ready="$RPRES_LINE"
printf 'GO %s\n' "$token" >&8
wait_prefix "M3_RPRES_JSON_END token=$token"
nonce="$("$OPENSSL" rand -hex 24)"
printf 'VERIFY %s\n' "$nonce" >&8
wait_prefix "M3_RPRES_PASS nonce=$nonce "
[ "${ready#M3_RPRES_READY token=$token }" = "${RPRES_LINE#M3_RPRES_PASS nonce=$nonce }" ] || fail guest-identity
qmp_send query-status post-probe; wait_for_qmp_response post-probe
qmp_running_response post-probe || fail not-running
assess_captured_qemu || fail process-changed
[ "$(socket_identity "$QMP_SOCKET")" = "$socket_before" ] || fail socket-changed
printf 'POWEROFF\n' >&8
status=0; wait "$QPID" || status=$?
[ "$status" = 0 ] || fail shutdown-status
qmp_guest_shutdown_event || fail unclean-shutdown
"$AWK" -v begin="M3_RPRES_JSON_BEGIN token=$token" -v end="M3_RPRES_JSON_END token=$token" '
    {sub(/\r$/, "")}
    $0==begin {b++; inside=1; next}
    $0==end {e++; inside=0; next}
    inside {print; rows++}
    END {if(b!=1 || e!=1 || rows!=1 || inside) exit 1}' "$SERIAL_LOG" > "$RUN_DIR/guest.json"
"$JQ" -e -s 'length==1' "$RUN_DIR/guest.json" >/dev/null
"$JQ" -e -f "$VALIDATOR" "$RUN_DIR/guest.json" >/dev/null
wait_prefix "M3_RPRES_SOURCE sha256="
[ "$RPRES_LINE" = "M3_RPRES_SOURCE sha256=$(sha256_file "$SOURCE") bytes=$(stat -f '%z' "$SOURCE")" ] || fail guest-source
verify_protected || fail protected-after
snapshot_protected > "$RUN_DIR/protected-after.json"
cmp "$RUN_DIR/protected-before.json" "$RUN_DIR/protected-after.json" || fail protected-content
INPUTS_VERIFIED=true
cleanup 0 || fail cleanup
trap - EXIT INT TERM HUP
"$JQ" -n --arg kind "$PROBE_KIND" --arg run "$RUN_DIR" --arg qemu_sha "$(sha256_file "$QEMU")" --arg collected "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{schema_version:1,probe_kind:$kind,run_directory:$run,collected_at:$collected,qemu_sha256:$qemu_sha,guest_capture:"guest.json",clean_guest_shutdown:true,protected_inputs_unchanged:true,overlay_removed:true}' > "$RUN_DIR/manifest.json"
echo "RPRES manifest: $RUN_DIR/manifest.json"

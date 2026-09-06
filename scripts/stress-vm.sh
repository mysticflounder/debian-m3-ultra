#!/bin/bash
# Bounded SMP/memory correctness stress using disposable guest overlays.
set -euo pipefail
umask 077
STRESS_HERE="$(cd "$(/usr/bin/dirname "$0")/.." && pwd -P)"
STRESS_REUSE="$STRESS_HERE/scripts/reboot-vm.sh"
STRESS_DEFS_DIR=""
STRESS_DEFS=""

# Bash 3.2 has no reliable source /dev/fd: retain and validate the helper
# scaffold as a private regular file before sourcing it.
[ -f "$STRESS_REUSE" ] && [ ! -L "$STRESS_REUSE" ] || exit 1
[ ! -L "$STRESS_HERE/out" ] || exit 1
/bin/mkdir -p "$STRESS_HERE/out"
[ "$(cd "$STRESS_HERE/out" && pwd -P)" = "$STRESS_HERE/out" ] || exit 1
STRESS_DEFS_DIR="$(/usr/bin/mktemp -d "$STRESS_HERE/out/stress-matrix.XXXXXX")"
STRESS_DEFS="$STRESS_DEFS_DIR/reboot-definitions.sh"
STRESS_REUSE_HASH="$(/usr/bin/shasum -a 256 "$STRESS_REUSE")"
[ "$(/usr/bin/awk '$0 == "# Main program." {n++} END {print n+0}' "$STRESS_REUSE")" = 1 ] || exit 1
/usr/bin/awk '$0 == "# Main program." {exit} {print}' "$STRESS_REUSE" > "$STRESS_DEFS"
[ -f "$STRESS_DEFS" ] && [ ! -L "$STRESS_DEFS" ] && [ -s "$STRESS_DEFS" ] || exit 1
[ "$(/usr/bin/shasum -a 256 "$STRESS_REUSE")" = "$STRESS_REUSE_HASH" ] || exit 1
QEMU="${QEMU:-$STRESS_HERE/out/qemu-fork-pmintenclr-build/qemu-system-aarch64}"
MEM="${MEM:-2G}"
source "$STRESS_DEFS"
RUN_DIR="$STRESS_DEFS_DIR"
HARNESS="$STRESS_HERE/scripts/stress-vm.sh"

fail() { echo "stress probe: $*" >&2; exit 1; }

stress_complete_lines() {
    local prefix=$1 line
    while IFS= read -r line; do
        line="${line%$'\r'}"
        case "$line" in "$prefix"*) printf '%s\n' "$line";; esac
    done < "$2"
}

stress_wait_serial_prefix() {
    local prefix=$1 step line
    for ((step=0; step<CONTROL_STEPS; step++)); do
        if /usr/bin/grep -q '^M3_STRESS_FAIL ' "$SERIAL_LOG"; then
            fail "guest stress witness failed; see $SERIAL_LOG"
        fi
        line="$(stress_complete_lines "$prefix" "$SERIAL_LOG")"
        if [ -n "$line" ]; then
            case "$line" in *$'\n'*) fail "duplicate guest marker: $prefix";; esac
            wait_for_marker_count "$line" 1 || fail "invalid guest marker: $prefix"
            STRESS_LINE="$line"
            return 0
        fi
        running_shell_job "$QPID" || fail "QEMU exited before $prefix"
        /bin/sleep 0.1
    done
    fail "timeout waiting for $prefix"
}

stress_qmp() {
    qmp_send "$1" "$2"
    wait_for_qmp_response "$2" || fail "QMP request failed: $2"
}

stress_validate_ready() {
    local line=$1 token=$2 smp=$3 pattern
    pattern="^M3_STRESS_READY token=$token pid=[1-9][0-9]* boot=[0-9a-f-]+ cpus=$smp bytes_per_cpu=16777216 passes=8$"
    [[ "$line" =~ $pattern ]]
}

stress_validate_cpu() {
    [ "$1" = "M3_STRESS_CPU token=$2 cpu=$3 passes=8 bytes=16777216" ]
}

stress_validate_done() {
    [ "$1" = "M3_STRESS_DONE token=$2 cpus=$3 passes=8 memory_bytes=$(($3*16777216)) atomic_count=$(($3*8*10000))" ]
}

stress_validate_pass() {
    [ "$2" = "M3_STRESS_PASS nonce=$3 pid=${1#* pid=}" ]
}

stress_run_count() {
    local smp=$1 token nonce info ready pass done_line cpu step socket_before final_snapshot status=0
    STRESS_SMP="$smp"
    COUNT_DIR="$RUN_DIR/smp-$smp"
    /bin/mkdir -m 700 "$COUNT_DIR"
    CURRENT_OVERLAY="$COUNT_DIR/root.qcow2"; OVERLAY_PATHS+=("$CURRENT_OVERLAY")
    SERIAL_FIFO="$COUNT_DIR/serial.in"; SERIAL_LOG="$COUNT_DIR/serial.raw.log"
    QMP_FIFO="$COUNT_DIR/qmp.in"; QMP_SOCKET="$COUNT_DIR/qmp.sock"
    QMP_LOG="$COUNT_DIR/qmp.events.jsonl"; QMP_ERROR="$COUNT_DIR/qmp.stderr.log"
    QEMU_PID_FILE="$COUNT_DIR/qemu.pid"
    CAPTURED_QEMU_PID=""; CAPTURED_QEMU_START=""; CAPTURED_QEMU_COMMAND=""
    CAPTURED_QEMU_UID=""; CAPTURED_PID_FILE_IDENTITY=""; CAPTURE_STATE=uncaptured
    QEMU_CHILD_SAFELY_GONE=false; QEMU_LAUNCH_ATTEMPTED=false; INPUTS_VERIFIED=false
    verify_protected || fail "protected inputs changed before overlay"
    [ "$(/bin/df -k "$COUNT_DIR" | "$AWK" 'END {print $4}')" -ge 1048576 ] || fail "need 1GiB free"
    "$QEMU_IMG" create -q -f qcow2 -F raw -b "$ROOTFS" "$CURRENT_OVERLAY"
    /bin/chmod 600 "$CURRENT_OVERLAY"
    info="$("$QEMU_IMG" info --output=json "$CURRENT_OVERLAY")"
    "$JQ" -e --arg root "$ROOTFS" '.format == "qcow2" and .["backing-filename"] == $root and .["backing-filename-format"] == "raw"' <<< "$info" >/dev/null || fail "overlay contract"
    /usr/bin/mkfifo -m 600 "$SERIAL_FIFO" "$QMP_FIFO"
    : > "$SERIAL_LOG"; : > "$QMP_LOG"; : > "$QMP_ERROR"; : > "$QEMU_PID_FILE"
    exec 8<> "$SERIAL_FIFO"; exec 9<> "$QMP_FIFO"
    ARGS=(-M virt,highmem=on -accel hvf,kernel-irqchip=on -cpu host
        -smp "$smp,sockets=1,cores=$smp,threads=1" -m 2G -kernel "$KERNEL" -initrd "$INITRD"
        -append 'root=/dev/vda rootfstype=ext4 rw console=ttyAMA0 systemd.unit=multi-user.target systemd.mask=m3-build.service'
        -drive "if=virtio,file=$CURRENT_OVERLAY,format=qcow2,cache=none" -nic none
        -display none -monitor none -serial stdio -qmp "unix:$QMP_SOCKET,server=on,wait=off" -nodefaults)
    "$JQ" -n --args '$ARGS.positional' -- "$QEMU" "${ARGS[@]}" > "$COUNT_DIR/qemu-argv.json"
    verify_protected || fail "protected inputs changed before launch"
    echo "stress probe: Asahi builder kernel $KVER, $smp vCPUs, 8 memory passes -> $COUNT_DIR"
    /usr/bin/env -i PATH="$PATH" LC_ALL=C TMPDIR="$COUNT_DIR" \
        "$TIMEOUT" --foreground --signal=TERM --kill-after=10 "$LAUNCH_TIMEOUT" \
        /bin/sh -c 'printf "%s\n" "$$" > "$1" || exit 125; shift; exec "$@"' \
        stress-qemu-launch "$QEMU_PID_FILE" "$QEMU" "${ARGS[@]}" <&8 > "$SERIAL_LOG" 2>&1 &
    QPID=$!; QEMU_LAUNCH_ATTEMPTED=true
    for ((step=0; step<100; step++)); do
        [ -s "$QEMU_PID_FILE" ] && break
        running_shell_job "$QPID" || break
        /bin/sleep 0.05
    done
    require_safe_input "$QEMU_PID_FILE"
    IFS= read -r QEMU_CHILD_PID < "$QEMU_PID_FILE" || fail "missing QEMU PID"
    capture_independent_qemu_identity || fail "cannot capture QEMU identity"
    for ((step=0; step<100; step++)); do
        [ -S "$QMP_SOCKET" ] && break
        running_shell_job "$QPID" || break
        /bin/sleep 0.05
    done
    [ -S "$QMP_SOCKET" ] && [ ! -L "$QMP_SOCKET" ] || fail "QMP socket missing"
    /bin/chmod 600 "$QMP_SOCKET"
    [ "$(/usr/bin/stat -f '%u:%Lp' "$QMP_SOCKET")" = "$(/usr/bin/id -u):600" ] || fail "QMP privacy"
    socket_before="$(socket_identity "$QMP_SOCKET")" || fail "QMP identity"
    "$NC" -U "$QMP_SOCKET" < "$QMP_FIFO" 8>&- 9>&- > "$QMP_LOG" 2> "$QMP_ERROR" & QMP_PID=$!
    wait_for_qmp_greeting || fail "QMP greeting"
    stress_qmp qmp_capabilities capabilities
    wait_for_marker_count "$AUTOLOGIN_MARKER" 1 || fail "serial autologin"
    # QEMU sets its stdio open-file description nonblocking. Reopen the host
    # writer independently so a larger source payload gets blocking writes.
    # No ancillary child holds a serial reader; VM timeout still ends writes.
    exec 8> "$SERIAL_FIFO"
    token="m3-stress-$smp-$$-$(/bin/date +%s)-$RANDOM"
    printf 'stty -echo\n' >&8
    printf "cat > /root/m3-smp-stress.c <<'M3_STRESS_C_EOF'\n" >&8
    /bin/cat "$STRESS_SOURCE" >&8
    printf '\nM3_STRESS_C_EOF\n' >&8
    printf 'cc -O2 -Wall -Wextra -Werror -std=c11 -pthread -o /root/m3-smp-stress /root/m3-smp-stress.c && /root/m3-smp-stress %s %s\n' "$smp" "$token" >&8
    stress_wait_serial_prefix "M3_STRESS_READY token=$token "
    ready="$STRESS_LINE"
    stress_validate_ready "$ready" "$token" "$smp" || fail "malformed READY"
    printf 'GO %s\n' "$token" >&8
    for ((cpu=0; cpu<smp; cpu++)); do
        stress_wait_serial_prefix "M3_STRESS_CPU token=$token cpu=$cpu "
        stress_validate_cpu "$STRESS_LINE" "$token" "$cpu" || fail "invalid CPU evidence $cpu"
    done
    stress_wait_serial_prefix "M3_STRESS_DONE token=$token "
    done_line="$STRESS_LINE"
    stress_validate_done "$done_line" "$token" "$smp" || fail "invalid DONE"
    nonce="$(/usr/bin/openssl rand -hex 24)"
    printf 'VERIFY %s\n' "$nonce" >&8
    stress_wait_serial_prefix "M3_STRESS_PASS nonce=$nonce "
    pass="$STRESS_LINE"
    stress_validate_pass "$ready" "$pass" "$nonce" || fail "guest identity changed"
    stress_qmp query-status verified-status
    qmp_running_response verified-status || fail "guest not running after stress"
    assess_captured_qemu || fail "QEMU process identity changed"
    [ "$(socket_identity "$QMP_SOCKET")" = "$socket_before" ] || fail "QMP socket identity changed"
    printf 'POWEROFF\n' >&8
    status=0; wait "$QPID" || status=$?
    [ "$status" -eq 0 ] || fail "QEMU shutdown status $status"
    "$JQ" -e -s 'any(.[]; .event? == "SHUTDOWN" and .data.guest == true and .data.reason == "guest-shutdown")' "$QMP_LOG" >/dev/null || fail "missing clean shutdown"
    terminate_owned_jobs || fail "QEMU cleanup"
    exec 8>&-; exec 9>&-
    remove_runtime_object "$SERIAL_FIFO" fifo || fail "serial FIFO cleanup"
    remove_runtime_object "$QMP_FIFO" fifo || fail "QMP FIFO cleanup"
    remove_runtime_object "$QMP_SOCKET" socket || fail "QMP socket cleanup"
    remove_runtime_object "$QEMU_PID_FILE" file || fail "PID file cleanup"
    SERIAL_FIFO=""; QMP_FIFO=""; QMP_SOCKET=""; QEMU_PID_FILE=""
    [ -z "$(lsof_openers "$CURRENT_OVERLAY")" ] || fail "overlay still open"
    remove_runtime_object "$CURRENT_OVERLAY" file || fail "overlay cleanup"
    final_snapshot="$(snapshot_protected)" || fail "final hashes"
    [ "$final_snapshot" = "$BASELINE_SNAPSHOT" ] || fail "protected inputs changed"
    INPUTS_VERIFIED=true
    "$JQ" -n --argjson smp "$smp" --arg token "$token" --arg ready "$ready" --arg pass "$pass" \
        --arg done "$done_line" --arg pid "$CAPTURED_QEMU_PID" --arg start "$CAPTURED_QEMU_START" \
        --arg socket "$socket_before" --argjson before "$BASELINE_SNAPSHOT" --argjson after "$final_snapshot" \
        '{smp:$smp,pass:true,sample_id:$token,
          guest:{ready:$ready,done:$done,pass:$pass,passes_per_cpu:8,memory_bytes:(16777216*$smp),atomic_count:(80000*$smp)},
          qemu:{pid:$pid,start:$start,same_process:true,same_qmp_socket:true,socket_identity:$socket},
          safety:{overlay_removed:true,protected_inputs_unchanged:true},
          protected_inputs:{before:$before,after:$after}}' > "$COUNT_DIR/evidence.json"
}

stress_main() {
    [ "$#" -eq 0 ] || fail "no command-line arguments accepted"
    [ "$(/usr/bin/id -u)" -ne 0 ] || fail "refusing host root"
    [ "$MEM" = 2G ] || fail "requires MEM=2G"
    case "$LAUNCH_TIMEOUT" in ''|*[!0-9]*|0*) fail "invalid LAUNCH_TIMEOUT";; esac
    [ "$LAUNCH_TIMEOUT" -ge 60 ] && [ "$LAUNCH_TIMEOUT" -le 420 ] || fail "timeout must be 60..420s"
    CONTROL_STEPS=$((LAUNCH_TIMEOUT * 10))
    case "$SMP_LIST" in *$'\n'*|*$'\r'*) fail "SMP_LIST must be one line";; esac
    read -r -a SMP_COUNTS <<< "$SMP_LIST"
    [ "${#SMP_COUNTS[@]}" -gt 0 ] || fail "empty SMP_LIST"
    local smp seen=' ' input tool
    for smp in "${SMP_COUNTS[@]}"; do
        case "$smp" in 1|8|16|24|32) ;; *) fail "SMP counts supported:1 8 16 24 32";; esac
        case "$seen" in *" $smp "*) fail "duplicate SMP count";; esac
        seen="$seen$smp "
    done
    STRESS_SOURCE="$STRESS_HERE/scripts/arm64-smp-stress.c"
    for tool in "$QEMU" "$QEMU_IMG" "$TIMEOUT" "$NC" "$JQ" "$AWK" "$LSOF"; do
        case "$tool" in /*) ;; *) fail "executable path must be absolute";; esac
        [ -x "$tool" ] && [ ! -u "$tool" ] && [ ! -g "$tool" ] || fail "unsafe/missing executable $tool"
    done
    validate_macos_system_ps "$PS" || fail "macOS ps safety contract"
    QEMU="$(/bin/realpath "$QEMU")"; QEMU_IMG="$(/bin/realpath "$QEMU_IMG")"
    TIMEOUT="$(/bin/realpath "$TIMEOUT")"; NC="$(/bin/realpath "$NC")"
    JQ="$(/bin/realpath "$JQ")"; AWK="$(/bin/realpath "$AWK")"; LSOF="$(/bin/realpath "$LSOF")"
    require_safe_input "$KVER_FILE"; KVER="$(/bin/cat "$KVER_FILE")"
    case "$KVER" in ''|*/*|*[!A-Za-z0-9.+_~-]*) fail "unsafe KVER";; esac
    case "$KVER" in *asahi*) ;; *) fail "requires Asahi builder kernel";; esac
    KERNEL="$OUT/Image-$KVER"; INITRD="$OUT/initrd.img-$KVER"
    PROTECTED_NAMES=(kver kernel initrd rootfs harness guest_source reboot_library extracted_library qemu qemu_img timeout nc jq awk lsof ps)
    PROTECTED_PATHS=("$KVER_FILE" "$KERNEL" "$INITRD" "$ROOTFS" "$HARNESS" "$STRESS_SOURCE" "$STRESS_REUSE" "$STRESS_DEFS" "$QEMU" "$QEMU_IMG" "$TIMEOUT" "$NC" "$JQ" "$AWK" "$LSOF" "$PS")
    for input in "${PROTECTED_PATHS[@]}"; do require_safe_input "$input"; done
    [ "$(/usr/bin/shasum -a 256 "$STRESS_REUSE")" = "$STRESS_REUSE_HASH" ] || fail "reboot library changed"
    /usr/bin/awk '$0 == "# Main program." {exit} {print}' "$STRESS_REUSE" | /usr/bin/cmp -s - "$STRESS_DEFS" || fail "extracted library changed"
    /bin/mkdir "$LOCK_DIR" 2>/dev/null || fail "another probe owns rootfs lock"
    LOCK_ACQUIRED=true; LOCK_TOKEN="$$:$(/bin/date +%s):$RANDOM"; LOCK_OWNER="$LOCK_DIR/owner.$$"
    printf '%s\n' "$LOCK_TOKEN" > "$LOCK_OWNER"
    [ -z "$(lsof_openers "$ROOTFS")" ] || fail "rootfs already open"
    ulimit -f 262144
    BASELINE_SNAPSHOT="$(snapshot_protected)" || fail "baseline hashes"
    BASELINE_IDENTITIES="$(snapshot_identities)" || fail "baseline identities"
    PROTECTED_WINDOW_STARTED=true; INPUTS_VERIFIED=true
    printf '%s\n' "$BASELINE_SNAPSHOT" > "$RUN_DIR/protected-before.json"
    for smp in "${SMP_COUNTS[@]}"; do stress_run_count "$smp"; done
    "$JQ" -s '{schema_version:1,scope:"bounded SMP/memory stress; Asahi builder",all_pass:all(.[];.pass),results:.}' "$RUN_DIR"/smp-*/evidence.json > "$RUN_DIR/manifest.json"
    cleanup 0 || fail "final cleanup"
    trap - EXIT INT TERM HUP
    echo "stress manifest: $RUN_DIR/manifest.json"
}

if [ "${STRESS_SOURCE_ONLY:-0}" != 1 ]; then stress_main "$@"; fi

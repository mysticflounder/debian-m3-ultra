#!/bin/bash
# Bounded idle/timerfd wakeup witness with same-user QEMU CPU accounting.
set -euo pipefail
umask 077
IDLE_HERE="$(cd "$(/usr/bin/dirname "$0")/.." && pwd -P)"
IDLE_REUSE="$IDLE_HERE/scripts/reboot-vm.sh"
IDLE_DEFS_DIR=""
IDLE_DEFS=""

# Bash 3.2 has no reliable source /dev/fd: retain and validate the helper
# scaffold as a private regular file before sourcing it.
[ -f "$IDLE_REUSE" ] && [ ! -L "$IDLE_REUSE" ] || exit 1
[ ! -L "$IDLE_HERE/out" ] || exit 1
/bin/mkdir -p "$IDLE_HERE/out"
[ "$(cd "$IDLE_HERE/out" && pwd -P)" = "$IDLE_HERE/out" ] || exit 1
IDLE_DEFS_DIR="$(/usr/bin/mktemp -d "$IDLE_HERE/out/idle-matrix.XXXXXX")"
IDLE_DEFS="$IDLE_DEFS_DIR/reboot-definitions.sh"
IDLE_REUSE_HASH="$(/usr/bin/shasum -a 256 "$IDLE_REUSE")"
[ "$(/usr/bin/awk '$0 == "# Main program." {n++} END {print n+0}' "$IDLE_REUSE")" = 1 ] || exit 1
/usr/bin/awk '$0 == "# Main program." {exit} {print}' "$IDLE_REUSE" > "$IDLE_DEFS"
[ -f "$IDLE_DEFS" ] && [ ! -L "$IDLE_DEFS" ] && [ -s "$IDLE_DEFS" ] || exit 1
[ "$(/usr/bin/shasum -a 256 "$IDLE_REUSE")" = "$IDLE_REUSE_HASH" ] || exit 1
QEMU="${QEMU:-$IDLE_HERE/out/qemu-fork-pmintenclr-build/qemu-system-aarch64}"
MEM="${MEM:-2G}"
source "$IDLE_DEFS"
RUN_DIR="$IDLE_DEFS_DIR"
HARNESS="$IDLE_HERE/scripts/idle-vm.sh"
CLANG="$(/usr/bin/xcrun --find clang)"
CLANG_SDK="$(/usr/bin/xcrun --show-sdk-path)"

# Preserve the borrowed cleanup, then add observer/FIFO cleanup around it.
eval "$(declare -f cleanup | sed '1s/^cleanup ()/idle_base_cleanup ()/')"
IDLE_OBSERVER_PID=""
IDLE_OBSERVER_FIFO=""
IDLE_OBSERVER_INPUT_OPEN=false
IDLE_OBSERVER_ERR=""
IDLE_OBSERVER_RAW=""
IDLE_OBSERVER_BIN=""

idle_fail() { echo "idle probe: $*" >&2; exit 1; }
fail() { idle_fail "$@"; }

idle_stop_observer() {
    local status=0
    if [ "$IDLE_OBSERVER_INPUT_OPEN" = true ]; then
        exec 10>&-
        IDLE_OBSERVER_INPUT_OPEN=false
    fi
    if [ -n "$IDLE_OBSERVER_PID" ]; then
        if running_shell_job "$IDLE_OBSERVER_PID"; then
            /bin/kill -TERM "$IDLE_OBSERVER_PID" || status=1
        fi
        # The shell-owned timeout wrapper forwards TERM, with a 10s kill bound.
        wait "$IDLE_OBSERVER_PID" 2>/dev/null || true
        IDLE_OBSERVER_PID=""
    fi
    if [ -n "$IDLE_OBSERVER_FIFO" ]; then
        if [ -L "$IDLE_OBSERVER_FIFO" ] || { [ -e "$IDLE_OBSERVER_FIFO" ] && [ ! -p "$IDLE_OBSERVER_FIFO" ]; }; then
            status=1
        elif [ -p "$IDLE_OBSERVER_FIFO" ]; then
            /bin/rm -f -- "$IDLE_OBSERVER_FIFO" || status=1
        fi
        IDLE_OBSERVER_FIFO=""
    fi
    return "$status"
}

cleanup() {
    local status=${1:-$?} observer_status=0 base_status=0
    idle_stop_observer || observer_status=$?
    idle_base_cleanup "$status" || base_status=$?
    [ "$observer_status" -eq 0 ] || status=1
    [ "$base_status" -eq 0 ] || status=1
    return "$status"
}

idle_complete_lines() {
    local prefix=$1 line
    while IFS= read -r line; do
        line="${line%$'\r'}"
        case "$line" in "$prefix"*) printf '%s\n' "$line";; esac
    done < "$2"
}

idle_wait_serial_prefix() {
    local prefix=$1 step line
    for ((step=0; step<CONTROL_STEPS; step++)); do
        if /usr/bin/grep -q '^M3_IDLE_FAIL ' "$SERIAL_LOG"; then
            fail "guest idle witness failed; see $SERIAL_LOG"
        fi
        line="$(idle_complete_lines "$prefix" "$SERIAL_LOG")"
        if [ -n "$line" ]; then
            case "$line" in *$'\n'*) fail "duplicate guest marker: $prefix";; esac
            wait_for_marker_count "$line" 1 || fail "invalid guest marker: $prefix"
            IDLE_LINE="$line"
            return 0
        fi
        running_shell_job "$QPID" || fail "QEMU exited before $prefix"
        /bin/sleep 0.1
    done
    fail "timeout waiting for $prefix"
}

idle_wait_observer_ack() {
    local expected=$1 step line
    for ((step=0; step<CONTROL_STEPS; step++)); do
        line="$(idle_complete_lines "OBSERVER_BEGIN sample_id=$expected workload=idle" "$IDLE_OBSERVER_ERR")"
        if [ -n "$line" ]; then
            case "$line" in *$'\n'*) fail "duplicate observer begin ack";; esac
            [ "$line" = "OBSERVER_BEGIN sample_id=$expected workload=idle" ] || fail "malformed observer ack"
            return 0
        fi
        running_shell_job "$IDLE_OBSERVER_PID" || fail "observer exited before begin ack"
        /bin/sleep 0.1
    done
    fail "timeout waiting for observer begin ack"
}

idle_validate_accounting() {
    local sample=$1
    "$JQ" -e -s --arg sample "$sample" --argjson smp "$IDLE_SMP" '
      def nn: type == "number" and isfinite and . >= 0;
      length == 1 and (.[0] |
      type == "object" and .sample_id == $sample and .workload == "idle" and
      .accounting_status == "ok" and .vcpu_thread_set_stable == true and
      .boundary_source == "observer-handshake" and
      (.vcpu_thread_count == $smp) and
      (.host_wall_seconds|nn and . >= 30 and . <= 420) and
      (.qemu_process_cpu_seconds|nn) and (.qemu_vcpu_cpu_seconds|nn) and
      (.qemu_management_cpu_seconds|nn) and
      (.sampling_uncertainty_seconds|nn) and (.counter_skew_clamped_seconds|nn) and
      (.counter_skew_clamped_seconds <= 2 * $smp * .sampling_uncertainty_seconds + 1e-8) and
      ((.qemu_process_cpu_seconds + .counter_skew_clamped_seconds -
        .qemu_vcpu_cpu_seconds - .qemu_management_cpu_seconds)|fabs) <= 1e-8 and
      (.qemu_vcpu_cpu_seconds <= $smp * (1.01 * .host_wall_seconds +
         2 * .sampling_uncertainty_seconds)))
    ' "$IDLE_OBSERVER_RAW" >/dev/null || fail "invalid CPU accounting row"
}

idle_validate_cpu_line() {
    local line=$1 token=$2 cpu=$3 pattern
    pattern="^M3_IDLE_CPU token=$token cpu=$cpu wakes=3 checksum=c4fa5bc401b5bac2 idle_ticks_before=([0-9]+) idle_ticks_after=([0-9]+) idle_ticks_delta=([0-9]+)$"
    [[ "$line" =~ $pattern ]] || return 1
    "$JQ" -en --argjson before "${BASH_REMATCH[1]}" --argjson after "${BASH_REMATCH[2]}" \
        --argjson delta "${BASH_REMATCH[3]}" '$delta > 0 and $after - $before == $delta' >/dev/null
}

idle_qmp() {
    qmp_send "$1" "$2"
    wait_for_qmp_response "$2" || fail "QMP request failed: $2"
}

idle_run_count() {
    local smp=$1 token nonce info ready pass done_line cpu step socket_before final_snapshot status=0
    IDLE_SMP="$smp"
    COUNT_DIR="$RUN_DIR/smp-$smp"
    /bin/mkdir -m 700 "$COUNT_DIR"
    CURRENT_OVERLAY="$COUNT_DIR/root.qcow2"; OVERLAY_PATHS+=("$CURRENT_OVERLAY")
    SERIAL_FIFO="$COUNT_DIR/serial.in"; SERIAL_LOG="$COUNT_DIR/serial.raw.log"
    QMP_FIFO="$COUNT_DIR/qmp.in"; QMP_SOCKET="$COUNT_DIR/qmp.sock"
    QMP_LOG="$COUNT_DIR/qmp.events.jsonl"; QMP_ERROR="$COUNT_DIR/qmp.stderr.log"
    QEMU_PID_FILE="$COUNT_DIR/qemu.pid"
    IDLE_OBSERVER_FIFO="$COUNT_DIR/observer.in"
    IDLE_OBSERVER_ERR="$COUNT_DIR/observer.stderr.log"
    IDLE_OBSERVER_RAW="$COUNT_DIR/accounting.jsonl"
    CAPTURED_QEMU_PID=""; CAPTURED_QEMU_START=""; CAPTURED_QEMU_COMMAND=""
    CAPTURED_QEMU_UID=""; CAPTURED_PID_FILE_IDENTITY=""; CAPTURE_STATE=uncaptured
    QEMU_CHILD_SAFELY_GONE=false; QEMU_LAUNCH_ATTEMPTED=false; INPUTS_VERIFIED=false
    verify_protected || fail "protected inputs changed before overlay"
    [ "$(/bin/df -k "$COUNT_DIR" | "$AWK" 'END {print $4}')" -ge 1048576 ] || fail "need 1GiB free"
    "$QEMU_IMG" create -q -f qcow2 -F raw -b "$ROOTFS" "$CURRENT_OVERLAY"
    /bin/chmod 600 "$CURRENT_OVERLAY"
    info="$("$QEMU_IMG" info --output=json "$CURRENT_OVERLAY")"
    "$JQ" -e --arg root "$ROOTFS" '.format == "qcow2" and .["backing-filename"] == $root and .["backing-filename-format"] == "raw"' <<< "$info" >/dev/null || fail "overlay contract"
    /usr/bin/mkfifo -m 600 "$SERIAL_FIFO" "$QMP_FIFO" "$IDLE_OBSERVER_FIFO"
    : > "$SERIAL_LOG"; : > "$QMP_LOG"; : > "$QMP_ERROR"; : > "$QEMU_PID_FILE"
    exec 8<> "$SERIAL_FIFO"; exec 9<> "$QMP_FIFO"
    ARGS=(-M virt,highmem=on -accel hvf,kernel-irqchip=on -cpu host
        -smp "$smp,sockets=1,cores=$smp,threads=1" -m 2G -kernel "$KERNEL" -initrd "$INITRD"
        -append 'root=/dev/vda rootfstype=ext4 rw console=ttyAMA0 systemd.unit=multi-user.target systemd.mask=m3-build.service'
        -drive "if=virtio,file=$CURRENT_OVERLAY,format=qcow2,cache=none" -nic none
        -display none -monitor none -serial stdio -qmp "unix:$QMP_SOCKET,server=on,wait=off" -nodefaults)
    "$JQ" -n --args '$ARGS.positional' -- "$QEMU" "${ARGS[@]}" > "$COUNT_DIR/qemu-argv.json"
    verify_protected || fail "protected inputs changed before launch"
    echo "idle probe: Asahi builder kernel $KVER, $smp vCPUs, 3x10s -> $COUNT_DIR"
    /usr/bin/env -i PATH="$PATH" LC_ALL=C TMPDIR="$COUNT_DIR" \
        "$TIMEOUT" --foreground --signal=TERM --kill-after=10 "$LAUNCH_TIMEOUT" \
        /bin/sh -c 'printf "%s\n" "$$" > "$1" || exit 125; shift; exec "$@"' \
        idle-qemu-launch "$QEMU_PID_FILE" "$QEMU" "${ARGS[@]}" <&8 > "$SERIAL_LOG" 2>&1 &
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
    idle_qmp qmp_capabilities capabilities
    wait_for_marker_count "$AUTOLOGIN_MARKER" 1 || fail "serial autologin"
    # QEMU sets its stdio open-file description nonblocking. Reopen the host
    # writer independently so a larger source payload gets blocking writes.
    # No ancillary child holds a serial reader; VM timeout still ends writes.
    exec 8> "$SERIAL_FIFO"
    token="m3-idle-$smp-$$-$(/bin/date +%s)-$RANDOM"
    printf 'stty -echo\n' >&8
    printf "cat > /root/m3-idle-wakeup.c <<'M3_IDLE_C_EOF'\n" >&8
    /bin/cat "$IDLE_SOURCE" >&8
    printf '\nM3_IDLE_C_EOF\n' >&8
    printf 'cc -O2 -Wall -Wextra -Werror -std=c11 -pthread -o /root/m3-idle-wakeup /root/m3-idle-wakeup.c && /root/m3-idle-wakeup %s %s\n' "$smp" "$token" >&8
    idle_wait_serial_prefix "M3_IDLE_READY token=$token "
    ready="$IDLE_LINE"
    [[ "$ready" =~ ^M3_IDLE_READY\ token=[A-Za-z0-9-]+\ pid=[0-9]+\ boot=[0-9a-f-]+\ cpus=$smp$ ]] || fail "malformed READY"
    # Only the parent holds the FIFO writer; the child opens a separate reader.
    exec 10<> "$IDLE_OBSERVER_FIFO"; IDLE_OBSERVER_INPUT_OPEN=true
    /usr/bin/env -i PATH="$PATH" LC_ALL=C TMPDIR="$COUNT_DIR" \
        "$TIMEOUT" --signal=TERM --kill-after=10 360 \
        "$IDLE_OBSERVER_BIN" "$QEMU_CHILD_PID" "$smp" \
        < "$IDLE_OBSERVER_FIFO" 10>&- 8>&- 9>&- > "$IDLE_OBSERVER_RAW" 2> "$IDLE_OBSERVER_ERR" &
    IDLE_OBSERVER_PID=$!
    printf 'BENCH_WORK_BEGIN sample_id=%s workload=idle\n' "$token" >&10
    idle_wait_observer_ack "$token"
    printf 'GO %s\n' "$token" >&8
    idle_wait_serial_prefix "M3_IDLE_DONE token=$token "
    done_line="$IDLE_LINE"
    [ "$done_line" = "M3_IDLE_DONE token=$token cpus=$smp wakes=$((3*smp)) checksum=c4fa5bc401b5bac2" ] || fail "invalid DONE"
    for ((cpu=0; cpu<smp; cpu++)); do
        idle_wait_serial_prefix "M3_IDLE_CPU token=$token cpu=$cpu "
        idle_validate_cpu_line "$IDLE_LINE" "$token" "$cpu" || fail "invalid CPU evidence $cpu"
    done
    printf 'BENCH_WORK_END sample_id=%s workload=idle status=ok\n' "$token" >&10
    exec 10>&-; IDLE_OBSERVER_INPUT_OPEN=false
    status=0; wait "$IDLE_OBSERVER_PID" || status=$?
    IDLE_OBSERVER_PID=""
    [ "$status" -eq 0 ] || fail "observer failed; see $IDLE_OBSERVER_ERR"
    idle_validate_accounting "$token"
    nonce="$(/usr/bin/openssl rand -hex 24)"
    printf 'VERIFY %s\n' "$nonce" >&8
    idle_wait_serial_prefix "M3_IDLE_PASS nonce=$nonce "
    pass="$IDLE_LINE"
    [ "$pass" = "M3_IDLE_PASS nonce=$nonce pid=${ready#* pid=}" ] || fail "guest identity changed"
    idle_qmp query-status verified-status
    qmp_running_response verified-status || fail "guest not running after idle"
    assess_captured_qemu || fail "QEMU process identity changed"
    [ "$(socket_identity "$QMP_SOCKET")" = "$socket_before" ] || fail "QMP socket identity changed"
    printf 'POWEROFF\n' >&8
    status=0; wait "$QPID" || status=$?
    [ "$status" -eq 0 ] || fail "QEMU shutdown status $status"
    "$JQ" -e -s 'any(.[]; .event? == "SHUTDOWN" and .data.guest == true and .data.reason == "guest-shutdown")' "$QMP_LOG" >/dev/null || fail "missing clean shutdown"
    terminate_owned_jobs || fail "QEMU cleanup"
    idle_stop_observer || fail "observer FIFO cleanup"
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
        --arg socket "$socket_before" --slurpfile row "$IDLE_OBSERVER_RAW" \
        --argjson before "$BASELINE_SNAPSHOT" --argjson after "$final_snapshot" \
        '{smp:$smp,pass:true,sample_id:$token,guest:{ready:$ready,done:$done,pass:$pass,wakes:(3*$smp)},
          accounting:($row[0]+{average_vcpu_host_cores:($row[0].qemu_vcpu_cpu_seconds/$row[0].host_wall_seconds),
          vcpu_occupancy:($row[0].qemu_vcpu_cpu_seconds/($smp*$row[0].host_wall_seconds)),classification:"descriptive_only"}),
          qemu:{pid:$pid,start:$start,same_process:true,same_qmp_socket:true,socket_identity:$socket},
          safety:{overlay_removed:true,protected_inputs_unchanged:true},
          protected_inputs:{before:$before,after:$after}}' > "$COUNT_DIR/evidence.json"
}

idle_main() {
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
    IDLE_SOURCE="$IDLE_HERE/scripts/arm64-idle-wakeup.c"
    CPU_OBSERVER_SOURCE="$IDLE_HERE/scripts/qemu-hvf-cpu-observer.c"
    IDLE_OBSERVER_BIN="$RUN_DIR/qemu-hvf-cpu-observer"
    for tool in "$QEMU" "$QEMU_IMG" "$TIMEOUT" "$NC" "$JQ" "$AWK" "$LSOF" "$CLANG"; do
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
    require_safe_input "$CPU_OBSERVER_SOURCE"
    "$CLANG" -isysroot "$CLANG_SDK" -O2 -Wall -Wextra -Werror -std=c11 "$CPU_OBSERVER_SOURCE" -o "$IDLE_OBSERVER_BIN"
    /bin/chmod 700 "$IDLE_OBSERVER_BIN"
    PROTECTED_NAMES=(kver kernel initrd rootfs harness guest_source observer_source observer_binary reboot_library extracted_library qemu qemu_img timeout nc jq awk lsof ps clang)
    PROTECTED_PATHS=("$KVER_FILE" "$KERNEL" "$INITRD" "$ROOTFS" "$HARNESS" "$IDLE_SOURCE" "$CPU_OBSERVER_SOURCE" "$IDLE_OBSERVER_BIN" "$IDLE_REUSE" "$IDLE_DEFS" "$QEMU" "$QEMU_IMG" "$TIMEOUT" "$NC" "$JQ" "$AWK" "$LSOF" "$PS" "$CLANG")
    for input in "${PROTECTED_PATHS[@]}"; do require_safe_input "$input"; done
    [ "$(/usr/bin/shasum -a 256 "$IDLE_REUSE")" = "$IDLE_REUSE_HASH" ] || fail "reboot library changed"
    /usr/bin/awk '$0 == "# Main program." {exit} {print}' "$IDLE_REUSE" | /usr/bin/cmp -s - "$IDLE_DEFS" || fail "extracted library changed"
    /bin/mkdir "$LOCK_DIR" 2>/dev/null || fail "another probe owns rootfs lock"
    LOCK_ACQUIRED=true; LOCK_TOKEN="$$:$(/bin/date +%s):$RANDOM"; LOCK_OWNER="$LOCK_DIR/owner.$$"
    printf '%s\n' "$LOCK_TOKEN" > "$LOCK_OWNER"
    [ -z "$(lsof_openers "$ROOTFS")" ] || fail "rootfs already open"
    ulimit -f 262144
    BASELINE_SNAPSHOT="$(snapshot_protected)" || fail "baseline hashes"
    BASELINE_IDENTITIES="$(snapshot_identities)" || fail "baseline identities"
    PROTECTED_WINDOW_STARTED=true; INPUTS_VERIFIED=true
    printf '%s\n' "$BASELINE_SNAPSHOT" > "$RUN_DIR/protected-before.json"
    for smp in "${SMP_COUNTS[@]}"; do idle_run_count "$smp"; done
    "$JQ" -s '{schema_version:1,scope:"bounded guest idle/timer wakeup; Asahi builder",all_pass:all(.[];.pass),results:.}' "$RUN_DIR"/smp-*/evidence.json > "$RUN_DIR/manifest.json"
    cleanup 0 || fail "final cleanup"
    trap - EXIT INT TERM HUP
    echo "idle manifest: $RUN_DIR/manifest.json"
}

if [ "${IDLE_SOURCE_ONLY:-0}" != 1 ]; then idle_main "$@"; fi

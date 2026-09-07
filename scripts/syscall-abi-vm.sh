#!/bin/bash
# Bounded arm64 syscall ABI smoke test.  Scope is explicitly one CPU and one
# unmodified matching syscall-abi.c/.S execution under an unprivileged guest UID.
set -euo pipefail
umask 077

SYSCALL_HERE="$(cd "$(/usr/bin/dirname "$0")/.." && pwd -P)"
SYSCALL_REUSE="$SYSCALL_HERE/scripts/reboot-vm.sh"
SYSCALL_DEFS_DIR=""
SYSCALL_DEFS=""
[ -f "$SYSCALL_REUSE" ] && [ ! -L "$SYSCALL_REUSE" ] || exit 1
[ ! -L "$SYSCALL_HERE/out" ] || exit 1
/bin/mkdir -p "$SYSCALL_HERE/out"
[ "$(cd "$SYSCALL_HERE/out" && pwd -P)" = "$SYSCALL_HERE/out" ] || exit 1
SYSCALL_DEFS_DIR="$(/usr/bin/mktemp -d "$SYSCALL_HERE/out/syscall-abi.XXXXXX")"
SYSCALL_DEFS="$SYSCALL_DEFS_DIR/reboot-definitions.sh"
SYSCALL_REUSE_HASH="$(/usr/bin/shasum -a 256 "$SYSCALL_REUSE")"
[ "$(/usr/bin/awk '$0 == "# Main program." {n++} END {print n+0}' "$SYSCALL_REUSE")" = 1 ] || exit 1
/usr/bin/awk '$0 == "# Main program." {exit} {print}' "$SYSCALL_REUSE" > "$SYSCALL_DEFS"
[ -f "$SYSCALL_DEFS" ] && [ ! -L "$SYSCALL_DEFS" ] && [ -s "$SYSCALL_DEFS" ] || exit 1
[ "$(/usr/bin/shasum -a 256 "$SYSCALL_REUSE")" = "$SYSCALL_REUSE_HASH" ] || exit 1

QEMU="${QEMU:-$SYSCALL_HERE/out/qemu-fork-pmintenclr-build/qemu-system-aarch64}"
MEM="${MEM:-2G}"
SMP_LIST="${SMP_LIST:-1}"
LAUNCH_TIMEOUT="${LAUNCH_TIMEOUT:-420}"
source "$SYSCALL_DEFS"
RUN_DIR="$SYSCALL_DEFS_DIR"
HARNESS="$SYSCALL_HERE/scripts/syscall-abi-vm.sh"
GUEST_SHELL="$SYSCALL_HERE/scripts/arm64-syscall-abi-guest.sh"
BUILD_DISK="$SYSCALL_HERE/out/build.ext4"
TAP_VALIDATOR="$SYSCALL_HERE/scripts/validate-kselftest.awk"
SYSCALL_OPENSSL=/usr/bin/openssl

sha256_file() {
    local output digest remainder
    output="$("$SYSCALL_OPENSSL" dgst -sha256 -r "$1")" || return 1
    IFS=' ' read -r digest remainder <<< "$output" || return 1
    case "$digest" in ''|*[!0-9a-f]*) return 1;; esac
    [ "${#digest}" -eq 64 ] || return 1
    printf '%s\n' "$digest"
}

fail() { echo "syscall ABI probe: $*" >&2; exit 1; }

syscall_complete_lines() {
    local prefix=$1 line
    while IFS= read -r line; do
        line="${line%$'\r'}"
        case "$line" in "$prefix"*) printf '%s\n' "$line";; esac
    done < "$2"
}

syscall_wait_serial_prefix() {
    local prefix=$1 step line
    for ((step=0; step<CONTROL_STEPS; step++)); do
        if /usr/bin/grep -q '^M3_SYSCALL_ABI_FAIL ' "$SERIAL_LOG" ||
           /usr/bin/grep -q '^M3_SELFTEST_FAIL ' "$SERIAL_LOG"; then
            fail "guest syscall witness failed; see $SERIAL_LOG"
        fi
        line="$(syscall_complete_lines "$prefix" "$SERIAL_LOG")"
        if [ -n "$line" ]; then
            case "$line" in *$'\n'*) fail "duplicate guest marker: $prefix";; esac
            wait_for_marker_count "$line" 1 || fail "invalid guest marker: $prefix"
            SYSCALL_LINE="$line"
            return 0
        fi
        running_shell_job "$QPID" || fail "QEMU exited before $prefix"
        /bin/sleep 0.1
    done
    fail "timeout waiting for $prefix"
}

syscall_qmp() {
    qmp_send "$1" "$2"
    wait_for_qmp_response "$2" || fail "QMP request failed: $2"
}

syscall_validate_ready() {
    local line=$1 token=$2
    [[ "$line" =~ ^M3_SELFTEST_READY\ token=$token\ pid=[1-9][0-9]*\ boot=[0-9a-f-]+\ cpus=1$ ]]
}

syscall_validate_done() { [ "$1" = "M3_SELFTEST_DONE token=$2 cpus=1" ]; }

syscall_validate_pass() {
    local ready=$1 pass=$2 nonce=$3 pid boot cpus
    [[ "$pass" =~ ^M3_SELFTEST_PASS\ nonce=$nonce\ pid=([1-9][0-9]*)\ boot=([0-9a-f-]+)\ cpus=(1)$ ]] || return 1
    pid="${BASH_REMATCH[1]}"; boot="${BASH_REMATCH[2]}"; cpus="${BASH_REMATCH[3]}"
    [[ "$ready" =~ pid=([1-9][0-9]*)\ boot=([0-9a-f-]+)\ cpus=(1)$ ]] || return 1
    [ "$pid" = "${BASH_REMATCH[1]}" ] && [ "$boot" = "${BASH_REMATCH[2]}" ] && [ "$cpus" = "${BASH_REMATCH[3]}" ]
}

syscall_extract_tap() {
    local begin=$1 end=$2 output=$3
    "$AWK" -v begin="$begin" -v end="$end" -v output="$output" '
        { sub(/\r$/, "") }
        $0 == begin { begins++; if (begins == 1) { inside=1; next } ; next }
        $0 == end { ends++; if (inside) { inside=0; closed++ }; next }
        inside { print > output }
        END { close(output); if (begins != 1 || ends != 1 || closed != 1 || inside) exit 1 }
    ' "$SERIAL_LOG"
}

syscall_validate_tap() {
    "$AWK" -f "$TAP_VALIDATOR" "$1" > "$2" || return 1
    # Exact pinned source: plan = 2 * (1 + S + 3*M + 3*S*M), 0 <= S,M <= 5.
    # This binary never emits SKIP, and both FPSIMD baselines are mandatory.
    "$JQ" -e '(.plan as $plan |
        (([2,4,6,8,10,12,14,16,20,24,26,28,32,40,42,48,52,56,60,64,70,78,80,84,96,100,104,120,128,130,156,160,192] | index($plan)) != null) and
        (.pass == $plan) and (.skip == 0) and (.fail == 0))' "$2" >/dev/null || return 1
    "$AWK" '
        { sub(/\r$/, "") }
        /^ok [1-9][0-9]* getpid\(\) FPSIMD$/ { getpid_count++; next }
        /^ok [1-9][0-9]* sched_yield\(\) FPSIMD$/ { sched_yield_count++; next }
        END { exit !(getpid_count == 1 && sched_yield_count == 1) }
    ' "$1"
}

syscall_run() {
    local token nonce info ready pass done_line tap summary socket_before final_snapshot status=0 step
    COUNT_DIR="$RUN_DIR/run"
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
        -smp 1,sockets=1,cores=1,threads=1 -m 2G -kernel "$KERNEL" -initrd "$INITRD"
        -append 'root=/dev/vda rootfstype=ext4 rw console=ttyAMA0 systemd.unit=multi-user.target systemd.mask=m3-build.service'
        -drive "if=virtio,file=$CURRENT_OVERLAY,format=qcow2,cache=none"
        -drive "if=virtio,file=$BUILD_DISK,format=raw,readonly=on,cache=none"
        -nic none -display none -monitor none -serial stdio
        -qmp "unix:$QMP_SOCKET,server=on,wait=off" -nodefaults)
    "$JQ" -n --args '$ARGS.positional' -- "$QEMU" "${ARGS[@]}" > "$COUNT_DIR/qemu-argv.json"
    verify_protected || fail "protected inputs changed before launch"
    echo "bounded arm64 syscall ABI: one unprivileged CPU -> $COUNT_DIR"
    /usr/bin/env -i PATH="$PATH" LC_ALL=C TMPDIR="$COUNT_DIR" \
        "$TIMEOUT" --foreground --signal=TERM --kill-after=10 "$LAUNCH_TIMEOUT" \
        /bin/sh -c 'printf "%s\n" "$$" > "$1" || exit 125; shift; exec "$@"' \
        syscall-abi-qemu "$QEMU_PID_FILE" "$QEMU" "${ARGS[@]}" <&8 > "$SERIAL_LOG" 2>&1 &
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
    syscall_qmp qmp_capabilities capabilities
    wait_for_marker_count "$AUTOLOGIN_MARKER" 1 || fail "serial autologin"
    exec 8> "$SERIAL_FIFO"
    token="m3-syscall-abi-$$-$(/bin/date +%s)-$RANDOM"
    printf 'stty -echo\n' >&8
    printf "cat > /root/m3-syscall-abi.sh <<'M3_SYSCALL_ABI_EOF'\n" >&8
    /bin/cat "$GUEST_SHELL" >&8
    printf '\nM3_SYSCALL_ABI_EOF\nchmod 700 /root/m3-syscall-abi.sh; /bin/bash /root/m3-syscall-abi.sh 1 %s\n' "$token" >&8
    syscall_wait_serial_prefix "M3_SELFTEST_READY token=$token "
    ready="$SYSCALL_LINE"
    syscall_validate_ready "$ready" "$token" || fail "malformed READY"
    printf 'GO %s\n' "$token" >&8
    syscall_wait_serial_prefix "M3_SELFTEST_BEGIN token=$token cpu=0 test=syscall-abi"
    [ "$SYSCALL_LINE" = "M3_SELFTEST_BEGIN token=$token cpu=0 test=syscall-abi" ] || fail "invalid BEGIN"
    syscall_wait_serial_prefix "M3_SELFTEST_END token=$token cpu=0 status=0"
    [ "$SYSCALL_LINE" = "M3_SELFTEST_END token=$token cpu=0 status=0" ] || fail "invalid END"
    syscall_wait_serial_prefix "M3_SELFTEST_DONE token=$token "
    done_line="$SYSCALL_LINE"
    syscall_validate_done "$done_line" "$token" || fail "invalid DONE"
    nonce="$("$SYSCALL_OPENSSL" rand -hex 24)"
    printf 'VERIFY %s\n' "$nonce" >&8
    syscall_wait_serial_prefix "M3_SELFTEST_PASS nonce=$nonce "
    pass="$SYSCALL_LINE"
    syscall_validate_pass "$ready" "$pass" "$nonce" || fail "guest identity changed"
    syscall_qmp query-status verified-status
    qmp_running_response verified-status || fail "guest not running after syscall ABI"
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
    tap="$COUNT_DIR/syscall.tap"
    syscall_extract_tap "M3_SELFTEST_BEGIN token=$token cpu=0 test=syscall-abi" \
        "M3_SELFTEST_END token=$token cpu=0 status=0" "$tap" || fail "invalid TAP boundaries"
    [ -s "$tap" ] || fail "empty TAP"
    summary="$COUNT_DIR/summary.json"
    syscall_validate_tap "$tap" "$summary" || fail "syscall TAP violates the pinned source contract"
    final_snapshot="$(snapshot_protected)" || fail "final hashes"
    [ "$final_snapshot" = "$BASELINE_SNAPSHOT" ] || fail "protected inputs changed"
    INPUTS_VERIFIED=true
    "$JQ" -n --arg scope "bounded arm64 syscall ABI" --arg token "$token" --arg ready "$ready" \
        --arg done "$done_line" --arg pass "$pass" --arg tap "$tap" --arg summary "$summary" \
        --arg pid "$CAPTURED_QEMU_PID" --arg start "$CAPTURED_QEMU_START" --arg socket "$socket_before" \
        --argjson tap_summary "$(/bin/cat "$summary")" --argjson before "$BASELINE_SNAPSHOT" --argjson after "$final_snapshot" \
        '{schema_version:1,scope:$scope,pass:true,sample_id:$token,protocol:{ready:$ready,done:$done,pass:$pass,begin_test:"syscall-abi",unprivileged_uid:65534},
          tap:{file:$tap,summary_file:$summary,plan:$tap_summary.plan,pass:$tap_summary.pass,skip:$tap_summary.skip,fail:$tap_summary.fail},
          qemu:{pid:$pid,start:$start,same_process:true,same_qmp_socket:true,socket_identity:$socket},
          safety:{overlay_removed:true,build_disk_readonly:true,protected_inputs_unchanged:true},protected_inputs:{before:$before,after:$after}}' > "$RUN_DIR/evidence.json"
}

syscall_main() {
    [ "$#" -eq 0 ] || fail "no command-line arguments accepted"
    [ "$(/usr/bin/id -u)" -ne 0 ] || fail "refusing to run QEMU as host root"
    [ "$MEM" = 2G ] || fail "requires MEM=2G"
    [ "$SMP_LIST" = 1 ] || fail "syscall ABI smoke requires fixed SMP_LIST=1"
    case "$LAUNCH_TIMEOUT" in ''|*[!0-9]*|0*) fail "invalid LAUNCH_TIMEOUT";; esac
    [ "$LAUNCH_TIMEOUT" -ge 60 ] && [ "$LAUNCH_TIMEOUT" -le 420 ] || fail "timeout must be 60..420s"
    CONTROL_STEPS=$((LAUNCH_TIMEOUT * 10))
    for tool in "$QEMU" "$QEMU_IMG" "$TIMEOUT" "$NC" "$JQ" "$AWK" "$LSOF" "$SYSCALL_OPENSSL"; do
        case "$tool" in /*) ;; *) fail "executable path must be absolute";; esac
        [ -x "$tool" ] && [ ! -u "$tool" ] && [ ! -g "$tool" ] || fail "unsafe/missing executable $tool"
    done
    validate_macos_system_ps "$PS" || fail "macOS ps safety contract"
    QEMU="$(/bin/realpath "$QEMU")"; QEMU_IMG="$(/bin/realpath "$QEMU_IMG")"
    TIMEOUT="$(/bin/realpath "$TIMEOUT")"; NC="$(/bin/realpath "$NC")"
    JQ="$(/bin/realpath "$JQ")"; AWK="$(/bin/realpath "$AWK")"; LSOF="$(/bin/realpath "$LSOF")"; SYSCALL_OPENSSL="$(/bin/realpath "$SYSCALL_OPENSSL")"
    require_safe_input "$KVER_FILE"; KVER="$(/bin/cat "$KVER_FILE")"
    case "$KVER" in ''|.|..|*/*|*[!A-Za-z0-9.+_~-]*) fail "unsafe KVER";; esac
    case "$KVER" in *asahi*) ;; *) fail "requires Asahi builder kernel";; esac
    KERNEL="$OUT/Image-$KVER"; INITRD="$OUT/initrd.img-$KVER"
    for input in "$KERNEL" "$INITRD" "$ROOTFS" "$BUILD_DISK" "$HARNESS" "$GUEST_SHELL" "$TAP_VALIDATOR"; do require_safe_input "$input"; done
    PROTECTED_NAMES=(kver kernel initrd rootfs build_disk harness guest_shell tap_validator reboot_library extracted_library qemu qemu_img timeout nc jq awk lsof ps openssl)
    PROTECTED_PATHS=("$KVER_FILE" "$KERNEL" "$INITRD" "$ROOTFS" "$BUILD_DISK" "$HARNESS" "$GUEST_SHELL" "$TAP_VALIDATOR" "$SYSCALL_REUSE" "$SYSCALL_DEFS" "$QEMU" "$QEMU_IMG" "$TIMEOUT" "$NC" "$JQ" "$AWK" "$LSOF" "$PS" "$SYSCALL_OPENSSL")
    for input in "${PROTECTED_PATHS[@]}"; do require_safe_input "$input"; done
    [ "$(/usr/bin/shasum -a 256 "$SYSCALL_REUSE")" = "$SYSCALL_REUSE_HASH" ] || fail "reboot library changed"
    /usr/bin/awk '$0 == "# Main program." {exit} {print}' "$SYSCALL_REUSE" | /usr/bin/cmp -s - "$SYSCALL_DEFS" || fail "extracted library changed"
    /bin/mkdir "$LOCK_DIR" 2>/dev/null || fail "another VM probe owns rootfs"
    LOCK_ACQUIRED=true; LOCK_TOKEN="$$:$(/bin/date +%s):$RANDOM"; LOCK_OWNER="$LOCK_DIR/owner.$$"
    printf '%s\n' "$LOCK_TOKEN" > "$LOCK_OWNER"
    [ -z "$(lsof_openers "$ROOTFS")" ] || fail "rootfs already open"
    [ -z "$(lsof_openers "$BUILD_DISK")" ] || fail "source disk already open"
    ulimit -f 262144
    BASELINE_SNAPSHOT="$(snapshot_protected)" || fail "baseline hashes"
    BASELINE_IDENTITIES="$(snapshot_identities)" || fail "baseline identities"
    PROTECTED_WINDOW_STARTED=true; INPUTS_VERIFIED=true
    printf '%s\n' "$BASELINE_SNAPSHOT" > "$RUN_DIR/protected-before.json"
    syscall_run
    "$JQ" -n --arg scope "bounded arm64 syscall ABI" --slurpfile result "$RUN_DIR/evidence.json" --arg run_dir "$RUN_DIR" \
        '{schema_version:1,scope:$scope,all_pass:($result|length == 1 and $result[0].pass),results:$result,run_directory:$run_dir}' > "$RUN_DIR/manifest.json"
    cleanup 0 || fail "runtime cleanup failed"
    trap - EXIT INT TERM HUP
    echo "syscall ABI manifest: $RUN_DIR/manifest.json"
}

if [ "${SYSCALL_ABI_SOURCE_ONLY:-0}" != 1 ]; then syscall_main "$@"; fi

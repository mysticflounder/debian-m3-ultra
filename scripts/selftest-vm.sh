#!/bin/bash
# Run the bounded arm64 Linux selftest witness in an isolated guest.
# The guest root is a disposable qcow2 overlay; the builder source disk is
# attached read-only and mounted read-only by arm64-selftest-guest.sh.
set -euo pipefail
umask 077

SELFTEST_HERE="$(cd "$(/usr/bin/dirname "$0")/.." && pwd -P)"
SELFTEST_REUSE="$SELFTEST_HERE/scripts/reboot-vm.sh"
SELFTEST_DEFS_DIR=""
SELFTEST_DEFS=""

# Extract only the reusable reboot/QMP/process-safety definitions.  Keeping a
# private regular copy avoids Bash 3.2's unreliable source /dev/fd behavior.
[ -f "$SELFTEST_REUSE" ] && [ ! -L "$SELFTEST_REUSE" ] || exit 1
[ ! -L "$SELFTEST_HERE/out" ] || exit 1
/bin/mkdir -p "$SELFTEST_HERE/out"
[ "$(cd "$SELFTEST_HERE/out" && pwd -P)" = "$SELFTEST_HERE/out" ] || exit 1
SELFTEST_DEFS_DIR="$(/usr/bin/mktemp -d "$SELFTEST_HERE/out/selftest-matrix.XXXXXX")"
SELFTEST_DEFS="$SELFTEST_DEFS_DIR/reboot-definitions.sh"
SELFTEST_REUSE_HASH="$(/usr/bin/shasum -a 256 "$SELFTEST_REUSE")"
[ "$(/usr/bin/awk '$0 == "# Main program." {n++} END {print n+0}' "$SELFTEST_REUSE")" = 1 ] || exit 1
/usr/bin/awk '$0 == "# Main program." {exit} {print}' "$SELFTEST_REUSE" > "$SELFTEST_DEFS"
[ -f "$SELFTEST_DEFS" ] && [ ! -L "$SELFTEST_DEFS" ] && [ -s "$SELFTEST_DEFS" ] || exit 1
[ "$(/usr/bin/shasum -a 256 "$SELFTEST_REUSE")" = "$SELFTEST_REUSE_HASH" ] || exit 1

QEMU="${QEMU:-$SELFTEST_HERE/out/qemu-fork-pmintenclr-build/qemu-system-aarch64}"
MEM="${MEM:-2G}"
SMP_LIST="${SMP_LIST:-1}"
LAUNCH_TIMEOUT="${LAUNCH_TIMEOUT:-420}"
source "$SELFTEST_DEFS"
RUN_DIR="$SELFTEST_DEFS_DIR"
HARNESS="$SELFTEST_HERE/scripts/selftest-vm.sh"

GUEST_SHELL="$SELFTEST_HERE/scripts/arm64-selftest-guest.sh"
TAP_VALIDATOR="$SELFTEST_HERE/scripts/validate-kselftest.awk"
BUILD_DISK="$SELFTEST_HERE/out/build.ext4"
SELFTEST_OPENSSL=/usr/bin/openssl

# Same full-file SHA-256 contract as the reusable library. Capture the tool
# status explicitly; a partial or failed digest must never become evidence.
sha256_file() {
    local output digest remainder
    output="$("$SELFTEST_OPENSSL" dgst -sha256 -r "$1")" || return 1
    IFS=' ' read -r digest remainder <<< "$output" || return 1
    case "$digest" in ''|*[!0-9a-f]*) return 1;; esac
    [ "${#digest}" -eq 64 ] || return 1
    printf '%s\n' "$digest"
}

fail() { echo "selftest probe: $*" >&2; exit 1; }

selftest_complete_lines() {
    local prefix=$1 line
    while IFS= read -r line; do
        line="${line%$'\r'}"
        case "$line" in "$prefix"*) printf '%s\n' "$line";; esac
    done < "$2"
}

selftest_wait_serial_prefix() {
    local prefix=$1 step line
    for ((step=0; step<CONTROL_STEPS; step++)); do
        if /usr/bin/grep -q '^M3_SELFTEST_FAIL ' "$SERIAL_LOG"; then
            fail "guest selftest witness failed; see $SERIAL_LOG"
        fi
        line="$(selftest_complete_lines "$prefix" "$SERIAL_LOG")"
        if [ -n "$line" ]; then
            case "$line" in *$'\n'*) fail "duplicate guest marker: $prefix";; esac
            wait_for_marker_count "$line" 1 || fail "invalid guest marker: $prefix"
            SELFTEST_LINE="$line"
            return 0
        fi
        running_shell_job "$QPID" || fail "QEMU exited before $prefix"
        /bin/sleep 0.1
    done
    fail "timeout waiting for $prefix"
}

selftest_qmp() {
    qmp_send "$1" "$2"
    wait_for_qmp_response "$2" || fail "QMP request failed: $2"
}

selftest_validate_ready() {
    local line=$1 token=$2 smp=$3
    [[ "$line" =~ ^M3_SELFTEST_READY\ token=$token\ pid=[1-9][0-9]*\ boot=[0-9a-f-]+\ cpus=$smp$ ]]
}

selftest_validate_done() {
    [ "$1" = "M3_SELFTEST_DONE token=$2 cpus=$3" ]
}

selftest_validate_pass() {
    local ready=$1 pass=$2 nonce=$3 pid boot cpus
    [[ "$pass" =~ ^M3_SELFTEST_PASS\ nonce=$nonce\ pid=([1-9][0-9]*)\ boot=([0-9a-f-]+)\ cpus=([1-9][0-9]*)$ ]] || return 1
    pid="${BASH_REMATCH[1]}"; boot="${BASH_REMATCH[2]}"; cpus="${BASH_REMATCH[3]}"
    [[ "$ready" =~ pid=([1-9][0-9]*)\ boot=([0-9a-f-]+)\ cpus=([1-9][0-9]*)$ ]] || return 1
    [ "$pid" = "${BASH_REMATCH[1]}" ] && [ "$boot" = "${BASH_REMATCH[2]}" ] &&
        [ "$cpus" = "${BASH_REMATCH[3]}" ]
}

# Extract one exact BEGIN/END-delimited TAP stream.  Marker-looking text in
# TAP is data unless the complete line is the unique marker for this CPU.
selftest_extract_tap() {
    local begin=$1 end=$2 output=$3
    "$AWK" -v begin="$begin" -v end="$end" -v output="$output" '
        { sub(/\r$/, "") }
        $0 == begin {
            begins++
            if (begins == 1) { inside=1; next }
            next
        }
        $0 == end {
            ends++
            if (inside) { inside=0; closed++ }
            next
        }
        inside { print > output }
        END {
            close(output)
            if (begins != 1 || ends != 1 || closed != 1 || inside) exit 1
        }
    ' "$SERIAL_LOG"
}

selftest_run_count() {
    local smp=$1 token nonce info ready pass done_line cpu step socket_before final_snapshot status=0
    local total_plan=0 total_pass=0 total_skip=0 total_fail=0 summary_json='[]' last_byte stats tap
    SELFTEST_SMP="$smp"
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
        -drive "if=virtio,file=$CURRENT_OVERLAY,format=qcow2,cache=none"
        -drive "if=virtio,file=$BUILD_DISK,format=raw,readonly=on,cache=none"
        -nic none -display none -monitor none -serial stdio
        -qmp "unix:$QMP_SOCKET,server=on,wait=off" -nodefaults)
    "$JQ" -n --args '$ARGS.positional' -- "$QEMU" "${ARGS[@]}" > "$COUNT_DIR/qemu-argv.json"
    verify_protected || fail "protected inputs changed before launch"
    echo "selftest probe: Asahi builder kernel $KVER, $smp vCPUs -> $COUNT_DIR"
    /usr/bin/env -i PATH="$PATH" LC_ALL=C TMPDIR="$COUNT_DIR" \
        "$TIMEOUT" --foreground --signal=TERM --kill-after=10 "$LAUNCH_TIMEOUT" \
        /bin/sh -c 'printf "%s\n" "$$" > "$1" || exit 125; shift; exec "$@"' \
        selftest-qemu-launch "$QEMU_PID_FILE" "$QEMU" "${ARGS[@]}" <&8 > "$SERIAL_LOG" 2>&1 &
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
    selftest_qmp qmp_capabilities capabilities
    wait_for_marker_count "$AUTOLOGIN_MARKER" 1 || fail "serial autologin"
    exec 8> "$SERIAL_FIFO"
    token="m3-selftest-$smp-$$-$(/bin/date +%s)-$RANDOM"
    printf 'stty -echo\n' >&8
    printf "cat > /root/m3-selftest.sh <<'M3_SELFTEST_SH_EOF'\n" >&8
    /bin/cat "$GUEST_SHELL" >&8
    printf '\nM3_SELFTEST_SH_EOF\nchmod 700 /root/m3-selftest.sh; /bin/bash /root/m3-selftest.sh %s %s\n' "$smp" "$token" >&8
    selftest_wait_serial_prefix "M3_SELFTEST_READY token=$token "
    ready="$SELFTEST_LINE"
    selftest_validate_ready "$ready" "$token" "$smp" || fail "malformed READY"
    printf 'GO %s\n' "$token" >&8
    for ((cpu=0; cpu<smp; cpu++)); do
        selftest_wait_serial_prefix "M3_SELFTEST_BEGIN token=$token cpu=$cpu test=hwcap"
        [ "$SELFTEST_LINE" = "M3_SELFTEST_BEGIN token=$token cpu=$cpu test=hwcap" ] || fail "invalid BEGIN cpu=$cpu"
    done
    selftest_wait_serial_prefix "M3_SELFTEST_DONE token=$token "
    done_line="$SELFTEST_LINE"
    selftest_validate_done "$done_line" "$token" "$smp" || fail "invalid DONE"
    for ((cpu=0; cpu<smp; cpu++)); do
        selftest_wait_serial_prefix "M3_SELFTEST_END token=$token cpu=$cpu "
        [ "$SELFTEST_LINE" = "M3_SELFTEST_END token=$token cpu=$cpu status=0" ] || fail "invalid END cpu=$cpu"
    done
    nonce="$(/usr/bin/openssl rand -hex 24)"
    printf 'VERIFY %s\n' "$nonce" >&8
    selftest_wait_serial_prefix "M3_SELFTEST_PASS nonce=$nonce "
    pass="$SELFTEST_LINE"
    selftest_validate_pass "$ready" "$pass" "$nonce" || fail "guest identity changed"
    selftest_qmp query-status verified-status
    qmp_running_response verified-status || fail "guest not running after selftest"
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
    for ((cpu=0; cpu<smp; cpu++)); do
        tap="$COUNT_DIR/cpu-$cpu.tap"
        selftest_extract_tap "M3_SELFTEST_BEGIN token=$token cpu=$cpu test=hwcap" \
            "M3_SELFTEST_END token=$token cpu=$cpu status=0" "$tap" || fail "invalid TAP boundaries cpu=$cpu"
        [ -s "$tap" ] || fail "empty TAP cpu=$cpu"
        # The exact END marker was observed as a complete newline-terminated
        # serial record by selftest_wait_serial_prefix. A missing newline
        # before END would concatenate it with TAP and fail that exact gate.
        last_byte="$(/usr/bin/tail -c 1 "$tap" | /usr/bin/od -An -t x1 | /usr/bin/tr -d '[:space:]')"
        [ "$last_byte" = "0a" ] || fail "TAP is not newline-terminated cpu=$cpu"
        "$AWK" -f "$TAP_VALIDATOR" "$tap" > "$COUNT_DIR/cpu-$cpu.summary.json" || fail "TAP validator rejected cpu=$cpu"
        stats="$(/bin/cat "$COUNT_DIR/cpu-$cpu.summary.json")"
        summary_json="$(printf '%s\n' "$summary_json" | "$JQ" -c --argjson cpu "$cpu" --argjson stats "$stats" '. + [{cpu:$cpu} + $stats]')"
        total_plan=$((total_plan + $(printf '%s\n' "$stats" | "$JQ" -r '.plan')))
        total_pass=$((total_pass + $(printf '%s\n' "$stats" | "$JQ" -r '.pass')))
        total_skip=$((total_skip + $(printf '%s\n' "$stats" | "$JQ" -r '.skip')))
    done
    final_snapshot="$(snapshot_protected)" || fail "final hashes"
    [ "$final_snapshot" = "$BASELINE_SNAPSHOT" ] || fail "protected inputs changed"
    INPUTS_VERIFIED=true
    "$JQ" -n --argjson smp "$smp" --arg token "$token" --arg ready "$ready" --arg pass "$pass" \
        --arg done "$done_line" --arg pid "$CAPTURED_QEMU_PID" --arg start "$CAPTURED_QEMU_START" \
        --arg socket "$socket_before" --argjson before "$BASELINE_SNAPSHOT" --argjson after "$final_snapshot" \
        --argjson per_cpu "$summary_json" --argjson plan "$total_plan" --argjson pass_count "$total_pass" \
        --argjson skip_count "$total_skip" '{smp:$smp,pass:true,sample_id:$token,
          guest:{ready:$ready,done:$done,pass:$pass,cpus:$smp},
          tap:{per_cpu:$per_cpu,plan:$plan,pass:$pass_count,skip:$skip_count,fail:0,all_skipped:false},
          qemu:{pid:$pid,start:$start,same_process:true,same_qmp_socket:true,socket_identity:$socket},
          safety:{overlay_removed:true,build_disk_readonly:true,protected_inputs_unchanged:true},
          protected_inputs:{before:$before,after:$after}}' > "$COUNT_DIR/evidence.json"
}

selftest_main() {
    [ "$#" -eq 0 ] || fail "no command-line arguments accepted"
    [ "$(/usr/bin/id -u)" -ne 0 ] || fail "refusing to run QEMU as host root"
    [ "$MEM" = 2G ] || fail "requires MEM=2G"
    case "$LAUNCH_TIMEOUT" in ''|*[!0-9]*|0*) fail "invalid LAUNCH_TIMEOUT";; esac
    [ "$LAUNCH_TIMEOUT" -ge 60 ] && [ "$LAUNCH_TIMEOUT" -le 420 ] || fail "timeout must be 60..420s"
    CONTROL_STEPS=$((LAUNCH_TIMEOUT * 10))
    case "$SMP_LIST" in *$'\n'*|*$'\r'*) fail "SMP_LIST must be one line";; esac
    read -r -a SMP_COUNTS <<< "$SMP_LIST"
    [ "${#SMP_COUNTS[@]}" -gt 0 ] || fail "empty SMP_LIST"
    local smp seen=' ' input tool
    for smp in "${SMP_COUNTS[@]}"; do
        case "$smp" in 1|8|16|24|32) ;; *) fail "SMP counts supported: 1 8 16 24 32";; esac
        case "$seen" in *" $smp "*) fail "duplicate SMP count";; esac
        seen="$seen$smp "
    done
    for tool in "$QEMU" "$QEMU_IMG" "$TIMEOUT" "$NC" "$JQ" "$AWK" "$LSOF" "$SELFTEST_OPENSSL"; do
        case "$tool" in /*) ;; *) fail "executable path must be absolute";; esac
        [ -x "$tool" ] && [ ! -u "$tool" ] && [ ! -g "$tool" ] || fail "unsafe/missing executable $tool"
    done
    validate_macos_system_ps "$PS" || fail "macOS ps safety contract"
    QEMU="$(/bin/realpath "$QEMU")"; QEMU_IMG="$(/bin/realpath "$QEMU_IMG")"
    TIMEOUT="$(/bin/realpath "$TIMEOUT")"; NC="$(/bin/realpath "$NC")"
    JQ="$(/bin/realpath "$JQ")"; AWK="$(/bin/realpath "$AWK")"; LSOF="$(/bin/realpath "$LSOF")"
    require_safe_input "$KVER_FILE"; KVER="$(/bin/cat "$KVER_FILE")"
    case "$KVER" in ''|.|..|*/*|*[!A-Za-z0-9.+_~-]*) fail "unsafe KVER";; esac
    case "$KVER" in *asahi*) ;; *) fail "requires Asahi builder kernel";; esac
    KERNEL="$OUT/Image-$KVER"; INITRD="$OUT/initrd.img-$KVER"
    for input in "$KERNEL" "$INITRD" "$ROOTFS" "$BUILD_DISK" "$HARNESS" "$GUEST_SHELL" "$TAP_VALIDATOR"; do require_safe_input "$input"; done
    PROTECTED_NAMES=(kver kernel initrd rootfs build_disk harness guest_shell tap_validator reboot_library extracted_library qemu qemu_img timeout nc jq awk lsof ps openssl)
    PROTECTED_PATHS=("$KVER_FILE" "$KERNEL" "$INITRD" "$ROOTFS" "$BUILD_DISK" "$HARNESS" "$GUEST_SHELL" "$TAP_VALIDATOR" "$SELFTEST_REUSE" "$SELFTEST_DEFS" "$QEMU" "$QEMU_IMG" "$TIMEOUT" "$NC" "$JQ" "$AWK" "$LSOF" "$PS" "$SELFTEST_OPENSSL")
    for input in "${PROTECTED_PATHS[@]}"; do require_safe_input "$input"; done
    [ "$(/usr/bin/shasum -a 256 "$SELFTEST_REUSE")" = "$SELFTEST_REUSE_HASH" ] || fail "reboot library changed"
    /usr/bin/awk '$0 == "# Main program." {exit} {print}' "$SELFTEST_REUSE" | /usr/bin/cmp -s - "$SELFTEST_DEFS" || fail "extracted library changed"
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
    for smp in "${SMP_COUNTS[@]}"; do selftest_run_count "$smp"; done
    "$JQ" -s '{schema_version:1,scope:"bounded Linux kselftest TAP; Asahi builder",all_pass:all(.[];.pass),results:.}' "$RUN_DIR"/smp-*/evidence.json > "$RUN_DIR/manifest.json"
    cleanup 0 || fail "runtime cleanup failed"
    trap - EXIT INT TERM HUP
    echo "selftest manifest: $RUN_DIR/manifest.json"
}

if [ "${SELFTEST_SOURCE_ONLY:-0}" != 1 ]; then selftest_main "$@"; fi

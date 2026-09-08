#!/bin/bash
# Combined bounded arm64 ABI matrix.  One disposable QEMU/HVF guest is used
# per vCPU count; the guest compiles exact pinned sources once and runs ptrace
# followed by syscall-ABI on every selected CPU.
set -euo pipefail
umask 077

ABI_MATRIX_HERE="$(cd "$(/usr/bin/dirname "$0")/.." && pwd -P)"
ABI_MATRIX_REUSE="$ABI_MATRIX_HERE/scripts/reboot-vm.sh"
ABI_MATRIX_DEFS_DIR=""
ABI_MATRIX_DEFS=""
ABI_MATRIX_QEMU="${QEMU:-$ABI_MATRIX_HERE/out/qemu-fork-pmintenclr-build/qemu-system-aarch64}"
ABI_MATRIX_MEM="${MEM:-2G}"
ABI_MATRIX_SMP_LIST="${SMP_LIST-1}"
ABI_MATRIX_LAUNCH_TIMEOUT="${LAUNCH_TIMEOUT:-420}"
[ -f "$ABI_MATRIX_REUSE" ] && [ ! -L "$ABI_MATRIX_REUSE" ] || exit 1
[ ! -L "$ABI_MATRIX_HERE/out" ] || exit 1
/bin/mkdir -p "$ABI_MATRIX_HERE/out"
[ "$(cd "$ABI_MATRIX_HERE/out" && pwd -P)" = "$ABI_MATRIX_HERE/out" ] || exit 1
ABI_MATRIX_DEFS_DIR="$(/usr/bin/mktemp -d "$ABI_MATRIX_HERE/out/abi-matrix.XXXXXX")"
ABI_MATRIX_DEFS="$ABI_MATRIX_DEFS_DIR/reboot-definitions.sh"
ABI_MATRIX_REUSE_HASH="$(/usr/bin/shasum -a 256 "$ABI_MATRIX_REUSE")"
/usr/bin/awk '$0 == "# Main program." {n++} END {print n+0}' "$ABI_MATRIX_REUSE" | /usr/bin/grep -qx 1 || exit 1
/usr/bin/awk '$0 == "# Main program." {exit} {print}' "$ABI_MATRIX_REUSE" > "$ABI_MATRIX_DEFS"
[ -f "$ABI_MATRIX_DEFS" ] && [ ! -L "$ABI_MATRIX_DEFS" ] && [ -s "$ABI_MATRIX_DEFS" ] || exit 1
[ "$(/usr/bin/shasum -a 256 "$ABI_MATRIX_REUSE")" = "$ABI_MATRIX_REUSE_HASH" ] || exit 1
/usr/bin/awk '$0 == "# Main program." {exit} {print}' "$ABI_MATRIX_REUSE" | /usr/bin/cmp -s - "$ABI_MATRIX_DEFS" || exit 1
source "$ABI_MATRIX_DEFS"
RUN_DIR="$ABI_MATRIX_DEFS_DIR"

HARNESS="$ABI_MATRIX_HERE/scripts/abi-matrix-vm.sh"
GUEST_SHELL="$ABI_MATRIX_HERE/scripts/arm64-abi-matrix-guest.sh"
BUILD_DISK="$ABI_MATRIX_HERE/out/build.ext4"
TAP_VALIDATOR="$ABI_MATRIX_HERE/scripts/validate-kselftest.awk"
OPENSSL=/usr/bin/openssl
QEMU="$ABI_MATRIX_QEMU"
MEM="$ABI_MATRIX_MEM"
SMP_LIST="$ABI_MATRIX_SMP_LIST"
LAUNCH_TIMEOUT="$ABI_MATRIX_LAUNCH_TIMEOUT"

sha256_file() {
    local output digest remainder
    output="$("$OPENSSL" dgst -sha256 -r "$1")" || return 1
    IFS=' ' read -r digest remainder <<< "$output" || return 1
    case "$digest" in ''|*[!0-9a-f]*) return 1;; esac
    [ "${#digest}" -eq 64 ] || return 1
    printf '%s\n' "$digest"
}

fail() { echo "ABI matrix: $*" >&2; exit 1; }

abi_parse_counts() {
    local input=$1 count seen=' '
    case "$input" in ''|*$'\r'*|*$'\n'*) return 1;; esac
    read -r -a requested_args <<< "$input"
    [ "${#requested_args[@]}" -gt 0 ] || return 1
    for count in "${requested_args[@]}"; do
        case "$count" in 1|8|16|24|32) ;; *) return 1;; esac
        case "$seen" in *" $count "*) return 1;; esac
        seen="$seen$count "
    done
}

abi_validate_ready() {
    local line=$1 token=$2 smp=$3
    [[ "$line" =~ ^M3_SELFTEST_READY\ token=$token\ pid=[1-9][0-9]*\ boot=[0-9a-f-]+\ cpus=$smp$ ]]
}
abi_validate_done() { [ "$1" = "M3_SELFTEST_DONE token=$2 cpus=$3" ]; }
abi_validate_pass() {
    local ready=$1 pass=$2 nonce=$3 smp=$4 pid boot cpus
    [[ "$pass" =~ ^M3_SELFTEST_PASS\ nonce=$nonce\ pid=([1-9][0-9]*)\ boot=([0-9a-f-]+)\ cpus=($smp)$ ]] || return 1
    pid="${BASH_REMATCH[1]}"; boot="${BASH_REMATCH[2]}"; cpus="${BASH_REMATCH[3]}"
    [[ "$ready" =~ pid=([1-9][0-9]*)\ boot=([0-9a-f-]+)\ cpus=($smp)$ ]] || return 1
    [ "$pid" = "${BASH_REMATCH[1]}" ] && [ "$boot" = "${BASH_REMATCH[2]}" ] && [ "$cpus" = "${BASH_REMATCH[3]}" ]
}
abi_complete_lines() {
    local prefix=$1 line
    while IFS= read -r line; do
        line="${line%$'\r'}"
        case "$line" in "$prefix"*) printf '%s\n' "$line";; esac
    done < "$2"
}
abi_wait_prefix() {
    local prefix=$1 var=$2 line step
    for ((step=0; step<CONTROL_STEPS; step++)); do
        if /usr/bin/grep -q '^M3_ABI_MATRIX_FAIL ' "$SERIAL_LOG"; then fail "guest ABI matrix failed"
        fi
        line="$(abi_complete_lines "$prefix" "$SERIAL_LOG")"
        if [ -n "$line" ]; then
            case "$line" in *$'\n'*) fail "duplicate marker: $prefix";; esac
            wait_for_marker_count "$line" 1 || fail "malformed marker: $prefix"
            printf -v "$var" '%s' "$line"
            return 0
        fi
        running_shell_job "$QPID" || fail "QEMU exited before $prefix"
        /bin/sleep 0.1
    done
    fail "timeout waiting for $prefix"
}
abi_extract_tap() {
    local begin=$1 end=$2 output=$3
    "$AWK" -v begin="$begin" -v end="$end" -v output="$output" '
        { sub(/\r$/, "") }
        $0 == begin { begins++; if (begins == 1) { inside=1; next }; next }
        $0 == end { ends++; if (inside) { inside=0; closed++ }; next }
        inside { print > output }
        END { close(output); if (begins != 1 || ends != 1 || closed != 1 || inside) exit 1 }
    ' "$SERIAL_LOG"
}
abi_validate_tap() {
    local test=$1 tap=$2 summary=$3
    case "$test" in ptrace|syscall-abi) ;; *) return 1;; esac
    "$AWK" -f "$TAP_VALIDATOR" "$tap" > "$summary" || return 1
    if [ "$test" = ptrace ]; then
        "$JQ" -e '.plan == 11 and (.pass >= 1) and (.skip >= 0) and .fail == 0' "$summary" >/dev/null || return 1
        return 0
    fi
    "$JQ" -e '(.plan as $p | (([2,4,6,8,10,12,14,16,20,24,26,28,32,40,42,48,52,56,60,64,70,78,80,84,96,100,104,120,128,130,156,160,192] | index($p)) != null) and .pass == $p and .skip == 0 and .fail == 0)' "$summary" >/dev/null || return 1
    "$AWK" '{sub(/\r$/, "")} /^ok [1-9][0-9]* getpid\(\) FPSIMD$/ {a++} /^ok [1-9][0-9]* sched_yield\(\) FPSIMD$/ {b++} END {exit !(a == 1 && b == 1)}' "$tap"
}
abi_validate_streams() {
    local serial=$1 token=$2 smp=$3
    "$AWK" -v token="$token" -v smp="$smp" '
      BEGIN {
        n=0
        for (cpu=0; cpu<smp; cpu++) {
          expected[n++]="M3_SELFTEST_BEGIN token=" token " cpu=" cpu " test=ptrace"
          expected[n++]="M3_SELFTEST_END token=" token " cpu=" cpu " test=ptrace status=0"
          expected[n++]="M3_SELFTEST_BEGIN token=" token " cpu=" cpu " test=syscall-abi"
          expected[n++]="M3_SELFTEST_END token=" token " cpu=" cpu " test=syscall-abi status=0"
        }
      }
      { sub(/\r$/, "") }
      /^M3_SELFTEST_(BEGIN|END)( |$)/ {
        if ($0 != expected[i++]) { bad=1; exit 1 }
      }
      END { exit !(!bad && i == n) }
    ' "$serial"
}

matrix_run_count() {
    local smp=$1 count_dir token ready done_line pass nonce socket_before final_snapshot
    local ptrace_shape="" syscall_shape="" stream_json shape
    count_dir="$RUN_DIR/run-$smp"; /bin/mkdir -m 700 "$count_dir"
    COUNT_DIR="$count_dir"; CURRENT_OVERLAY="$count_dir/root.qcow2"; OVERLAY_PATHS+=("$CURRENT_OVERLAY")
    SERIAL_FIFO="$count_dir/serial.in"; SERIAL_LOG="$count_dir/serial.raw.log"
    QMP_FIFO="$count_dir/qmp.in"; QMP_SOCKET="$count_dir/qmp.sock"; QMP_LOG="$count_dir/qmp.events.jsonl"; QMP_ERROR="$count_dir/qmp.stderr.log"; QEMU_PID_FILE="$count_dir/qemu.pid"
    CAPTURED_QEMU_PID=""; CAPTURED_QEMU_START=""; CAPTURED_QEMU_COMMAND=""; CAPTURED_QEMU_UID=""; CAPTURED_PID_FILE_IDENTITY=""; CAPTURE_STATE=uncaptured; QEMU_CHILD_SAFELY_GONE=false; QEMU_LAUNCH_ATTEMPTED=false; INPUTS_VERIFIED=false
    verify_protected || fail "protected inputs changed before $smp"
    [ "$(/bin/df -k "$count_dir" | "$AWK" 'END {print $4}')" -ge 1048576 ] || fail "need 1GiB free"
    "$QEMU_IMG" create -q -f qcow2 -F raw -b "$ROOTFS" "$CURRENT_OVERLAY"; /bin/chmod 600 "$CURRENT_OVERLAY"
    "$JQ" -e --arg root "$ROOTFS" '.format == "qcow2" and .["backing-filename"] == $root and .["backing-filename-format"] == "raw"' < <("$QEMU_IMG" info --output=json "$CURRENT_OVERLAY") >/dev/null || fail overlay
    /usr/bin/mkfifo -m 600 "$SERIAL_FIFO" "$QMP_FIFO"; : > "$SERIAL_LOG"; : > "$QMP_LOG"; : > "$QMP_ERROR"; : > "$QEMU_PID_FILE"
    exec 8<> "$SERIAL_FIFO"; exec 9<> "$QMP_FIFO"
    ARGS=(-M virt,highmem=on -accel hvf,kernel-irqchip=on -cpu host -smp "$smp",sockets=1,cores="$smp",threads=1 -m 2G -kernel "$KERNEL" -initrd "$INITRD"
      -append 'root=/dev/vda rootfstype=ext4 rw console=ttyAMA0 systemd.unit=multi-user.target systemd.mask=m3-build.service'
      -drive "if=virtio,file=$CURRENT_OVERLAY,format=qcow2,cache=none" -drive "if=virtio,file=$BUILD_DISK,format=raw,readonly=on,cache=none"
      -nic none -display none -monitor none -serial stdio -qmp "unix:$QMP_SOCKET,server=on,wait=off" -nodefaults)
    "$JQ" -n --args '$ARGS.positional' -- "$QEMU" "${ARGS[@]}" > "$count_dir/qemu-argv.json"
    [ "$(/usr/bin/shasum -a 256 "$ABI_MATRIX_REUSE")" = "$ABI_MATRIX_REUSE_HASH" ] || fail "reboot library changed before launch"
    /usr/bin/awk '$0 == "# Main program." {exit} {print}' "$ABI_MATRIX_REUSE" | /usr/bin/cmp -s - "$ABI_MATRIX_DEFS" || fail "extracted library changed before launch"
    verify_protected || fail "protected inputs changed before launch"
    /usr/bin/env -i PATH="$PATH" LC_ALL=C TMPDIR="$count_dir" "$TIMEOUT" --foreground --signal=TERM --kill-after=10 "$LAUNCH_TIMEOUT" /bin/sh -c 'printf "%s\n" "$$" > "$1" || exit 125; shift; exec "$@"' abi-matrix-qemu "$QEMU_PID_FILE" "$QEMU" "${ARGS[@]}" <&8 >"$SERIAL_LOG" 2>&1 &
    QPID=$!; QEMU_LAUNCH_ATTEMPTED=true
    for ((step=0; step<100; step++)); do [ -s "$QEMU_PID_FILE" ] && break; running_shell_job "$QPID" || break; /bin/sleep 0.05; done
    require_safe_input "$QEMU_PID_FILE"; IFS= read -r QEMU_CHILD_PID < "$QEMU_PID_FILE"; capture_independent_qemu_identity || fail qemu-identity
    for ((step=0; step<100; step++)); do [ -S "$QMP_SOCKET" ] && break; running_shell_job "$QPID" || break; /bin/sleep 0.05; done
    [ -S "$QMP_SOCKET" ] && [ ! -L "$QMP_SOCKET" ] || fail qmp-socket; /bin/chmod 600 "$QMP_SOCKET"
    [ "$(/usr/bin/stat -f '%u:%Lp' "$QMP_SOCKET")" = "$(/usr/bin/id -u):600" ] || fail qmp-privacy
    socket_before="$(socket_identity "$QMP_SOCKET")"; "$NC" -U "$QMP_SOCKET" < "$QMP_FIFO" 8>&- 9>&- > "$QMP_LOG" 2> "$QMP_ERROR" & QMP_PID=$!
    wait_for_qmp_greeting; qmp_send qmp_capabilities capabilities; wait_for_qmp_response capabilities
    wait_for_marker_count "$AUTOLOGIN_MARKER" 1 || fail autologin
    exec 8> "$SERIAL_FIFO"
    token="m3-abi-matrix-$smp-$$-$(/bin/date +%s)-$RANDOM"
    printf 'stty -echo\n' >&8
    printf "cat > /root/m3-abi-matrix.sh <<'M3_ABI_MATRIX_EOF'\n" >&8; /bin/cat "$GUEST_SHELL" >&8
    printf '\nM3_ABI_MATRIX_EOF\nchmod 700 /root/m3-abi-matrix.sh; /bin/bash /root/m3-abi-matrix.sh %s %s\n' "$smp" "$token" >&8
    abi_wait_prefix "M3_SELFTEST_READY token=$token " ready
    abi_validate_ready "$ready" "$token" "$smp" || fail ready
    printf 'GO %s\n' "$token" >&8
    for ((cpu=0; cpu<smp; cpu++)); do
      for test in ptrace syscall-abi; do
        abi_wait_prefix "M3_SELFTEST_BEGIN token=$token cpu=$cpu test=$test" begin_line
        [ "$begin_line" = "M3_SELFTEST_BEGIN token=$token cpu=$cpu test=$test" ] || fail begin
        abi_wait_prefix "M3_SELFTEST_END token=$token cpu=$cpu test=$test status=0" end_line
        [ "$end_line" = "M3_SELFTEST_END token=$token cpu=$cpu test=$test status=0" ] || fail end
      done
    done
    abi_wait_prefix "M3_SELFTEST_DONE token=$token " done_line; abi_validate_done "$done_line" "$token" "$smp" || fail done
    nonce="$("$OPENSSL" rand -hex 24)"; printf 'VERIFY %s\n' "$nonce" >&8; abi_wait_prefix "M3_SELFTEST_PASS nonce=$nonce " pass; abi_validate_pass "$ready" "$pass" "$nonce" "$smp" || fail pass
    qmp_send query-status verified-status; wait_for_qmp_response verified-status; qmp_running_response verified-status || fail qmp-status; assess_captured_qemu || fail qemu-identity; [ "$(socket_identity "$QMP_SOCKET")" = "$socket_before" ] || fail qmp-socket
    wait_for_marker_count "$ready" 1 || fail duplicate-ready
    wait_for_marker_count "$done_line" 1 || fail duplicate-done
    wait_for_marker_count "$pass" 1 || fail duplicate-pass
    abi_validate_streams "$SERIAL_LOG" "$token" "$smp" || fail streams
    printf 'POWEROFF\n' >&8; local status=0; wait "$QPID" || status=$?; [ "$status" -eq 0 ] || fail "shutdown-$status"
    "$JQ" -e -s 'any(.[]; .event? == "SHUTDOWN" and .data.guest == true and .data.reason == "guest-shutdown")' "$QMP_LOG" >/dev/null || fail clean-shutdown
    terminate_owned_jobs || fail qemu-cleanup; exec 8>&-; exec 9>&-
    remove_runtime_object "$SERIAL_FIFO" fifo || fail serial-fifo-cleanup
    remove_runtime_object "$QMP_FIFO" fifo || fail qmp-fifo-cleanup
    remove_runtime_object "$QMP_SOCKET" socket || fail qmp-socket-cleanup
    remove_runtime_object "$QEMU_PID_FILE" file || fail pid-file-cleanup
    SERIAL_FIFO=""; QMP_FIFO=""; QMP_SOCKET=""; QEMU_PID_FILE=""
    [ -z "$(lsof_openers "$CURRENT_OVERLAY")" ] || fail overlay-open
    remove_runtime_object "$CURRENT_OVERLAY" file || fail overlay-cleanup
    for ((cpu=0; cpu<smp; cpu++)); do
      for test in ptrace syscall-abi; do
        tap="$count_dir/cpu-$cpu-$test.tap"; summary="$count_dir/cpu-$cpu-$test.json"
        abi_extract_tap "M3_SELFTEST_BEGIN token=$token cpu=$cpu test=$test" "M3_SELFTEST_END token=$token cpu=$cpu test=$test status=0" "$tap" || fail tap-boundary
        [ -s "$tap" ] || fail empty-tap; abi_validate_tap "$test" "$tap" "$summary" || fail "tap-$cpu-$test"
        shape="$("$JQ" -c '{plan,pass,skip,fail}' "$summary")"
        "$JQ" -n --arg file "$summary" --arg tap "$tap" --argjson cpu "$cpu" --arg test "$test" --slurpfile result "$summary" \
            '$result[0] + {cpu:$cpu,test:$test,tap:$tap,file:$file}' > "$summary.tmp"
        /bin/mv -f -- "$summary.tmp" "$summary"
        if [ "$test" = ptrace ]; then
            [ -n "$ptrace_shape" ] || ptrace_shape="$shape"
            [ "$ptrace_shape" = "$shape" ] || fail ptrace-shape
        else
            [ -n "$syscall_shape" ] || syscall_shape="$shape"
            [ "$syscall_shape" = "$shape" ] || fail syscall-shape
        fi
      done
    done
    final_snapshot="$(snapshot_protected)"; [ "$final_snapshot" = "$BASELINE_SNAPSHOT" ] || fail protected-inputs; INPUTS_VERIFIED=true
    stream_json="$("$JQ" -s '.' "$count_dir"/cpu-*.json)"
    "$JQ" -n --arg scope "bounded arm64 combined ABI matrix" --argjson smp "$smp" --arg token "$token" --arg ready "$ready" --arg done "$done_line" --arg pass "$pass" --arg pid "$CAPTURED_QEMU_PID" --arg start "$CAPTURED_QEMU_START" --arg socket "$socket_before" --argjson streams "$stream_json" --argjson before "$BASELINE_SNAPSHOT" --argjson after "$final_snapshot" --arg run "$count_dir" '
      {schema_version:1,scope:$scope,smp:$smp,pass:true,sample_id:$token,protocol:{ready:$ready,done:$done,pass:$pass,unprivileged_uid:65534,expected_streams:(2*$smp),tests_per_cpu:["ptrace","syscall-abi"]},streams:$streams,aggregate:{plan:($streams|map(.plan)|add),pass:($streams|map(.pass)|add),skip:($streams|map(.skip)|add),fail:($streams|map(.fail)|add)},qemu:{pid:$pid,start:$start,same_process:true,same_qmp_socket:true,socket_identity:$socket},run_directory:$run,safety:{overlay_removed:true,build_disk_readonly:true,protected_inputs_unchanged:true},protected_inputs:{before:$before,after:$after}}' > "$count_dir/evidence.json"
}

main() {
    [ "$#" = 0 ] || fail arguments; [ "$(/usr/bin/id -u)" -ne 0 ] || fail host-root
    [ "$MEM" = 2G ] || fail memory; case "$LAUNCH_TIMEOUT" in ''|*[!0-9]*|0*) fail timeout;; esac
    [ "$LAUNCH_TIMEOUT" -ge 60 ] && [ "$LAUNCH_TIMEOUT" -le 420 ] || fail timeout
    abi_parse_counts "$SMP_LIST" || fail "SMP_LIST must contain unique supported counts"
    CONTROL_STEPS=$((LAUNCH_TIMEOUT * 10))
    for tool in "$QEMU" "$QEMU_IMG" "$TIMEOUT" "$NC" "$JQ" "$AWK" "$LSOF" "$OPENSSL"; do case "$tool" in /*) ;; *) fail tool-path;; esac; [ -x "$tool" ] && [ ! -u "$tool" ] && [ ! -g "$tool" ] || fail "tool-$tool"; done
    validate_macos_system_ps "$PS" || fail ps
    QEMU="$(/bin/realpath "$QEMU")"; QEMU_IMG="$(/bin/realpath "$QEMU_IMG")"; TIMEOUT="$(/bin/realpath "$TIMEOUT")"; NC="$(/bin/realpath "$NC")"; JQ="$(/bin/realpath "$JQ")"; AWK="$(/bin/realpath "$AWK")"; LSOF="$(/bin/realpath "$LSOF")"; OPENSSL="$(/bin/realpath "$OPENSSL")"
    require_safe_input "$KVER_FILE"; KVER="$(/bin/cat "$KVER_FILE")"
    case "$KVER" in ''|.|..|*/*|*[!A-Za-z0-9.+_~-]*) fail "unsafe KVER";; esac
    case "$KVER" in *asahi*) ;; *) fail kernel;; esac
    KERNEL="$OUT/Image-$KVER"; INITRD="$OUT/initrd.img-$KVER"
    for input in "$KERNEL" "$INITRD" "$ROOTFS" "$BUILD_DISK" "$HARNESS" "$GUEST_SHELL" "$TAP_VALIDATOR"; do require_safe_input "$input"; done
    PROTECTED_NAMES=(kver kernel initrd rootfs build_disk harness guest_shell tap_validator reboot_library extracted_library qemu qemu_img timeout nc jq awk lsof ps openssl)
    PROTECTED_PATHS=("$KVER_FILE" "$KERNEL" "$INITRD" "$ROOTFS" "$BUILD_DISK" "$HARNESS" "$GUEST_SHELL" "$TAP_VALIDATOR" "$ABI_MATRIX_REUSE" "$ABI_MATRIX_DEFS" "$QEMU" "$QEMU_IMG" "$TIMEOUT" "$NC" "$JQ" "$AWK" "$LSOF" "$PS" "$OPENSSL")
    for input in "${PROTECTED_PATHS[@]}"; do require_safe_input "$input"; done
    /bin/mkdir "$LOCK_DIR" 2>/dev/null || fail lock; LOCK_ACQUIRED=true; LOCK_TOKEN="$$:$(/bin/date +%s):$RANDOM"; LOCK_OWNER="$LOCK_DIR/owner.$$"; printf '%s\n' "$LOCK_TOKEN" > "$LOCK_OWNER"
    [ -z "$(lsof_openers "$ROOTFS")" ] || fail rootfs-open; [ -z "$(lsof_openers "$BUILD_DISK")" ] || fail build-open
    [ "$(/usr/bin/shasum -a 256 "$ABI_MATRIX_REUSE")" = "$ABI_MATRIX_REUSE_HASH" ] || fail "reboot library changed"
    /usr/bin/awk '$0 == "# Main program." {exit} {print}' "$ABI_MATRIX_REUSE" | /usr/bin/cmp -s - "$ABI_MATRIX_DEFS" || fail "extracted library changed"
    BASELINE_SNAPSHOT="$(snapshot_protected)"; BASELINE_IDENTITIES="$(snapshot_identities)"; PROTECTED_WINDOW_STARTED=true; INPUTS_VERIFIED=true; printf '%s\n' "$BASELINE_SNAPSHOT" > "$RUN_DIR/protected-before.json"
    ulimit -f 262144
    for smp in "${requested_args[@]}"; do matrix_run_count "$smp"; done
    requested_json="$("$JQ" -n --args '$ARGS.positional | map(tonumber)' -- "${requested_args[@]}")"
    results_json="$("$JQ" -s '.' "$RUN_DIR"/run-*/evidence.json)"
    "$JQ" -n --arg scope "bounded arm64 combined ABI matrix" --arg run "$RUN_DIR" --argjson requested "$requested_json" --argjson results "$results_json" '{schema_version:1,scope:$scope,requested_smp:$requested,all_pass:(($results|length)==($requested|length) and all($requested[]; . as $s | any($results[]; .smp == $s and .pass == true))),results:$results,run_directory:$run}' > "$RUN_DIR/manifest.json"
    "$JQ" -e '.all_pass == true' "$RUN_DIR/manifest.json" >/dev/null || fail incomplete-matrix
    cleanup 0 || fail cleanup; trap - EXIT INT TERM HUP; echo "ABI matrix manifest: $RUN_DIR/manifest.json"
}
if [ "${ABI_MATRIX_SOURCE_ONLY:-0}" != 1 ]; then main "$@"; fi

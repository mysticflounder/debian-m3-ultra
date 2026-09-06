#!/bin/bash
# Same-QEMU-process, same-configuration HVF internal snapshot witness.
# SMP_LIST='1' ./scripts/save-restore-vm.sh is the first smoke test.
# Fixed 2G guest RAM; one 4GiB-bounded disposable overlay; Asahi builder kernel.
set -euo pipefail
umask 077
SR_HERE="$(cd "$(/usr/bin/dirname "$0")/.." && pwd -P)"
SR_REUSE="$SR_HERE/scripts/reboot-vm.sh"
SR_SOURCE="$SR_HERE/scripts/arm64-save-restore.c"
SR_HARNESS="$SR_HERE/scripts/save-restore-vm.sh"
[ -f "$SR_REUSE" ] && [ ! -L "$SR_REUSE" ] || exit 1
[ ! -L "$SR_HERE/out" ] || exit 1
/bin/mkdir -p "$SR_HERE/out"
[ "$(cd "$SR_HERE/out" && pwd -P)" = "$SR_HERE/out" ] || exit 1
SR_BOOT="$(/usr/bin/mktemp -d "$SR_HERE/out/save-restore-matrix.XXXXXX")"
SR_DEFS="$SR_BOOT/reboot-definitions.sh"
SR_ORIGINAL_HASH="$(/usr/bin/shasum -a 256 "$SR_REUSE")"
# Reuse the established safety implementation, without executing its main.
# A retained regular file works on macOS Bash 3.2 (source /dev/fd does not).
[ "$(/usr/bin/awk '$0 == "# Main program." {n++} END {print n+0}' "$SR_REUSE")" = 1 ] || exit 1
/usr/bin/awk '$0 == "# Main program." {exit} {print}' "$SR_REUSE" > "$SR_DEFS"
[ -s "$SR_DEFS" ] && [ -f "$SR_DEFS" ] && [ ! -L "$SR_DEFS" ] || exit 1
[ "$(/usr/bin/shasum -a 256 "$SR_REUSE")" = "$SR_ORIGINAL_HASH" ] || exit 1
QEMU="${QEMU:-$SR_HERE/out/qemu-fork-pmintenclr-build/qemu-system-aarch64}"
MEM="${MEM:-2G}"
source "$SR_DEFS"
HARNESS="$SR_HARNESS"
RUN_DIR="$SR_BOOT"

sr_request() {
    local command=$1 id=$2 arguments=${3:-'{}'}
    "$JQ" -cn --arg command "$command" --arg id "$id" --argjson arguments "$arguments" \
        '{execute:$command,id:$id,arguments:$arguments}' >&9
    wait_for_qmp_response "$id" || fail "QMP request failed: $id ($command); see $QMP_LOG"
}

# Output running/concluded, rejecting missing/duplicate jobs, wrong job type,
# malformed responses and any asynchronous error, including at conclusion.
sr_job_state() {
    local response=$1 job=$2 kind=$3
    "$JQ" -er -s --arg response "$response" --arg job "$job" --arg kind "$kind" '
      [.[] | select(.id? == $response)] as $r |
      if ($r|length) != 1 or ($r[0]|has("error")) or ($r[0].return|type) != "array"
      then error("invalid query-jobs response") else $r[0].return end |
      map(select(.id == $job)) |
      if length != 1 or .[0].type != $kind or (.[0]|has("error"))
      then error("missing, duplicate, wrong-type or failed snapshot job")
      elif .[0].status == "concluded" then "concluded"
      else .[0].status end' "$QMP_LOG"
}

sr_snapshot() {
    local kind=$1 job=$2 step state args
    args="$("$JQ" -cn --arg job "$job" '{"job-id":$job,tag:"baseline",vmstate:"root-state",devices:["root-state"]}')"
    sr_request "$kind" "${job}-start" "$args"
    for ((step=0; step<CONTROL_STEPS; step++)); do
        sr_request query-jobs "${job}-query-${step}"
        state="$(sr_job_state "${job}-query-${step}" "$job" "$kind")" || fail "snapshot job failed: $job"
        case "$state" in
            concluded)
                sr_request job-dismiss "${job}-dismiss" "$("$JQ" -cn --arg id "$job" '{id:$id}')"
                return 0 ;;
            created|running|waiting|pending) ;;
            *) fail "unexpected snapshot job state: $state" ;;
        esac
        /bin/sleep 0.1
    done
    fail "snapshot job did not conclude: $job"
}

sr_complete_prefix_lines() {
    local prefix=$1 line
    # awk consumes an unterminated EOF record: snapshotting that partial marker
    # would make the subsequent exact-marker wait stale forever. read succeeds
    # only for complete newline-terminated records, even while QEMU appends.
    while IFS= read -r line; do
        line="${line%$'\r'}"
        case "$line" in "$prefix"*) printf '%s\n' "$line" ;; esac
    done < "$SERIAL_LOG"
    return 0
}

sr_wait_prefix() {
    local prefix=$1 step
    for ((step=0; step<CONTROL_STEPS; step++)); do
        if /usr/bin/grep -q '^M3_SR_FAIL ' "$SERIAL_LOG"; then fail "guest witness failed; see $SERIAL_LOG"; fi
        SR_LINE="$(sr_complete_prefix_lines "$prefix")"
        if [ -n "$SR_LINE" ]; then
            case "$SR_LINE" in *$'\n'*) fail "duplicate guest witness: $prefix" ;; esac
            wait_for_marker_count "$SR_LINE" 1 || fail "non-exact guest witness: $prefix"
            return 0
        fi
        running_shell_job "$QPID" || fail "QEMU exited before $prefix"
        /bin/sleep 0.1
    done
    fail "timeout waiting for $prefix"
}

sr_validate_pass() {
    local ready=$1 pass=$2 nonce=$3 smp=$4
    [[ "$ready" =~ ^M3_SR_READY\ token=[A-Za-z0-9-]+\ pid=[0-9]+\ boot=[0-9a-f-]+\ cpus=$smp$ ]] &&
        [ "$pass" = "M3_SR_PASS nonce=$nonce ${ready#M3_SR_READY } ram=baseline disk=baseline timer=expired monotonic=progress" ]
}

sr_run_count() {
    local smp=$1 socket_before ready pass token nonce step status info final_snapshot
    COUNT_DIR="$RUN_DIR/smp-$smp"
    /bin/mkdir -m 700 "$COUNT_DIR"
    CURRENT_OVERLAY="$COUNT_DIR/root.qcow2"
    OVERLAY_PATHS+=("$CURRENT_OVERLAY")
    SERIAL_FIFO="$COUNT_DIR/serial.in"; SERIAL_LOG="$COUNT_DIR/serial.raw.log"
    QMP_FIFO="$COUNT_DIR/qmp.in"; QMP_SOCKET="$COUNT_DIR/qmp.sock"
    QMP_LOG="$COUNT_DIR/qmp.events.jsonl"; QMP_ERROR="$COUNT_DIR/qmp.stderr.log"
    QEMU_PID_FILE="$COUNT_DIR/qemu.pid"
    CAPTURED_QEMU_PID=""; CAPTURED_QEMU_START=""; CAPTURED_QEMU_COMMAND=""
    CAPTURED_QEMU_UID=""; CAPTURED_PID_FILE_IDENTITY=""; CAPTURE_STATE=uncaptured
    QEMU_CHILD_SAFELY_GONE=false; QEMU_LAUNCH_ATTEMPTED=false; INPUTS_VERIFIED=false
    verify_protected || fail "protected inputs changed before overlay creation"
    # Enough headroom for the full 2GiB RAM image plus root changes and metadata.
    [ "$(/bin/df -k "$COUNT_DIR" | "$AWK" 'END {print $4}')" -ge 6291456 ] || fail "need 6GiB free before each snapshot run"
    "$QEMU_IMG" create -q -f qcow2 -F raw -b "$ROOTFS" "$CURRENT_OVERLAY"
    /bin/chmod 600 "$CURRENT_OVERLAY"
    info="$("$QEMU_IMG" info --output=json "$CURRENT_OVERLAY")"
    "$JQ" -e --arg root "$ROOTFS" '.format == "qcow2" and .["backing-filename"] == $root and .["backing-filename-format"] == "raw"' <<< "$info" >/dev/null || fail "overlay backing contract"
    /usr/bin/mkfifo -m 600 "$SERIAL_FIFO" "$QMP_FIFO"
    : > "$SERIAL_LOG"; : > "$QMP_LOG"; : > "$QMP_ERROR"; : > "$QEMU_PID_FILE"
    exec 8<> "$SERIAL_FIFO"; exec 9<> "$QMP_FIFO"
    ARGS=(-M virt,highmem=on -accel hvf,kernel-irqchip=on -cpu host
        -smp "$smp,sockets=1,cores=$smp,threads=1" -m 2G
        -kernel "$KERNEL" -initrd "$INITRD"
        -append 'root=/dev/vda rootfstype=ext4 rw console=ttyAMA0 systemd.unit=multi-user.target systemd.mask=m3-build.service'
        -drive "if=virtio,file=$CURRENT_OVERLAY,format=qcow2,cache=none,node-name=root-state"
        -nic none -display none -monitor none -serial stdio
        -qmp "unix:$QMP_SOCKET,server=on,wait=off" -nodefaults)
    "$JQ" -n --args '$ARGS.positional' -- "$QEMU" "${ARGS[@]}" > "$COUNT_DIR/qemu-argv.json"
    verify_protected || fail "protected inputs changed before launch"
    echo "snapshot probe: Asahi builder kernel $KVER, $smp vCPUs, 2G RAM -> $COUNT_DIR"
    /usr/bin/env -i PATH="$PATH" TMPDIR="$COUNT_DIR" HOME="$COUNT_DIR" \
        "$TIMEOUT" --foreground --signal=TERM --kill-after=10 "$LAUNCH_TIMEOUT" \
        /bin/sh -c 'printf "%s\n" "$$" > "$1" || exit 125; shift; exec "$@"' \
        save-restore-qemu-launch "$QEMU_PID_FILE" "$QEMU" "${ARGS[@]}" <&8 > "$SERIAL_LOG" 2>&1 &
    QPID=$!; QEMU_LAUNCH_ATTEMPTED=true
    for ((step=0; step<100; step++)); do
        [ -s "$QEMU_PID_FILE" ] && break
        running_shell_job "$QPID" || break
        /bin/sleep 0.05
    done
    require_safe_input "$QEMU_PID_FILE"
    IFS= read -r QEMU_CHILD_PID < "$QEMU_PID_FILE" || fail "missing QEMU child PID"
    capture_independent_qemu_identity || fail "cannot capture child identity"
    for ((step=0; step<100; step++)); do
        [ -S "$QMP_SOCKET" ] && break
        running_shell_job "$QPID" || break
        /bin/sleep 0.05
    done
    [ ! -L "$QMP_SOCKET" ] && [ -S "$QMP_SOCKET" ] || fail "QMP socket missing"
    /bin/chmod 600 "$QMP_SOCKET"
    [ "$(/usr/bin/stat -f '%u:%Lp' "$QMP_SOCKET")" = "$(/usr/bin/id -u):600" ] || fail "QMP privacy"
    socket_before="$(socket_identity "$QMP_SOCKET")" || fail "QMP identity"
    "$NC" -U "$QMP_SOCKET" < "$QMP_FIFO" > "$QMP_LOG" 2> "$QMP_ERROR" &
    QMP_PID=$!
    wait_for_qmp_greeting || fail "QMP greeting"
    sr_request qmp_capabilities capabilities
    sr_request query-block root-node
    "$JQ" -e -s 'any(.[]; .id? == "root-node" and ([.return[] | select(.inserted["node-name"] == "root-state" and .inserted.ro == false)] | length) == 1)' "$QMP_LOG" >/dev/null || fail "root-state node missing"
    wait_for_marker_count "$AUTOLOGIN_MARKER" 1 || fail "serial autologin"
    token="m3-sr-$smp-$$-$(/bin/date +%s)-$RANDOM"
    printf 'stty -echo\n' >&8
    printf "cat > /root/m3-save-restore.c <<'M3_SR_C_EOF'\n" >&8
    /bin/cat "$SR_SOURCE" >&8
    printf '\nM3_SR_C_EOF\n' >&8
    printf 'cc -O2 -Wall -Wextra -Werror -o /root/m3-save-restore /root/m3-save-restore.c && /root/m3-save-restore %s %s\n' "$smp" "$token" >&8
    sr_wait_prefix "M3_SR_READY token=$token "
    ready="$SR_LINE"
    [[ "$ready" =~ ^M3_SR_READY\ token=[A-Za-z0-9-]+\ pid=[0-9]+\ boot=[0-9a-f-]+\ cpus=$smp$ ]] || fail "malformed READY"
    sr_request stop stop-before-save
    sr_snapshot snapshot-save save-baseline
    sr_request cont resume-after-save
    printf 'MUTATE %s\n' "$token" >&8
    wait_for_marker_count "M3_SR_MUTATED token=$token" 1 || fail "mutation not acknowledged"
    sr_request stop stop-before-load
    sr_snapshot snapshot-load load-baseline
    # Fresh challenge is generated only after load has completed and dismissed.
    nonce="$(/usr/bin/openssl rand -hex 24)"
    sr_request cont resume-after-load
    printf 'VERIFY %s\n' "$nonce" >&8
    sr_wait_prefix "M3_SR_PASS nonce=$nonce "
    pass="$SR_LINE"
    sr_validate_pass "$ready" "$pass" "$nonce" "$smp" || fail "restored helper/boot identity or pass contract changed"
    for ((step=0; step<smp; step++)); do
        wait_for_marker_count "M3_SR_CPU nonce=$nonce cpu=$step checksum=d9ef6e3b3f70baaf" 1 || fail "missing CPU workload $step"
    done
    sr_request query-status verified-status
    qmp_running_response verified-status || fail "restored guest not running"
    assess_captured_qemu || fail "QEMU process identity changed"
    [ "$(socket_identity "$QMP_SOCKET")" = "$socket_before" ] || fail "QMP socket identity changed"
    printf 'POWEROFF\n' >&8
    status=0; wait "$QPID" || status=$?
    [ "$status" -eq 0 ] || fail "QEMU exit status $status"
    "$JQ" -e -s 'any(.[]; .event? == "SHUTDOWN" and .data.guest == true and .data.reason == "guest-shutdown")' "$QMP_LOG" >/dev/null || fail "missing clean guest shutdown"
    terminate_owned_jobs || fail "child cleanup"
    exec 8>&-; exec 9>&-
    remove_runtime_object "$SERIAL_FIFO" fifo || fail "serial FIFO cleanup"
    remove_runtime_object "$QMP_FIFO" fifo || fail "QMP FIFO cleanup"
    remove_runtime_object "$QMP_SOCKET" socket || fail "QMP socket cleanup"
    remove_runtime_object "$QEMU_PID_FILE" file || fail "PID file cleanup"
    SERIAL_FIFO=""; QMP_FIFO=""; QMP_SOCKET=""; QEMU_PID_FILE=""
    [ -z "$(lsof_openers "$CURRENT_OVERLAY")" ] || fail "overlay still open"
    remove_runtime_object "$CURRENT_OVERLAY" file || fail "overlay cleanup"
    final_snapshot="$(snapshot_protected)" || fail "final protected hashes"
    [ "$final_snapshot" = "$BASELINE_SNAPSHOT" ] || fail "protected inputs changed"
    INPUTS_VERIFIED=true
    "$JQ" -n --argjson smp "$smp" --arg ready "$ready" --arg pass "$pass" --arg nonce "$nonce" \
        --arg pid "$CAPTURED_QEMU_PID" --arg start "$CAPTURED_QEMU_START" --arg socket "$socket_before" \
        --argjson before "$BASELINE_SNAPSHOT" --argjson after "$final_snapshot" \
        '{smp:$smp,pass:true,scope:"same-process same-configuration HVF internal snapshot",kernel_role:"Asahi builder",guest:{ready:$ready,pass:$pass,fresh_challenge:$nonce},qemu:{pid:$pid,start:$start,same_process:true},qmp:{socket_identity:$socket,same_socket:true,save_job:"save-baseline",load_job:"load-baseline",jobs_completed_and_dismissed:true},safety:{overlay_removed:true,protected_inputs_unchanged:true},protected_inputs:{before:$before,after:$after}}' > "$COUNT_DIR/evidence.json"
}

sr_main() {
    [ "$#" -eq 0 ] || fail "no command-line arguments accepted"
    [ "$MEM" = 2G ] || fail "snapshot experiment requires MEM=2G"
    case "$LAUNCH_TIMEOUT" in ''|*[!0-9]*|0|0*) fail "invalid LAUNCH_TIMEOUT" ;; esac
    [ "$LAUNCH_TIMEOUT" -le 900 ] || fail "LAUNCH_TIMEOUT exceeds 900 seconds"
    CONTROL_STEPS=$((LAUNCH_TIMEOUT * 10))
    case "$SMP_LIST" in *$'\n'*|*$'\r'*) fail "SMP_LIST must be one line" ;; esac
    read -r -a SMP_COUNTS <<< "$SMP_LIST"
    [ "${#SMP_COUNTS[@]}" -gt 0 ] || fail "empty SMP_LIST"
    local smp seen=' ' tool input
    for smp in "${SMP_COUNTS[@]}"; do
        case "$smp" in 1|8|16|24|32) ;; *) fail "SMP counts supported: 1 8 16 24 32" ;; esac
        case "$seen" in *" $smp "*) fail "duplicate SMP count" ;; esac
        seen="$seen$smp "
    done
    [ "$(/usr/bin/id -u)" -ne 0 ] || fail "refusing host root"
    for tool in "$QEMU" "$QEMU_IMG" "$TIMEOUT" "$NC" "$JQ" "$AWK" "$LSOF"; do
        case "$tool" in /*) ;; *) fail "executable path must be absolute" ;; esac
        [ -x "$tool" ] && [ ! -u "$tool" ] && [ ! -g "$tool" ] || fail "unsafe/missing executable $tool"
    done
    validate_macos_system_ps "$PS" || fail "macOS ps safety contract"
    QEMU="$(/bin/realpath "$QEMU")"; QEMU_IMG="$(/bin/realpath "$QEMU_IMG")"
    TIMEOUT="$(/bin/realpath "$TIMEOUT")"; NC="$(/bin/realpath "$NC")"
    JQ="$(/bin/realpath "$JQ")"; AWK="$(/bin/realpath "$AWK")"; LSOF="$(/bin/realpath "$LSOF")"
    require_safe_input "$KVER_FILE"
    KVER="$(/bin/cat "$KVER_FILE")"
    case "$KVER" in ''|*/*|*[!A-Za-z0-9.+_~-]*) fail "unsafe KVER" ;; esac
    case "$KVER" in *asahi*) ;; *) fail "requires Asahi builder kernel" ;; esac
    KERNEL="$OUT/Image-$KVER"; INITRD="$OUT/initrd.img-$KVER"
    PROTECTED_NAMES=(kver kernel initrd rootfs harness witness reboot_library extracted_library qemu qemu_img timeout nc jq awk lsof ps)
    PROTECTED_PATHS=("$KVER_FILE" "$KERNEL" "$INITRD" "$ROOTFS" "$HARNESS" "$SR_SOURCE" "$SR_REUSE" "$SR_DEFS" "$QEMU" "$QEMU_IMG" "$TIMEOUT" "$NC" "$JQ" "$AWK" "$LSOF" "$PS")
    for input in "${PROTECTED_PATHS[@]}"; do require_safe_input "$input"; done
    [ "$(/usr/bin/shasum -a 256 "$SR_REUSE")" = "$SR_ORIGINAL_HASH" ] || fail "reuse source changed"
    /usr/bin/awk '$0 == "# Main program." {exit} {print}' "$SR_REUSE" | /usr/bin/cmp -s - "$SR_DEFS" || fail "extracted helper differs from source"
    /bin/mkdir "$LOCK_DIR" 2>/dev/null || fail "another probe owns rootfs lock"
    LOCK_ACQUIRED=true; LOCK_TOKEN="$$:$(/bin/date +%s):$RANDOM"; LOCK_OWNER="$LOCK_DIR/owner.$$"
    printf '%s\n' "$LOCK_TOKEN" > "$LOCK_OWNER"
    [ -z "$(lsof_openers "$ROOTFS")" ] || fail "rootfs already open"
    # Bash ulimit -f uses 1024-byte blocks on this supported macOS Bash.
    ulimit -f 4194304
    BASELINE_SNAPSHOT="$(snapshot_protected)" || fail "baseline hashes"
    BASELINE_IDENTITIES="$(snapshot_identities)" || fail "baseline identities"
    PROTECTED_WINDOW_STARTED=true; INPUTS_VERIFIED=true
    printf '%s\n' "$BASELINE_SNAPSHOT" > "$RUN_DIR/protected-before.json"
    for smp in "${SMP_COUNTS[@]}"; do sr_run_count "$smp"; done
    "$JQ" -s '{schema_version:1,all_pass:all(.[];.pass),results:.}' "$RUN_DIR"/smp-*/evidence.json > "$RUN_DIR/manifest.json"
    cleanup 0 || fail "final cleanup"
    trap - EXIT INT TERM HUP
    echo "snapshot manifest: $RUN_DIR/manifest.json"
}

if [ "${SAVE_RESTORE_SOURCE_ONLY:-0}" != 1 ]; then sr_main "$@"; fi

#!/bin/bash
# Current-fork raw EL1 capture; lifecycle follows abi-matrix-vm.sh.
set -euo pipefail
umask 077
EL1_HERE="$(cd "$(/usr/bin/dirname "$0")/.." && pwd -P)"
EL1_REUSE="$EL1_HERE/scripts/reboot-vm.sh"
[ -f "$EL1_REUSE" ] && [ ! -L "$EL1_REUSE" ] || exit 1
[ ! -L "$EL1_HERE/out" ] || exit 1
/bin/mkdir -p "$EL1_HERE/out"
[ "$(cd "$EL1_HERE/out" && pwd -P)" = "$EL1_HERE/out" ] || exit 1
EL1_DEFS_DIR="$(/usr/bin/mktemp -d "$EL1_HERE/out/el1-fork.XXXXXX")"
EL1_DEFS="$EL1_DEFS_DIR/reboot-definitions.sh"
EL1_REUSE_HASH="$(/usr/bin/shasum -a 256 "$EL1_REUSE")"
[ "$(/usr/bin/awk '$0 == "# Main program." {n++} END {print n+0}' "$EL1_REUSE")" = 1 ] || exit 1
/usr/bin/awk '$0 == "# Main program." {exit} {print}' "$EL1_REUSE" > "$EL1_DEFS"
[ -s "$EL1_DEFS" ] && [ ! -L "$EL1_DEFS" ] || exit 1
[ "$(/usr/bin/shasum -a 256 "$EL1_REUSE")" = "$EL1_REUSE_HASH" ] || exit 1
QEMU="${QEMU:-$EL1_HERE/out/qemu-fork-pmintenclr-build/qemu-system-aarch64}"
MEM="${MEM:-2G}"
SMP_LIST="${SMP_LIST:-1}"
LAUNCH_TIMEOUT="${LAUNCH_TIMEOUT:-420}"
HOST_JSON_INPUT="${HOST_JSON:-}"
source "$EL1_DEFS"
RUN_DIR="$EL1_DEFS_DIR"
HARNESS="$HERE/scripts/el1-fork-vm.sh"
GUEST_SHELL="$HERE/scripts/arm64-el1-fork-guest.sh"
PARSER="$HERE/scripts/el1-fork-parser.sh"
COMPARATOR="$HERE/scripts/el1-probe-compare.sh"
MODULE_SOURCE="$HERE/scripts/arm64-el1-probe.c"
MODULE_MAKEFILE="$HERE/scripts/arm64-el1-probe.Makefile"
BUILD_DISK="$OUT/build.ext4"
OPENSSL=/usr/bin/openssl
EL1_FORK_PARSER_SOURCE_ONLY=1 source "$PARSER"

fail() { echo "EL1 fork: $*" >&2; exit 1; }
sha256_file() {
    local output digest remainder
    output="$("$OPENSSL" dgst -sha256 -r "$1")" || return 1
    IFS=' ' read -r digest remainder <<< "$output" || return 1
    case "$digest" in ''|*[!0-9a-f]*) return 1;; esac
    [ "${#digest}" -eq 64 ] || return 1
    printf '%s\n' "$digest"
}
parse_counts() {
    local count seen=' '
    case "$1" in ''|*$'\n'*|*$'\r'*) return 1;; esac
    read -r -a requested_args <<< "$1"
    [ "${#requested_args[@]}" -gt 0 ] || return 1
    for count in "${requested_args[@]}"; do
        case "$count" in 1|8|16|24|32) ;; *) return 1;; esac
        case "$seen" in *" $count "*) return 1;; esac
        seen="$seen$count "
    done
}
el1_complete_lines() {
    local prefix=$1 line
    while IFS= read -r line; do
        line="${line%$'\r'}"
        case "$line" in "$prefix"*) printf '%s\n' "$line";; esac
    done < "$SERIAL_LOG"
}
el1_wait_marker() {
    local wanted=$1 step line
    for ((step=0; step<CONTROL_STEPS; step++)); do
        /usr/bin/grep -q '^EL1_FORK_GUEST_ERROR ' "$SERIAL_LOG" && fail "guest error; see $SERIAL_LOG"
        line="$(el1_complete_lines "$wanted")"
        if [ -n "$line" ]; then
            [ "$line" = "$wanted" ] || fail "duplicate or malformed marker: $wanted"
            wait_for_marker_count "$wanted" 1 || fail "invalid marker: $wanted"
            return 0
        fi
        running_shell_job "$QPID" || fail "guest exited before $wanted"
        /bin/sleep 0.1
    done
    fail "timeout waiting for $wanted"
}
el1_extract_markers() {
    local token=$1 output=$2
    "$AWK" -v begin="EL1_FORK_BEGIN token=$token" -v end="EL1_FORK_END token=$token" '
      {sub(/\r$/, "")}
      $0 == begin {begins++; if (!inside && !closed) {inside=1; next}; bad=1; next}
      $0 == end {ends++; if (inside) {inside=0; closed=1; next}; bad=1; next}
      inside {if ($0 !~ /^EL1_PROBE_/) bad=1; print}
      END {if (begins!=1 || ends!=1 || !closed || inside || bad) exit 1}
    ' "$SERIAL_LOG" > "$output"
}

run_one() {
    local smp=$1 count_dir token socket_before final_snapshot status=0 step
    count_dir="$RUN_DIR/smp-$smp"; /bin/mkdir -m 700 "$count_dir"
    COUNT_DIR="$count_dir"; CURRENT_OVERLAY="$count_dir/root.qcow2"; OVERLAY_PATHS+=("$CURRENT_OVERLAY")
    SERIAL_FIFO="$count_dir/serial.in"; SERIAL_LOG="$count_dir/serial.raw.log"
    QMP_FIFO="$count_dir/qmp.in"; QMP_SOCKET="$count_dir/qmp.sock"
    QMP_LOG="$count_dir/qmp.events.jsonl"; QMP_ERROR="$count_dir/qmp.stderr.log"; QEMU_PID_FILE="$count_dir/qemu.pid"
    CAPTURED_QEMU_PID=""; CAPTURED_QEMU_START=""; CAPTURED_QEMU_COMMAND=""; CAPTURED_QEMU_UID=""; CAPTURED_PID_FILE_IDENTITY=""
    CAPTURE_STATE=uncaptured; QEMU_CHILD_SAFELY_GONE=false; QEMU_LAUNCH_ATTEMPTED=false; INPUTS_VERIFIED=false
    verify_protected || fail "protected inputs changed before $smp"
    [ "$(/bin/df -k "$count_dir" | "$AWK" 'END {print $4}')" -ge 1048576 ] || fail "need 1GiB free"
    "$QEMU_IMG" create -q -f qcow2 -F raw -b "$ROOTFS" "$CURRENT_OVERLAY"; /bin/chmod 600 "$CURRENT_OVERLAY"
    "$JQ" -e --arg root "$ROOTFS" '.format == "qcow2" and .["backing-filename"] == $root and .["backing-filename-format"] == "raw"' < <("$QEMU_IMG" info --output=json "$CURRENT_OVERLAY") >/dev/null || fail overlay
    /usr/bin/mkfifo -m 600 "$SERIAL_FIFO" "$QMP_FIFO"; : > "$SERIAL_LOG"; : > "$QMP_LOG"; : > "$QMP_ERROR"; : > "$QEMU_PID_FILE"
    exec 8<> "$SERIAL_FIFO"; exec 9<> "$QMP_FIFO"
    ARGS=(-M virt,highmem=on -accel hvf,kernel-irqchip=on -cpu host -smp "$smp",sockets=1,cores="$smp",threads=1 -m 2G -kernel "$KERNEL" -initrd "$INITRD"
      -append 'root=/dev/vda rootfstype=ext4 rw console=ttyAMA0 systemd.unit=multi-user.target systemd.mask=m3-build.service'
      -drive "if=virtio,file=$CURRENT_OVERLAY,format=qcow2,cache=none"
      -drive "if=virtio,file=$BUILD_DISK,format=raw,readonly=on,cache=none"
      -drive "if=virtio,file=fat:ro:$HERE/scripts,format=raw,readonly=on"
      -nic none -display none -monitor none -serial stdio -qmp "unix:$QMP_SOCKET,server=on,wait=off" -nodefaults)
    "$JQ" -n --args '$ARGS.positional' -- "$QEMU" "${ARGS[@]}" > "$count_dir/qemu-argv.json"
    [ "$(/usr/bin/shasum -a 256 "$EL1_REUSE")" = "$EL1_REUSE_HASH" ] || fail "reboot library changed"
    /usr/bin/awk '$0 == "# Main program." {exit} {print}' "$EL1_REUSE" | /usr/bin/cmp -s - "$EL1_DEFS" || fail "extracted library changed"
    verify_protected || fail "protected inputs changed before launch"
    echo "booting EL1 fork probe: $smp vCPUs -> $count_dir"
    /usr/bin/env -i PATH="$PATH" LC_ALL=C TMPDIR="$count_dir" "$TIMEOUT" --foreground --signal=TERM --kill-after=10 "$LAUNCH_TIMEOUT" /bin/sh -c 'printf "%s\n" "$$" > "$1" || exit 125; shift; exec "$@"' el1-fork-qemu "$QEMU_PID_FILE" "$QEMU" "${ARGS[@]}" <&8 >"$SERIAL_LOG" 2>&1 &
    QPID=$!; QEMU_LAUNCH_ATTEMPTED=true
    for ((step=0; step<100; step++)); do [ -s "$QEMU_PID_FILE" ] && break; running_shell_job "$QPID" || break; /bin/sleep 0.05; done
    require_safe_input "$QEMU_PID_FILE"; IFS= read -r QEMU_CHILD_PID < "$QEMU_PID_FILE"; capture_independent_qemu_identity || fail qemu-identity
    for ((step=0; step<100; step++)); do [ -S "$QMP_SOCKET" ] && break; running_shell_job "$QPID" || break; /bin/sleep 0.05; done
    [ -S "$QMP_SOCKET" ] && [ ! -L "$QMP_SOCKET" ] || fail qmp-socket; /bin/chmod 600 "$QMP_SOCKET"
    [ "$(/usr/bin/stat -f '%u:%Lp' "$QMP_SOCKET")" = "$(/usr/bin/id -u):600" ] || fail qmp-privacy
    socket_before="$(socket_identity "$QMP_SOCKET")"
    "$NC" -U "$QMP_SOCKET" < "$QMP_FIFO" 8>&- 9>&- > "$QMP_LOG" 2> "$QMP_ERROR" & QMP_PID=$!
    wait_for_qmp_greeting; qmp_send qmp_capabilities capabilities; wait_for_qmp_response capabilities
    wait_for_marker_count "$AUTOLOGIN_MARKER" 1 || fail autologin
    exec 8> "$SERIAL_FIFO"
    token="m3-el1-$smp-$$-$(/bin/date +%s)-$RANDOM"
    printf 'stty -echo\n' >&8
    printf "cat > /root/m3-el1.sh <<'M3_EL1_EOF'\n" >&8; /bin/cat "$GUEST_SHELL" >&8
    printf '\nM3_EL1_EOF\n/bin/bash /root/m3-el1.sh %s %s\n' "$smp" "$token" >&8
    el1_wait_marker "EL1_FORK_READY token=$token smp=$smp"
    printf 'GO %s\n' "$token" >&8
    el1_wait_marker "EL1_FORK_END token=$token"
    el1_wait_marker "EL1_FORK_COMPLETE token=$token smp=$smp"
    qmp_send query-status post-probe; wait_for_qmp_response post-probe
    qmp_running_response post-probe || fail qmp-not-running
    assess_captured_qemu || fail identity-after-probe
    [ "$(socket_identity "$QMP_SOCKET")" = "$socket_before" ] || fail socket-changed
    printf 'POWEROFF\n' >&8
    wait "$QPID" || status=$?; [ "$status" -eq 0 ] || fail "shutdown-$status"
    qmp_guest_shutdown_event || fail clean-shutdown
    terminate_owned_jobs || fail qemu-cleanup; exec 8>&-; exec 9>&-
    remove_runtime_object "$SERIAL_FIFO" fifo || fail serial-fifo-cleanup
    remove_runtime_object "$QMP_FIFO" fifo || fail qmp-fifo-cleanup
    remove_runtime_object "$QMP_SOCKET" socket || fail qmp-socket-cleanup
    remove_runtime_object "$QEMU_PID_FILE" file || fail pid-file-cleanup
    SERIAL_FIFO=""; QMP_FIFO=""; QMP_SOCKET=""; QEMU_PID_FILE=""
    [ -z "$(lsof_openers "$CURRENT_OVERLAY")" ] || fail overlay-open
    remove_runtime_object "$CURRENT_OVERLAY" file || fail overlay-cleanup
    final_snapshot="$(snapshot_protected)"; [ "$final_snapshot" = "$BASELINE_SNAPSHOT" ] || fail protected-inputs
    INPUTS_VERIFIED=true
    el1_extract_markers "$token" "$count_dir/markers.txt" || fail marker-boundary
    parse_probe_json "$smp" "$count_dir/markers.txt" "$count_dir/raw.json" || fail parser
    validate_probe_json "$smp" "$count_dir/raw.json" || fail raw-schema
    "$JQ" --arg run "$count_dir" --arg collected "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" --argjson uid "$(/usr/bin/id -u)" \
      --arg qemu "$QEMU" --arg version "$QEMU_VERSION" --arg sha "$QEMU_SHA256" --slurpfile argv "$count_dir/qemu-argv.json" \
      --arg pid "$CAPTURED_QEMU_PID" --arg start "$CAPTURED_QEMU_START" --arg socket "$socket_before" \
      --argjson before "$BASELINE_SNAPSHOT" --argjson after "$final_snapshot" '
      . + {collected_at:$collected,run:{directory:$run,memory:"2G",
        qemu:{path:$qemu,version:$version,sha256:$sha,argv:$argv[0],pid:$pid,start:$start},
        qmp:{same_socket:true,socket_identity:$socket,clean_guest_shutdown:true},
        safety:{host_uid:$uid,host_privilege_required:false,explicit_disposable_overlay:true,root_backing_opened_via_overlay:true,
          build_drive_read_only:true,source_drive_read_only:true,network_disabled:true,monitor_disabled:true,
          firmware_or_pflash_attached:false,host_devices_attached:false,protected_inputs_unchanged:true,overlay_removed_after_shutdown:true}},
        protected_inputs:{before:$before,after:$after},
        consistency:{configured_cpu_count_matches:((.cpus|length)==.requested_smp),
          observed_cpu_ids_match:([.cpus[].observed_cpu]==[range(0;.requested_smp)]),
          mpidr_values_unique:(([.cpus[].registers.MPIDR_EL1.value]|unique|length)==.requested_smp),
          register_contract_homogeneous:(([.cpus[].registers|del(.MPIDR_EL1)]|unique|length)==1),
          cache_contract_homogeneous:(([.cpus[].cache_registers.entries]|unique|length)==1)}}
    ' "$count_dir/raw.json" > "$count_dir/evidence.json"
    HOST_JSON="$HOST_JSON" REPORT_JSON="$count_dir/host-comparison.json" /bin/bash "$COMPARATOR" "$count_dir/evidence.json"
    "$JQ" -e '.summary.cache_exact == 3 and .summary.cache_mismatch == 0 and .summary.cache_unavailable == 0' "$count_dir/host-comparison.json" >/dev/null || fail cache-comparison
    "$JQ" -e 'all(.consistency[]; . == true)' "$count_dir/evidence.json" >/dev/null || fail inconsistent
}

main() {
    [ "$#" = 0 ] || fail arguments; [ "$(/usr/bin/id -u)" -ne 0 ] || fail host-root
    [ "$MEM" = 2G ] || fail memory; case "$LAUNCH_TIMEOUT" in ''|*[!0-9]*|0*) fail timeout;; esac
    [ "$LAUNCH_TIMEOUT" -ge 60 ] && [ "$LAUNCH_TIMEOUT" -le 420 ] || fail timeout
    parse_counts "$SMP_LIST" || fail "SMP_LIST must contain unique supported counts"
    CONTROL_STEPS=$((LAUNCH_TIMEOUT * 10))
    for tool in "$QEMU" "$QEMU_IMG" "$TIMEOUT" "$NC" "$JQ" "$AWK" "$LSOF" "$OPENSSL"; do
      case "$tool" in /*) ;; *) fail tool-path;; esac
      [ -x "$tool" ] && [ ! -u "$tool" ] && [ ! -g "$tool" ] || fail "tool-$tool"
    done
    validate_macos_system_ps "$PS" || fail ps
    QEMU="$(/bin/realpath "$QEMU")"; QEMU_IMG="$(/bin/realpath "$QEMU_IMG")"; TIMEOUT="$(/bin/realpath "$TIMEOUT")"
    NC="$(/bin/realpath "$NC")"; JQ="$(/bin/realpath "$JQ")"; AWK="$(/bin/realpath "$AWK")"; LSOF="$(/bin/realpath "$LSOF")"; OPENSSL="$(/bin/realpath "$OPENSSL")"
    require_safe_input "$KVER_FILE"; KVER="$(/bin/cat "$KVER_FILE")"
    case "$KVER" in ''|.|..|*/*|*[!A-Za-z0-9.+_~-]*) fail "unsafe KVER";; esac
    case "$KVER" in *asahi*) ;; *) fail kernel;; esac
    KERNEL="$OUT/Image-$KVER"; INITRD="$OUT/initrd.img-$KVER"
    [ -n "$HOST_JSON_INPUT" ] || fail "HOST_JSON must name a fresh host capture"
    HOST_JSON="$(/bin/realpath "$HOST_JSON_INPUT")"
    PROTECTED_NAMES=(kver kernel initrd rootfs build_disk harness guest_shell module_source module_makefile parser comparator host_json reboot_library extracted_library qemu qemu_img timeout nc jq awk lsof ps openssl)
    PROTECTED_PATHS=("$KVER_FILE" "$KERNEL" "$INITRD" "$ROOTFS" "$BUILD_DISK" "$HARNESS" "$GUEST_SHELL" "$MODULE_SOURCE" "$MODULE_MAKEFILE" "$PARSER" "$COMPARATOR" "$HOST_JSON" "$EL1_REUSE" "$EL1_DEFS" "$QEMU" "$QEMU_IMG" "$TIMEOUT" "$NC" "$JQ" "$AWK" "$LSOF" "$PS" "$OPENSSL")
    for input in "${PROTECTED_PATHS[@]}"; do require_safe_input "$input"; done
    "$JQ" -e '.schema_version==1 and .config.status=="ok" and (.feature_registers|length)==14 and all(.feature_registers[];.status=="ok")' "$HOST_JSON" >/dev/null || fail host-capture
    QEMU_VERSION="$("$QEMU" --version)"; QEMU_VERSION="${QEMU_VERSION%%$'\n'*}"
    /bin/mkdir "$LOCK_DIR" 2>/dev/null || fail lock
    LOCK_ACQUIRED=true; LOCK_TOKEN="$$:$(/bin/date +%s):$RANDOM"; LOCK_OWNER="$LOCK_DIR/owner.$$"; printf '%s\n' "$LOCK_TOKEN" > "$LOCK_OWNER"
    [ -z "$(lsof_openers "$ROOTFS")" ] || fail rootfs-open; [ -z "$(lsof_openers "$BUILD_DISK")" ] || fail build-open
    BASELINE_SNAPSHOT="$(snapshot_protected)"; BASELINE_IDENTITIES="$(snapshot_identities)"; PROTECTED_WINDOW_STARTED=true; INPUTS_VERIFIED=true
    printf '%s\n' "$BASELINE_SNAPSHOT" > "$RUN_DIR/protected-before.json"
    QEMU_SHA256="$(sha256_file "$QEMU")"
    ulimit -f 262144
    for smp in "${requested_args[@]}"; do run_one "$smp"; done
    requested_json="$("$JQ" -n --args '$ARGS.positional|map(tonumber)' -- "${requested_args[@]}")"
    results_json="$("$JQ" -s '.' "$RUN_DIR"/smp-*/evidence.json)"
    "$JQ" -n --arg run "$RUN_DIR" --arg host "$HOST_JSON" --arg host_sha "$(sha256_file "$HOST_JSON")" --argjson requested "$requested_json" --argjson results "$results_json" '
      {schema_version:1,scope:"current-fork raw EL1 register/cache matrix",requested_smp:$requested,host:{path:$host,sha256:$host_sha},
       results:$results,run_directory:$run,all_pass:(($results|length)==($requested|length) and all($requested[];. as $s|any($results[];.requested_smp==$s and all(.consistency[];.==true)))
         and ([$results[].cpus[].registers|del(.MPIDR_EL1)]|unique|length)==1 and ([$results[].cpus[].cache_registers.entries]|unique|length)==1)}
    ' > "$RUN_DIR/manifest.json"
    "$JQ" -e '.all_pass==true' "$RUN_DIR/manifest.json" >/dev/null || fail matrix
    cleanup 0 || fail cleanup; trap - EXIT INT TERM HUP
    echo "EL1 fork manifest: $RUN_DIR/manifest.json"
}
if [ "${EL1_FORK_SOURCE_ONLY:-0}" != 1 ]; then main "$@"; fi

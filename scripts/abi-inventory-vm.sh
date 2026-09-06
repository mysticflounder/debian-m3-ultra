#!/bin/bash
# Transport an allowlisted arm64 ABI source inventory through one disposable
# guest.  This is ABI SOURCE INVENTORY ONLY: it is not an ABI test pass.
set -euo pipefail
umask 077

ABI_HERE="$(cd "$(/usr/bin/dirname "$0")/.." && pwd -P)"
ABI_REUSE="$ABI_HERE/scripts/reboot-vm.sh"
ABI_DEFS_DIR=""
ABI_DEFS=""

# Reuse the tested QEMU/HVF, QMP, process-identity, overlay, and protected
# input cleanup definitions without sourcing the reboot main program.
[ -f "$ABI_REUSE" ] && [ ! -L "$ABI_REUSE" ] || exit 1
[ ! -L "$ABI_HERE/out" ] || exit 1
/bin/mkdir -p "$ABI_HERE/out"
[ "$(cd "$ABI_HERE/out" && pwd -P)" = "$ABI_HERE/out" ] || exit 1
ABI_DEFS_DIR="$(/usr/bin/mktemp -d "$ABI_HERE/out/abi-inventory.XXXXXX")"
ABI_DEFS="$ABI_DEFS_DIR/reboot-definitions.sh"
ABI_REUSE_HASH="$(/usr/bin/shasum -a 256 "$ABI_REUSE")"
[ "$(/usr/bin/awk '$0 == "# Main program." {n++} END {print n+0}' "$ABI_REUSE")" = 1 ] || exit 1
/usr/bin/awk '$0 == "# Main program." {exit} {print}' "$ABI_REUSE" > "$ABI_DEFS"
[ -f "$ABI_DEFS" ] && [ ! -L "$ABI_DEFS" ] && [ -s "$ABI_DEFS" ] || exit 1
[ "$(/usr/bin/shasum -a 256 "$ABI_REUSE")" = "$ABI_REUSE_HASH" ] || exit 1

QEMU="${QEMU:-$ABI_HERE/out/qemu-fork-pmintenclr-build/qemu-system-aarch64}"
MEM="${MEM:-2G}"
SMP_LIST="${SMP_LIST:-1}"
LAUNCH_TIMEOUT="${LAUNCH_TIMEOUT:-420}"
source "$ABI_DEFS"
RUN_DIR="$ABI_DEFS_DIR"
HARNESS="$ABI_HERE/scripts/abi-inventory-vm.sh"
GUEST_SHELL="$ABI_HERE/scripts/arm64-abi-inventory-guest.sh"
BUILD_DISK="$ABI_HERE/out/build.ext4"
ABI_OPENSSL=/usr/bin/openssl

# Use the same full-file digest behavior as the selftest harness, including
# explicit failure on a partial digest (build.ext4 is intentionally large).
sha256_file() {
    local output digest remainder
    output="$("$ABI_OPENSSL" dgst -sha256 -r "$1")" || return 1
    IFS=' ' read -r digest remainder <<< "$output" || return 1
    case "$digest" in ''|*[!0-9a-f]*) return 1;; esac
    [ "${#digest}" -eq 64 ] || return 1
    printf '%s\n' "$digest"
}

fail() { echo "abi inventory: $*" >&2; exit 1; }

abi_complete_lines() {
    local prefix=$1 line
    while IFS= read -r line; do
        line="${line%$'\r'}"
        case "$line" in "$prefix"*) printf '%s\n' "$line";; esac
    done < "$2"
}

abi_wait_serial_prefix() {
    local prefix=$1 step line
    for ((step=0; step<CONTROL_STEPS; step++)); do
        if /usr/bin/grep -q '^M3_ABI_INVENTORY_FAIL ' "$SERIAL_LOG" ||
           /usr/bin/grep -q '^M3_SELFTEST_FAIL ' "$SERIAL_LOG"; then
            fail "guest inventory witness failed; see $SERIAL_LOG"
        fi
        line="$(abi_complete_lines "$prefix" "$SERIAL_LOG")"
        if [ -n "$line" ]; then
            case "$line" in *$'\n'*) fail "duplicate guest marker: $prefix";; esac
            wait_for_marker_count "$line" 1 || fail "invalid guest marker: $prefix"
            ABI_LINE="$line"
            return 0
        fi
        running_shell_job "$QPID" || fail "QEMU exited before $prefix"
        /bin/sleep 0.1
    done
    fail "timeout waiting for $prefix"
}

abi_qmp() {
    qmp_send "$1" "$2"
    wait_for_qmp_response "$2" || fail "QMP request failed: $2"
}

abi_validate_ready() {
    local line=$1 token=$2
    [[ "$line" =~ ^M3_SELFTEST_READY\ token=$token\ pid=[1-9][0-9]*\ boot=[0-9a-f-]+\ cpus=1$ ]]
}

abi_validate_done() {
    [ "$1" = "M3_SELFTEST_DONE token=$2 cpus=1" ]
}

abi_validate_pass() {
    local ready=$1 pass=$2 nonce=$3 pid boot cpus
    [[ "$pass" =~ ^M3_SELFTEST_PASS\ nonce=$nonce\ pid=([1-9][0-9]*)\ boot=([0-9a-f-]+)\ cpus=(1)$ ]] || return 1
    pid="${BASH_REMATCH[1]}"; boot="${BASH_REMATCH[2]}"; cpus="${BASH_REMATCH[3]}"
    [[ "$ready" =~ pid=([1-9][0-9]*)\ boot=([0-9a-f-]+)\ cpus=(1)$ ]] || return 1
    [ "$pid" = "${BASH_REMATCH[1]}" ] && [ "$boot" = "${BASH_REMATCH[2]}" ] && [ "$cpus" = "${BASH_REMATCH[3]}" ]
}

abi_validate_inventory_markers() {
    local name marker count
    for name in Makefile ptrace.c syscall-abi.c syscall-abi-asm.S syscall-abi.h tpidr2.c hwcap.c kselftest.h lib.mk; do
        marker="M3_ABI_FILE_BEGIN name=$name "
        count="$("$AWK" -v marker="$marker" '{ line=$0; sub(/\r$/, "", line); if (index(line, marker) == 1) n++ } END { print n + 0 }' "$SERIAL_LOG")"
        [ "$count" -eq 1 ] || return 1
        marker="M3_ABI_FILE_END name=$name"
        count="$("$AWK" -v marker="$marker" '{ line=$0; sub(/\r$/, "", line); if (line == marker) n++ } END { print n + 0 }' "$SERIAL_LOG")"
        [ "$count" -eq 1 ] || return 1
    done
}

abi_run() {
    local token nonce info ready pass done_line step socket_before final_snapshot status=0
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
    echo "ABI SOURCE INVENTORY ONLY (not ABI test pass): $KVER -> $COUNT_DIR"
    /usr/bin/env -i PATH="$PATH" LC_ALL=C TMPDIR="$COUNT_DIR" \
        "$TIMEOUT" --foreground --signal=TERM --kill-after=10 "$LAUNCH_TIMEOUT" \
        /bin/sh -c 'printf "%s\n" "$$" > "$1" || exit 125; shift; exec "$@"' \
        abi-inventory-qemu "$QEMU_PID_FILE" "$QEMU" "${ARGS[@]}" <&8 > "$SERIAL_LOG" 2>&1 &
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
    abi_qmp qmp_capabilities capabilities
    wait_for_marker_count "$AUTOLOGIN_MARKER" 1 || fail "serial autologin"
    exec 8> "$SERIAL_FIFO"
    token="m3-abi-inventory-$$-$(/bin/date +%s)-$RANDOM"
    printf 'stty -echo\n' >&8
    printf "cat > /root/m3-abi-inventory.sh <<'M3_ABI_INVENTORY_EOF'\n" >&8
    /bin/cat "$GUEST_SHELL" >&8
    printf '\nM3_ABI_INVENTORY_EOF\nchmod 700 /root/m3-abi-inventory.sh; /bin/bash /root/m3-abi-inventory.sh 1 %s\n' "$token" >&8
    abi_wait_serial_prefix "M3_SELFTEST_READY token=$token "
    ready="$ABI_LINE"
    abi_validate_ready "$ready" "$token" || fail "malformed READY"
    printf 'GO %s\n' "$token" >&8
    abi_wait_serial_prefix "M3_SELFTEST_BEGIN token=$token cpu=0 test=hwcap"
    [ "$ABI_LINE" = "M3_SELFTEST_BEGIN token=$token cpu=0 test=hwcap" ] || fail "invalid BEGIN"
    abi_wait_serial_prefix "M3_SELFTEST_END token=$token cpu=0 status=0"
    [ "$ABI_LINE" = "M3_SELFTEST_END token=$token cpu=0 status=0" ] || fail "invalid END"
    abi_wait_serial_prefix "M3_SELFTEST_DONE token=$token "
    done_line="$ABI_LINE"
    abi_validate_done "$done_line" "$token" || fail "invalid DONE"
    nonce="$("$ABI_OPENSSL" rand -hex 24)"
    printf 'VERIFY %s\n' "$nonce" >&8
    abi_wait_serial_prefix "M3_SELFTEST_PASS nonce=$nonce "
    pass="$ABI_LINE"
    abi_validate_pass "$ready" "$pass" "$nonce" || fail "guest identity changed"
    abi_qmp query-status verified-status
    qmp_running_response verified-status || fail "guest not running after inventory"
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
    abi_validate_inventory_markers || fail "inventory marker set invalid"
    final_snapshot="$(snapshot_protected)" || fail "final hashes"
    [ "$final_snapshot" = "$BASELINE_SNAPSHOT" ] || fail "protected inputs changed"
    INPUTS_VERIFIED=true
    "$JQ" -n --arg scope "ABI SOURCE INVENTORY ONLY (not ABI test pass)" --arg token "$token" \
        --arg ready "$ready" --arg done "$done_line" --arg pass "$pass" --arg serial "$SERIAL_LOG" \
        --arg pid "$CAPTURED_QEMU_PID" --arg start "$CAPTURED_QEMU_START" --arg socket "$socket_before" \
        --argjson before "$BASELINE_SNAPSHOT" --argjson after "$final_snapshot" \
        '{schema_version:1,scope:$scope,pass:true,sample_id:$token,protocol:{ready:$ready,done:$done,pass:$pass,synthetic_tap:true,abi_execution:false},
          inventory:{serial_log:$serial,files:["Makefile","ptrace.c","syscall-abi.c","syscall-abi-asm.S","syscall-abi.h","tpidr2.c","hwcap.c","kselftest.h","lib.mk"],caps:{file_bytes:131072,total_bytes:524288}},
          qemu:{pid:$pid,start:$start,same_process:true,same_qmp_socket:true,socket_identity:$socket},
          safety:{overlay_removed:true,build_disk_readonly:true,protected_inputs_unchanged:true},protected_inputs:{before:$before,after:$after}}' > "$RUN_DIR/evidence.json"
}

abi_main() {
    [ "$#" -eq 0 ] || fail "no command-line arguments accepted"
    [ "$(/usr/bin/id -u)" -ne 0 ] || fail "refusing to run QEMU as host root"
    [ "$MEM" = 2G ] || fail "requires MEM=2G"
    [ "$SMP_LIST" = 1 ] || fail "ABI inventory requires fixed SMP_LIST=1"
    case "$LAUNCH_TIMEOUT" in ''|*[!0-9]*|0*) fail "invalid LAUNCH_TIMEOUT";; esac
    [ "$LAUNCH_TIMEOUT" -ge 60 ] && [ "$LAUNCH_TIMEOUT" -le 420 ] || fail "timeout must be 60..420s"
    CONTROL_STEPS=$((LAUNCH_TIMEOUT * 10))
    for tool in "$QEMU" "$QEMU_IMG" "$TIMEOUT" "$NC" "$JQ" "$AWK" "$LSOF" "$ABI_OPENSSL"; do
        case "$tool" in /*) ;; *) fail "executable path must be absolute";; esac
        [ -x "$tool" ] && [ ! -u "$tool" ] && [ ! -g "$tool" ] || fail "unsafe/missing executable $tool"
    done
    validate_macos_system_ps "$PS" || fail "macOS ps safety contract"
    QEMU="$(/bin/realpath "$QEMU")"; QEMU_IMG="$(/bin/realpath "$QEMU_IMG")"
    TIMEOUT="$(/bin/realpath "$TIMEOUT")"; NC="$(/bin/realpath "$NC")"
    JQ="$(/bin/realpath "$JQ")"; AWK="$(/bin/realpath "$AWK")"; LSOF="$(/bin/realpath "$LSOF")"
    ABI_OPENSSL="$(/bin/realpath "$ABI_OPENSSL")"
    require_safe_input "$KVER_FILE"; KVER="$(/bin/cat "$KVER_FILE")"
    case "$KVER" in ''|.|..|*/*|*[!A-Za-z0-9.+_~-]*) fail "unsafe KVER";; esac
    case "$KVER" in *asahi*) ;; *) fail "requires Asahi builder kernel";; esac
    KERNEL="$OUT/Image-$KVER"; INITRD="$OUT/initrd.img-$KVER"
    for input in "$KERNEL" "$INITRD" "$ROOTFS" "$BUILD_DISK" "$HARNESS" "$GUEST_SHELL"; do require_safe_input "$input"; done
    PROTECTED_NAMES=(kver kernel initrd rootfs build_disk harness guest_shell reboot_library extracted_library qemu qemu_img timeout nc jq awk lsof ps openssl)
    PROTECTED_PATHS=("$KVER_FILE" "$KERNEL" "$INITRD" "$ROOTFS" "$BUILD_DISK" "$HARNESS" "$GUEST_SHELL" "$ABI_REUSE" "$ABI_DEFS" "$QEMU" "$QEMU_IMG" "$TIMEOUT" "$NC" "$JQ" "$AWK" "$LSOF" "$PS" "$ABI_OPENSSL")
    for input in "${PROTECTED_PATHS[@]}"; do require_safe_input "$input"; done
    [ "$(/usr/bin/shasum -a 256 "$ABI_REUSE")" = "$ABI_REUSE_HASH" ] || fail "reboot library changed"
    /usr/bin/awk '$0 == "# Main program." {exit} {print}' "$ABI_REUSE" | /usr/bin/cmp -s - "$ABI_DEFS" || fail "extracted library changed"
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
    abi_run
    "$JQ" -n --arg scope "ABI SOURCE INVENTORY ONLY (not ABI test pass)" --slurpfile result "$RUN_DIR/evidence.json" --arg run_dir "$RUN_DIR" \
        '{schema_version:1,scope:$scope,all_pass:($result|length == 1 and $result[0].pass),results:$result,run_directory:$run_dir}' > "$RUN_DIR/manifest.json"
    cleanup 0 || fail "runtime cleanup failed"
    trap - EXIT INT TERM HUP
    echo "ABI inventory manifest: $RUN_DIR/manifest.json"
}

if [ "${ABI_INVENTORY_SOURCE_ONLY:-0}" != 1 ]; then abi_main "$@"; fi

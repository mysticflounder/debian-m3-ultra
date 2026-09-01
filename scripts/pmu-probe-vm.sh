#!/bin/bash
# Compile and run the read-only PMU behavior collector in an isolated QEMU/HVF
# guest. Guest writes land only in an explicit disposable qcow2 root overlay.
#
#   SMP=8 KERNEL_IRQCHIP=on ./scripts/pmu-probe-vm.sh
#
# Environment: SMP (default 8), MEM (default 8G), and KERNEL_IRQCHIP (on|off).
set -euo pipefail
umask 077

HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
OUT="$HERE/out"
QEMU="/opt/homebrew/bin/qemu-system-aarch64"
QEMU_IMG="/opt/homebrew/bin/qemu-img"
TIMEOUT="/opt/homebrew/bin/gtimeout"
LSOF="/usr/sbin/lsof"
SMP="${SMP:-8}"
MEM="${MEM:-8G}"
KERNEL_IRQCHIP="${KERNEL_IRQCHIP:-on}"
KVER_FILE="$OUT/KVER"
ROOTFS="$OUT/vmroot.ext4"
SOURCE="$HERE/scripts/arm64-pmu-behavior.c"
LOCK_DIR="$OUT/.vmroot.ext4.probe.lock"

RUN_DIR=""
ROOT_OVERLAY=""
SERIAL_FIFO=""
QPID=""
QEMU_CHILD_PID=""
FEED_PID=""
LOCK_ACQUIRED=false
LOCK_OWNER=""
LOCK_TOKEN=""
HASHES_READY=false
LAUNCH_STARTED=false
INPUTS_VERIFIED=false

fail() {
    echo "PMU probe: $*" >&2
    exit 1
}

sha256_file() {
    local digest remainder

    IFS=' ' read -r digest remainder < <(shasum -a 256 "$1")
    case "$digest" in
        ''|*[!0-9a-f]*) return 1 ;;
    esac
    [ "${#digest}" -eq 64 ] || return 1
    printf '%s\n' "$digest"
}

file_size() {
    stat -f '%z' "$1"
}

require_safe_input() {
    local input=$1
    local links

    if [ -L "$input" ] || [ ! -f "$input" ] || [ ! -r "$input" ]; then
        fail "required input must be a readable regular non-symlink file: $input"
    fi
    links="$(stat -f '%l' "$input")"
    [ "$links" -eq 1 ] || fail "required input is multiply linked: $input"
}

require_distinct_inputs() {
    local left=$1
    local right=$2

    [ "$left" != "$right" ] || fail "protected inputs collide: $left"
    if [ -e "$left" ] && [ -e "$right" ] && [ "$left" -ef "$right" ]; then
        fail "protected inputs resolve to the same file: $left and $right"
    fi
}

release_lock() {
    local observed_token=""

    if [ "$LOCK_ACQUIRED" != true ]; then
        return 0
    fi
    if [ -z "$LOCK_OWNER" ] || [ ! -f "$LOCK_OWNER" ]; then
        echo "PMU probe: owned lock marker is missing: $LOCK_OWNER" >&2
        LOCK_ACQUIRED=false
        return 1
    fi
    IFS= read -r observed_token < "$LOCK_OWNER" || true
    if [ "$observed_token" != "$LOCK_TOKEN" ]; then
        echo "PMU probe: lock ownership token changed; leaving lock intact" >&2
        LOCK_ACQUIRED=false
        return 1
    fi
    if ! rm -f -- "$LOCK_OWNER" || ! rmdir "$LOCK_DIR" 2>/dev/null; then
        echo "PMU probe: failed to release owned lock: $LOCK_DIR" >&2
        LOCK_ACQUIRED=false
        return 1
    fi
    LOCK_ACQUIRED=false
    return 0
}

verify_protected_inputs() {
    KVER_SHA256_AFTER="$(sha256_file "$KVER_FILE")" || return 1
    KERNEL_SHA256_AFTER="$(sha256_file "$KERNEL")" || return 1
    INITRD_SHA256_AFTER="$(sha256_file "$INITRD")" || return 1
    ROOTFS_SHA256_AFTER="$(sha256_file "$ROOTFS")" || return 1
    SOURCE_SHA256_AFTER="$(sha256_file "$SOURCE")" || return 1
    QEMU_SHA256_AFTER="$(sha256_file "$QEMU_REAL")" || return 1
    QEMU_IMG_SHA256_AFTER="$(sha256_file "$QEMU_IMG_REAL")" || return 1
    TIMEOUT_SHA256_AFTER="$(sha256_file "$TIMEOUT_REAL")" || return 1
    LSOF_SHA256_AFTER="$(sha256_file "$LSOF_REAL")" || return 1

    [ "$KVER_SHA256_BEFORE" = "$KVER_SHA256_AFTER" ] &&
        [ "$KERNEL_SHA256_BEFORE" = "$KERNEL_SHA256_AFTER" ] &&
        [ "$INITRD_SHA256_BEFORE" = "$INITRD_SHA256_AFTER" ] &&
        [ "$ROOTFS_SHA256_BEFORE" = "$ROOTFS_SHA256_AFTER" ] &&
        [ "$SOURCE_SHA256_BEFORE" = "$SOURCE_SHA256_AFTER" ] &&
        [ "$QEMU_SHA256_BEFORE" = "$QEMU_SHA256_AFTER" ] &&
        [ "$QEMU_IMG_SHA256_BEFORE" = "$QEMU_IMG_SHA256_AFTER" ] &&
        [ "$TIMEOUT_SHA256_BEFORE" = "$TIMEOUT_SHA256_AFTER" ] &&
        [ "$LSOF_SHA256_BEFORE" = "$LSOF_SHA256_AFTER" ]
}

lsof_openers() {
    local path=$1
    local output
    local status

    if output="$("$LSOF" -t -- "$path" 2>&1)"; then
        status=0
    else
        status=$?
    fi
    if [ "$status" -eq 0 ]; then
        printf '%s\n' "$output"
        return 0
    fi
    if [ "$status" -eq 1 ] && [ -z "$output" ]; then
        return 0
    fi
    echo "PMU probe: lsof failed for $path (status $status): $output" >&2
    return 1
}

cleanup() {
    local cleanup_status=$?

    # QPID is a shell-owned child job with its own 300-second timeout.  Waiting
    # on that job avoids ever signalling a numeric PID that the host might have
    # reused for an unrelated process.
    if [ -n "$QPID" ]; then
        wait "$QPID" 2>/dev/null || true
        QPID=""
    fi
    QEMU_CHILD_PID=""
    if [ -n "$FEED_PID" ]; then
        wait "$FEED_PID" 2>/dev/null || true
        FEED_PID=""
    fi
    { exec 9>&- 9<&-; } 2>/dev/null || true
    if [ -n "$SERIAL_FIFO" ] && [ -p "$SERIAL_FIFO" ]; then
        rm -f -- "$SERIAL_FIFO" || cleanup_status=1
    fi
    if [ -n "$ROOT_OVERLAY" ] && [ -f "$ROOT_OVERLAY" ]; then
        if ! OVERLAY_OPENERS="$(lsof_openers "$ROOT_OVERLAY")"; then
            cleanup_status=1
        elif [ -n "$OVERLAY_OPENERS" ]; then
            echo "PMU probe: refusing to remove overlay still open by pid(s): $OVERLAY_OPENERS" >&2
            cleanup_status=1
        else
            rm -f -- "$ROOT_OVERLAY" || cleanup_status=1
        fi
    fi
    if [ -n "$ROOT_OVERLAY" ] && [ -e "$ROOT_OVERLAY" ]; then
        echo "PMU probe: disposable overlay remains after cleanup: $ROOT_OVERLAY" >&2
        cleanup_status=1
    fi
    if [ "$LAUNCH_STARTED" = true ] && [ "$HASHES_READY" = true ] &&
       [ "$INPUTS_VERIFIED" = false ]; then
        if verify_protected_inputs; then
            INPUTS_VERIFIED=true
        else
            echo "PMU probe: a protected input changed during cleanup" >&2
            cleanup_status=1
        fi
    fi
    if ! release_lock; then
        cleanup_status=1
    fi
    return "$cleanup_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

case "$SMP" in
    ''|*[!0-9]*|0|0*) fail "SMP must be a positive canonical integer: $SMP" ;;
esac
[ "$SMP" -le 64 ] || fail "SMP exceeds the 64-vCPU safety limit: $SMP"

case "$MEM" in
    *G)
        MEM_VALUE="${MEM%G}"
        case "$MEM_VALUE" in ''|*[!0-9]*|0|0*) fail "invalid MEM value: $MEM" ;; esac
        [ "$MEM_VALUE" -le 64 ] || fail "MEM exceeds the 64G safety limit: $MEM"
        ;;
    *M)
        MEM_VALUE="${MEM%M}"
        case "$MEM_VALUE" in ''|*[!0-9]*|0|0*) fail "invalid MEM value: $MEM" ;; esac
        [ "$MEM_VALUE" -le 65536 ] || fail "MEM exceeds the 64G safety limit: $MEM"
        ;;
    *) fail "MEM must be an integer number of M or G: $MEM" ;;
esac

case "$KERNEL_IRQCHIP" in
    on|off) ;;
    *) fail "KERNEL_IRQCHIP must be on or off: $KERNEL_IRQCHIP" ;;
esac

[ "$(id -u)" -ne 0 ] || fail "refusing to run QEMU as host root"
HOST_UID="$(id -u)"
if [ -L "$OUT" ]; then
    fail "refusing symlinked output root: $OUT"
fi
mkdir -p "$OUT"
[ "$(cd "$OUT" && pwd -P)" = "$OUT" ] ||
    fail "output root is not canonical: $OUT"

for tool in "$QEMU" "$QEMU_IMG" "$TIMEOUT" "$LSOF"; do
    [ -x "$tool" ] || fail "missing pinned executable: $tool"
    [ ! -u "$tool" ] && [ ! -g "$tool" ] ||
        fail "refusing setuid/setgid executable: $tool"
done
QEMU_REAL="$(realpath "$QEMU")"
QEMU_IMG_REAL="$(realpath "$QEMU_IMG")"
TIMEOUT_REAL="$(realpath "$TIMEOUT")"
LSOF_REAL="$(realpath "$LSOF")"
for tool in "$QEMU_REAL" "$QEMU_IMG_REAL" "$TIMEOUT_REAL" "$LSOF_REAL"; do
    [ -f "$tool" ] && [ -x "$tool" ] ||
        fail "pinned executable resolves unsafely: $tool"
done
QEMU="$QEMU_REAL"
QEMU_IMG="$QEMU_IMG_REAL"
TIMEOUT="$TIMEOUT_REAL"
LSOF="$LSOF_REAL"

require_safe_input "$KVER_FILE"
KVER_SHA256_SELECTED="$(sha256_file "$KVER_FILE")"
KVER="$(cat "$KVER_FILE")"
case "$KVER" in
    ''|.|..|*/*|*[!A-Za-z0-9.+_~-]*) fail "KVER contains unsafe characters: $KVER" ;;
esac
KERNEL="$OUT/Image-$KVER"
INITRD="$OUT/initrd.img-$KVER"
for input in "$KERNEL" "$INITRD" "$ROOTFS" "$SOURCE"; do
    require_safe_input "$input"
done
require_distinct_inputs "$KERNEL" "$INITRD"
require_distinct_inputs "$KERNEL" "$ROOTFS"
require_distinct_inputs "$KERNEL" "$SOURCE"
require_distinct_inputs "$INITRD" "$ROOTFS"
require_distinct_inputs "$INITRD" "$SOURCE"
require_distinct_inputs "$ROOTFS" "$SOURCE"

QEMU_VERSION="$($QEMU --version | head -1)"
case "$QEMU_VERSION" in
    'QEMU emulator version 11.1.1'*) ;;
    *) fail "expected pinned QEMU 11.1.1, got: $QEMU_VERSION" ;;
esac

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    fail "another VM probe owns $LOCK_DIR; inspect it rather than deleting it blindly"
fi
LOCK_ACQUIRED=true
LOCK_TOKEN="$$:$(date +%s):$RANDOM"
LOCK_OWNER="$LOCK_DIR/owner"
printf '%s\n' "$LOCK_TOKEN" > "$LOCK_OWNER"
OPENERS="$(lsof_openers "$ROOTFS")" || fail "could not verify vmroot.ext4 openers"
[ -z "$OPENERS" ] || fail "vmroot.ext4 is already open by pid(s): $OPENERS"

RUN_DIR="$(mktemp -d "$OUT/pmu-probe-smp${SMP}-irqchip${KERNEL_IRQCHIP}.XXXXXX")"
chmod 700 "$RUN_DIR"
LOG="$RUN_DIR/serial.log"
CONSOLE="$RUN_DIR/console.txt"
RAW_JSON="$RUN_DIR/raw.json"
FINAL_JSON="$RUN_DIR/evidence.json"
FINAL_TMP="$(mktemp "$RUN_DIR/.evidence.XXXXXX")"
ROOT_OVERLAY="$RUN_DIR/root.qcow2"
SERIAL_FIFO="$RUN_DIR/serial.in"
QEMU_PID_FILE="$RUN_DIR/qemu.pid"
: > "$LOG"
: > "$CONSOLE"
: > "$RAW_JSON"
mkfifo -m 600 "$SERIAL_FIFO"
# At most 128 MiB per regular output file.
ulimit -f 262144

echo "hashing protected inputs before launch"
KVER_SHA256_BEFORE="$(sha256_file "$KVER_FILE")"
[ "$KVER_SHA256_SELECTED" = "$KVER_SHA256_BEFORE" ] ||
    fail "KVER changed while selecting the kernel inputs"
KERNEL_SHA256_BEFORE="$(sha256_file "$KERNEL")"
INITRD_SHA256_BEFORE="$(sha256_file "$INITRD")"
ROOTFS_SHA256_BEFORE="$(sha256_file "$ROOTFS")"
SOURCE_SHA256_BEFORE="$(sha256_file "$SOURCE")"
QEMU_SHA256_BEFORE="$(sha256_file "$QEMU_REAL")"
QEMU_IMG_SHA256_BEFORE="$(sha256_file "$QEMU_IMG_REAL")"
TIMEOUT_SHA256_BEFORE="$(sha256_file "$TIMEOUT_REAL")"
LSOF_SHA256_BEFORE="$(sha256_file "$LSOF_REAL")"
HASHES_READY=true
# From this point, every exit path re-hashes all protected inputs. This also
# covers a failure while creating the disposable overlay before QEMU starts.
LAUNCH_STARTED=true

"$QEMU_IMG" create -q -f qcow2 -F raw -b "$ROOTFS" "$ROOT_OVERLAY"
chmod 600 "$ROOT_OVERLAY"

GUEST=$(cat <<'GUEST_EOF'
set -eu
WORK=""
guest_cleanup() {
    rc=$?
    set +e
    if [ "$rc" -ne 0 ]; then
        echo "PMU_GUEST_ERROR rc=$rc"
    fi
    umount /mnt/pmu-source 2>/dev/null || true
    trap - EXIT
    poweroff -f
}
trap guest_cleanup EXIT

mkdir -p /mnt/pmu-source
mount -o ro /dev/vdb1 /mnt/pmu-source
[ "$(blockdev --getro /dev/vdb)" = 1 ]
findmnt -n -o OPTIONS /mnt/pmu-source | grep -qw ro
if touch /mnt/pmu-source/.pmu-write-must-fail 2>/dev/null; then
    echo "PMU_GUEST_ERROR source_write_succeeded"
    exit 1
fi

WORK="$(mktemp -d /tmp/arm64-pmu-behavior.XXXXXX)"
cp /mnt/pmu-source/arm64-pmu-behavior.c "$WORK/"
gcc -O2 -Wall -Wextra -Werror -std=gnu11 \
    -o "$WORK/arm64-pmu-behavior" "$WORK/arm64-pmu-behavior.c"
set +e
"$WORK/arm64-pmu-behavior" > "$WORK/result.json"
PROBE_RC=$?
set -e
cat "$WORK/result.json"
echo "PMU_GUEST_COMPLETE probe_rc=$PROBE_RC guest_uid=$(id -u)"
umount /mnt/pmu-source
trap - EXIT
poweroff -f
GUEST_EOF
)

ARGS=(
    -M virt,highmem=on
    -accel "hvf,kernel-irqchip=$KERNEL_IRQCHIP"
    -cpu host
    -smp "$SMP,sockets=1,cores=$SMP,threads=1"
    -m "$MEM"
    -kernel "$KERNEL"
    -initrd "$INITRD"
    -append "root=/dev/vda rootfstype=ext4 rw console=ttyAMA0 systemd.unit=multi-user.target systemd.mask=m3-build.service"
    -drive "if=virtio,file=$ROOT_OVERLAY,format=qcow2,cache=none"
    -drive "if=virtio,file=fat:ro:$HERE/scripts,format=raw,readonly=on"
    -nic none
    -monitor none
    -display none
    -serial stdio
    -no-reboot
)
QEMU_ARGV_JSON="$(jq -n --args '$ARGS.positional' -- "$QEMU" "${ARGS[@]}")"
EXPECTED_ACCEL="hvf,kernel-irqchip=$KERNEL_IRQCHIP"
EXPECTED_ROOT_DRIVE="if=virtio,file=$ROOT_OVERLAY,format=qcow2,cache=none"
EXPECTED_SOURCE_DRIVE="if=virtio,file=fat:ro:$HERE/scripts,format=raw,readonly=on"
if ! jq -e \
    --arg qemu "$QEMU" \
    --arg accel "$EXPECTED_ACCEL" \
    --arg root_drive "$EXPECTED_ROOT_DRIVE" \
    --arg source_drive "$EXPECTED_SOURCE_DRIVE" '
    . as $argv |
    $argv[0] == $qemu and
    ([range(0; ($argv | length) - 1) as $i |
        select($argv[$i] == "-accel" and $argv[$i + 1] == $accel)] | length) == 1 and
    ([range(0; ($argv | length) - 1) as $i |
        select($argv[$i] == "-drive" and $argv[$i + 1] == $root_drive)] | length) == 1 and
    ([range(0; ($argv | length) - 1) as $i |
        select($argv[$i] == "-drive" and $argv[$i + 1] == $source_drive)] | length) == 1 and
    ([$argv[] | select(. == "-drive")] | length) == 2 and
    ([range(0; ($argv | length) - 1) as $i |
        select($argv[$i] == "-nic" and $argv[$i + 1] == "none")] | length) == 1 and
    ([range(0; ($argv | length) - 1) as $i |
        select($argv[$i] == "-monitor" and $argv[$i + 1] == "none")] | length) == 1 and
    ([range(0; ($argv | length) - 1) as $i |
        select($argv[$i] == "-display" and $argv[$i + 1] == "none")] | length) == 1 and
    ([range(0; ($argv | length) - 1) as $i |
        select($argv[$i] == "-serial" and $argv[$i + 1] == "stdio")] | length) == 1 and
    ($argv | index("-no-reboot")) != null and
    all(["-bios", "-pflash", "-firmware", "-netdev", "-device", "-object"][];
        . as $forbidden | ($argv | index($forbidden)) == null)
' <<<"$QEMU_ARGV_JSON" >/dev/null; then
    fail "internal QEMU argument safety contract failed validation"
fi

exec 9<> "$SERIAL_FIFO"
echo "booting isolated PMU probe: ${SMP} vCPUs, ${MEM} RAM, kernel-irqchip=${KERNEL_IRQCHIP} -> $RUN_DIR"
(
    sleep 30
    printf 'stty -echo\n' >&9
    sleep 1
    printf '%s\n' "$GUEST" >&9
) &
FEED_PID=$!

set +e
env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin \
    TMPDIR="$RUN_DIR" \
    HOME="$RUN_DIR" \
    "$TIMEOUT" --foreground --signal=TERM --kill-after=10 300 \
    /bin/sh -c 'printf "%s\n" "$$" > "$1" || exit 125; shift; exec "$@"' \
    pmu-qemu-launch "$QEMU_PID_FILE" "$QEMU" "${ARGS[@]}" \
    <&9 > "$LOG" 2>&1 &
QPID=$!
for _ in $(seq 1 100); do
    [ -s "$QEMU_PID_FILE" ] && break
    kill -0 "$QPID" 2>/dev/null || break
    sleep 0.05
done
if [ -s "$QEMU_PID_FILE" ]; then
    QEMU_CHILD_PID="$(cat "$QEMU_PID_FILE")"
fi
case "$QEMU_CHILD_PID" in
    ''|*[!0-9]*|0) fail "failed to capture the QEMU child pid" ;;
esac
wait "$QPID"
QEMU_STATUS=$?
set -e
QPID=""
QEMU_CHILD_PID=""
wait "$FEED_PID" 2>/dev/null || true
FEED_PID=""
exec 9>&- 9<&-
rm -f -- "$SERIAL_FIFO"
SERIAL_FIFO=""

OVERLAY_OPENERS="$(lsof_openers "$ROOT_OVERLAY")" ||
    fail "could not verify disposable overlay openers"
[ -z "$OVERLAY_OPENERS" ] ||
    fail "refusing to remove overlay still open by pid(s): $OVERLAY_OPENERS"
rm -f -- "$ROOT_OVERLAY"
[ ! -e "$ROOT_OVERLAY" ] || fail "disposable overlay still exists after removal"
ROOT_OVERLAY=""

echo "verifying protected inputs after shutdown"
verify_protected_inputs || fail "a protected input changed during the PMU probe"

if [ "$QEMU_STATUS" -eq 124 ]; then
    fail "QEMU timed out after 300 seconds; inspect $LOG"
fi
if [ "$QEMU_STATUS" -ne 0 ]; then
    fail "QEMU exited with status $QEMU_STATUS; inspect $LOG"
fi
# Keep the console byte stream intact apart from CR normalization.  macOS sed
# does not interpret the GNU-style \x1b escapes previously used here, and the
# shell's OSC command prefix can therefore remain on marker lines.  Match the
# controlled markers at end-of-line instead of depending on ANSI stripping.
tr -d '\r' < "$LOG" > "$CONSOLE"

if rg -q 'PMU_GUEST_ERROR (rc=[0-9]+|source_write_succeeded)$' "$CONSOLE"; then
    fail "guest reported a PMU probe error; inspect $LOG"
fi
COMPLETE_COUNT="$(awk '$0 ~ /PMU_GUEST_COMPLETE probe_rc=(0|2) guest_uid=0$/ {n++} END {print n+0}' "$CONSOLE")"
[ "$COMPLETE_COUNT" -eq 1 ] ||
    fail "guest did not report one complete, guest-root-confined result; inspect $CONSOLE"
START_COUNT="$(awk '$0 ~ /=== PMU PROBE JSON START ===$/ {n++} END {print n+0}' "$CONSOLE")"
END_COUNT="$(awk '$0 ~ /=== PMU PROBE JSON END ===$/ {n++} END {print n+0}' "$CONSOLE")"
[ "$START_COUNT" -eq 1 ] && [ "$END_COUNT" -eq 1 ] ||
    fail "expected exactly one PMU JSON marker pair; inspect $CONSOLE"
awk '
    $0 ~ /=== PMU PROBE JSON START ===$/ {inside=1; next}
    $0 ~ /=== PMU PROBE JSON END ===$/ {inside=0; exit}
    inside {print}
' "$CONSOLE" > "$RAW_JSON"

if ! jq -e --argjson smp "$SMP" '
    def expected_events: [
        "cycles", "instructions", "branch_instructions", "cache_references",
        "cache_misses", "bus_cycles", "stalled_frontend",
        "stalled_backend", "ref_cpu_cycles"
    ];
    def expected_configs: {
        cycles: "0", instructions: "1", branch_instructions: "4",
        cache_references: "2", cache_misses: "3", bus_cycles: "6",
        stalled_frontend: "7", stalled_backend: "8", ref_cpu_cycles: "9"
    };
    def op:
        (keys | sort) == ["errno", "status"] and
        (.errno | type) == "number" and
        (.status | IN("success", "error", "unavailable", "not_attempted"));
    def text_result:
        (keys | sort) == ["errno", "status", "value"] and
        (.errno | type) == "number" and
        (.status | IN("success", "missing", "error")) and
        (if .status == "success" then (.value | type) == "string"
         else .value == null end);
    def decimal: type == "string" and test("^(0|[1-9][0-9]*)$");
    def read_result:
        (keys | sort) == ["count", "errno", "status", "time_enabled", "time_running"] and
        (.errno | type) == "number" and
        (.status | IN("success", "error", "not_attempted")) and
        (.count | decimal) and (.time_enabled | decimal) and
        (.time_running | decimal);
    def event_shape:
        (keys | sort) == [
            "affinity_correct", "close", "config", "count_delta", "disable",
            "enable", "open", "read_after", "read_before", "reason", "reset",
            "status", "time_enabled_delta", "time_running_delta", "type",
            "verify_affinity"
        ] and
        (.status | IN("pass", "unavailable", "fail", "error", "not_run")) and
        (.reason | type) == "string" and .type == 0 and
        (.config | decimal) and (.open | op) and (.reset | op) and
        (.enable | op) and (.read_before | read_result) and
        (.read_after | read_result) and (.disable | op) and (.close | op) and
        (.count_delta | decimal) and (.time_enabled_delta | decimal) and
        (.time_running_delta | decimal) and
        (.verify_affinity | op) and
        (.affinity_correct | type) == "boolean" and
        (if .status == "pass" then
            .open.status == "success" and .reset.status == "success" and
            .enable.status == "success" and .read_before.status == "success" and
            .read_after.status == "success" and .disable.status == "success" and
            .close.status == "success" and
            .verify_affinity.status == "success" and
            (.count_delta | tonumber) > 0 and
            (.time_enabled_delta | tonumber) > 0 and
            (.time_running_delta | tonumber) > 0 and .affinity_correct
         elif .status == "unavailable" then
            .open.status == "unavailable" and .open.errno > 0 and
            .reset.status == "not_attempted" and
            .enable.status == "not_attempted" and
            .read_before.status == "not_attempted" and
            .read_after.status == "not_attempted"
         else true end);
    (keys | sort) == [
        "affinity", "armv8_pmu_sysfs", "cpus", "guest_euid",
        "perf_event_paranoid", "read_only", "required_cycles_pass_all",
        "schema_version"
    ] and
    .schema_version == 1 and .read_only == true and .guest_euid == 0 and
    (.perf_event_paranoid | text_result) and
    (.armv8_pmu_sysfs | keys | sort) ==
        ["cpumask", "nr_counters", "source", "type"] and
    all(.armv8_pmu_sysfs[]; text_result) and
    .affinity.parse_errno == 0 and
    (.affinity.online_before | text_result) and
    (.affinity.online_after | text_result) and
    (.affinity | keys | sort) == [
        "get_original", "online_after", "online_before", "online_cpu_ids",
        "online_mask_stable", "original_cpu_ids", "parse_errno", "restore",
        "restored_exactly", "verify_restored"
    ] and
    (.affinity.online_cpu_ids | length) == $smp and
    (.affinity.online_cpu_ids | unique | length) == $smp and
    all(.affinity.online_cpu_ids[]; type == "number" and . >= 0 and floor == .) and
    all(.affinity.original_cpu_ids[]; type == "number" and . >= 0 and floor == .) and
    (.affinity.online_cpu_ids == (.affinity.online_cpu_ids | sort)) and
    (.affinity.get_original | op) and .affinity.get_original.status == "success" and
    (.affinity.restore | op) and .affinity.restore.status == "success" and
    (.affinity.verify_restored | op) and
    .affinity.verify_restored.status == "success" and
    .affinity.restored_exactly == true and .affinity.online_mask_stable == true and
    (.cpus | map(.cpu)) == .affinity.online_cpu_ids and
    (.cpus | length) == $smp and
    (.required_cycles_pass_all | type) == "boolean" and
    .required_cycles_pass_all == all(.cpus[]; .events.cycles.status == "pass") and
    all(.cpus[];
        (keys | sort) == [
            "affinity_correct", "cpu", "events", "observed_after",
            "observed_before", "pin", "verify_after", "verify_before"
        ] and
        (.pin | op) and .pin.status == "success" and
        (.verify_before | op) and .verify_before.status == "success" and
        (.verify_after | op) and .verify_after.status == "success" and
        .observed_before == .cpu and .observed_after == .cpu and
        .affinity_correct == true and
        (.events | keys | sort) == (expected_events | sort) and
        all(.events[]; event_shape) and
        all(.events | to_entries[];
            . as $entry | $entry.value.config ==
                (expected_configs | .[$entry.key])))
' "$RAW_JSON" >/dev/null; then
    fail "PMU evidence failed strict schema validation; inspect $RAW_JSON"
fi

if jq -e '.required_cycles_pass_all == true' "$RAW_JSON" >/dev/null; then
    CAPABILITY_GATE_PASSED=true
    EXPECTED_PROBE_RC=0
else
    CAPABILITY_GATE_PASSED=false
    EXPECTED_PROBE_RC=2
fi
EXPECTED_COMPLETE_COUNT="$(awk -v rc="$EXPECTED_PROBE_RC" \
    '$0 ~ ("PMU_GUEST_COMPLETE probe_rc=" rc " guest_uid=0$") {n++} END {print n+0}' \
    "$CONSOLE")"
[ "$EXPECTED_COMPLETE_COUNT" -eq 1 ] ||
    fail "guest completion status disagrees with PMU capability result"

COLLECTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
jq \
    --arg collected_at "$COLLECTED_AT" \
    --argjson host_uid "$HOST_UID" \
    --arg memory "$MEM" \
    --arg kernel_irqchip "$KERNEL_IRQCHIP" \
    --arg run_directory "$RUN_DIR" \
    --arg qemu_path "$QEMU_REAL" \
    --arg qemu_version "$QEMU_VERSION" \
    --arg qemu_sha256_before "$QEMU_SHA256_BEFORE" \
    --arg qemu_sha256_after "$QEMU_SHA256_AFTER" \
    --arg qemu_img_path "$QEMU_IMG_REAL" \
    --arg qemu_img_sha256_before "$QEMU_IMG_SHA256_BEFORE" \
    --arg qemu_img_sha256_after "$QEMU_IMG_SHA256_AFTER" \
    --arg timeout_path "$TIMEOUT_REAL" \
    --arg timeout_sha256_before "$TIMEOUT_SHA256_BEFORE" \
    --arg timeout_sha256_after "$TIMEOUT_SHA256_AFTER" \
    --arg lsof_path "$LSOF_REAL" \
    --arg lsof_sha256_before "$LSOF_SHA256_BEFORE" \
    --arg lsof_sha256_after "$LSOF_SHA256_AFTER" \
    --argjson qemu_argv "$QEMU_ARGV_JSON" \
    --arg kver_path "$KVER_FILE" \
    --arg kver_sha256_before "$KVER_SHA256_BEFORE" \
    --arg kver_sha256_after "$KVER_SHA256_AFTER" \
    --arg kernel_path "$KERNEL" \
    --arg kernel_sha256_before "$KERNEL_SHA256_BEFORE" \
    --arg kernel_sha256_after "$KERNEL_SHA256_AFTER" \
    --argjson kernel_size "$(file_size "$KERNEL")" \
    --arg initrd_path "$INITRD" \
    --arg initrd_sha256_before "$INITRD_SHA256_BEFORE" \
    --arg initrd_sha256_after "$INITRD_SHA256_AFTER" \
    --argjson initrd_size "$(file_size "$INITRD")" \
    --arg rootfs_path "$ROOTFS" \
    --arg rootfs_sha256_before "$ROOTFS_SHA256_BEFORE" \
    --arg rootfs_sha256_after "$ROOTFS_SHA256_AFTER" \
    --argjson rootfs_size "$(file_size "$ROOTFS")" \
    --arg source_path "$SOURCE" \
    --arg source_sha256_before "$SOURCE_SHA256_BEFORE" \
    --arg source_sha256_after "$SOURCE_SHA256_AFTER" '
    . + {
        collected_at: $collected_at,
        run: {
            memory: $memory,
            kernel_irqchip: $kernel_irqchip,
            directory: $run_directory,
            capability_gate: {
                name: "positive-cycles-on-every-vcpu",
                passed: .required_cycles_pass_all
            },
            safety: {
                host_uid: $host_uid,
                host_privilege_required: false,
                guest_execution_uid: .guest_euid,
                guest_root_confined_to_disposable_vm: (.guest_euid == 0),
                explicit_disposable_overlay: true,
                root_backing_opened_via_overlay: true,
                source_drive_read_only: true,
                network_disabled: true,
                monitor_disabled: true,
                display_disabled: true,
                firmware_or_pflash_attached: false,
                host_devices_attached: false,
                protected_inputs_unchanged: true,
                qemu_binaries_unchanged: true,
                overlay_removed_after_shutdown: true
            },
            qemu: {
                path: $qemu_path, version: $qemu_version,
                sha256_before: $qemu_sha256_before,
                sha256_after: $qemu_sha256_after,
                argv: $qemu_argv
            },
            qemu_img: {
                path: $qemu_img_path,
                sha256_before: $qemu_img_sha256_before,
                sha256_after: $qemu_img_sha256_after
            },
            timeout: {
                path: $timeout_path,
                sha256_before: $timeout_sha256_before,
                sha256_after: $timeout_sha256_after
            },
            lsof: {
                path: $lsof_path,
                sha256_before: $lsof_sha256_before,
                sha256_after: $lsof_sha256_after
            }
        },
        inputs: {
            kernel_version: {path: $kver_path,
                             sha256_before: $kver_sha256_before,
                             sha256_after: $kver_sha256_after},
            kernel: {path: $kernel_path,
                     sha256_before: $kernel_sha256_before,
                     sha256_after: $kernel_sha256_after, size: $kernel_size},
            initrd: {path: $initrd_path,
                     sha256_before: $initrd_sha256_before,
                     sha256_after: $initrd_sha256_after, size: $initrd_size},
            rootfs: {path: $rootfs_path,
                     sha256_before: $rootfs_sha256_before,
                     sha256_after: $rootfs_sha256_after, size: $rootfs_size},
            collector_source: {path: $source_path,
                               sha256_before: $source_sha256_before,
                               sha256_after: $source_sha256_after}
        }
    }
' "$RAW_JSON" > "$FINAL_TMP"

if ! jq -e --arg irqchip "$KERNEL_IRQCHIP" '
    def expected_safety: [
        "display_disabled", "explicit_disposable_overlay",
        "firmware_or_pflash_attached", "guest_execution_uid",
        "guest_root_confined_to_disposable_vm", "host_devices_attached",
        "host_privilege_required", "host_uid", "monitor_disabled",
        "network_disabled", "overlay_removed_after_shutdown",
        "protected_inputs_unchanged", "qemu_binaries_unchanged",
        "root_backing_opened_via_overlay", "source_drive_read_only"
    ];
    .run.kernel_irqchip == $irqchip and
    .run.capability_gate == {
        name: "positive-cycles-on-every-vcpu",
        passed: .required_cycles_pass_all
    } and
    (.run.safety | keys | sort) == (expected_safety | sort) and
    .run.safety.host_uid != 0 and
    .run.safety.host_privilege_required == false and
    .run.safety.guest_execution_uid == 0 and
    .run.safety.guest_root_confined_to_disposable_vm == true and
    .run.safety.explicit_disposable_overlay == true and
    .run.safety.root_backing_opened_via_overlay == true and
    .run.safety.source_drive_read_only == true and
    .run.safety.network_disabled == true and
    .run.safety.monitor_disabled == true and
    .run.safety.display_disabled == true and
    .run.safety.firmware_or_pflash_attached == false and
    .run.safety.host_devices_attached == false and
    .run.safety.protected_inputs_unchanged == true and
    .run.safety.qemu_binaries_unchanged == true and
    .run.safety.overlay_removed_after_shutdown == true and
    .run.qemu.sha256_before == .run.qemu.sha256_after and
    .run.qemu_img.sha256_before == .run.qemu_img.sha256_after and
    .run.timeout.sha256_before == .run.timeout.sha256_after and
    .run.lsof.sha256_before == .run.lsof.sha256_after and
    all(.inputs[]; .sha256_before == .sha256_after)
' "$FINAL_TMP" >/dev/null; then
    fail "final PMU evidence failed safety validation"
fi
if rg -qi 'machineid|machine_id|bootid|boot_id|serial[_ -]?number' "$FINAL_TMP"; then
    fail "PMU evidence contains a prohibited machine, boot, or serial identifier"
fi

verify_protected_inputs || fail "a protected input changed before PMU evidence completion"
cleanup
trap - EXIT
mv "$FINAL_TMP" "$FINAL_JSON"
echo "PMU evidence: $FINAL_JSON"
echo "serial log: $LOG"
if [ "$CAPABILITY_GATE_PASSED" != true ]; then
    echo "PMU capability gate: failed (cycles were not usable on every vCPU)" >&2
    exit 2
fi
echo "PMU capability gate: passed"

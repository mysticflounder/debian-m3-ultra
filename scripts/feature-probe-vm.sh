#!/bin/bash
# Run advertised AArch64 instruction-behavior checks in an isolated QEMU/HVF
# guest. Guest writes land only in a disposable qcow2 overlay, and the source
# share is a read-only vvfat image containing two copied inputs.
#
#   SMP=8 ./scripts/feature-probe-vm.sh
#
# Environment: SMP (default 8), MEM (default 8G).
set -euo pipefail
umask 077

HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
OUT="$HERE/out"
QEMU="/opt/homebrew/bin/qemu-system-aarch64"
QEMU_IMG="/opt/homebrew/bin/qemu-img"
TIMEOUT="/opt/homebrew/bin/gtimeout"
LSOF="/usr/sbin/lsof"
AWK="/usr/bin/awk"
SMP="${SMP:-8}"
MEM="${MEM:-8G}"
KVER_FILE="$OUT/KVER"
ROOTFS="$OUT/vmroot.ext4"
C_SOURCE="$HERE/scripts/arm64-feature-behavior.c"
ASM_SOURCE="$HERE/scripts/arm64-feature-tests.S"
LOCK_DIR="$OUT/.vmroot.ext4.probe.lock"

RUN_DIR=""
SOURCE_SHARE=""
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
    echo "feature probe: $*" >&2
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

release_lock() {
    local observed_token=""
    local release_status=0

    if [ "$LOCK_ACQUIRED" = true ]; then
        if [ -z "$LOCK_OWNER" ] || [ ! -f "$LOCK_OWNER" ]; then
            release_status=1
        else
            IFS= read -r observed_token < "$LOCK_OWNER" || true
            if [ "$observed_token" != "$LOCK_TOKEN" ]; then
                release_status=1
            elif ! rm -f -- "$LOCK_OWNER"; then
                release_status=1
            elif ! rmdir "$LOCK_DIR" 2>/dev/null; then
                release_status=1
            fi
        fi
    fi
    LOCK_ACQUIRED=false
    return "$release_status"
}

verify_protected_inputs() {
    KVER_SHA256_AFTER="$(sha256_file "$KVER_FILE")" || return 1
    KERNEL_SHA256_AFTER="$(sha256_file "$KERNEL")" || return 1
    INITRD_SHA256_AFTER="$(sha256_file "$INITRD")" || return 1
    ROOTFS_SHA256_AFTER="$(sha256_file "$ROOTFS")" || return 1
    C_SOURCE_SHA256_AFTER="$(sha256_file "$C_SOURCE")" || return 1
    ASM_SOURCE_SHA256_AFTER="$(sha256_file "$ASM_SOURCE")" || return 1
    QEMU_SHA256_AFTER="$(sha256_file "$QEMU_REAL")" || return 1
    QEMU_IMG_SHA256_AFTER="$(sha256_file "$QEMU_IMG_REAL")" || return 1
    TIMEOUT_SHA256_AFTER="$(sha256_file "$TIMEOUT_REAL")" || return 1
    LSOF_SHA256_AFTER="$(sha256_file "$LSOF_REAL")" || return 1
    AWK_SHA256_AFTER="$(sha256_file "$AWK_REAL")" || return 1

    [ "$KVER_SHA256_BEFORE" = "$KVER_SHA256_AFTER" ] &&
        [ "$KERNEL_SHA256_BEFORE" = "$KERNEL_SHA256_AFTER" ] &&
        [ "$INITRD_SHA256_BEFORE" = "$INITRD_SHA256_AFTER" ] &&
        [ "$ROOTFS_SHA256_BEFORE" = "$ROOTFS_SHA256_AFTER" ] &&
        [ "$C_SOURCE_SHA256_BEFORE" = "$C_SOURCE_SHA256_AFTER" ] &&
        [ "$ASM_SOURCE_SHA256_BEFORE" = "$ASM_SOURCE_SHA256_AFTER" ] &&
        [ "$QEMU_SHA256_BEFORE" = "$QEMU_SHA256_AFTER" ] &&
        [ "$QEMU_IMG_SHA256_BEFORE" = "$QEMU_IMG_SHA256_AFTER" ] &&
        [ "$TIMEOUT_SHA256_BEFORE" = "$TIMEOUT_SHA256_AFTER" ] &&
        [ "$LSOF_SHA256_BEFORE" = "$LSOF_SHA256_AFTER" ] &&
        [ "$AWK_SHA256_BEFORE" = "$AWK_SHA256_AFTER" ]
}

lsof_openers() {
    local path=$1
    local output
    local status

    if output="$("$LSOF_REAL" -t -- "$path" 2>&1)"; then
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
    echo "feature probe: lsof failed for $path (status $status): $output" >&2
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
    exec 9>&- 9<&- 2>/dev/null || true
    if [ -n "$SERIAL_FIFO" ] && { [ -e "$SERIAL_FIFO" ] || [ -L "$SERIAL_FIFO" ]; }; then
        if { [ -p "$SERIAL_FIFO" ] || [ -L "$SERIAL_FIFO" ]; } &&
           rm -f -- "$SERIAL_FIFO"; then
            :
        else
            cleanup_status=1
        fi
    fi
    if [ -n "$ROOT_OVERLAY" ] && [ -f "$ROOT_OVERLAY" ]; then
        if ! OVERLAY_OPENERS="$(lsof_openers "$ROOT_OVERLAY")"; then
            cleanup_status=1
        elif [ -n "$OVERLAY_OPENERS" ]; then
            echo "feature probe: refusing to remove overlay still open by pid(s): $OVERLAY_OPENERS" >&2
            cleanup_status=1
        else
            rm -f -- "$ROOT_OVERLAY" || cleanup_status=1
        fi
    fi
    if [ -n "$ROOT_OVERLAY" ] && [ -e "$ROOT_OVERLAY" ]; then
        echo "feature probe: disposable overlay remains after cleanup: $ROOT_OVERLAY" >&2
        cleanup_status=1
    fi
    if [ -n "$SOURCE_SHARE" ] && [ -L "$SOURCE_SHARE" ]; then
        echo "feature probe: refusing a replaced symlink at the source staging path" >&2
        cleanup_status=1
    elif [ -n "$SOURCE_SHARE" ] && [ -d "$SOURCE_SHARE" ]; then
        if ! rm -f -- "$SOURCE_SHARE/arm64-feature-behavior.c"; then
            cleanup_status=1
        fi
        if ! rm -f -- "$SOURCE_SHARE/arm64-feature-tests.S"; then
            cleanup_status=1
        fi
        if ! rmdir "$SOURCE_SHARE" 2>/dev/null; then
            cleanup_status=1
        fi
    elif [ -n "$SOURCE_SHARE" ] && [ -e "$SOURCE_SHARE" ]; then
        cleanup_status=1
    fi
    if [ "$LAUNCH_STARTED" = true ] && [ "$HASHES_READY" = true ] &&
       [ "$INPUTS_VERIFIED" = false ]; then
        if verify_protected_inputs; then
            INPUTS_VERIFIED=true
        else
            echo "feature probe: a protected input changed during cleanup" >&2
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

[ "$(id -u)" -ne 0 ] || fail "refusing to run QEMU as host root"
if [ -L "$OUT" ]; then
    fail "refusing symlinked output root: $OUT"
fi
mkdir -p "$OUT"
[ "$(cd "$OUT" && pwd -P)" = "$OUT" ] || fail "output root is not canonical: $OUT"

for tool in "$QEMU" "$QEMU_IMG" "$TIMEOUT" "$LSOF" "$AWK"; do
    [ -x "$tool" ] || fail "missing pinned executable: $tool"
    [ ! -u "$tool" ] && [ ! -g "$tool" ] || fail "refusing setuid/setgid executable: $tool"
done
QEMU_REAL="$(realpath "$QEMU")"
QEMU_IMG_REAL="$(realpath "$QEMU_IMG")"
TIMEOUT_REAL="$(realpath "$TIMEOUT")"
LSOF_REAL="$(realpath "$LSOF")"
AWK_REAL="$(realpath "$AWK")"
for tool in "$QEMU_REAL" "$QEMU_IMG_REAL" "$TIMEOUT_REAL" "$LSOF_REAL" "$AWK_REAL"; do
    [ -f "$tool" ] && [ -x "$tool" ] || fail "pinned executable resolves unsafely: $tool"
done
QEMU="$QEMU_REAL"
QEMU_IMG="$QEMU_IMG_REAL"
TIMEOUT="$TIMEOUT_REAL"
LSOF="$LSOF_REAL"
AWK="$AWK_REAL"

require_safe_input "$KVER_FILE"
KVER_SHA256_SELECTED="$(sha256_file "$KVER_FILE")" || fail "could not hash KVER"
KVER="$(/bin/cat "$KVER_FILE")"
case "$KVER" in
    ''|.|..|*/*|*[!A-Za-z0-9.+_~-]*) fail "KVER contains unsafe characters: $KVER" ;;
esac
KERNEL="$OUT/Image-$KVER"
INITRD="$OUT/initrd.img-$KVER"
for input in "$KERNEL" "$INITRD" "$ROOTFS" "$C_SOURCE" "$ASM_SOURCE"; do
    require_safe_input "$input"
done
INPUT_LIST=("$KVER_FILE" "$KERNEL" "$INITRD" "$ROOTFS" "$C_SOURCE" "$ASM_SOURCE")
for ((left = 0; left < ${#INPUT_LIST[@]}; left++)); do
    for ((right = left + 1; right < ${#INPUT_LIST[@]}; right++)); do
        [ ! "${INPUT_LIST[$left]}" -ef "${INPUT_LIST[$right]}" ] ||
            fail "protected inputs resolve to the same file"
    done
done

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
LOCK_OWNER="$LOCK_DIR/owner.$$"
printf '%s\n' "$LOCK_TOKEN" > "$LOCK_OWNER"
OPENERS="$(lsof_openers "$ROOTFS")" || fail "could not verify vmroot.ext4 openers"
[ -z "$OPENERS" ] || fail "vmroot.ext4 is already open by pid(s): $OPENERS"

RUN_DIR="$(mktemp -d "$OUT/feature-probe-smp${SMP}.XXXXXX")"
chmod 700 "$RUN_DIR"
SOURCE_SHARE="$RUN_DIR/source"
mkdir -m 700 "$SOURCE_SHARE"
cp "$C_SOURCE" "$SOURCE_SHARE/arm64-feature-behavior.c"
cp "$ASM_SOURCE" "$SOURCE_SHARE/arm64-feature-tests.S"
chmod 400 "$SOURCE_SHARE/arm64-feature-behavior.c" "$SOURCE_SHARE/arm64-feature-tests.S"
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
# On macOS this is in 512-byte blocks: cap a runaway log/overlay at 256 MiB.
ulimit -f 524288

echo "hashing protected inputs before launch"
KVER_SHA256_BEFORE="$(sha256_file "$KVER_FILE")"
KERNEL_SHA256_BEFORE="$(sha256_file "$KERNEL")"
INITRD_SHA256_BEFORE="$(sha256_file "$INITRD")"
ROOTFS_SHA256_BEFORE="$(sha256_file "$ROOTFS")"
C_SOURCE_SHA256_BEFORE="$(sha256_file "$C_SOURCE")"
ASM_SOURCE_SHA256_BEFORE="$(sha256_file "$ASM_SOURCE")"
QEMU_SHA256_BEFORE="$(sha256_file "$QEMU_REAL")"
QEMU_IMG_SHA256_BEFORE="$(sha256_file "$QEMU_IMG_REAL")"
TIMEOUT_SHA256_BEFORE="$(sha256_file "$TIMEOUT_REAL")"
LSOF_SHA256_BEFORE="$(sha256_file "$LSOF_REAL")"
AWK_SHA256_BEFORE="$(sha256_file "$AWK_REAL")"
[ "$KVER_SHA256_SELECTED" = "$KVER_SHA256_BEFORE" ] ||
    fail "KVER changed while selecting the kernel inputs"
[ "$(sha256_file "$SOURCE_SHARE/arm64-feature-behavior.c")" = "$C_SOURCE_SHA256_BEFORE" ] ||
    fail "staged C source differs from the protected input"
[ "$(sha256_file "$SOURCE_SHARE/arm64-feature-tests.S")" = "$ASM_SOURCE_SHA256_BEFORE" ] ||
    fail "staged assembly source differs from the protected input"
HASHES_READY=true
LAUNCH_STARTED=true

"$QEMU_IMG" create -q -f qcow2 -F raw -b "$ROOTFS" "$ROOT_OVERLAY"
chmod 600 "$ROOT_OVERLAY"

GUEST=$(cat <<'GUEST_EOF'
set -eu
guest_cleanup() {
    rc=$?
    set +e
    if [ "$rc" -ne 0 ]; then
        echo "FEATURE_GUEST_ERROR rc=$rc"
    fi
    umount /mnt/feature-source 2>/dev/null || true
    trap - EXIT
    poweroff -f
}
trap guest_cleanup EXIT

mkdir -p /mnt/feature-source
mount -o ro /dev/vdb1 /mnt/feature-source
[ "$(blockdev --getro /dev/vdb)" = 1 ]
findmnt -n -o OPTIONS /mnt/feature-source | grep -qw ro
if touch /mnt/feature-source/.write-must-fail 2>/dev/null; then
    echo "FEATURE_GUEST_ERROR source_write_succeeded"
    exit 1
fi

WORK="$(mktemp -d /tmp/arm64-feature-behavior.XXXXXX)"
cp /mnt/feature-source/arm64-feature-behavior.c "$WORK/"
cp /mnt/feature-source/arm64-feature-tests.S "$WORK/"
cd "$WORK"
cc -O2 -Wall -Wextra -Werror -std=gnu11 -march=armv8-a \
    -fno-tree-vectorize -fno-builtin -mno-outline-atomics \
    -mgeneral-regs-only -c arm64-feature-behavior.c -o driver.o
cc -c arm64-feature-tests.S -o feature-tests.o
cc driver.o feature-tests.o -o arm64-feature-behavior
test -x arm64-feature-behavior
./arm64-feature-behavior
echo "FEATURE_GUEST_COMPLETE"
umount /mnt/feature-source
trap - EXIT
poweroff -f
GUEST_EOF
)

ARGS=(
    -M virt,highmem=on
    -accel hvf,kernel-irqchip=on
    -cpu host
    -smp "$SMP,sockets=1,cores=$SMP,threads=1"
    -m "$MEM"
    -kernel "$KERNEL"
    -initrd "$INITRD"
    -append "root=/dev/vda rootfstype=ext4 rw console=ttyAMA0 systemd.unit=multi-user.target systemd.mask=m3-build.service"
    -drive "if=virtio,file=$ROOT_OVERLAY,format=qcow2,cache=none"
    -drive "if=virtio,file=fat:ro:$SOURCE_SHARE,format=raw,readonly=on"
    -nic none
    -display none
    -monitor none
    -serial stdio
    -no-reboot
)
QEMU_ARGV_JSON="$(jq -n --args '$ARGS.positional' -- "$QEMU" "${ARGS[@]}")"
EXPECTED_ACCEL="hvf,kernel-irqchip=on"
EXPECTED_ROOT_DRIVE="if=virtio,file=$ROOT_OVERLAY,format=qcow2,cache=none"
EXPECTED_SOURCE_DRIVE="if=virtio,file=fat:ro:$SOURCE_SHARE,format=raw,readonly=on"
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
echo "booting isolated feature probe: ${SMP} vCPUs, ${MEM} RAM -> $RUN_DIR"
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
    feature-qemu-launch "$QEMU_PID_FILE" "$QEMU" "${ARGS[@]}" \
    <&9 > "$LOG" 2>&1 &
QPID=$!
for _ in $(seq 1 100); do
    [ -s "$QEMU_PID_FILE" ] && break
    kill -0 "$QPID" 2>/dev/null || break
    sleep 0.05
done
if [ -s "$QEMU_PID_FILE" ]; then
    QEMU_CHILD_PID="$(/bin/cat "$QEMU_PID_FILE")"
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

rm -f -- "$SOURCE_SHARE/arm64-feature-behavior.c" "$SOURCE_SHARE/arm64-feature-tests.S"
rmdir "$SOURCE_SHARE"
SOURCE_SHARE=""
[ ! -e "$RUN_DIR/source" ] || fail "temporary source share still exists after removal"

echo "verifying protected inputs after shutdown"
verify_protected_inputs || fail "a protected input changed during the feature probe"
INPUTS_VERIFIED=true

if [ "$QEMU_STATUS" -eq 124 ]; then
    fail "QEMU timed out after 300 seconds; inspect $LOG"
fi
if [ "$QEMU_STATUS" -ne 0 ]; then
    fail "QEMU exited with status $QEMU_STATUS; inspect $LOG"
fi
"$AWK" '
    {
        gsub(/\033\][^\007\033]*\007/, "")
        gsub(/\033\][^\007\033]*\033\\/, "")
        gsub(/\033\[[0-9;?]*[[:alpha:]]/, "")
        gsub(/\r/, "")
        print
    }
' "$LOG" > "$CONSOLE"

if rg -q 'FEATURE_GUEST_ERROR (rc=[0-9]+|source_write_succeeded)$' "$CONSOLE"; then
    fail "guest reported a feature-probe error; inspect $LOG"
fi
[ "$(rg -c '^FEATURE_GUEST_COMPLETE$' "$CONSOLE" || true)" = 1 ] ||
    fail "guest did not report exactly one completed feature probe"
[ "$(rg -c '^FEATURE_BEHAVIOR_JSON_BEGIN$' "$CONSOLE" || true)" = 1 ] ||
    fail "missing or duplicate feature JSON start marker"
[ "$(rg -c '^FEATURE_BEHAVIOR_JSON_END$' "$CONSOLE" || true)" = 1 ] ||
    fail "missing or duplicate feature JSON end marker"
"$AWK" '
    /^FEATURE_BEHAVIOR_JSON_BEGIN$/ { capture = 1; next }
    /^FEATURE_BEHAVIOR_JSON_END$/ { capture = 0; next }
    capture { print }
' "$CONSOLE" > "$RAW_JSON"

# This first slice is a regression fixture for the already captured guest ABI,
# not a portable discovery runner. Capability values and positive expectations
# are deliberately exact; DCZID is checked for sane decimal formatting/range
# because its implementation-defined block-size field is not a fixed fixture.
if ! jq -e --argjson smp "$SMP" '
    def expected_specs: [
        {feature:"fp_asimd", source:"AT_HWCAP", bit:"HWCAP_FP|HWCAP_ASIMD", level:"semantic"},
        {feature:"crc32", source:"AT_HWCAP", bit:"HWCAP_CRC32", level:"semantic"},
        {feature:"pmull", source:"AT_HWCAP", bit:"HWCAP_PMULL", level:"semantic"},
        {feature:"lse_atomic", source:"AT_HWCAP", bit:"HWCAP_ATOMICS", level:"semantic"},
        {feature:"lrcpc_ldapr", source:"AT_HWCAP", bit:"HWCAP_LRCPC", level:"execution"},
        {feature:"ilrcpc_ldapur", source:"AT_HWCAP", bit:"HWCAP_ILRCPC", level:"execution"},
        {feature:"flagm_cfinv", source:"AT_HWCAP", bit:"HWCAP_FLAGM", level:"semantic"},
        {feature:"sb", source:"AT_HWCAP", bit:"HWCAP_SB", level:"execution"},
        {feature:"dit", source:"AT_HWCAP", bit:"HWCAP_DIT", level:"semantic"},
        {feature:"paca_roundtrip", source:"AT_HWCAP", bit:"HWCAP_PACA", level:"execution"},
        {feature:"pacg", source:"AT_HWCAP", bit:"HWCAP_PACG", level:"execution"},
        {feature:"dc_zva", source:"DCZID_EL0", bit:"DZP==0", level:"semantic"},
        {feature:"dc_cvap", source:"AT_HWCAP", bit:"HWCAP_DCPOP", level:"execution"},
        {feature:"dc_cvadp", source:"AT_HWCAP2", bit:"HWCAP2_DCPODP", level:"execution"}
    ];
    def row_spec: {feature, source:.hwcap_source, bit:.hwcap_bit, level:.test_level};
    type == "object" and
    (keys | sort) == (["dczid_el0", "hwcap", "hwcap2", "online_cpu_count", "schema_version", "tests"] | sort) and
    .schema_version == 1 and .online_cpu_count == $smp and
    .hwcap == "4021551103" and .hwcap2 == "1204609" and
    (.dczid_el0 | type == "string" and
        test("^(0|[1-9][0-9]{0,19})$") and
        tonumber >= 0 and tonumber <= 18446744073709551615) and
    (.tests | type == "array" and length == ($smp * (expected_specs | length))) and
    ([range(0; $smp) as $cpu |
        [.tests[] | select(.cpu == $cpu) | row_spec]] ==
     [range(0; $smp) | expected_specs]) and
    all(.tests[];
        (keys | sort) == (["advertised", "classification", "cpu", "expected", "feature",
                           "hwcap_bit", "hwcap_source", "observed", "observed_cpu", "test_level"] | sort) and
        .advertised == true and .classification == "pass" and
        (.expected | type == "string" and length > 0) and
        (.observed | type == "string" and length > 0) and
        (.cpu | type == "number" and . >= 0 and . < $smp and floor == .) and
        .observed_cpu == .cpu)
' "$RAW_JSON" >/dev/null; then
    fail "feature JSON failed strict captured-ABI validation; inspect $RAW_JSON"
fi

jq \
    --arg memory "$MEM" \
    --arg qemu_path "$QEMU_REAL" \
    --arg qemu_version "$QEMU_VERSION" \
    --arg qemu_sha256_before "$QEMU_SHA256_BEFORE" \
    --arg qemu_sha256_after "$QEMU_SHA256_AFTER" \
    --argjson qemu_argv "$QEMU_ARGV_JSON" \
    --arg qemu_img_path "$QEMU_IMG_REAL" \
    --arg qemu_img_sha256_before "$QEMU_IMG_SHA256_BEFORE" \
    --arg qemu_img_sha256_after "$QEMU_IMG_SHA256_AFTER" \
    --arg timeout_path "$TIMEOUT_REAL" \
    --arg timeout_sha256_before "$TIMEOUT_SHA256_BEFORE" \
    --arg timeout_sha256_after "$TIMEOUT_SHA256_AFTER" \
    --arg lsof_path "$LSOF_REAL" \
    --arg lsof_sha256_before "$LSOF_SHA256_BEFORE" \
    --arg lsof_sha256_after "$LSOF_SHA256_AFTER" \
    --arg parser_path "$AWK_REAL" \
    --arg parser_sha256_before "$AWK_SHA256_BEFORE" \
    --arg parser_sha256_after "$AWK_SHA256_AFTER" \
    --arg kver_path "$KVER_FILE" \
    --arg kver_sha256_before "$KVER_SHA256_BEFORE" \
    --arg kver_sha256_after "$KVER_SHA256_AFTER" \
    --arg kernel_path "$KERNEL" \
    --arg kernel_name "$(basename "$KERNEL")" \
    --arg kernel_sha256_before "$KERNEL_SHA256_BEFORE" \
    --arg kernel_sha256_after "$KERNEL_SHA256_AFTER" \
    --argjson kernel_size "$(file_size "$KERNEL")" \
    --arg initrd_path "$INITRD" \
    --arg initrd_name "$(basename "$INITRD")" \
    --arg initrd_sha256_before "$INITRD_SHA256_BEFORE" \
    --arg initrd_sha256_after "$INITRD_SHA256_AFTER" \
    --argjson initrd_size "$(file_size "$INITRD")" \
    --arg rootfs_path "$ROOTFS" \
    --arg rootfs_sha256_before "$ROOTFS_SHA256_BEFORE" \
    --arg rootfs_sha256_after "$ROOTFS_SHA256_AFTER" \
    --argjson rootfs_size "$(file_size "$ROOTFS")" \
    --arg c_source_path "$C_SOURCE" \
    --arg c_source_sha256_before "$C_SOURCE_SHA256_BEFORE" \
    --arg c_source_sha256_after "$C_SOURCE_SHA256_AFTER" \
    --arg asm_source_path "$ASM_SOURCE" \
    --arg asm_source_sha256_before "$ASM_SOURCE_SHA256_BEFORE" \
    --arg asm_source_sha256_after "$ASM_SOURCE_SHA256_AFTER" '
    . + {
        run: {
            memory: $memory,
            qemu: {path: $qemu_path, version: $qemu_version,
                   sha256_before: $qemu_sha256_before, sha256_after: $qemu_sha256_after,
                   argv: $qemu_argv},
            qemu_img: {path: $qemu_img_path,
                       sha256_before: $qemu_img_sha256_before, sha256_after: $qemu_img_sha256_after},
            timeout: {path: $timeout_path,
                      sha256_before: $timeout_sha256_before, sha256_after: $timeout_sha256_after},
            lsof: {path: $lsof_path,
                   sha256_before: $lsof_sha256_before, sha256_after: $lsof_sha256_after},
            parser: {path: $parser_path,
                     sha256_before: $parser_sha256_before, sha256_after: $parser_sha256_after},
            safety: {
                host_privilege_required: false,
                explicit_disposable_overlay: true,
                root_backing_opened_via_overlay: true,
                source_drive_read_only: true,
                build_drive_attached: false,
                network_disabled: true,
                monitor_disabled: true,
                display_disabled: true,
                firmware_or_pflash_attached: false,
                host_devices_attached: false,
                protected_inputs_unchanged: true,
                qemu_binaries_unchanged: true,
                parser_unchanged: true,
                overlay_removed_after_shutdown: true,
                source_staging_removed_after_shutdown: true
            }
        },
        inputs: {
            kernel_version: {path: $kver_path,
                             sha256_before: $kver_sha256_before,
                             sha256_after: $kver_sha256_after},
            kernel: {path: $kernel_path, name: $kernel_name,
                     sha256_before: $kernel_sha256_before,
                     sha256_after: $kernel_sha256_after, size: $kernel_size},
            initrd: {path: $initrd_path, name: $initrd_name,
                     sha256_before: $initrd_sha256_before,
                     sha256_after: $initrd_sha256_after, size: $initrd_size},
            rootfs: {path: $rootfs_path,
                     sha256_before: $rootfs_sha256_before,
                     sha256_after: $rootfs_sha256_after, size: $rootfs_size},
            driver_source: {path: $c_source_path,
                            sha256_before: $c_source_sha256_before,
                            sha256_after: $c_source_sha256_after},
            instruction_source: {path: $asm_source_path,
                                 sha256_before: $asm_source_sha256_before,
                                 sha256_after: $asm_source_sha256_after}
        }
    }
' "$RAW_JSON" > "$FINAL_TMP"

if ! jq -e '
    .run.safety == {
        host_privilege_required: false,
        explicit_disposable_overlay: true,
        root_backing_opened_via_overlay: true,
        source_drive_read_only: true,
        build_drive_attached: false,
        network_disabled: true,
        monitor_disabled: true,
        display_disabled: true,
        firmware_or_pflash_attached: false,
        host_devices_attached: false,
        protected_inputs_unchanged: true,
        qemu_binaries_unchanged: true,
        parser_unchanged: true,
        overlay_removed_after_shutdown: true,
        source_staging_removed_after_shutdown: true
    }
' "$FINAL_TMP" >/dev/null; then
    fail "final feature evidence failed safety validation"
fi
if ! jq -e --argjson expected_argv "$QEMU_ARGV_JSON" '
    (keys | sort) == (["dczid_el0", "hwcap", "hwcap2", "inputs",
                       "online_cpu_count", "run", "schema_version", "tests"] | sort) and
    (.run | keys | sort) == (["lsof", "memory", "parser", "qemu", "qemu_img",
                              "safety", "timeout"] | sort) and
    (.inputs | keys | sort) == (["driver_source", "initrd", "instruction_source",
                                 "kernel", "kernel_version", "rootfs"] | sort) and
    .run.qemu.argv == $expected_argv and
    .run.qemu.sha256_before == .run.qemu.sha256_after and
    .run.qemu_img.sha256_before == .run.qemu_img.sha256_after and
    .run.timeout.sha256_before == .run.timeout.sha256_after and
    .run.lsof.sha256_before == .run.lsof.sha256_after and
    .run.parser.sha256_before == .run.parser.sha256_after and
    all(.inputs[]; .sha256_before == .sha256_after)
' "$FINAL_TMP" >/dev/null; then
    fail "final feature evidence failed repeated-hash validation"
fi
if rg -qi 'machineid|bootid|serial[_ -]?number|hostname' "$FINAL_TMP"; then
    fail "feature evidence contains a prohibited machine, boot, serial, or hostname identifier"
fi

verify_protected_inputs || fail "a protected input changed before feature evidence completion"
cleanup
trap - EXIT
mv "$FINAL_TMP" "$FINAL_JSON"
echo "feature evidence: $FINAL_JSON"
echo "serial log: $LOG"

#!/bin/bash
# Run the matched benchmark in an isolated AArch64 guest and retain a complete
# evidence bundle. The root filesystem is used only as the read-only backing
# file of a disposable qcow2 overlay; the only other drive is a read-only
# vvfat share containing a copy of bench.c.
#
#   SMP=8 MEM=16G THREAD_COUNTS=1,8 WARMUPS=1 REPETITIONS=7 \
#     ./scripts/bench-vm.sh
set -euo pipefail
umask 077
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin
LC_ALL=C
export PATH LC_ALL

HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
OUT="$HERE/out"
QEMU="/opt/homebrew/bin/qemu-system-aarch64"
QEMU_IMG="/opt/homebrew/bin/qemu-img"
TIMEOUT="/opt/homebrew/bin/gtimeout"
LSOF="/usr/sbin/lsof"
AWK="/usr/bin/awk"
JQ="/usr/bin/jq"
REALPATH="/bin/realpath"
SMP="${SMP:-8}"
MEM="${MEM:-16G}"
THREAD_COUNTS_RAW="${THREAD_COUNTS:-1,$SMP}"
WARMUPS="${WARMUPS:-1}"
REPETITIONS="${REPETITIONS:-7}"
PREFLIGHT_ONLY="${PREFLIGHT_ONLY-0}"
KVER_FILE="$OUT/KVER"
ROOTFS="$OUT/vmroot.ext4"
BENCH_SOURCE="$HERE/scripts/bench.c"
LOCK_DIR="$OUT/.vmroot.ext4.probe.lock"

RUN_DIR=""
SOURCE_SHARE=""
ROOT_OVERLAY=""
SERIAL_FIFO=""
GUEST_BODY=""
QPID=""
QEMU_CHILD_PID=""
QEMU_CHILD_VERIFIED=false
QEMU_WRAPPER_REAPED=false
QEMU_PID_FILE=""
FEED_PID=""
LOCK_ACQUIRED=false
LOCK_OWNER=""
LOCK_TOKEN=""
HASHES_READY=false
LAUNCH_STARTED=false
INPUTS_VERIFIED=false

fail() {
    echo "guest benchmark: $*" >&2
    exit 1
}

sha256_file() {
    local digest remainder

    IFS=' ' read -r digest remainder < <(/usr/bin/shasum -a 256 "$1")
    case "$digest" in
        ''|*[!0-9a-f]*) return 1 ;;
    esac
    [ "${#digest}" -eq 64 ] || return 1
    printf '%s\n' "$digest"
}

file_size() {
    /usr/bin/stat -f '%z' "$1"
}

require_safe_input() {
    local input=$1
    local links

    if [ -L "$input" ] || [ ! -f "$input" ] || [ ! -r "$input" ]; then
        fail "required input must be a readable regular non-symlink file: $input"
    fi
    links="$(/usr/bin/stat -f '%l' "$input")"
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
            elif ! /bin/rm -f -- "$LOCK_OWNER"; then
                release_status=1
            elif ! /bin/rmdir "$LOCK_DIR" 2>/dev/null; then
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
    BENCH_SOURCE_SHA256_AFTER="$(sha256_file "$BENCH_SOURCE")" || return 1
    QEMU_SHA256_AFTER="$(sha256_file "$QEMU_REAL")" || return 1
    QEMU_IMG_SHA256_AFTER="$(sha256_file "$QEMU_IMG_REAL")" || return 1
    TIMEOUT_SHA256_AFTER="$(sha256_file "$TIMEOUT_REAL")" || return 1
    LSOF_SHA256_AFTER="$(sha256_file "$LSOF_REAL")" || return 1
    AWK_SHA256_AFTER="$(sha256_file "$AWK_REAL")" || return 1
    JQ_SHA256_AFTER="$(sha256_file "$JQ_REAL")" || return 1
    REALPATH_SHA256_AFTER="$(sha256_file "$REALPATH_REAL")" || return 1

    [ "$KVER_SHA256_BEFORE" = "$KVER_SHA256_AFTER" ] &&
        [ "$KERNEL_SHA256_BEFORE" = "$KERNEL_SHA256_AFTER" ] &&
        [ "$INITRD_SHA256_BEFORE" = "$INITRD_SHA256_AFTER" ] &&
        [ "$ROOTFS_SHA256_BEFORE" = "$ROOTFS_SHA256_AFTER" ] &&
        [ "$BENCH_SOURCE_SHA256_BEFORE" = "$BENCH_SOURCE_SHA256_AFTER" ] &&
        [ "$QEMU_SHA256_BEFORE" = "$QEMU_SHA256_AFTER" ] &&
        [ "$QEMU_IMG_SHA256_BEFORE" = "$QEMU_IMG_SHA256_AFTER" ] &&
        [ "$TIMEOUT_SHA256_BEFORE" = "$TIMEOUT_SHA256_AFTER" ] &&
        [ "$LSOF_SHA256_BEFORE" = "$LSOF_SHA256_AFTER" ] &&
        [ "$AWK_SHA256_BEFORE" = "$AWK_SHA256_AFTER" ] &&
        [ "$JQ_SHA256_BEFORE" = "$JQ_SHA256_AFTER" ] &&
        [ "$REALPATH_SHA256_BEFORE" = "$REALPATH_SHA256_AFTER" ]
}

lsof_openers() {
    local path=$1
    local output status

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
    echo "guest benchmark: lsof failed for $path (status $status): $output" >&2
    return 1
}

canonical_process_pid() {
    case "$1" in
        ''|*[!0-9]*|0|1) return 1 ;;
    esac
    [ "$1" -gt 1 ]
}

wrapper_pid_in_job_output() {
    local job_output=$1
    local job_pid

    canonical_process_pid "$QPID" || return 1
    while IFS= read -r job_pid; do
        [ -n "$job_pid" ] || continue
        canonical_process_pid "$job_pid" || return 2
        [ "$job_pid" = "$QPID" ] && return 0
    done <<< "$job_output"
    return 1
}

wrapper_job_state() {
    local running_jobs stopped_jobs match_status

    canonical_process_pid "$QPID" || return 1
    running_jobs="$(jobs -rp 2>/dev/null)" || return 1
    if wrapper_pid_in_job_output "$running_jobs"; then
        printf '%s\n' running
        return 0
    else
        match_status=$?
    fi
    [ "$match_status" -eq 1 ] || return 1
    stopped_jobs="$(jobs -sp 2>/dev/null)" || return 1
    if wrapper_pid_in_job_output "$stopped_jobs"; then
        printf '%s\n' stopped
        return 0
    else
        match_status=$?
    fi
    [ "$match_status" -eq 1 ] || return 1
    printf '%s\n' completed
}

verified_qemu_child_of_wrapper() {
    local observed_parent

    [ "$QEMU_CHILD_VERIFIED" = true ] || return 1
    canonical_process_pid "$QPID" || return 1
    [ "$(wrapper_job_state)" = running ] || return 1
    canonical_process_pid "$QEMU_CHILD_PID" || return 1
    [ "$QEMU_CHILD_PID" != "$QPID" ] || return 1
    observed_parent="$(/bin/ps -o ppid= -p "$QEMU_CHILD_PID" 2>/dev/null)" || return 1
    observed_parent="${observed_parent//[[:space:]]/}"
    [ "$observed_parent" = "$QPID" ]
}

clear_qemu_process_state() {
    QPID=""
    QEMU_CHILD_PID=""
    QEMU_CHILD_VERIFIED=false
    QEMU_WRAPPER_REAPED=false
}

qemu_child_absence_confirmed() {
    canonical_process_pid "$QEMU_CHILD_PID" || return 1
    ! /bin/kill -0 "$QEMU_CHILD_PID" 2>/dev/null
}

reap_wrapper_after_child_absence() {
    local step wrapper_state

    qemu_child_absence_confirmed || return 1
    if [ "$QEMU_WRAPPER_REAPED" = true ]; then
        clear_qemu_process_state
        return 0
    fi
    canonical_process_pid "$QPID" || return 1
    for ((step = 0; step < 20; step++)); do
        wrapper_state="$(wrapper_job_state)" || return 1
        [ "$wrapper_state" = running ] || break
        sleep 0.1
    done
    wrapper_state="$(wrapper_job_state)" || return 1
    [ "$wrapper_state" = completed ] || return 1
    # The exact PID is now in neither Bash's running nor stopped job set.
    # wait may reap a completed child or return 127 if it was already reaped;
    # either result is non-signalling and safe after confirmed child absence.
    wait "$QPID" 2>/dev/null || true
    QEMU_WRAPPER_REAPED=true
    qemu_child_absence_confirmed || return 1
    clear_qemu_process_state
    return 0
}

cleanup_qemu_job() {
    local step
    local wrapper_state

    if [ "$QEMU_WRAPPER_REAPED" = true ]; then
        qemu_child_absence_confirmed || return 1
        clear_qemu_process_state
        return 0
    fi
    canonical_process_pid "$QPID" || return 1
    canonical_process_pid "$QEMU_CHILD_PID" || return 1
    [ "$QEMU_CHILD_PID" != "$QPID" ] || return 1

    if qemu_child_absence_confirmed; then
        reap_wrapper_after_child_absence
        return
    fi
    wrapper_state="$(wrapper_job_state)" || return 1
    [ "$wrapper_state" = running ] || return 1
    verified_qemu_child_of_wrapper || return 1
    /bin/kill -TERM "$QEMU_CHILD_PID" 2>/dev/null || true

    for ((step = 0; step < 20; step++)); do
        qemu_child_absence_confirmed && break
        wrapper_state="$(wrapper_job_state)" || return 1
        [ "$wrapper_state" = running ] || return 1
        verified_qemu_child_of_wrapper || return 1
        sleep 0.1
    done
    if ! qemu_child_absence_confirmed; then
        wrapper_state="$(wrapper_job_state)" || return 1
        [ "$wrapper_state" = running ] || return 1
        verified_qemu_child_of_wrapper || return 1
        /bin/kill -KILL "$QEMU_CHILD_PID" 2>/dev/null || true
    fi
    for ((step = 0; step < 20; step++)); do
        qemu_child_absence_confirmed && break
        wrapper_state="$(wrapper_job_state)" || return 1
        [ "$wrapper_state" = running ] || return 1
        verified_qemu_child_of_wrapper || return 1
        sleep 0.1
    done
    qemu_child_absence_confirmed || return 1
    reap_wrapper_after_child_absence
}

cleanup() {
    local cleanup_status=${1:-$?}
    local openers=""

    if [ -n "$QPID" ] && ! cleanup_qemu_job; then
        cleanup_status=1
    fi
    if [ -n "$FEED_PID" ]; then
        /bin/kill -TERM "$FEED_PID" 2>/dev/null || true
        wait "$FEED_PID" 2>/dev/null || true
        FEED_PID=""
    fi
    exec 9>&- 9<&- 2>/dev/null || true

    if [ -n "$QPID" ]; then
        echo "guest benchmark: process state is uncertain; retaining lock and all run artifacts" >&2
        return 1
    fi

    if [ -n "$QEMU_PID_FILE" ] && { [ -e "$QEMU_PID_FILE" ] || [ -L "$QEMU_PID_FILE" ]; }; then
        if [ -f "$QEMU_PID_FILE" ] && [ ! -L "$QEMU_PID_FILE" ]; then
            /bin/rm -f -- "$QEMU_PID_FILE" || cleanup_status=1
        else
            echo "guest benchmark: refusing a replaced QEMU pid file" >&2
            cleanup_status=1
        fi
    fi

    if [ -n "$SERIAL_FIFO" ] && { [ -e "$SERIAL_FIFO" ] || [ -L "$SERIAL_FIFO" ]; }; then
        if [ -p "$SERIAL_FIFO" ] && [ ! -L "$SERIAL_FIFO" ]; then
            /bin/rm -f -- "$SERIAL_FIFO" || cleanup_status=1
        else
            echo "guest benchmark: refusing a replaced serial FIFO" >&2
            cleanup_status=1
        fi
    fi
    if [ -n "$GUEST_BODY" ] && { [ -e "$GUEST_BODY" ] || [ -L "$GUEST_BODY" ]; }; then
        if [ -f "$GUEST_BODY" ] && [ ! -L "$GUEST_BODY" ]; then
            /bin/rm -f -- "$GUEST_BODY" || cleanup_status=1
        else
            echo "guest benchmark: refusing a replaced guest payload staging file" >&2
            cleanup_status=1
        fi
    fi
    if [ -n "$ROOT_OVERLAY" ] && [ -L "$ROOT_OVERLAY" ]; then
        echo "guest benchmark: refusing a replaced symlink at the overlay path" >&2
        cleanup_status=1
    elif [ -n "$ROOT_OVERLAY" ] && [ -f "$ROOT_OVERLAY" ]; then
        if ! openers="$(lsof_openers "$ROOT_OVERLAY")"; then
            cleanup_status=1
        elif [ -n "$openers" ]; then
            echo "guest benchmark: refusing to remove overlay still open by pid(s): $openers" >&2
            cleanup_status=1
        else
            /bin/rm -f -- "$ROOT_OVERLAY" || cleanup_status=1
        fi
    elif [ -n "$ROOT_OVERLAY" ] && [ -e "$ROOT_OVERLAY" ]; then
        cleanup_status=1
    fi
    if [ -n "$ROOT_OVERLAY" ] && [ -e "$ROOT_OVERLAY" ]; then
        echo "guest benchmark: disposable overlay remains after cleanup: $ROOT_OVERLAY" >&2
        cleanup_status=1
    fi

    if [ -n "$SOURCE_SHARE" ] && [ -L "$SOURCE_SHARE" ]; then
        echo "guest benchmark: refusing a replaced symlink at the source staging path" >&2
        cleanup_status=1
    elif [ -n "$SOURCE_SHARE" ] && [ -d "$SOURCE_SHARE" ]; then
        /bin/rm -f -- "$SOURCE_SHARE/bench.c" || cleanup_status=1
        /bin/rmdir "$SOURCE_SHARE" 2>/dev/null || cleanup_status=1
    elif [ -n "$SOURCE_SHARE" ] && [ -e "$SOURCE_SHARE" ]; then
        cleanup_status=1
    fi
    if [ -n "$SOURCE_SHARE" ] && [ -e "$SOURCE_SHARE" ]; then
        echo "guest benchmark: source staging remains after cleanup: $SOURCE_SHARE" >&2
        cleanup_status=1
    fi

    if [ "$LAUNCH_STARTED" = true ] && [ "$HASHES_READY" = true ] &&
       [ "$INPUTS_VERIFIED" = false ]; then
        if verify_protected_inputs; then
            INPUTS_VERIFIED=true
        else
            echo "guest benchmark: a protected input or tool changed during cleanup" >&2
            cleanup_status=1
        fi
    fi
    if ! release_lock; then
        cleanup_status=1
    fi
    return "$cleanup_status"
}

cleanup_on_exit() {
    local original_status=$?
    local cleanup_status=0

    # Prevent recursive EXIT handling and preserve the status that caused the
    # trap. Cleanup is allowed to turn an otherwise successful exit into a
    # failure, but it must never mask an existing failure.
    trap - EXIT
    if cleanup "$original_status"; then
        cleanup_status=0
    else
        cleanup_status=$?
    fi
    if [ "$original_status" -ne 0 ]; then
        cleanup_status=$original_status
    fi
    exit "$cleanup_status"
}
trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

[ "$#" -eq 0 ] || fail "this runner takes no command-line arguments"

case "$PREFLIGHT_ONLY" in
    0|1) ;;
    *) fail "PREFLIGHT_ONLY must be exactly 0 or 1: $PREFLIGHT_ONLY" ;;
esac

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

case "$WARMUPS" in
    ''|*[!0-9]*|0[0-9]*) fail "WARMUPS must be a canonical non-negative integer: $WARMUPS" ;;
esac
[ "$WARMUPS" -le 10 ] || fail "WARMUPS exceeds the safety limit of 10: $WARMUPS"
case "$REPETITIONS" in
    ''|*[!0-9]*|0|0*) fail "REPETITIONS must be a positive canonical integer: $REPETITIONS" ;;
esac
[ "$REPETITIONS" -le 25 ] || fail "REPETITIONS exceeds the safety limit of 25: $REPETITIONS"

case "$THREAD_COUNTS_RAW" in
    ''|*[!0-9,]*|,*|*,|*,,*) fail "THREAD_COUNTS must be a non-empty CSV of canonical positive integers" ;;
esac
[ "${#THREAD_COUNTS_RAW}" -le 256 ] || fail "THREAD_COUNTS exceeds the 256-character safety limit"
IFS=, read -r -a REQUESTED_THREADS <<< "$THREAD_COUNTS_RAW"
[ "${#REQUESTED_THREADS[@]}" -le 64 ] || fail "THREAD_COUNTS exceeds the 64-entry safety limit"
UNIQUE_THREADS=()
for requested in "${REQUESTED_THREADS[@]}"; do
    case "$requested" in
        ''|*[!0-9]*|0|0*) fail "invalid thread count: $requested" ;;
    esac
    [ "$requested" -le "$SMP" ] || fail "thread count $requested exceeds configured SMP $SMP"
    duplicate=false
    if [ "${#UNIQUE_THREADS[@]}" -gt 0 ]; then
        for existing in "${UNIQUE_THREADS[@]}"; do
            if [ "$requested" = "$existing" ]; then
                duplicate=true
                break
            fi
        done
    fi
    if [ "$duplicate" = false ]; then
        UNIQUE_THREADS+=("$requested")
    fi
done
[ "${#UNIQUE_THREADS[@]}" -ge 1 ] || fail "THREAD_COUNTS produced no thread counts"
TOTAL_EXECUTIONS=$(( (WARMUPS + REPETITIONS) * ${#UNIQUE_THREADS[@]} ))
[ "$TOTAL_EXECUTIONS" -le 512 ] || fail "requested executions exceed the safety limit of 512"
THREAD_COUNTS_CSV="$(IFS=,; printf '%s' "${UNIQUE_THREADS[*]}")"

[ "$(id -u)" -ne 0 ] || fail "refusing to run QEMU as host root"
if [ -L "$OUT" ]; then
    fail "refusing symlinked output root: $OUT"
fi
/bin/mkdir -p "$OUT"
[ "$(cd "$OUT" && pwd -P)" = "$OUT" ] || fail "output root is not canonical: $OUT"

for tool in "$QEMU" "$QEMU_IMG" "$TIMEOUT" "$LSOF" "$AWK" "$JQ" "$REALPATH"; do
    [ -x "$tool" ] || fail "missing pinned executable: $tool"
    [ ! -u "$tool" ] && [ ! -g "$tool" ] || fail "refusing setuid/setgid executable: $tool"
done
REALPATH_REAL="$("$REALPATH" "$REALPATH")"
QEMU_REAL="$("$REALPATH" "$QEMU")"
QEMU_IMG_REAL="$("$REALPATH" "$QEMU_IMG")"
TIMEOUT_REAL="$("$REALPATH" "$TIMEOUT")"
LSOF_REAL="$("$REALPATH" "$LSOF")"
AWK_REAL="$("$REALPATH" "$AWK")"
JQ_REAL="$("$REALPATH" "$JQ")"
for tool in "$QEMU_REAL" "$QEMU_IMG_REAL" "$TIMEOUT_REAL" "$LSOF_REAL" "$AWK_REAL" "$JQ_REAL" "$REALPATH_REAL"; do
    [ -f "$tool" ] && [ -x "$tool" ] && [ ! -L "$tool" ] || fail "pinned executable resolves unsafely: $tool"
done
QEMU="$QEMU_REAL"
QEMU_IMG="$QEMU_IMG_REAL"
TIMEOUT="$TIMEOUT_REAL"
LSOF="$LSOF_REAL"
AWK="$AWK_REAL"
JQ="$JQ_REAL"
REALPATH="$REALPATH_REAL"

require_safe_input "$KVER_FILE"
KVER_SHA256_SELECTED="$(sha256_file "$KVER_FILE")" || fail "could not hash KVER"
KVER="$(/bin/cat "$KVER_FILE")"
case "$KVER" in
    ''|.|..|*/*|*[!A-Za-z0-9.+_~-]*) fail "KVER contains unsafe characters: $KVER" ;;
esac
KERNEL="$OUT/Image-$KVER"
INITRD="$OUT/initrd.img-$KVER"
for input in "$KERNEL" "$INITRD" "$ROOTFS" "$BENCH_SOURCE"; do
    require_safe_input "$input"
done
INPUT_LIST=("$KVER_FILE" "$KERNEL" "$INITRD" "$ROOTFS" "$BENCH_SOURCE")
for ((left = 0; left < ${#INPUT_LIST[@]}; left++)); do
    for ((right = left + 1; right < ${#INPUT_LIST[@]}; right++)); do
        [ ! "${INPUT_LIST[$left]}" -ef "${INPUT_LIST[$right]}" ] || fail "protected inputs resolve to the same file"
    done
done

QEMU_VERSION="$("$QEMU" --version)"
QEMU_VERSION="${QEMU_VERSION%%$'\n'*}"
case "$QEMU_VERSION" in
    'QEMU emulator version 11.1.1'*) ;;
    *) fail "expected pinned QEMU 11.1.1, got: $QEMU_VERSION" ;;
esac
QEMU_IMG_VERSION="$("$QEMU_IMG" --version)"
QEMU_IMG_VERSION="${QEMU_IMG_VERSION%%$'\n'*}"
case "$QEMU_IMG_VERSION" in
    'qemu-img version 11.1.1'*) ;;
    *) fail "expected pinned qemu-img 11.1.1, got: $QEMU_IMG_VERSION" ;;
esac
JQ_VERSION="$("$JQ" --version)"
[ "$JQ_VERSION" = "jq-1.7.1-apple" ] || fail "expected pinned jq-1.7.1-apple, got: $JQ_VERSION"

if ! /bin/mkdir "$LOCK_DIR" 2>/dev/null; then
    fail "another VM probe owns $LOCK_DIR; inspect it rather than deleting it blindly"
fi
LOCK_ACQUIRED=true
LOCK_TOKEN="$$:$(date +%s):$RANDOM"
LOCK_OWNER="$LOCK_DIR/owner.$$"
printf '%s\n' "$LOCK_TOKEN" > "$LOCK_OWNER"
OPENERS="$(lsof_openers "$ROOTFS")" || fail "could not verify vmroot.ext4 openers"
[ -z "$OPENERS" ] || fail "vmroot.ext4 is already open by pid(s): $OPENERS"

RUN_DIR="$(mktemp -d "$OUT/benchmark-guest-smp${SMP}.XXXXXX")"
/bin/chmod 700 "$RUN_DIR"
SOURCE_SHARE="$RUN_DIR/source"
/bin/mkdir -m 700 "$SOURCE_SHARE"
/bin/cp "$BENCH_SOURCE" "$SOURCE_SHARE/bench.c"
/bin/chmod 400 "$SOURCE_SHARE/bench.c"
LOG="$RUN_DIR/serial.log"
CONSOLE="$RUN_DIR/console.txt"
RAW_SAMPLES="$RUN_DIR/guest-samples.jsonl"
RAW_METADATA="$RUN_DIR/.guest-metadata.json"
FINAL_JSON="$RUN_DIR/evidence.json"
ROOT_OVERLAY="$RUN_DIR/root.qcow2"
SERIAL_FIFO="$RUN_DIR/serial.in"
QEMU_PID_FILE="$RUN_DIR/.qemu.pid"
# macOS measures this in 512-byte blocks: cap a runaway log/overlay at 1 GiB.
ulimit -f 2097152
ulimit -n 256

echo "hashing protected inputs and tools before launch"
KVER_SHA256_BEFORE="$(sha256_file "$KVER_FILE")"
KERNEL_SHA256_BEFORE="$(sha256_file "$KERNEL")"
INITRD_SHA256_BEFORE="$(sha256_file "$INITRD")"
ROOTFS_SHA256_BEFORE="$(sha256_file "$ROOTFS")"
BENCH_SOURCE_SHA256_BEFORE="$(sha256_file "$BENCH_SOURCE")"
QEMU_SHA256_BEFORE="$(sha256_file "$QEMU_REAL")"
QEMU_IMG_SHA256_BEFORE="$(sha256_file "$QEMU_IMG_REAL")"
TIMEOUT_SHA256_BEFORE="$(sha256_file "$TIMEOUT_REAL")"
LSOF_SHA256_BEFORE="$(sha256_file "$LSOF_REAL")"
AWK_SHA256_BEFORE="$(sha256_file "$AWK_REAL")"
JQ_SHA256_BEFORE="$(sha256_file "$JQ_REAL")"
REALPATH_SHA256_BEFORE="$(sha256_file "$REALPATH_REAL")"
[ "$KVER_SHA256_SELECTED" = "$KVER_SHA256_BEFORE" ] || fail "KVER changed while selecting kernel inputs"
STAGED_SOURCE_SHA256_BEFORE="$(sha256_file "$SOURCE_SHARE/bench.c")"
[ "$STAGED_SOURCE_SHA256_BEFORE" = "$BENCH_SOURCE_SHA256_BEFORE" ] ||
    fail "staged source differs from protected input"
HASHES_READY=true
LAUNCH_STARTED=true

"$QEMU_IMG" create -q -f qcow2 -F raw -b "$ROOTFS" "$ROOT_OVERLAY"
/bin/chmod 600 "$ROOT_OVERLAY"
if ! "$QEMU_IMG" info --output=json "$ROOT_OVERLAY" | "$JQ" -e --arg rootfs "$ROOTFS" '
    .format == "qcow2" and .["backing-filename"] == $rootfs and
    .["backing-filename-format"] == "raw"
' >/dev/null; then
    fail "overlay does not name the exact raw rootfs backing file"
fi

GUEST_BODY="$(mktemp "$RUN_DIR/.guest-body.XXXXXX")"
/bin/chmod 600 "$GUEST_BODY"
/bin/cat > "$GUEST_BODY" <<'GUEST_EOF'
set -eu
guest_cleanup() {
    rc=$?
    set +e
    if [ "$rc" -ne 0 ]; then
        echo "BENCH_GUEST_ERROR rc=$rc"
    fi
    umount /mnt/bench-source 2>/dev/null || true
    trap - EXIT
    poweroff -f
}
trap guest_cleanup EXIT

mkdir -p /mnt/bench-source
mount -o ro /dev/vdb1 /mnt/bench-source
[ "$(blockdev --getro /dev/vdb)" = 1 ]
findmnt -n -o OPTIONS /mnt/bench-source | grep -qw ro
if touch /mnt/bench-source/.write-must-fail 2>/dev/null; then
    echo "BENCH_GUEST_ERROR source_write_succeeded"
    exit 1
fi
echo "BENCH_GUEST_SAFETY source_block_read_only=1 source_mount_read_only=1"

WORK="$(mktemp -d /tmp/guest-benchmark.XXXXXX)"
cp /mnt/bench-source/bench.c "$WORK/bench.c"
cd "$WORK"
[ -f /usr/bin/gcc ]
[ -x /usr/bin/gcc ]
[ ! -u /usr/bin/gcc ]
[ ! -g /usr/bin/gcc ]
GCC_NUMERIC_VERSION="$(/usr/bin/gcc -dumpfullversion -dumpversion)"
GCC_VERSION_LINE="$(/usr/bin/gcc --version | /usr/bin/head -n 1)"
case "$GCC_NUMERIC_VERSION" in
    ''|*[!0-9.]*|.*|*.|*..*) exit 21 ;;
esac
[ "${#GCC_NUMERIC_VERSION}" -le 64 ] || exit 22
[ "${#GCC_VERSION_LINE}" -le 160 ] || exit 23
printf '%s\n' "$GCC_VERSION_LINE" |
    /usr/bin/grep -Eq '^[A-Za-z0-9][A-Za-z0-9 .,+_()/:~-]*$' || exit 24
/usr/bin/gcc -O2 -pthread -Wall -Wextra -Werror -std=gnu11 bench.c -o bench
test -x bench

KERNEL_RELEASE="$(uname -r)"
ONLINE_CPU_COUNT="$(getconf _NPROCESSORS_ONLN)"
CPU_IMPLEMENTER="$(awk -F: '/^CPU implementer/{gsub(/[[:space:]]/, "", $2); print $2; exit}' /proc/cpuinfo)"
CPU_PART="$(awk -F: '/^CPU part/{gsub(/[[:space:]]/, "", $2); print $2; exit}' /proc/cpuinfo)"
case "$KERNEL_RELEASE" in ''|*[!A-Za-z0-9.+_~-]*) exit 25 ;; esac
case "$ONLINE_CPU_COUNT" in ''|*[!0-9]*|0|0*) exit 26 ;; esac
case "$CPU_IMPLEMENTER" in 0x[0-9A-Fa-f]*) ;; *) exit 27 ;; esac
case "$CPU_PART" in 0x[0-9A-Fa-f]*) ;; *) exit 28 ;; esac
if dmesg | grep -qi 'TSO memory model'; then
    TSO_PRESENT=true
else
    TSO_PRESENT=false
fi
echo "BENCH_GUEST_METADATA_BEGIN"
printf '{"compiler_path":"/usr/bin/gcc","compiler_family":"gcc","compiler_version":"%s","compiler_version_line":"%s","kernel_release":"%s","online_cpu_count":%s,"cpu_implementer":"%s","cpu_part":"%s","tso_present":%s}\n' \
    "$GCC_NUMERIC_VERSION" "$GCC_VERSION_LINE" "$KERNEL_RELEASE" \
    "$ONLINE_CPU_COUNT" "$CPU_IMPLEMENTER" "$CPU_PART" "$TSO_PRESENT"
echo "BENCH_GUEST_METADATA_END"

SAMPLE_FILE="$(mktemp /tmp/guest-benchmark-samples.XXXXXX)"
OLD_IFS=$IFS
IFS=,
for threads in $THREAD_COUNTS; do
    warmup=0
    while [ "$warmup" -lt "$WARMUPS" ]; do
        ./bench --json "$threads" >/dev/null
        warmup=$((warmup + 1))
    done
    echo "BENCH_GUEST_THREAD_WARMUPS_COMPLETE threads=$threads"
    repetition=0
    while [ "$repetition" -lt "$REPETITIONS" ]; do
        ./bench --json "$threads" >> "$SAMPLE_FILE"
        repetition=$((repetition + 1))
    done
done
IFS=$OLD_IFS
echo "BENCH_GUEST_EXECUTIONS_COMPLETE"
echo "BENCH_GUEST_SAMPLES_BEGIN"
cat "$SAMPLE_FILE"
echo "BENCH_GUEST_SAMPLES_END"
umount /mnt/bench-source
echo "BENCH_GUEST_COMPLETE"
trap - EXIT
poweroff -f
GUEST_EOF
GUEST="$(
    {
        printf "THREAD_COUNTS='%s'\n" "$THREAD_COUNTS_CSV"
        printf "WARMUPS='%s'\n" "$WARMUPS"
        printf "REPETITIONS='%s'\n" "$REPETITIONS"
        /bin/cat "$GUEST_BODY"
    }
)"
/bin/rm -f -- "$GUEST_BODY"
GUEST_BODY=""

EXPECTED_MACHINE="virt,highmem=on"
EXPECTED_ACCEL="hvf,kernel-irqchip=on"
EXPECTED_SMP="$SMP,sockets=1,cores=$SMP,threads=1"
EXPECTED_APPEND="root=/dev/vda rootfstype=ext4 rw console=ttyAMA0 systemd.unit=multi-user.target systemd.mask=m3-build.service"
EXPECTED_ROOT_DRIVE="if=virtio,file=$ROOT_OVERLAY,format=qcow2,cache=none"
EXPECTED_SOURCE_DRIVE="if=virtio,file=fat:ro:$SOURCE_SHARE,format=raw,readonly=on"
ARGS=(
    -no-user-config
    -nodefaults
    -M "$EXPECTED_MACHINE"
    -accel "$EXPECTED_ACCEL"
    -cpu host
    -smp "$EXPECTED_SMP"
    -m "$MEM"
    -kernel "$KERNEL"
    -initrd "$INITRD"
    -append "$EXPECTED_APPEND"
    -drive "$EXPECTED_ROOT_DRIVE"
    -drive "$EXPECTED_SOURCE_DRIVE"
    -nic none
    -display none
    -monitor none
    -serial stdio
    -no-reboot
)
QEMU_ARGV_JSON="$("$JQ" -n --args '$ARGS.positional' -- "$QEMU" "${ARGS[@]}")"
if ! "$JQ" -e \
    --arg qemu "$QEMU" \
    --arg machine "$EXPECTED_MACHINE" \
    --arg accel "$EXPECTED_ACCEL" \
    --arg smp "$EXPECTED_SMP" \
    --arg memory "$MEM" \
    --arg kernel "$KERNEL" \
    --arg initrd "$INITRD" \
    --arg append "$EXPECTED_APPEND" \
    --arg root_drive "$EXPECTED_ROOT_DRIVE" \
    --arg source_drive "$EXPECTED_SOURCE_DRIVE" '
    . as $argv |
    $argv == [
        $qemu,
        "-no-user-config", "-nodefaults",
        "-M", $machine,
        "-accel", $accel,
        "-cpu", "host",
        "-smp", $smp,
        "-m", $memory,
        "-kernel", $kernel,
        "-initrd", $initrd,
        "-append", $append,
        "-drive", $root_drive,
        "-drive", $source_drive,
        "-nic", "none",
        "-display", "none",
        "-monitor", "none",
        "-serial", "stdio",
        "-no-reboot"
    ] and
    ([$argv[] | select(. == "-drive")] | length) == 2 and
    ($argv | index("-nodefaults")) != null and
    all(["-bios", "-pflash", "-firmware", "-netdev", "-device", "-object",
         "-blockdev", "-chardev", "-incoming", "-snapshot"][];
        . as $forbidden | ($argv | index($forbidden)) == null)
' <<< "$QEMU_ARGV_JSON" >/dev/null; then
    fail "internal QEMU argument safety contract failed exact validation"
fi

if [ "$PREFLIGHT_ONLY" = 1 ]; then
    cleanup
    trap - EXIT
    if [ -L "$RUN_DIR" ] || [ ! -d "$RUN_DIR" ]; then
        echo "guest benchmark: refusing replaced preflight run directory: $RUN_DIR" >&2
        exit 1
    fi
    if ! /bin/rmdir "$RUN_DIR"; then
        echo "guest benchmark: preflight run directory was not empty after cleanup: $RUN_DIR" >&2
        exit 1
    fi
    echo "guest benchmark preflight passed: source staging, overlay, guest payload, and QEMU argv validated"
    exit 0
fi

FINAL_TMP="$(mktemp "$RUN_DIR/.evidence.XXXXXX")"
: > "$LOG"
: > "$CONSOLE"
: > "$RAW_SAMPLES"
: > "$RAW_METADATA"
: > "$QEMU_PID_FILE"
/usr/bin/mkfifo -m 600 "$SERIAL_FIFO"

exec 9<> "$SERIAL_FIFO"
echo "booting isolated guest benchmark: ${SMP} vCPUs, ${MEM} RAM -> $RUN_DIR"
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
    LC_ALL=C \
    TMPDIR="$RUN_DIR" \
    HOME="$RUN_DIR" \
    "$TIMEOUT" --foreground --signal=TERM --kill-after=10 1800 \
    /bin/sh -c 'printf "%s\n" "$$" > "$1" || exit 125; shift; exec "$@"' \
    benchmark-qemu-launch "$QEMU_PID_FILE" "$QEMU" "${ARGS[@]}" \
    <&9 > "$LOG" 2>&1 &
QPID=$!
QEMU_WRAPPER_REAPED=false
canonical_process_pid "$QPID" || fail "failed to capture the timeout wrapper pid"
[ "$(wrapper_job_state)" = running ] || fail "timeout wrapper is not an active owned shell job"
for _ in $(seq 1 100); do
    [ -s "$QEMU_PID_FILE" ] && break
    [ "$(wrapper_job_state)" = running ] || break
    sleep 0.05
done
if [ -s "$QEMU_PID_FILE" ]; then
    QEMU_CHILD_PID="$(/bin/cat "$QEMU_PID_FILE")"
fi
case "$QEMU_CHILD_PID" in
    ''|*[!0-9]*|0) fail "failed to capture the QEMU child pid" ;;
esac
QEMU_CHILD_VERIFIED=true
verified_qemu_child_of_wrapper || fail "captured QEMU pid is not owned by the timeout wrapper"
wait "$QPID"
QEMU_STATUS=$?
set -e
QEMU_WRAPPER_REAPED=true
qemu_child_absence_confirmed ||
    fail "QEMU child pid is still present after the timeout wrapper was reaped"
clear_qemu_process_state
[ -f "$QEMU_PID_FILE" ] && [ ! -L "$QEMU_PID_FILE" ] || fail "QEMU pid file was replaced"
/bin/rm -f -- "$QEMU_PID_FILE"
QEMU_PID_FILE=""
wait "$FEED_PID" 2>/dev/null || true
FEED_PID=""
exec 9>&- 9<&-
[ -p "$SERIAL_FIFO" ] && [ ! -L "$SERIAL_FIFO" ] || fail "serial FIFO was replaced before cleanup"
/bin/rm -f -- "$SERIAL_FIFO"
SERIAL_FIFO=""

ROOT_OPENERS="$(lsof_openers "$ROOTFS")" || fail "could not verify rootfs openers after shutdown"
[ -z "$ROOT_OPENERS" ] || fail "rootfs remains open after shutdown by pid(s): $ROOT_OPENERS"
OVERLAY_OPENERS="$(lsof_openers "$ROOT_OVERLAY")" || fail "could not verify disposable overlay openers"
[ -f "$ROOT_OVERLAY" ] && [ ! -L "$ROOT_OVERLAY" ] || fail "disposable overlay was replaced before cleanup"
[ -z "$OVERLAY_OPENERS" ] || fail "refusing to remove overlay still open by pid(s): $OVERLAY_OPENERS"
/bin/rm -f -- "$ROOT_OVERLAY"
[ ! -e "$ROOT_OVERLAY" ] || fail "disposable overlay still exists after removal"
ROOT_OVERLAY=""

[ -d "$SOURCE_SHARE" ] && [ ! -L "$SOURCE_SHARE" ] || fail "source staging was replaced before cleanup"
[ "$(cd "$SOURCE_SHARE" && pwd -P)" = "$SOURCE_SHARE" ] || fail "source staging is no longer canonical"
require_safe_input "$SOURCE_SHARE/bench.c"
STAGED_SOURCE_SHA256_AFTER="$(sha256_file "$SOURCE_SHARE/bench.c")"
[ "$STAGED_SOURCE_SHA256_BEFORE" = "$STAGED_SOURCE_SHA256_AFTER" ] ||
    fail "staged benchmark source changed while attached read-only"
/bin/rm -f -- "$SOURCE_SHARE/bench.c"
/bin/rmdir "$SOURCE_SHARE"
SOURCE_SHARE=""
[ ! -e "$RUN_DIR/source" ] || fail "temporary source share still exists after removal"

echo "verifying protected inputs and tools after shutdown"
verify_protected_inputs || fail "a protected input or tool changed during the guest benchmark"

if [ "$QEMU_STATUS" -eq 124 ]; then
    fail "QEMU timed out after 1800 seconds; inspect $LOG"
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

marker_count() {
    "$AWK" -v target="$1" '$0 == target { count++ } END { print count + 0 }' "$CONSOLE"
}

[ "$(marker_count 'BENCH_GUEST_SAFETY source_block_read_only=1 source_mount_read_only=1')" = 1 ] ||
    fail "guest did not report exactly one successful read-only source proof"
[ "$(marker_count BENCH_GUEST_METADATA_BEGIN)" = 1 ] || fail "missing or duplicate metadata start marker"
[ "$(marker_count BENCH_GUEST_METADATA_END)" = 1 ] || fail "missing or duplicate metadata end marker"
[ "$(marker_count BENCH_GUEST_EXECUTIONS_COMPLETE)" = 1 ] || fail "benchmark executions did not complete exactly once"
[ "$(marker_count BENCH_GUEST_SAMPLES_BEGIN)" = 1 ] || fail "missing or duplicate samples start marker"
[ "$(marker_count BENCH_GUEST_SAMPLES_END)" = 1 ] || fail "missing or duplicate samples end marker"
[ "$(marker_count BENCH_GUEST_COMPLETE)" = 1 ] || fail "guest did not complete exactly once"
if [ "$("$AWK" 'index($0, "BENCH_GUEST_ERROR") == 1 { count++ } END { print count + 0 }' "$CONSOLE")" -ne 0 ]; then
    fail "guest reported an error; inspect $LOG"
fi
if ! "$AWK" -v thread_counts="$THREAD_COUNTS_CSV" '
    BEGIN { thread_total = split(thread_counts, expected_thread, ","); next_thread = 1 }
    $0 == "BENCH_GUEST_SAFETY source_block_read_only=1 source_mount_read_only=1" {
        if (state != 0) exit 50; state = 1; next
    }
    $0 == "BENCH_GUEST_METADATA_BEGIN" {
        if (state != 1) exit 51; state = 2; next
    }
    $0 == "BENCH_GUEST_METADATA_END" {
        if (state != 2) exit 52; state = 3; next
    }
    index($0, "BENCH_GUEST_THREAD_WARMUPS_COMPLETE threads=") == 1 {
        expected = "BENCH_GUEST_THREAD_WARMUPS_COMPLETE threads=" expected_thread[next_thread]
        if (state != 3 || next_thread > thread_total || $0 != expected) exit 53
        next_thread++; next
    }
    $0 == "BENCH_GUEST_EXECUTIONS_COMPLETE" {
        if (state != 3 || next_thread != thread_total + 1) exit 54; state = 4; next
    }
    $0 == "BENCH_GUEST_SAMPLES_BEGIN" {
        if (state != 4) exit 55; state = 5; next
    }
    $0 == "BENCH_GUEST_SAMPLES_END" {
        if (state != 5) exit 56; state = 6; next
    }
    $0 == "BENCH_GUEST_COMPLETE" {
        if (state != 6) exit 57; state = 7; next
    }
    END { if (state != 7) exit 58 }
' "$CONSOLE" >/dev/null; then
    fail "guest protocol markers were out of order"
fi

if ! "$AWK" '
    $0 == "BENCH_GUEST_METADATA_BEGIN" { if (state != 0) exit 40; state = 1; next }
    $0 == "BENCH_GUEST_METADATA_END" { if (state != 1) exit 41; state = 2; next }
    state == 1 && length($0) >= 2 && substr($0, 1, 1) == "{" &&
        substr($0, length($0), 1) == "}" { print }
    END { if (state != 2) exit 42 }
' "$CONSOLE" > "$RAW_METADATA"; then
    fail "metadata markers were out of order"
fi
if ! "$AWK" '
    $0 == "BENCH_GUEST_SAMPLES_BEGIN" { if (state != 0) exit 40; state = 1; next }
    $0 == "BENCH_GUEST_SAMPLES_END" { if (state != 1) exit 41; state = 2; next }
    state == 1 && length($0) >= 2 && substr($0, 1, 1) == "{" &&
        substr($0, length($0), 1) == "}" { print }
    END { if (state != 2) exit 42 }
' "$CONSOLE" > "$RAW_SAMPLES"; then
    fail "sample markers were out of order"
fi

if [ "$("$AWK" 'NF { count++ } END { print count + 0 }' "$RAW_METADATA")" -ne 1 ]; then
    fail "guest metadata was not exactly one compact JSON object"
fi
if ! "$JQ" -e --argjson smp "$SMP" '
    type == "object" and
    (keys | sort) == (["compiler_family", "compiler_path", "compiler_version",
                       "compiler_version_line", "cpu_implementer", "cpu_part",
                       "kernel_release", "online_cpu_count", "tso_present"] | sort) and
    .compiler_path == "/usr/bin/gcc" and
    .compiler_family == "gcc" and
    (.compiler_version | type == "string" and test("^[0-9]+([.][0-9]+){0,3}$") and length <= 64) and
    (.compiler_version_line | type == "string" and
        test("^[A-Za-z0-9][A-Za-z0-9 .,+_()/:~-]*$") and length <= 160) and
    (.kernel_release | type == "string" and test("^[A-Za-z0-9.+_~-]{1,128}$")) and
    .online_cpu_count == $smp and
    (.cpu_implementer | type == "string" and test("^0x[0-9A-Fa-f]{1,16}$")) and
    (.cpu_part | type == "string" and test("^0x[0-9A-Fa-f]{1,16}$")) and
    (.tso_present | type == "boolean")
' "$RAW_METADATA" >/dev/null; then
    fail "guest metadata failed strict schema or sanitization validation"
fi

THREAD_COUNTS_JSON="$("$JQ" -n --args '$ARGS.positional | map(tonumber)' -- "${UNIQUE_THREADS[@]}")"
EXPECTED_SAMPLE_COUNT=$(( REPETITIONS * ${#UNIQUE_THREADS[@]} ))
if [ "$("$AWK" 'NF { count++ } END { print count + 0 }' "$RAW_SAMPLES")" -ne "$EXPECTED_SAMPLE_COUNT" ]; then
    fail "guest emitted the wrong number of compact sample objects"
fi
if ! "$JQ" -s -e \
    --argjson expected_threads "$THREAD_COUNTS_JSON" \
    --argjson repetitions "$REPETITIONS" '
    def positive_finite: type == "number" and isfinite and . > 0;
    . as $samples |
    ($samples | length) == ($repetitions * ($expected_threads | length)) and
    ([$expected_threads[] as $threads | range(0; $repetitions) | $threads]) as $expected_order |
    ([$samples[].threads] == $expected_order) and
    all($samples[];
        type == "object" and
        (keys | sort) == (["checksum", "int_gops", "int_iterations_per_thread",
                           "int_operations_per_iteration", "int_seconds", "memory_bytes",
                           "memory_gib_s", "memory_passes", "memory_seconds", "threads"] | sort) and
        (.threads | type == "number" and . == floor) and
        (.threads as $threads | ($expected_threads | index($threads)) != null) and
        .int_iterations_per_thread == 400000000 and
        .int_operations_per_iteration == 4 and
        (.int_seconds | positive_finite) and
        (.int_gops | positive_finite) and
        .memory_bytes == 268435456 and
        .memory_passes == 8 and
        (.memory_seconds | positive_finite) and
        (.memory_gib_s | positive_finite) and
        (.checksum | type == "string" and test("^[0-9a-f]{16}$"))) and
    all($expected_threads[];
        . as $threads | ([$samples[] | select(.threads == $threads)] | length) == $repetitions)
' "$RAW_SAMPLES" >/dev/null; then
    fail "guest samples failed strict schema, value, or cardinality validation"
fi

KERNEL_SIZE="$(file_size "$KERNEL")"
INITRD_SIZE="$(file_size "$INITRD")"
ROOTFS_SIZE="$(file_size "$ROOTFS")"
if ! "$JQ" -n \
    --slurpfile metadata "$RAW_METADATA" \
    --slurpfile samples "$RAW_SAMPLES" \
    --argjson thread_counts "$THREAD_COUNTS_JSON" \
    --argjson smp "$SMP" \
    --arg memory "$MEM" \
    --argjson warmups "$WARMUPS" \
    --argjson repetitions "$REPETITIONS" \
    --argjson qemu_argv "$QEMU_ARGV_JSON" \
    --arg qemu_path "$QEMU_REAL" --arg qemu_version "$QEMU_VERSION" \
    --arg qemu_before "$QEMU_SHA256_BEFORE" --arg qemu_after "$QEMU_SHA256_AFTER" \
    --arg qemu_img_path "$QEMU_IMG_REAL" --arg qemu_img_version "$QEMU_IMG_VERSION" \
    --arg qemu_img_before "$QEMU_IMG_SHA256_BEFORE" --arg qemu_img_after "$QEMU_IMG_SHA256_AFTER" \
    --arg timeout_path "$TIMEOUT_REAL" --arg timeout_before "$TIMEOUT_SHA256_BEFORE" --arg timeout_after "$TIMEOUT_SHA256_AFTER" \
    --arg lsof_path "$LSOF_REAL" --arg lsof_before "$LSOF_SHA256_BEFORE" --arg lsof_after "$LSOF_SHA256_AFTER" \
    --arg awk_path "$AWK_REAL" --arg awk_before "$AWK_SHA256_BEFORE" --arg awk_after "$AWK_SHA256_AFTER" \
    --arg jq_path "$JQ_REAL" --arg jq_version "$JQ_VERSION" --arg jq_before "$JQ_SHA256_BEFORE" --arg jq_after "$JQ_SHA256_AFTER" \
    --arg realpath_path "$REALPATH_REAL" --arg realpath_before "$REALPATH_SHA256_BEFORE" --arg realpath_after "$REALPATH_SHA256_AFTER" \
    --arg kver_path "$KVER_FILE" --arg kver_before "$KVER_SHA256_BEFORE" --arg kver_after "$KVER_SHA256_AFTER" \
    --arg kernel_path "$KERNEL" --arg kernel_before "$KERNEL_SHA256_BEFORE" --arg kernel_after "$KERNEL_SHA256_AFTER" --argjson kernel_size "$KERNEL_SIZE" \
    --arg initrd_path "$INITRD" --arg initrd_before "$INITRD_SHA256_BEFORE" --arg initrd_after "$INITRD_SHA256_AFTER" --argjson initrd_size "$INITRD_SIZE" \
    --arg rootfs_path "$ROOTFS" --arg rootfs_before "$ROOTFS_SHA256_BEFORE" --arg rootfs_after "$ROOTFS_SHA256_AFTER" --argjson rootfs_size "$ROOTFS_SIZE" \
    --arg source_path "$BENCH_SOURCE" --arg source_before "$BENCH_SOURCE_SHA256_BEFORE" --arg source_after "$BENCH_SOURCE_SHA256_AFTER" \
    --arg staged_source_before "$STAGED_SOURCE_SHA256_BEFORE" --arg staged_source_after "$STAGED_SOURCE_SHA256_AFTER" '
    def stats($field):
        map(.[$field]) | sort as $values |
        ($values | length) as $count |
        {
            count: $count,
            min: $values[0],
            median: (if ($count % 2) == 1 then
                         $values[($count / 2 | floor)]
                     else
                         (($values[$count / 2 - 1] + $values[$count / 2]) / 2)
                     end),
            mean: ($values | add / $count),
            max: $values[-1]
        };
    ($samples) as $sample_rows |
    {
        schema_version: 1,
        role: "guest",
        metadata: $metadata[0],
        samples: $sample_rows,
        distributions: [
            $thread_counts[] as $threads |
            ($sample_rows | map(select(.threads == $threads))) as $rows |
            {
                threads: $threads,
                int_seconds: ($rows | stats("int_seconds")),
                int_gops: ($rows | stats("int_gops")),
                memory_seconds: ($rows | stats("memory_seconds")),
                memory_gib_s: ($rows | stats("memory_gib_s"))
            }
        ],
        benchmark: {
            smp: $smp,
            memory: $memory,
            thread_counts: $thread_counts,
            warmups: $warmups,
            repetitions: $repetitions,
            sample_order: "thread_counts order, then repetition order; warmups omitted",
            int_iterations_per_thread: 400000000,
            int_operations_per_iteration: 4,
            memory_bytes: 268435456,
            memory_passes: 8,
            compile_flags: ["-O2", "-pthread", "-Wall", "-Wextra", "-Werror", "-std=gnu11"],
            compile_argv: ["/usr/bin/gcc", "-O2", "-pthread", "-Wall", "-Wextra", "-Werror",
                           "-std=gnu11", "bench.c", "-o", "bench"],
            argv_template: ["./bench", "--json", "<threads>"]
        },
        inputs: {
            kernel_version: {path: $kver_path, sha256_before: $kver_before, sha256_after: $kver_after},
            kernel: {path: $kernel_path, size: $kernel_size, sha256_before: $kernel_before, sha256_after: $kernel_after},
            initrd: {path: $initrd_path, size: $initrd_size, sha256_before: $initrd_before, sha256_after: $initrd_after},
            rootfs: {path: $rootfs_path, size: $rootfs_size, sha256_before: $rootfs_before, sha256_after: $rootfs_after},
            benchmark_source: {
                path: $source_path,
                sha256_before: $source_before,
                sha256_after: $source_after,
                staged_copy_sha256_before: $staged_source_before,
                staged_copy_sha256_after: $staged_source_after
            }
        },
        run: {
            qemu: {path: $qemu_path, version: $qemu_version, argv: $qemu_argv, sha256_before: $qemu_before, sha256_after: $qemu_after},
            qemu_img: {path: $qemu_img_path, version: $qemu_img_version, sha256_before: $qemu_img_before, sha256_after: $qemu_img_after},
            timeout: {path: $timeout_path, seconds: 1800, sha256_before: $timeout_before, sha256_after: $timeout_after},
            lsof: {path: $lsof_path, sha256_before: $lsof_before, sha256_after: $lsof_after},
            parser: {path: $awk_path, sha256_before: $awk_before, sha256_after: $awk_after},
            jq: {path: $jq_path, version: $jq_version, sha256_before: $jq_before, sha256_after: $jq_after},
            realpath: {path: $realpath_path, sha256_before: $realpath_before, sha256_after: $realpath_after}
        },
        safety: {
            host_privilege_required: false,
            explicit_disposable_overlay: true,
            root_backing_read_only: true,
            root_backing_opened_via_overlay: true,
            source_drive_read_only: true,
            source_block_read_only_proved_in_guest: true,
            source_mount_read_only_proved_in_guest: true,
            warmup_boundaries_validated_in_guest: true,
            qemu_child_pid_captured: true,
            qemu_child_pid_parent_verified: true,
            qemu_wrapper_never_signaled: true,
            cleanup_wait_requires_wrapper_not_running_or_stopped: true,
            qemu_child_absence_required_before_artifact_cleanup: true,
            uncertain_process_state_retains_artifacts_and_lock: true,
            build_drive_attached: false,
            network_disabled: true,
            monitor_disabled: true,
            display_disabled: true,
            firmware_or_pflash_attached: false,
            host_devices_attached: false,
            implicit_disks_disabled: true,
            protected_inputs_unchanged: true,
            protected_tools_unchanged: true,
            staged_source_unchanged: true,
            overlay_removed_after_shutdown: true,
            source_staging_removed_after_shutdown: true,
            serial_fifo_removed_after_shutdown: true
        }
    }
' > "$FINAL_TMP"; then
    fail "could not construct guest benchmark evidence"
fi

if ! "$JQ" -e \
    --slurpfile expected_samples "$RAW_SAMPLES" \
    --argjson expected_argv "$QEMU_ARGV_JSON" \
    --argjson expected_threads "$THREAD_COUNTS_JSON" \
    --argjson repetitions "$REPETITIONS" '
    (keys | sort) == (["benchmark", "distributions", "inputs", "metadata", "role", "run",
                       "safety", "samples", "schema_version"] | sort) and
    .schema_version == 1 and .role == "guest" and
    .samples == $expected_samples and
    .metadata.compiler_path == "/usr/bin/gcc" and
    .metadata.compiler_family == "gcc" and
    (.metadata.compiler_version | test("^[0-9]+([.][0-9]+){0,3}$")) and
    .benchmark.thread_counts == $expected_threads and
    .benchmark.repetitions == $repetitions and
    .benchmark.sample_order == "thread_counts order, then repetition order; warmups omitted" and
    (.run | keys | sort) == (["jq", "lsof", "parser", "qemu", "qemu_img", "realpath", "timeout"] | sort) and
    (.run.qemu | keys | sort) == (["argv", "path", "sha256_after", "sha256_before", "version"] | sort) and
    (.run.qemu_img | keys | sort) == (["path", "sha256_after", "sha256_before", "version"] | sort) and
    (.run.timeout | keys | sort) == (["path", "seconds", "sha256_after", "sha256_before"] | sort) and
    all([.run.lsof, .run.parser, .run.realpath][];
        (keys | sort) == (["path", "sha256_after", "sha256_before"] | sort)) and
    (.run.jq | keys | sort) == (["path", "sha256_after", "sha256_before", "version"] | sort) and
    .run.qemu.argv == $expected_argv and
    .safety == {
        host_privilege_required: false,
        explicit_disposable_overlay: true,
        root_backing_read_only: true,
        root_backing_opened_via_overlay: true,
        source_drive_read_only: true,
        source_block_read_only_proved_in_guest: true,
        source_mount_read_only_proved_in_guest: true,
        warmup_boundaries_validated_in_guest: true,
        qemu_child_pid_captured: true,
        qemu_child_pid_parent_verified: true,
        qemu_wrapper_never_signaled: true,
        cleanup_wait_requires_wrapper_not_running_or_stopped: true,
        qemu_child_absence_required_before_artifact_cleanup: true,
        uncertain_process_state_retains_artifacts_and_lock: true,
        build_drive_attached: false,
        network_disabled: true,
        monitor_disabled: true,
        display_disabled: true,
        firmware_or_pflash_attached: false,
        host_devices_attached: false,
        implicit_disks_disabled: true,
        protected_inputs_unchanged: true,
        protected_tools_unchanged: true,
        staged_source_unchanged: true,
        overlay_removed_after_shutdown: true,
        source_staging_removed_after_shutdown: true,
        serial_fifo_removed_after_shutdown: true
    } and
    all(.inputs[]; .sha256_before == .sha256_after) and
    .inputs.benchmark_source.staged_copy_sha256_before ==
        .inputs.benchmark_source.staged_copy_sha256_after and
    all([.run.qemu, .run.qemu_img, .run.timeout, .run.lsof, .run.parser, .run.jq,
         .run.realpath][];
        .sha256_before == .sha256_after) and
    (.distributions | type) == "array" and
    (.distributions | map(.threads)) == $expected_threads and
    all(.distributions[];
        (keys | sort) == (["int_gops", "int_seconds", "memory_gib_s",
                           "memory_seconds", "threads"] | sort) and
        all([.int_seconds, .int_gops, .memory_seconds, .memory_gib_s][];
            type == "object" and
            (keys | sort) == (["count", "max", "mean", "median", "min"] | sort) and
            .count == $repetitions and
            all([.min, .median, .mean, .max][]; type == "number" and isfinite and . > 0)))
' "$FINAL_TMP" >/dev/null; then
    fail "final guest benchmark evidence failed strict validation"
fi
if "$AWK" '
    {
        lowered = tolower($0)
        if (lowered ~ /machine[ _-]?id|boot[ _-]?id|serial[ _-]?(number|id)|host[ _-]?name|hostname/)
            found = 1
    }
    END { exit found ? 0 : 1 }
' "$FINAL_TMP"; then
    fail "guest benchmark evidence contains a prohibited machine, boot, serial, or hostname identifier term"
fi

verify_protected_inputs || fail "a protected input or tool changed before evidence publication"
INPUTS_VERIFIED=true
cleanup
trap - EXIT
/bin/rm -f -- "$RAW_METADATA"
/bin/mv "$FINAL_TMP" "$FINAL_JSON"
echo "guest benchmark evidence: $FINAL_JSON"
echo "raw guest samples: $RAW_SAMPLES"
echo "normalized console: $CONSOLE"
echo "serial log: $LOG"

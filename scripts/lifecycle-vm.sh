#!/bin/bash
# Exercise the QEMU/HVF boot/shutdown lifecycle across the M3 Ultra CPU-count
# matrix.  Each count gets one disposable qcow2 overlay and two clean QEMU
# launches.  A sentinel written during launch 1 must survive launch 2.
#
# This intentionally tests a relaunch, not an in-process guest reboot.  Serial
# console automation is sufficient for a clean shutdown, while reset/reboot
# control would require a monitor or QMP surface that this safety-focused
# harness deliberately does not expose.
#
#   ./scripts/lifecycle-vm.sh
#   SMP_LIST="1 32" ./scripts/lifecycle-vm.sh
#
# Environment: SMP_LIST (default "1 8 16 24 32"), MEM (default 8G),
# LAUNCH_TIMEOUT (default 300 seconds), BOOT_DELAY (default 30 seconds), and
# optional absolute QEMU/QEMU_IMG/TIMEOUT executable paths.
set -euo pipefail
umask 077
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin
LC_ALL=C
export PATH LC_ALL

# Threat boundary: this harness treats the invoking account and the local
# project/tool directories as trusted against concurrent malicious writers.
# Identity checkpoints plus hashes detect replacement that persists across a
# checkpoint.  Portable pathname APIs cannot eliminate a swap-and-restore
# attack performed entirely between checkpoints, so the evidence records the
# trusted invoking account, OS command directories, and local project/tool
# directory assumption explicitly.
HERE="$(cd "$(/usr/bin/dirname "$0")/.." && pwd -P)"
OUT="$HERE/out"
HARNESS="$HERE/scripts/lifecycle-vm.sh"
QEMU="${QEMU:-/opt/homebrew/bin/qemu-system-aarch64}"
QEMU_IMG="${QEMU_IMG:-/opt/homebrew/bin/qemu-img}"
TIMEOUT="${TIMEOUT:-/opt/homebrew/bin/gtimeout}"
LSOF="/usr/sbin/lsof"
AWK="/usr/bin/awk"
JQ="/usr/bin/jq"
SMP_LIST="${SMP_LIST:-1 8 16 24 32}"
MEM="${MEM:-8G}"
LAUNCH_TIMEOUT="${LAUNCH_TIMEOUT:-300}"
BOOT_DELAY="${BOOT_DELAY:-30}"
KVER_FILE="$OUT/KVER"
ROOTFS="$OUT/vmroot.ext4"
LOCK_DIR="$OUT/.vmroot.ext4.probe.lock"

RUN_DIR=""
CURRENT_OVERLAY=""
SERIAL_FIFO=""
QPID=""
QEMU_CHILD_PID=""
QEMU_PID_FILE=""
FEED_PID=""
LOCK_ACQUIRED=false
LOCK_OWNER=""
LOCK_TOKEN=""
HASHES_READY=false
INPUTS_VERIFIED=false
PROTECTED_WINDOW_STARTED=false
OVERLAY_PATHS=()

fail() {
    echo "lifecycle probe: $*" >&2
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

sha256_text() {
    local digest remainder

    IFS=' ' read -r digest remainder < <(printf '%s' "$1" | /usr/bin/shasum -a 256)
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

# The stable string is deliberately evidence-friendly.  It contains the
# minimum pathname identity required by this harness: device, inode, file
# type, and hard-link count.  Symlinks and non-regular files are rejected at
# every checkpoint rather than merely producing a different identity string.
filesystem_identity() {
    local input=$1

    [ ! -L "$input" ] && [ -f "$input" ] || return 1
    /usr/bin/stat -f 'device=%d;inode=%i;type=%HT;links=%l' "$input"
}

capture_protected_identities() {
    KVER_IDENTITY_BEFORE="$(filesystem_identity "$KVER_FILE")" || return 1
    KERNEL_IDENTITY_BEFORE="$(filesystem_identity "$KERNEL")" || return 1
    INITRD_IDENTITY_BEFORE="$(filesystem_identity "$INITRD")" || return 1
    ROOTFS_IDENTITY_BEFORE="$(filesystem_identity "$ROOTFS")" || return 1
    HARNESS_IDENTITY_BEFORE="$(filesystem_identity "$HARNESS")" || return 1
    QEMU_IDENTITY_BEFORE="$(filesystem_identity "$QEMU_REAL")" || return 1
    QEMU_IMG_IDENTITY_BEFORE="$(filesystem_identity "$QEMU_IMG_REAL")" || return 1
    TIMEOUT_IDENTITY_BEFORE="$(filesystem_identity "$TIMEOUT_REAL")" || return 1
    LSOF_IDENTITY_BEFORE="$(filesystem_identity "$LSOF_REAL")" || return 1
    AWK_IDENTITY_BEFORE="$(filesystem_identity "$AWK_REAL")" || return 1
    JQ_IDENTITY_BEFORE="$(filesystem_identity "$JQ_REAL")" || return 1
}

verify_protected_identities() {
    KVER_IDENTITY_CURRENT="$(filesystem_identity "$KVER_FILE")" || return 1
    KERNEL_IDENTITY_CURRENT="$(filesystem_identity "$KERNEL")" || return 1
    INITRD_IDENTITY_CURRENT="$(filesystem_identity "$INITRD")" || return 1
    ROOTFS_IDENTITY_CURRENT="$(filesystem_identity "$ROOTFS")" || return 1
    HARNESS_IDENTITY_CURRENT="$(filesystem_identity "$HARNESS")" || return 1
    QEMU_IDENTITY_CURRENT="$(filesystem_identity "$QEMU_REAL")" || return 1
    QEMU_IMG_IDENTITY_CURRENT="$(filesystem_identity "$QEMU_IMG_REAL")" || return 1
    TIMEOUT_IDENTITY_CURRENT="$(filesystem_identity "$TIMEOUT_REAL")" || return 1
    LSOF_IDENTITY_CURRENT="$(filesystem_identity "$LSOF_REAL")" || return 1
    AWK_IDENTITY_CURRENT="$(filesystem_identity "$AWK_REAL")" || return 1
    JQ_IDENTITY_CURRENT="$(filesystem_identity "$JQ_REAL")" || return 1

    [ "$KVER_IDENTITY_BEFORE" = "$KVER_IDENTITY_CURRENT" ] &&
        [ "$KERNEL_IDENTITY_BEFORE" = "$KERNEL_IDENTITY_CURRENT" ] &&
        [ "$INITRD_IDENTITY_BEFORE" = "$INITRD_IDENTITY_CURRENT" ] &&
        [ "$ROOTFS_IDENTITY_BEFORE" = "$ROOTFS_IDENTITY_CURRENT" ] &&
        [ "$HARNESS_IDENTITY_BEFORE" = "$HARNESS_IDENTITY_CURRENT" ] &&
        [ "$QEMU_IDENTITY_BEFORE" = "$QEMU_IDENTITY_CURRENT" ] &&
        [ "$QEMU_IMG_IDENTITY_BEFORE" = "$QEMU_IMG_IDENTITY_CURRENT" ] &&
        [ "$TIMEOUT_IDENTITY_BEFORE" = "$TIMEOUT_IDENTITY_CURRENT" ] &&
        [ "$LSOF_IDENTITY_BEFORE" = "$LSOF_IDENTITY_CURRENT" ] &&
        [ "$AWK_IDENTITY_BEFORE" = "$AWK_IDENTITY_CURRENT" ] &&
        [ "$JQ_IDENTITY_BEFORE" = "$JQ_IDENTITY_CURRENT" ]
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
    echo "lifecycle probe: lsof failed for $path (status $status): $output" >&2
    return 1
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

hash_inputs_before() {
    KVER_SHA256_BEFORE="$(sha256_file "$KVER_FILE")"
    KERNEL_SHA256_BEFORE="$(sha256_file "$KERNEL")"
    INITRD_SHA256_BEFORE="$(sha256_file "$INITRD")"
    ROOTFS_SHA256_BEFORE="$(sha256_file "$ROOTFS")"
    HARNESS_SHA256_BEFORE="$(sha256_file "$HARNESS")"
    QEMU_SHA256_BEFORE="$(sha256_file "$QEMU_REAL")"
    QEMU_IMG_SHA256_BEFORE="$(sha256_file "$QEMU_IMG_REAL")"
    TIMEOUT_SHA256_BEFORE="$(sha256_file "$TIMEOUT_REAL")"
    LSOF_SHA256_BEFORE="$(sha256_file "$LSOF_REAL")"
    AWK_SHA256_BEFORE="$(sha256_file "$AWK_REAL")"
    JQ_SHA256_BEFORE="$(sha256_file "$JQ_REAL")"
    HASHES_READY=true
}

hash_inputs_after() {
    KVER_SHA256_AFTER="$(sha256_file "$KVER_FILE")" || return 1
    KERNEL_SHA256_AFTER="$(sha256_file "$KERNEL")" || return 1
    INITRD_SHA256_AFTER="$(sha256_file "$INITRD")" || return 1
    ROOTFS_SHA256_AFTER="$(sha256_file "$ROOTFS")" || return 1
    HARNESS_SHA256_AFTER="$(sha256_file "$HARNESS")" || return 1
    QEMU_SHA256_AFTER="$(sha256_file "$QEMU_REAL")" || return 1
    QEMU_IMG_SHA256_AFTER="$(sha256_file "$QEMU_IMG_REAL")" || return 1
    TIMEOUT_SHA256_AFTER="$(sha256_file "$TIMEOUT_REAL")" || return 1
    LSOF_SHA256_AFTER="$(sha256_file "$LSOF_REAL")" || return 1
    AWK_SHA256_AFTER="$(sha256_file "$AWK_REAL")" || return 1
    JQ_SHA256_AFTER="$(sha256_file "$JQ_REAL")" || return 1

    [ "$KVER_SHA256_BEFORE" = "$KVER_SHA256_AFTER" ] &&
        [ "$KERNEL_SHA256_BEFORE" = "$KERNEL_SHA256_AFTER" ] &&
        [ "$INITRD_SHA256_BEFORE" = "$INITRD_SHA256_AFTER" ] &&
        [ "$ROOTFS_SHA256_BEFORE" = "$ROOTFS_SHA256_AFTER" ] &&
        [ "$HARNESS_SHA256_BEFORE" = "$HARNESS_SHA256_AFTER" ] &&
        [ "$QEMU_SHA256_BEFORE" = "$QEMU_SHA256_AFTER" ] &&
        [ "$QEMU_IMG_SHA256_BEFORE" = "$QEMU_IMG_SHA256_AFTER" ] &&
        [ "$TIMEOUT_SHA256_BEFORE" = "$TIMEOUT_SHA256_AFTER" ] &&
        [ "$LSOF_SHA256_BEFORE" = "$LSOF_SHA256_AFTER" ] &&
        [ "$AWK_SHA256_BEFORE" = "$AWK_SHA256_AFTER" ] &&
        [ "$JQ_SHA256_BEFORE" = "$JQ_SHA256_AFTER" ]
}

canonical_process_pid() {
    case "$1" in
        ''|*[!0-9]*|0|1) return 1 ;;
    esac
    [ "$1" -gt 1 ]
}

running_shell_job() {
    local wanted=$1
    local running_jobs job_pid

    canonical_process_pid "$wanted" || return 1
    running_jobs="$(jobs -rp 2>/dev/null)" || return 1
    while IFS= read -r job_pid; do
        [ "$job_pid" = "$wanted" ] && return 0
    done <<< "$running_jobs"
    return 1
}

verified_qemu_child() {
    local observed_parent

    canonical_process_pid "$QEMU_CHILD_PID" || return 1
    running_shell_job "$QPID" || return 1
    [ "$QEMU_CHILD_PID" != "$QPID" ] || return 1
    observed_parent="$(/bin/ps -o ppid= -p "$QEMU_CHILD_PID" 2>/dev/null)" || return 1
    observed_parent="${observed_parent//[[:space:]]/}"
    [ "$observed_parent" = "$QPID" ]
}

# Signal only PIDs that are still registered as this shell's jobs, or a QEMU
# child whose live parent is that verified timeout job.  This makes signal
# cleanup prompt without risking a reused, unrelated numeric PID.
terminate_owned_jobs() {
    local step

    if [ -n "$QPID" ] && running_shell_job "$QPID"; then
        if verified_qemu_child; then
            /bin/kill -TERM "$QEMU_CHILD_PID" 2>/dev/null || true
        else
            # If interruption arrives before the pid file is populated, the
            # verified shell-owned gtimeout job is the only safe target.  GNU
            # timeout forwards the termination signal to its monitored child.
            /bin/kill -TERM "$QPID" 2>/dev/null || true
        fi
    fi
    if [ -n "$FEED_PID" ] && running_shell_job "$FEED_PID"; then
        /bin/kill -TERM "$FEED_PID" 2>/dev/null || true
    fi

    # Give a directly signalled QEMU and the feeder at most two seconds to
    # leave voluntarily while the timeout wrapper remains available to reap.
    for ((step = 0; step < 20; step++)); do
        { ! verified_qemu_child &&
          { [ -z "$FEED_PID" ] || ! running_shell_job "$FEED_PID"; }; } && break
        /bin/sleep 0.1
    done
    if verified_qemu_child; then
        /bin/kill -KILL "$QEMU_CHILD_PID" 2>/dev/null || true
    fi
    if [ -n "$QPID" ] && running_shell_job "$QPID"; then
        /bin/kill -TERM "$QPID" 2>/dev/null || true
    fi
    for ((step = 0; step < 10; step++)); do
        { { [ -z "$QPID" ] || ! running_shell_job "$QPID"; } &&
          { [ -z "$FEED_PID" ] || ! running_shell_job "$FEED_PID"; }; } && break
        /bin/sleep 0.1
    done
    if [ -n "$QPID" ] && running_shell_job "$QPID"; then
        /bin/kill -KILL "$QPID" 2>/dev/null || true
    fi
    if [ -n "$FEED_PID" ] && running_shell_job "$FEED_PID"; then
        /bin/kill -KILL "$FEED_PID" 2>/dev/null || true
    fi

    if [ -n "$QPID" ]; then
        wait "$QPID" 2>/dev/null || true
        QPID=""
        QEMU_CHILD_PID=""
    fi
    if [ -n "$FEED_PID" ]; then
        wait "$FEED_PID" 2>/dev/null || true
        FEED_PID=""
    fi
}

cleanup() {
    local cleanup_status=${1:-$?}
    local openers="" overlay_path

    terminate_owned_jobs
    exec 9>&- 9<&- 2>/dev/null || true
    if [ -n "$SERIAL_FIFO" ] && { [ -e "$SERIAL_FIFO" ] || [ -L "$SERIAL_FIFO" ]; }; then
        if [ -p "$SERIAL_FIFO" ] && [ ! -L "$SERIAL_FIFO" ] &&
           /bin/rm -f -- "$SERIAL_FIFO"; then
            :
        else
            cleanup_status=1
        fi
    fi
    SERIAL_FIFO=""
    if [ -n "$QEMU_PID_FILE" ] && { [ -e "$QEMU_PID_FILE" ] || [ -L "$QEMU_PID_FILE" ]; }; then
        if [ -f "$QEMU_PID_FILE" ] && [ ! -L "$QEMU_PID_FILE" ]; then
            /bin/rm -f -- "$QEMU_PID_FILE" || cleanup_status=1
        else
            echo "lifecycle probe: refusing a replaced QEMU pid file" >&2
            cleanup_status=1
        fi
    fi
    QEMU_PID_FILE=""
    for overlay_path in "${OVERLAY_PATHS[@]}"; do
        if [ -L "$overlay_path" ]; then
            echo "lifecycle probe: refusing a replaced symlink at overlay path: $overlay_path" >&2
            cleanup_status=1
        elif [ -f "$overlay_path" ]; then
            if ! openers="$(lsof_openers "$overlay_path")"; then
                cleanup_status=1
            elif [ -n "$openers" ]; then
                echo "lifecycle probe: refusing to remove overlay still open by pid(s): $openers" >&2
                cleanup_status=1
            elif ! /bin/rm -f -- "$overlay_path"; then
                cleanup_status=1
            fi
        elif [ -e "$overlay_path" ]; then
            echo "lifecycle probe: refusing unexpected object at overlay path: $overlay_path" >&2
            cleanup_status=1
        fi
        if [ -e "$overlay_path" ] || [ -L "$overlay_path" ]; then
            echo "lifecycle probe: disposable overlay remains: $overlay_path" >&2
            cleanup_status=1
        fi
    done
    if [ "$PROTECTED_WINDOW_STARTED" = true ] && [ "$HASHES_READY" = true ] &&
       [ "$INPUTS_VERIFIED" = false ]; then
        if verify_protected_identities && hash_inputs_after; then
            INPUTS_VERIFIED=true
        else
            echo "lifecycle probe: a protected input identity or content changed during cleanup" >&2
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

    trap - EXIT
    if cleanup "$original_status"; then
        cleanup_status=0
    else
        cleanup_status=$?
    fi
    [ "$original_status" -eq 0 ] || cleanup_status=$original_status
    exit "$cleanup_status"
}
trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

[ "$#" -eq 0 ] || fail "this runner takes no command-line arguments"

case "$LAUNCH_TIMEOUT" in
    ''|*[!0-9]*|0|0*) fail "LAUNCH_TIMEOUT must be a positive canonical integer" ;;
esac
[ "$LAUNCH_TIMEOUT" -le 900 ] || fail "LAUNCH_TIMEOUT exceeds the 900-second safety limit"
case "$BOOT_DELAY" in
    ''|*[!0-9]*|0|0*) fail "BOOT_DELAY must be a positive canonical integer" ;;
esac
[ "$BOOT_DELAY" -le 120 ] || fail "BOOT_DELAY exceeds the 120-second safety limit"

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

case "$SMP_LIST" in
    *$'\n'*|*$'\r'*) fail "SMP_LIST must be a single whitespace-separated line" ;;
esac
read -r -a SMP_COUNTS <<< "$SMP_LIST"
[ "${#SMP_COUNTS[@]}" -gt 0 ] || fail "SMP_LIST must contain at least one vCPU count"
SEEN_COUNTS=" "
for smp in "${SMP_COUNTS[@]}"; do
    case "$smp" in
        ''|*[!0-9]*|0|0*) fail "invalid vCPU count in SMP_LIST: $smp" ;;
    esac
    [ "$smp" -le 64 ] || fail "vCPU count exceeds the 64-vCPU safety limit: $smp"
    case "$SEEN_COUNTS" in
        *" $smp "*) fail "duplicate vCPU count in SMP_LIST: $smp" ;;
    esac
    SEEN_COUNTS="$SEEN_COUNTS$smp "
done

[ "$(/usr/bin/id -u)" -ne 0 ] || fail "refusing to run QEMU as host root"
if [ -L "$OUT" ]; then
    fail "refusing symlinked output root: $OUT"
fi
/bin/mkdir -p "$OUT"
[ "$(cd "$OUT" && pwd -P)" = "$OUT" ] || fail "output root is not canonical: $OUT"

for tool in "$QEMU" "$QEMU_IMG" "$TIMEOUT" "$LSOF" "$AWK" "$JQ"; do
    [ -x "$tool" ] || fail "missing executable: $tool"
    [ ! -u "$tool" ] && [ ! -g "$tool" ] || fail "refusing setuid/setgid executable: $tool"
done
QEMU_REAL="$(/bin/realpath "$QEMU")"
QEMU_IMG_REAL="$(/bin/realpath "$QEMU_IMG")"
TIMEOUT_REAL="$(/bin/realpath "$TIMEOUT")"
LSOF_REAL="$(/bin/realpath "$LSOF")"
AWK_REAL="$(/bin/realpath "$AWK")"
JQ_REAL="$(/bin/realpath "$JQ")"
for tool in "$QEMU_REAL" "$QEMU_IMG_REAL" "$TIMEOUT_REAL" "$LSOF_REAL" \
            "$AWK_REAL" "$JQ_REAL"; do
    [ -f "$tool" ] && [ -x "$tool" ] || fail "executable resolves unsafely: $tool"
done
QEMU="$QEMU_REAL"
QEMU_IMG="$QEMU_IMG_REAL"
TIMEOUT="$TIMEOUT_REAL"
LSOF="$LSOF_REAL"
AWK="$AWK_REAL"
JQ="$JQ_REAL"

require_safe_input "$KVER_FILE"
KVER_SHA256_SELECTED="$(sha256_file "$KVER_FILE")" || fail "could not hash KVER"
KVER="$(/bin/cat "$KVER_FILE")"
case "$KVER" in
    ''|.|..|*/*|*[!A-Za-z0-9.+_~-]*) fail "KVER contains unsafe characters: $KVER" ;;
esac
KERNEL="$OUT/Image-$KVER"
INITRD="$OUT/initrd.img-$KVER"
for input in "$KERNEL" "$INITRD" "$ROOTFS" "$HARNESS"; do
    require_safe_input "$input"
done
INPUT_LIST=("$KVER_FILE" "$KERNEL" "$INITRD" "$ROOTFS" "$HARNESS")
for ((left = 0; left < ${#INPUT_LIST[@]}; left++)); do
    for ((right = left + 1; right < ${#INPUT_LIST[@]}; right++)); do
        [ ! "${INPUT_LIST[$left]}" -ef "${INPUT_LIST[$right]}" ] ||
            fail "protected inputs resolve to the same file"
    done
done

QEMU_VERSION="$("$QEMU" --version)"
QEMU_VERSION="${QEMU_VERSION%%$'\n'*}"
JQ_VERSION="$("$JQ" --version)"
if ! /bin/mkdir "$LOCK_DIR" 2>/dev/null; then
    fail "another VM probe owns $LOCK_DIR; inspect it rather than deleting it blindly"
fi
LOCK_ACQUIRED=true
LOCK_TOKEN="$$:$(/bin/date +%s):$RANDOM"
LOCK_OWNER="$LOCK_DIR/owner.$$"
printf '%s\n' "$LOCK_TOKEN" > "$LOCK_OWNER"
OPENERS="$(lsof_openers "$ROOTFS")" || fail "could not verify vmroot.ext4 openers"
[ -z "$OPENERS" ] || fail "vmroot.ext4 is already open by pid(s): $OPENERS"

RUN_DIR="$(/usr/bin/mktemp -d "$OUT/lifecycle-matrix.XXXXXX")"
/bin/chmod 700 "$RUN_DIR"
MANIFEST="$RUN_DIR/manifest.json"
MANIFEST_TMP="$(/usr/bin/mktemp "$RUN_DIR/.manifest.XXXXXX")"
# macOS expresses RLIMIT_FSIZE in 512-byte blocks.  Bound each log, overlay,
# and JSON artifact to 256 MiB even if a guest or QEMU misbehaves.
ulimit -f 524288

marker_count() {
    local line=$1
    local file=$2

    "$AWK" -v wanted="$line" '$0 == wanted { count++ } END { print count + 0 }' "$file"
}

extract_online_count() {
    local cycle=$1
    local configured=$2
    local file=$3

    "$AWK" -v wanted_cycle="$cycle" -v wanted_configured="$configured" '
        $1 == "LIFECYCLE_CPU" &&
        $2 == "cycle=" wanted_cycle &&
        $3 == "configured=" wanted_configured &&
        $4 ~ /^online=[0-9]+$/ {
            value = $4
            sub(/^online=/, "", value)
            count++
        }
        END {
            if (count == 1) print value
        }
    ' "$file"
}

make_guest_script() {
    local cycle=$1
    local smp=$2
    local token=$3

    if [ "$cycle" -eq 1 ]; then
        /bin/cat <<GUEST_EOF
set -eu
guest_shutdown() {
    rc=\$?
    trap - EXIT
    if [ "\$rc" -ne 0 ]; then
        echo "LIFECYCLE_GUEST_ERROR cycle=1 rc=\$rc"
    fi
    sync
    echo "LIFECYCLE_CLEAN_SHUTDOWN_REQUESTED cycle=1"
    systemctl poweroff || true
    sleep 300
}
trap guest_shutdown EXIT
echo "LIFECYCLE_CYCLE_BEGIN cycle=1"
online=\$(getconf _NPROCESSORS_ONLN)
echo "LIFECYCLE_CPU cycle=1 configured=$smp online=\$online"
install -d -m 700 /var/lib/m3-hvf-lifecycle
printf '%s\\n' '$token' > /var/lib/m3-hvf-lifecycle/sentinel.new
chmod 600 /var/lib/m3-hvf-lifecycle/sentinel.new
mv /var/lib/m3-hvf-lifecycle/sentinel.new /var/lib/m3-hvf-lifecycle/sentinel
sync
IFS= read -r observed < /var/lib/m3-hvf-lifecycle/sentinel
[ "\$observed" = '$token' ]
echo "LIFECYCLE_SENTINEL_WRITE_OK cycle=1"
echo "LIFECYCLE_CYCLE_COMPLETE cycle=1"
trap - EXIT
sync
echo "LIFECYCLE_CLEAN_SHUTDOWN_REQUESTED cycle=1"
systemctl poweroff
sleep 300
exit 1
GUEST_EOF
    else
        /bin/cat <<GUEST_EOF
set -eu
guest_shutdown() {
    rc=\$?
    trap - EXIT
    if [ "\$rc" -ne 0 ]; then
        echo "LIFECYCLE_GUEST_ERROR cycle=2 rc=\$rc"
    fi
    sync
    echo "LIFECYCLE_CLEAN_SHUTDOWN_REQUESTED cycle=2"
    systemctl poweroff || true
    sleep 300
}
trap guest_shutdown EXIT
echo "LIFECYCLE_CYCLE_BEGIN cycle=2"
online=\$(getconf _NPROCESSORS_ONLN)
echo "LIFECYCLE_CPU cycle=2 configured=$smp online=\$online"
[ -f /var/lib/m3-hvf-lifecycle/sentinel ]
IFS= read -r observed < /var/lib/m3-hvf-lifecycle/sentinel
[ "\$observed" = '$token' ]
echo "LIFECYCLE_SENTINEL_PERSISTED_OK cycle=2"
echo "LIFECYCLE_CYCLE_COMPLETE cycle=2"
trap - EXIT
sync
echo "LIFECYCLE_CLEAN_SHUTDOWN_REQUESTED cycle=2"
systemctl poweroff
sleep 300
exit 1
GUEST_EOF
    fi
}

run_cycle() {
    local cycle=$1
    local smp=$2
    local token=$3
    local log=$4
    local console=$5
    local guest_script pid_step

    CYCLE_STATUS=125
    CYCLE_TIMED_OUT=false
    CYCLE_BEGIN=false
    CYCLE_CPU_MARKER=false
    CYCLE_SENTINEL=false
    CYCLE_COMPLETE=false
    CYCLE_CLEAN_SHUTDOWN=false
    CYCLE_GUEST_ERROR=false
    CYCLE_ONLINE=""
    CYCLE_IDENTITY_BEFORE=false
    CYCLE_IDENTITY_AFTER=false
    CYCLE_PID_FILE_REMOVED=false
    CYCLE_VALID=false

    guest_script="$(make_guest_script "$cycle" "$smp" "$token")"
    SERIAL_FIFO="$COUNT_DIR/serial-$cycle.in"
    : > "$log"
    : > "$console"
    /usr/bin/mkfifo -m 600 "$SERIAL_FIFO"
    exec 9<> "$SERIAL_FIFO"
    QEMU_PID_FILE="$COUNT_DIR/qemu-$cycle.pid"
    : > "$QEMU_PID_FILE"
    /bin/chmod 600 "$QEMU_PID_FILE"

    # This is the last pathname operation before creating the launch jobs.
    # A mismatch aborts without executing QEMU.
    verify_protected_identities ||
        fail "protected input identity changed immediately before cycle $cycle"
    CYCLE_IDENTITY_BEFORE=true
    (
        # Use Bash's timed read as a childless timer.  The FIFO has no writer
        # until this subshell writes the command stream, and guest output goes
        # to the serial log, so the read cannot consume guest data.  Keeping
        # the feeder childless lets signal cleanup terminate FEED_PID itself
        # promptly without leaving an orphaned sleep process.
        IFS= read -r -t "$BOOT_DELAY" <&9 || true
        printf 'stty -echo\n' >&9
        printf "/bin/bash <<'LIFECYCLE_GUEST_EOF'\n%s\nLIFECYCLE_GUEST_EOF\n" \
            "$guest_script" >&9
    ) &
    FEED_PID=$!

    set +e
    /usr/bin/env -i \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin \
        TMPDIR="$COUNT_DIR" \
        HOME="$COUNT_DIR" \
        "$TIMEOUT" --foreground --signal=TERM --kill-after=10 "$LAUNCH_TIMEOUT" \
        /bin/sh -c 'printf "%s\n" "$$" > "$1" || exit 125; shift; exec "$@"' \
        lifecycle-qemu-launch "$QEMU_PID_FILE" "$QEMU" "${ARGS[@]}" \
        <&9 > "$log" 2>&1 &
    QPID=$!
    for ((pid_step = 0; pid_step < 100; pid_step++)); do
        [ -s "$QEMU_PID_FILE" ] && break
        running_shell_job "$QPID" || break
        /bin/sleep 0.05
    done
    if [ -s "$QEMU_PID_FILE" ] && [ -f "$QEMU_PID_FILE" ] && [ ! -L "$QEMU_PID_FILE" ]; then
        IFS= read -r QEMU_CHILD_PID < "$QEMU_PID_FILE" || true
    fi
    if ! verified_qemu_child; then
        terminate_owned_jobs
        CYCLE_STATUS=125
    else
        wait "$QPID"
        CYCLE_STATUS=$?
        QPID=""
        QEMU_CHILD_PID=""
    fi
    set -e

    # QEMU is gone and no other artifact processing has occurred yet.
    if verify_protected_identities; then
        CYCLE_IDENTITY_AFTER=true
    else
        STOP_AFTER_COUNT=true
    fi
    if [ -n "$FEED_PID" ]; then
        wait "$FEED_PID" 2>/dev/null || true
        FEED_PID=""
    fi
    exec 9>&- 9<&-
    /bin/rm -f -- "$SERIAL_FIFO"
    SERIAL_FIFO=""
    if [ -f "$QEMU_PID_FILE" ] && [ ! -L "$QEMU_PID_FILE" ]; then
        /bin/rm -f -- "$QEMU_PID_FILE"
    else
        fail "QEMU pid staging path was replaced during cycle $cycle"
    fi
    QEMU_PID_FILE=""
    CYCLE_PID_FILE_REMOVED=true

    "$AWK" '
        {
            gsub(/\033\][^\007\033]*\007/, "")
            gsub(/\033\][^\007\033]*\033\\/, "")
            gsub(/\033\[[0-9;?]*[[:alpha:]]/, "")
            gsub(/\r/, "")
            print
        }
    ' "$log" > "$console"

    [ "$CYCLE_STATUS" -ne 124 ] || CYCLE_TIMED_OUT=true
    [ "$(marker_count "LIFECYCLE_CYCLE_BEGIN cycle=$cycle" "$console")" -eq 1 ] &&
        CYCLE_BEGIN=true
    CYCLE_ONLINE="$(extract_online_count "$cycle" "$smp" "$console")"
    case "$CYCLE_ONLINE" in
        ''|*[!0-9]*) ;;
        *) [ "$CYCLE_ONLINE" -eq "$smp" ] && CYCLE_CPU_MARKER=true ;;
    esac
    if [ "$cycle" -eq 1 ]; then
        [ "$(marker_count "LIFECYCLE_SENTINEL_WRITE_OK cycle=1" "$console")" -eq 1 ] &&
            CYCLE_SENTINEL=true
    else
        [ "$(marker_count "LIFECYCLE_SENTINEL_PERSISTED_OK cycle=2" "$console")" -eq 1 ] &&
            CYCLE_SENTINEL=true
    fi
    [ "$(marker_count "LIFECYCLE_CYCLE_COMPLETE cycle=$cycle" "$console")" -eq 1 ] &&
        CYCLE_COMPLETE=true
    [ "$(marker_count "LIFECYCLE_CLEAN_SHUTDOWN_REQUESTED cycle=$cycle" "$console")" -eq 1 ] &&
        CYCLE_CLEAN_SHUTDOWN=true
    [ "$("$AWK" -v cycle="$cycle" \
        '$0 ~ ("^LIFECYCLE_GUEST_ERROR cycle=" cycle " rc=[0-9]+$") { n++ } END { print n + 0 }' \
        "$console")" -eq 0 ] || CYCLE_GUEST_ERROR=true

    if [ "$CYCLE_STATUS" -eq 0 ] && [ "$CYCLE_TIMED_OUT" = false ] &&
       [ "$CYCLE_BEGIN" = true ] && [ "$CYCLE_CPU_MARKER" = true ] &&
       [ "$CYCLE_SENTINEL" = true ] && [ "$CYCLE_COMPLETE" = true ] &&
       [ "$CYCLE_CLEAN_SHUTDOWN" = true ] && [ "$CYCLE_GUEST_ERROR" = false ] &&
       [ "$CYCLE_IDENTITY_BEFORE" = true ] && [ "$CYCLE_IDENTITY_AFTER" = true ] &&
       [ "$CYCLE_PID_FILE_REMOVED" = true ]; then
        CYCLE_VALID=true
    fi
}

EVIDENCE_FILES=()
COMPLETED_COUNTS=()
OVERALL_PASS=true
STOP_AFTER_COUNT=false

run_count() {
    local smp=$1
    local token token_sha256 overlay_info openers
    local c1_status c1_online c1_timed_out c1_begin c1_cpu c1_sentinel
    local c1_complete c1_shutdown c1_error c1_identity_before c1_identity_after
    local c1_pid_file_removed c1_valid
    local c2_status=125 c2_online="" c2_timed_out=false c2_begin=false
    local c2_cpu=false c2_sentinel=false c2_complete=false c2_shutdown=false
    local c2_error=false c2_identity_before=false c2_identity_after=false
    local c2_pid_file_removed=false c2_valid=false c2_attempted=false
    local overlay_removed=false inputs_unchanged=false identities_stable=false
    local final_identity_check=false result=false failure_reason=""
    local c1_online_json=null c2_online_json=null c2_status_json=null
    local evidence evidence_tmp qemu_argv_json expected_drive

    COUNT_DIR="$RUN_DIR/smp-$smp"
    /bin/mkdir -m 700 "$COUNT_DIR"
    CURRENT_OVERLAY="$COUNT_DIR/root-smp${smp}.qcow2"
    CYCLE1_LOG="$COUNT_DIR/cycle-1.serial.log"
    CYCLE1_CONSOLE="$COUNT_DIR/cycle-1.console.txt"
    CYCLE2_LOG="$COUNT_DIR/cycle-2.serial.log"
    CYCLE2_CONSOLE="$COUNT_DIR/cycle-2.console.txt"
    evidence="$COUNT_DIR/evidence.json"
    evidence_tmp="$(/usr/bin/mktemp "$COUNT_DIR/.evidence.XXXXXX")"

    INPUTS_VERIFIED=false
    OVERLAY_PATHS+=("$CURRENT_OVERLAY")

    verify_protected_identities ||
        fail "protected input identity changed before overlay creation for ${smp} vCPUs"
    "$QEMU_IMG" create -q -f qcow2 -F raw -b "$ROOTFS" "$CURRENT_OVERLAY"
    /bin/chmod 600 "$CURRENT_OVERLAY"
    overlay_info="$("$QEMU_IMG" info --output=json "$CURRENT_OVERLAY")"
    if ! "$JQ" -e --arg rootfs "$ROOTFS" '
        .format == "qcow2" and
        .["backing-filename"] == $rootfs and
        .["backing-filename-format"] == "raw"
    ' <<< "$overlay_info" >/dev/null; then
        fail "disposable overlay does not have the required raw backing file"
    fi

    ARGS=(
        -M virt,highmem=on
        -accel hvf,kernel-irqchip=on
        -cpu host
        -smp "$smp,sockets=1,cores=$smp,threads=1"
        -m "$MEM"
        -kernel "$KERNEL"
        -initrd "$INITRD"
        -append "root=/dev/vda rootfstype=ext4 rw console=ttyAMA0 systemd.unit=multi-user.target systemd.mask=m3-build.service"
        -drive "if=virtio,file=$CURRENT_OVERLAY,format=qcow2,cache=none"
        -nic none
        -display none
        -monitor none
        -serial stdio
        -nodefaults
        -no-reboot
    )
    qemu_argv_json="$("$JQ" -n --args '$ARGS.positional' -- "$QEMU" "${ARGS[@]}")"
    expected_drive="if=virtio,file=$CURRENT_OVERLAY,format=qcow2,cache=none"
    if ! "$JQ" -e \
        --arg qemu "$QEMU" \
        --arg drive "$expected_drive" '
        . as $argv |
        $argv[0] == $qemu and
        ([$argv[] | select(. == "-drive")] | length) == 1 and
        ([range(0; ($argv | length) - 1) as $i |
            select($argv[$i] == "-drive" and $argv[$i + 1] == $drive)] | length) == 1 and
        ([range(0; ($argv | length) - 1) as $i |
            select($argv[$i] == "-nic" and $argv[$i + 1] == "none")] | length) == 1 and
        ([range(0; ($argv | length) - 1) as $i |
            select($argv[$i] == "-display" and $argv[$i + 1] == "none")] | length) == 1 and
        ([range(0; ($argv | length) - 1) as $i |
            select($argv[$i] == "-monitor" and $argv[$i + 1] == "none")] | length) == 1 and
        ([range(0; ($argv | length) - 1) as $i |
            select($argv[$i] == "-serial" and $argv[$i + 1] == "stdio")] | length) == 1 and
        ($argv | index("-nodefaults")) != null and
        ($argv | index("-no-reboot")) != null and
        all(["-bios", "-pflash", "-firmware", "-netdev", "-device", "-object", "-qmp"][];
            . as $forbidden | ($argv | index($forbidden)) == null)
    ' <<< "$qemu_argv_json" >/dev/null; then
        fail "internal QEMU argument safety contract failed validation"
    fi

    token="m3-hvf-lifecycle-smp${smp}-$(/bin/date +%s)-$RANDOM$RANDOM"
    token_sha256="$(sha256_text "$token")"
    echo "booting lifecycle cycle 1: ${smp} vCPUs, ${MEM} RAM -> $COUNT_DIR"
    run_cycle 1 "$smp" "$token" "$CYCLE1_LOG" "$CYCLE1_CONSOLE"
    c1_status=$CYCLE_STATUS
    c1_online=$CYCLE_ONLINE
    c1_timed_out=$CYCLE_TIMED_OUT
    c1_begin=$CYCLE_BEGIN
    c1_cpu=$CYCLE_CPU_MARKER
    c1_sentinel=$CYCLE_SENTINEL
    c1_complete=$CYCLE_COMPLETE
    c1_shutdown=$CYCLE_CLEAN_SHUTDOWN
    c1_error=$CYCLE_GUEST_ERROR
    c1_identity_before=$CYCLE_IDENTITY_BEFORE
    c1_identity_after=$CYCLE_IDENTITY_AFTER
    c1_pid_file_removed=$CYCLE_PID_FILE_REMOVED
    c1_valid=$CYCLE_VALID

    if [ "$c1_valid" = true ]; then
        c2_attempted=true
        echo "booting lifecycle cycle 2 (relaunch): ${smp} vCPUs"
        run_cycle 2 "$smp" "$token" "$CYCLE2_LOG" "$CYCLE2_CONSOLE"
        c2_status=$CYCLE_STATUS
        c2_online=$CYCLE_ONLINE
        c2_timed_out=$CYCLE_TIMED_OUT
        c2_begin=$CYCLE_BEGIN
        c2_cpu=$CYCLE_CPU_MARKER
        c2_sentinel=$CYCLE_SENTINEL
        c2_complete=$CYCLE_COMPLETE
        c2_shutdown=$CYCLE_CLEAN_SHUTDOWN
        c2_error=$CYCLE_GUEST_ERROR
        c2_identity_before=$CYCLE_IDENTITY_BEFORE
        c2_identity_after=$CYCLE_IDENTITY_AFTER
        c2_pid_file_removed=$CYCLE_PID_FILE_REMOVED
        c2_valid=$CYCLE_VALID
    else
        : > "$CYCLE2_LOG"
        : > "$CYCLE2_CONSOLE"
    fi

    if [ -f "$CURRENT_OVERLAY" ] && [ ! -L "$CURRENT_OVERLAY" ]; then
        openers="$(lsof_openers "$CURRENT_OVERLAY")" ||
            fail "could not verify disposable overlay openers"
        if [ -z "$openers" ] && /bin/rm -f -- "$CURRENT_OVERLAY" &&
           [ ! -e "$CURRENT_OVERLAY" ] && [ ! -L "$CURRENT_OVERLAY" ]; then
            overlay_removed=true
        fi
    fi

    echo "verifying protected inputs after ${smp}-vCPU lifecycle test"
    if verify_protected_identities; then
        final_identity_check=true
    else
        STOP_AFTER_COUNT=true
    fi
    if hash_inputs_after; then
        inputs_unchanged=true
    else
        STOP_AFTER_COUNT=true
    fi
    if [ "$c1_identity_before" = true ] && [ "$c1_identity_after" = true ] &&
       { [ "$c2_attempted" = false ] ||
         { [ "$c2_identity_before" = true ] && [ "$c2_identity_after" = true ]; }; } &&
       [ "$final_identity_check" = true ]; then
        identities_stable=true
    fi
    if [ "$inputs_unchanged" = true ] && [ "$identities_stable" = true ]; then
        INPUTS_VERIFIED=true
    fi

    case "$c1_online" in ''|*[!0-9]*) ;; *) c1_online_json=$c1_online ;; esac
    if [ "$c2_attempted" = true ]; then
        c2_status_json=$c2_status
        case "$c2_online" in ''|*[!0-9]*) ;; *) c2_online_json=$c2_online ;; esac
    fi

    if [ "$c1_valid" = true ] && [ "$c2_valid" = true ] &&
       [ "$c2_sentinel" = true ] && [ "$overlay_removed" = true ] &&
       [ "$inputs_unchanged" = true ] && [ "$identities_stable" = true ]; then
        result=true
    elif [ "$identities_stable" != true ]; then
        failure_reason="a protected input filesystem identity changed during the lifecycle test"
    elif [ "$c1_valid" != true ]; then
        failure_reason="cycle 1 did not satisfy the lifecycle marker and shutdown contract"
    elif [ "$c2_valid" != true ]; then
        failure_reason="cycle 2 did not satisfy the relaunch persistence and shutdown contract"
    elif [ "$overlay_removed" != true ]; then
        failure_reason="disposable overlay could not be removed safely"
    else
        failure_reason="a protected input changed during the lifecycle test"
    fi

    "$JQ" -n \
        --argjson smp "$smp" \
        --arg memory "$MEM" \
        --arg mode "relaunch" \
        --arg sentinel_path "/var/lib/m3-hvf-lifecycle/sentinel" \
        --arg sentinel_sha256 "$token_sha256" \
        --argjson qemu_argv "$qemu_argv_json" \
        --arg qemu_path "$QEMU_REAL" \
        --arg qemu_version "$QEMU_VERSION" \
        --arg qemu_sha256_before "$QEMU_SHA256_BEFORE" \
        --arg qemu_sha256_after "$QEMU_SHA256_AFTER" \
        --arg qemu_identity_before "$QEMU_IDENTITY_BEFORE" \
        --arg qemu_identity_after "$QEMU_IDENTITY_CURRENT" \
        --arg qemu_img_path "$QEMU_IMG_REAL" \
        --arg qemu_img_sha256_before "$QEMU_IMG_SHA256_BEFORE" \
        --arg qemu_img_sha256_after "$QEMU_IMG_SHA256_AFTER" \
        --arg qemu_img_identity_before "$QEMU_IMG_IDENTITY_BEFORE" \
        --arg qemu_img_identity_after "$QEMU_IMG_IDENTITY_CURRENT" \
        --arg timeout_path "$TIMEOUT_REAL" \
        --arg timeout_sha256_before "$TIMEOUT_SHA256_BEFORE" \
        --arg timeout_sha256_after "$TIMEOUT_SHA256_AFTER" \
        --arg timeout_identity_before "$TIMEOUT_IDENTITY_BEFORE" \
        --arg timeout_identity_after "$TIMEOUT_IDENTITY_CURRENT" \
        --arg lsof_path "$LSOF_REAL" \
        --arg lsof_sha256_before "$LSOF_SHA256_BEFORE" \
        --arg lsof_sha256_after "$LSOF_SHA256_AFTER" \
        --arg lsof_identity_before "$LSOF_IDENTITY_BEFORE" \
        --arg lsof_identity_after "$LSOF_IDENTITY_CURRENT" \
        --arg awk_path "$AWK_REAL" \
        --arg awk_sha256_before "$AWK_SHA256_BEFORE" \
        --arg awk_sha256_after "$AWK_SHA256_AFTER" \
        --arg awk_identity_before "$AWK_IDENTITY_BEFORE" \
        --arg awk_identity_after "$AWK_IDENTITY_CURRENT" \
        --arg jq_path "$JQ_REAL" \
        --arg jq_version "$JQ_VERSION" \
        --arg jq_sha256_before "$JQ_SHA256_BEFORE" \
        --arg jq_sha256_after "$JQ_SHA256_AFTER" \
        --arg jq_identity_before "$JQ_IDENTITY_BEFORE" \
        --arg jq_identity_after "$JQ_IDENTITY_CURRENT" \
        --arg kver_path "$KVER_FILE" \
        --arg kver "$KVER" \
        --arg kver_sha256_before "$KVER_SHA256_BEFORE" \
        --arg kver_sha256_after "$KVER_SHA256_AFTER" \
        --arg kver_identity_before "$KVER_IDENTITY_BEFORE" \
        --arg kver_identity_after "$KVER_IDENTITY_CURRENT" \
        --arg kernel_path "$KERNEL" \
        --arg kernel_sha256_before "$KERNEL_SHA256_BEFORE" \
        --arg kernel_sha256_after "$KERNEL_SHA256_AFTER" \
        --arg kernel_identity_before "$KERNEL_IDENTITY_BEFORE" \
        --arg kernel_identity_after "$KERNEL_IDENTITY_CURRENT" \
        --argjson kernel_size "$(file_size "$KERNEL")" \
        --arg initrd_path "$INITRD" \
        --arg initrd_sha256_before "$INITRD_SHA256_BEFORE" \
        --arg initrd_sha256_after "$INITRD_SHA256_AFTER" \
        --arg initrd_identity_before "$INITRD_IDENTITY_BEFORE" \
        --arg initrd_identity_after "$INITRD_IDENTITY_CURRENT" \
        --argjson initrd_size "$(file_size "$INITRD")" \
        --arg rootfs_path "$ROOTFS" \
        --arg rootfs_sha256_before "$ROOTFS_SHA256_BEFORE" \
        --arg rootfs_sha256_after "$ROOTFS_SHA256_AFTER" \
        --arg rootfs_identity_before "$ROOTFS_IDENTITY_BEFORE" \
        --arg rootfs_identity_after "$ROOTFS_IDENTITY_CURRENT" \
        --argjson rootfs_size "$(file_size "$ROOTFS")" \
        --arg harness_path "$HARNESS" \
        --arg harness_sha256_before "$HARNESS_SHA256_BEFORE" \
        --arg harness_sha256_after "$HARNESS_SHA256_AFTER" \
        --arg harness_identity_before "$HARNESS_IDENTITY_BEFORE" \
        --arg harness_identity_after "$HARNESS_IDENTITY_CURRENT" \
        --arg identity_format "device=<dev>;inode=<inode>;type=<type>;links=<count>" \
        --arg threat_boundary "invoking account, OS-owned command directories, and local project/tool directories must exclude concurrent untrusted writers" \
        --arg trusted_host_path "$PATH" \
        --arg cycle1_log "$CYCLE1_LOG" \
        --arg cycle1_console "$CYCLE1_CONSOLE" \
        --arg cycle2_log "$CYCLE2_LOG" \
        --arg cycle2_console "$CYCLE2_CONSOLE" \
        --arg evidence_path "$evidence" \
        --arg failure_reason "$failure_reason" \
        --argjson launch_timeout "$LAUNCH_TIMEOUT" \
        --argjson c1_status "$c1_status" \
        --argjson c1_online "$c1_online_json" \
        --argjson c1_timed_out "$c1_timed_out" \
        --argjson c1_begin "$c1_begin" \
        --argjson c1_cpu "$c1_cpu" \
        --argjson c1_sentinel "$c1_sentinel" \
        --argjson c1_complete "$c1_complete" \
        --argjson c1_shutdown "$c1_shutdown" \
        --argjson c1_error "$c1_error" \
        --argjson c1_identity_before "$c1_identity_before" \
        --argjson c1_identity_after "$c1_identity_after" \
        --argjson c1_pid_file_removed "$c1_pid_file_removed" \
        --argjson c1_valid "$c1_valid" \
        --argjson c2_attempted "$c2_attempted" \
        --argjson c2_status "$c2_status_json" \
        --argjson c2_online "$c2_online_json" \
        --argjson c2_timed_out "$c2_timed_out" \
        --argjson c2_begin "$c2_begin" \
        --argjson c2_cpu "$c2_cpu" \
        --argjson c2_sentinel "$c2_sentinel" \
        --argjson c2_complete "$c2_complete" \
        --argjson c2_shutdown "$c2_shutdown" \
        --argjson c2_error "$c2_error" \
        --argjson c2_identity_before "$c2_identity_before" \
        --argjson c2_identity_after "$c2_identity_after" \
        --argjson c2_pid_file_removed "$c2_pid_file_removed" \
        --argjson c2_valid "$c2_valid" \
        --argjson overlay_removed "$overlay_removed" \
        --argjson inputs_unchanged "$inputs_unchanged" \
        --argjson identities_stable "$identities_stable" \
        --argjson pass "$result" '
        {
            schema_version: 1,
            test: "m3-ultra-hvf-lifecycle",
            lifecycle_mode: $mode,
            configured_cpu_count: $smp,
            memory: $memory,
            launch_timeout_seconds: $launch_timeout,
            integrity_model: {
                filesystem_identity_format: $identity_format,
                trusted_host_path: $trusted_host_path,
                trusted_local_directory_boundary: $threat_boundary,
                swap_and_restore_entirely_between_checkpoints_portably_excluded: false,
                checkpoint_schedule: [
                    "before_matrix", "immediately_before_each_qemu_launch",
                    "immediately_after_each_qemu_exit", "after_each_count",
                    "before_final_publication"
                ]
            },
            cycles: [
                {
                    number: 1, transition: "initial_launch", attempted: true,
                    qemu_exit_status: $c1_status, timed_out: $c1_timed_out,
                    online_cpu_count: $c1_online,
                    markers: {begin: $c1_begin, cpu_count: $c1_cpu,
                              sentinel_write: $c1_sentinel,
                              complete: $c1_complete,
                              clean_shutdown_requested: $c1_shutdown,
                              guest_error: $c1_error},
                    filesystem_identity_checks: {
                        immediately_before_launch: $c1_identity_before,
                        immediately_after_exit: $c1_identity_after
                    },
                    temporary_qemu_pid_file_removed: $c1_pid_file_removed,
                    pass: $c1_valid
                },
                {
                    number: 2, transition: "clean_relaunch", attempted: $c2_attempted,
                    qemu_exit_status: $c2_status, timed_out: $c2_timed_out,
                    online_cpu_count: $c2_online,
                    markers: {begin: $c2_begin, cpu_count: $c2_cpu,
                              sentinel_persisted: $c2_sentinel,
                              complete: $c2_complete,
                              clean_shutdown_requested: $c2_shutdown,
                              guest_error: $c2_error},
                    filesystem_identity_checks: {
                        immediately_before_launch: $c2_identity_before,
                        immediately_after_exit: $c2_identity_after
                    },
                    temporary_qemu_pid_file_removed: $c2_pid_file_removed,
                    pass: $c2_valid
                }
            ],
            sentinel: {
                guest_path: $sentinel_path,
                token_sha256: $sentinel_sha256,
                write_verified_in_cycle_1: $c1_sentinel,
                survived_clean_relaunch: $c2_sentinel
            },
            qemu: {
                path: $qemu_path, version: $qemu_version,
                sha256_before: $qemu_sha256_before,
                sha256_after: $qemu_sha256_after,
                filesystem_identity_before: $qemu_identity_before,
                filesystem_identity_after: $qemu_identity_after,
                argv: $qemu_argv,
                argv_by_cycle: [
                    $qemu_argv,
                    (if $c2_attempted then $qemu_argv else null end)
                ]
            },
            tools: {
                qemu_img: {path: $qemu_img_path, sha256_before: $qemu_img_sha256_before,
                           sha256_after: $qemu_img_sha256_after,
                           filesystem_identity_before: $qemu_img_identity_before,
                           filesystem_identity_after: $qemu_img_identity_after},
                timeout: {path: $timeout_path, sha256_before: $timeout_sha256_before,
                          sha256_after: $timeout_sha256_after,
                          filesystem_identity_before: $timeout_identity_before,
                          filesystem_identity_after: $timeout_identity_after},
                lsof: {path: $lsof_path, sha256_before: $lsof_sha256_before,
                       sha256_after: $lsof_sha256_after,
                       filesystem_identity_before: $lsof_identity_before,
                       filesystem_identity_after: $lsof_identity_after},
                parser: {path: $awk_path, sha256_before: $awk_sha256_before,
                         sha256_after: $awk_sha256_after,
                         filesystem_identity_before: $awk_identity_before,
                         filesystem_identity_after: $awk_identity_after},
                jq: {path: $jq_path, version: $jq_version,
                     sha256_before: $jq_sha256_before, sha256_after: $jq_sha256_after,
                     filesystem_identity_before: $jq_identity_before,
                     filesystem_identity_after: $jq_identity_after}
            },
            inputs: {
                kernel_version: {path: $kver_path, value: $kver,
                                 sha256_before: $kver_sha256_before,
                                 sha256_after: $kver_sha256_after,
                                 filesystem_identity_before: $kver_identity_before,
                                 filesystem_identity_after: $kver_identity_after},
                kernel: {path: $kernel_path, size: $kernel_size,
                         sha256_before: $kernel_sha256_before,
                         sha256_after: $kernel_sha256_after,
                         filesystem_identity_before: $kernel_identity_before,
                         filesystem_identity_after: $kernel_identity_after},
                initrd: {path: $initrd_path, size: $initrd_size,
                         sha256_before: $initrd_sha256_before,
                         sha256_after: $initrd_sha256_after,
                         filesystem_identity_before: $initrd_identity_before,
                         filesystem_identity_after: $initrd_identity_after},
                rootfs: {path: $rootfs_path, size: $rootfs_size,
                         sha256_before: $rootfs_sha256_before,
                         sha256_after: $rootfs_sha256_after,
                         filesystem_identity_before: $rootfs_identity_before,
                         filesystem_identity_after: $rootfs_identity_after},
                harness: {path: $harness_path,
                          sha256_before: $harness_sha256_before,
                          sha256_after: $harness_sha256_after,
                          filesystem_identity_before: $harness_identity_before,
                          filesystem_identity_after: $harness_identity_after}
            },
            safety: {
                host_privilege_required: false,
                explicit_disposable_overlay: true,
                raw_rootfs_used_only_as_backing: true,
                same_overlay_configured_for_both_cycles: true,
                lifecycle_is_relaunch_not_reboot: true,
                build_drive_attached: false,
                network_disabled: true,
                monitor_and_qmp_disabled: true,
                display_disabled: true,
                firmware_or_pflash_attached: false,
                host_devices_attached: false,
                hard_timeout_per_cycle: true,
                artifact_file_sizes_bounded: true,
                clean_shutdown_requested_both_cycles: ($c1_shutdown and $c2_shutdown),
                protected_inputs_unchanged: $inputs_unchanged,
                protected_input_filesystem_identities_stable: $identities_stable,
                overlay_removed_after_completion: $overlay_removed,
                guest_payload_or_drive_staging_created: false,
                temporary_control_staging_removed:
                    ($c1_pid_file_removed and $c2_pid_file_removed)
            },
            artifacts: {
                cycle_1_serial_log: $cycle1_log,
                cycle_1_console: $cycle1_console,
                cycle_2_serial_log: $cycle2_log,
                cycle_2_console: $cycle2_console,
                evidence: $evidence_path
            },
            pass: $pass,
            failure_reason: (if $pass then null else $failure_reason end)
        }
    ' > "$evidence_tmp"

    if ! "$JQ" -e --argjson expected_argv "$qemu_argv_json" '
        .schema_version == 1 and .lifecycle_mode == "relaunch" and
        .configured_cpu_count > 0 and (.cycles | length) == 2 and
        .qemu.argv == $expected_argv and
        .qemu.argv_by_cycle[0] == $expected_argv and
        .qemu.argv_by_cycle[1] ==
            (if .cycles[1].attempted then $expected_argv else null end) and
        .safety.host_privilege_required == false and
        .safety.explicit_disposable_overlay == true and
        .safety.raw_rootfs_used_only_as_backing == true and
        .safety.same_overlay_configured_for_both_cycles == true and
        .safety.lifecycle_is_relaunch_not_reboot == true and
        .safety.build_drive_attached == false and
        .safety.network_disabled == true and
        .safety.monitor_and_qmp_disabled == true and
        .safety.display_disabled == true and
        .safety.firmware_or_pflash_attached == false and
        .safety.host_devices_attached == false and
        .safety.hard_timeout_per_cycle == true and
        .safety.artifact_file_sizes_bounded == true and
        .safety.guest_payload_or_drive_staging_created == false and
        ((.pass == false) or .safety.temporary_control_staging_removed) and
        .integrity_model.swap_and_restore_entirely_between_checkpoints_portably_excluded == false and
        .integrity_model.trusted_host_path == "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" and
        (.integrity_model.trusted_local_directory_boundary | length) > 0 and
        (.safety.protected_input_filesystem_identities_stable | type) == "boolean" and
        ((.pass == false) or .safety.protected_input_filesystem_identities_stable) and
        .qemu.sha256_before == .qemu.sha256_after and
        (.qemu.filesystem_identity_before | startswith("device=")) and
        (.qemu.filesystem_identity_after | startswith("device=")) and
        all(.tools[];
            .sha256_before == .sha256_after and
            (.filesystem_identity_before | startswith("device=")) and
            (.filesystem_identity_after | startswith("device="))) and
        all(.inputs[];
            .sha256_before == .sha256_after and
            (.filesystem_identity_before | startswith("device=")) and
            (.filesystem_identity_after | startswith("device=")))
    ' "$evidence_tmp" >/dev/null; then
        fail "generated lifecycle evidence failed structural validation"
    fi
    /bin/mv "$evidence_tmp" "$evidence"
    EVIDENCE_FILES+=("$evidence")
    COMPLETED_COUNTS+=("$smp")
    if [ "$result" != true ]; then
        OVERALL_PASS=false
    fi
    echo "lifecycle evidence: $evidence"
}

echo "hashing protected inputs before lifecycle matrix"
hash_inputs_before
[ "$KVER_SHA256_SELECTED" = "$KVER_SHA256_BEFORE" ] ||
    fail "KVER changed while selecting kernel inputs"
capture_protected_identities || fail "could not capture protected input filesystem identities"
verify_protected_identities || fail "protected input identity changed before the matrix"
PROTECTED_WINDOW_STARTED=true

for smp in "${SMP_COUNTS[@]}"; do
    run_count "$smp"
    [ "$STOP_AFTER_COUNT" = false ] || break
done

verify_protected_identities ||
    fail "protected input identity changed before aggregate finalization"

REQUESTED_COUNTS_JSON="$("$JQ" -n --args '$ARGS.positional | map(tonumber)' -- "${SMP_COUNTS[@]}")"
COMPLETED_COUNTS_JSON="$("$JQ" -n --args '$ARGS.positional | map(tonumber)' -- "${COMPLETED_COUNTS[@]}")"
"$JQ" -s \
    --argjson requested "$REQUESTED_COUNTS_JSON" \
    --argjson completed "$COMPLETED_COUNTS_JSON" \
    --argjson pass "$OVERALL_PASS" \
    --arg mode "relaunch" \
    --arg manifest "$MANIFEST" '
    {
        schema_version: 1,
        test: "m3-ultra-hvf-lifecycle-matrix",
        lifecycle_mode: $mode,
        requested_cpu_counts: $requested,
        completed_cpu_counts: $completed,
        counts: map({configured_cpu_count, online_cpu_counts: [.cycles[].online_cpu_count],
                     sentinel_survived: .sentinel.survived_clean_relaunch,
                     pass, evidence: .artifacts.evidence}),
        safety: {
            no_network_firmware_monitor_display_or_host_devices:
                all(.[]; .safety.network_disabled and
                         .safety.monitor_and_qmp_disabled and
                         .safety.display_disabled and
                         .safety.firmware_or_pflash_attached == false and
                         .safety.host_devices_attached == false),
            all_overlays_removed:
                all(.[]; .safety.overlay_removed_after_completion),
            all_protected_inputs_unchanged:
                all(.[]; .safety.protected_inputs_unchanged),
            all_protected_input_filesystem_identities_stable:
                all(.[]; .safety.protected_input_filesystem_identities_stable),
            trusted_local_directory_boundary:
                (.[0].integrity_model.trusted_local_directory_boundary),
            swap_and_restore_entirely_between_checkpoints_portably_excluded: false
        },
        pass: ($pass and (($requested | length) == ($completed | length)) and
               all(.[]; .pass)),
        artifact: $manifest
    }
' "${EVIDENCE_FILES[@]}" > "$MANIFEST_TMP"

if ! "$JQ" -e '
    .schema_version == 1 and .lifecycle_mode == "relaunch" and
    (.requested_cpu_counts | length) > 0 and
    (.counts | length) == (.completed_cpu_counts | length) and
    (.safety | type) == "object" and (.pass | type) == "boolean"
' "$MANIFEST_TMP" >/dev/null; then
    fail "aggregate lifecycle manifest failed structural validation"
fi

# Make the final protected-input check immediately before publishing the
# aggregate result.  Do not reset the baseline here: it remains the hash set
# captured immediately before the matrix, so this also covers manifest
# assembly rather than comparing two adjacent post-run snapshots.  Mark the
# inputs unverified so cleanup performs this check after rechecking every
# retained overlay pathname and immediately before releasing the lock.
INPUTS_VERIFIED=false
set +e
cleanup 0
FINAL_CLEANUP_STATUS=$?
set -e
trap - EXIT
[ "$FINAL_CLEANUP_STATUS" -eq 0 ] ||
    fail "final cleanup could not prove that temporary VM artifacts were removed safely"
/bin/mv "$MANIFEST_TMP" "$MANIFEST"
echo "lifecycle manifest: $MANIFEST"

if [ "$OVERALL_PASS" != true ] ||
   [ "${#COMPLETED_COUNTS[@]}" -ne "${#SMP_COUNTS[@]}" ]; then
    exit 1
fi

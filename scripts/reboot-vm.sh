#!/bin/bash
# Prove that a guest-requested reboot survives inside one QEMU/HVF process.
# Each CPU count uses one disposable qcow2 overlay and one private QMP socket.
# The immutable root image is only the overlay's raw, read-only backing file.
#
#   ./scripts/reboot-vm.sh
#   SMP_LIST="1 32" ./scripts/reboot-vm.sh
#
# Environment: SMP_LIST (default "1 8 16 24 32"), MEM (default 8G),
# LAUNCH_TIMEOUT (default 420 seconds), and optional absolute QEMU, QEMU_IMG,
# TIMEOUT, or NC executable paths.
set -euo pipefail
umask 077
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin
LC_ALL=C
export PATH LC_ALL

# Threat boundary: the invoking account, OS-owned command directories, and
# local project/tool directories are trusted against concurrent malicious
# writers.  Identity and content checkpoints detect persistent replacement,
# but portable pathname APIs cannot exclude a swap-and-restore attack wholly
# between two checkpoints.
HERE="$(cd "$(/usr/bin/dirname "$0")/.." && pwd -P)"
OUT="$HERE/out"
HARNESS="$HERE/scripts/reboot-vm.sh"
QEMU="${QEMU:-/opt/homebrew/bin/qemu-system-aarch64}"
QEMU_IMG="${QEMU_IMG:-/opt/homebrew/bin/qemu-img}"
TIMEOUT="${TIMEOUT:-/opt/homebrew/bin/gtimeout}"
NC="${NC:-/usr/bin/nc}"
JQ="/usr/bin/jq"
AWK="/usr/bin/awk"
LSOF="/usr/sbin/lsof"
PS="/bin/ps"
SMP_LIST="${SMP_LIST:-1 8 16 24 32}"
MEM="${MEM:-8G}"
LAUNCH_TIMEOUT="${LAUNCH_TIMEOUT:-420}"
AUTOLOGIN_MARKER="m3builder login: root (automatic login)"
KVER_FILE="$OUT/KVER"
ROOTFS="$OUT/vmroot.ext4"
LOCK_DIR="$OUT/.vmroot.ext4.probe.lock"

RUN_DIR=""
COUNT_DIR=""
CURRENT_OVERLAY=""
SERIAL_FIFO=""
QMP_FIFO=""
QMP_SOCKET=""
QMP_LOG=""
QMP_ERROR=""
QEMU_PID_FILE=""
QPID=""
QEMU_CHILD_PID=""
QMP_PID=""
CAPTURED_QEMU_PID=""
CAPTURED_QEMU_START=""
CAPTURED_QEMU_COMMAND=""
CAPTURED_QEMU_UID=""
CAPTURED_PID_FILE_IDENTITY=""
CAPTURE_STATE="uncaptured"
QEMU_CHILD_SAFELY_GONE=false
QEMU_LAUNCH_ATTEMPTED=false
LOCK_ACQUIRED=false
LOCK_OWNER=""
LOCK_TOKEN=""
PROTECTED_WINDOW_STARTED=false
INPUTS_VERIFIED=false
BASELINE_SNAPSHOT=""
BASELINE_IDENTITIES=""
OVERLAY_PATHS=()

fail() {
    echo "reboot probe: $*" >&2
    exit 1
}

sha256_file() {
    local digest remainder

    IFS=' ' read -r digest remainder < <(/usr/bin/shasum -a 256 "$1")
    case "$digest" in ''|*[!0-9a-f]*) return 1 ;; esac
    [ "${#digest}" -eq 64 ] || return 1
    printf '%s\n' "$digest"
}

sha256_text() {
    local digest remainder

    IFS=' ' read -r digest remainder < <(printf '%s' "$1" | /usr/bin/shasum -a 256)
    case "$digest" in ''|*[!0-9a-f]*) return 1 ;; esac
    [ "${#digest}" -eq 64 ] || return 1
    printf '%s\n' "$digest"
}

file_size() {
    /usr/bin/stat -f '%z' "$1"
}

require_safe_input() {
    local input=$1 links

    [ ! -L "$input" ] && [ -f "$input" ] && [ -r "$input" ] ||
        fail "required input must be a readable regular non-symlink file: $input"
    links="$(/usr/bin/stat -f '%l' "$input")"
    [ "$links" -eq 1 ] || fail "required input is multiply linked: $input"
}

filesystem_identity() {
    local input=$1

    [ ! -L "$input" ] && [ -f "$input" ] || return 1
    /usr/bin/stat -f 'device=%d;inode=%i;type=%HT;links=%l' "$input"
}

socket_identity() {
    local input=$1

    [ ! -L "$input" ] && [ -S "$input" ] || return 1
    /usr/bin/stat -f 'device=%d;inode=%i;type=%HT;links=%l' "$input"
}

snapshot_protected() {
    local index name path identity digest snapshot='[]'

    for ((index = 0; index < ${#PROTECTED_PATHS[@]}; index++)); do
        name="${PROTECTED_NAMES[$index]}"
        path="${PROTECTED_PATHS[$index]}"
        identity="$(filesystem_identity "$path")" || return 1
        digest="$(sha256_file "$path")" || return 1
        snapshot="$("$JQ" -c \
            --arg name "$name" --arg path "$path" --arg identity "$identity" \
            --arg sha256 "$digest" '. + [{name:$name,path:$path,identity:$identity,sha256:$sha256}]' \
            <<< "$snapshot")" || return 1
    done
    printf '%s\n' "$snapshot"
}

snapshot_identities() {
    local index name path identity snapshot='[]'

    for ((index = 0; index < ${#PROTECTED_PATHS[@]}; index++)); do
        name="${PROTECTED_NAMES[$index]}"
        path="${PROTECTED_PATHS[$index]}"
        identity="$(filesystem_identity "$path")" || return 1
        snapshot="$("$JQ" -c \
            --arg name "$name" --arg path "$path" --arg identity "$identity" \
            '. + [{name:$name,path:$path,identity:$identity}]' \
            <<< "$snapshot")" || return 1
    done
    printf '%s\n' "$snapshot"
}

verify_protected() {
    local observed

    observed="$(snapshot_identities)" || return 1
    [ "$observed" = "$BASELINE_IDENTITIES" ]
}

lsof_openers() {
    local path=$1 output status

    if output="$("$LSOF" -t -- "$path" 2>&1)"; then
        status=0
    else
        status=$?
    fi
    if [ "$status" -eq 0 ]; then
        printf '%s\n' "$output"
        return 0
    fi
    [ "$status" -eq 1 ] && [ -z "$output" ] && return 0
    echo "reboot probe: lsof failed for $path (status $status): $output" >&2
    return 1
}

canonical_process_pid() {
    case "$1" in ''|*[!0-9]*|0|1) return 1 ;; esac
    [ "$1" -gt 1 ]
}

running_shell_job() {
    local wanted=$1 running_jobs job_pid

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
    observed_parent="$("$PS" -o ppid= -p "$QEMU_CHILD_PID" 2>/dev/null)" || return 1
    observed_parent="${observed_parent//[[:space:]]/}"
    [ "$observed_parent" = "$QPID" ]
}

process_start_identity() {
    verified_qemu_child || return 1
    process_start_for_pid "$QEMU_CHILD_PID"
}

process_start_for_pid() {
    local pid=$1 value

    value="$("$PS" -o lstart= -p "$pid" 2>/dev/null)" || return 1
    value="$(printf '%s\n' "$value" | "$AWK" '{$1=$1; print}')"
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

process_command_for_pid() {
    local pid=$1 value

    value="$("$PS" -ww -o command= -p "$pid" 2>/dev/null)" || return 1
    value="$(printf '%s\n' "$value" | "$AWK" '
        { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print }
    ')"
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

process_uid_for_pid() {
    local pid=$1 value

    value="$("$PS" -o uid= -p "$pid" 2>/dev/null)" || return 1
    value="${value//[[:space:]]/}"
    case "$value" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$value"
}

pid_file_matches_capture() {
    local observed_identity observed_pid line_count

    [ -n "$QEMU_PID_FILE" ] && [ -n "$CAPTURED_PID_FILE_IDENTITY" ] || return 1
    observed_identity="$(filesystem_identity "$QEMU_PID_FILE")" || return 1
    [ "$observed_identity" = "$CAPTURED_PID_FILE_IDENTITY" ] || return 1
    observed_pid="$(/bin/cat "$QEMU_PID_FILE")" || return 1
    line_count="$("$AWK" 'END {print NR + 0}' "$QEMU_PID_FILE")" || return 1
    [ "$line_count" -eq 1 ] && [ "$observed_pid" = "$CAPTURED_QEMU_PID" ]
}

capture_independent_qemu_identity() {
    local command uid start pid_file_identity current_uid pid_file_uid
    local pid_file_mode pid_file_links

    verified_qemu_child || return 1
    start="$(process_start_for_pid "$QEMU_CHILD_PID")" || return 1
    command="$(process_command_for_pid "$QEMU_CHILD_PID")" || return 1
    uid="$(process_uid_for_pid "$QEMU_CHILD_PID")" || return 1
    current_uid="$(/usr/bin/id -u)" || return 1
    [ "$uid" = "$current_uid" ] || return 1
    case "$command" in "$QEMU"|"$QEMU "*) ;; *) return 1 ;; esac
    pid_file_identity="$(filesystem_identity "$QEMU_PID_FILE")" || return 1
    pid_file_uid="$(/usr/bin/stat -f '%u' "$QEMU_PID_FILE")" || return 1
    pid_file_mode="$(/usr/bin/stat -f '%Lp' "$QEMU_PID_FILE")" || return 1
    pid_file_links="$(/usr/bin/stat -f '%l' "$QEMU_PID_FILE")" || return 1
    [ "$pid_file_uid" = "$current_uid" ] && [ "$pid_file_mode" = "600" ] &&
        [ "$pid_file_links" -eq 1 ] || return 1

    CAPTURED_QEMU_PID="$QEMU_CHILD_PID"
    CAPTURED_QEMU_START="$start"
    CAPTURED_QEMU_COMMAND="$command"
    CAPTURED_QEMU_UID="$uid"
    CAPTURED_PID_FILE_IDENTITY="$pid_file_identity"
    pid_file_matches_capture || return 1
    CAPTURE_STATE="matching"
    QEMU_CHILD_SAFELY_GONE=false
}

# Set CAPTURE_STATE to matching, absent, different, unknown, or uncaptured.
# Only "matching" may be signalled directly.  A different start identity or
# owner proves PID reuse; an unexplained command/PID-file mismatch is unknown
# and is deliberately not signalled or cleaned through.
assess_captured_qemu() {
    local present status current_start current_command current_uid

    if ! canonical_process_pid "$CAPTURED_QEMU_PID"; then
        CAPTURE_STATE="uncaptured"
        return 3
    fi
    set +e
    present="$("$PS" -o pid= -p "$CAPTURED_QEMU_PID" 2>/dev/null)"
    status=$?
    set -e
    present="${present//[[:space:]]/}"
    if [ "$status" -ne 0 ] || [ -z "$present" ]; then
        if /bin/kill -0 "$CAPTURED_QEMU_PID" 2>/dev/null; then
            CAPTURE_STATE="unknown"
            return 3
        fi
        CAPTURE_STATE="absent"
        return 1
    fi
    [ "$present" = "$CAPTURED_QEMU_PID" ] || {
        CAPTURE_STATE="unknown"
        return 3
    }
    current_start="$(process_start_for_pid "$CAPTURED_QEMU_PID")" || {
        CAPTURE_STATE="unknown"
        return 3
    }
    current_uid="$(process_uid_for_pid "$CAPTURED_QEMU_PID")" || {
        CAPTURE_STATE="unknown"
        return 3
    }
    if [ "$current_start" != "$CAPTURED_QEMU_START" ] ||
       [ "$current_uid" != "$CAPTURED_QEMU_UID" ]; then
        CAPTURE_STATE="different"
        return 2
    fi
    current_command="$(process_command_for_pid "$CAPTURED_QEMU_PID")" || {
        CAPTURE_STATE="unknown"
        return 3
    }
    if [ "$current_command" != "$CAPTURED_QEMU_COMMAND" ] ||
       ! pid_file_matches_capture; then
        CAPTURE_STATE="unknown"
        return 3
    fi
    CAPTURE_STATE="matching"
    return 0
}

terminate_owned_jobs() {
    local step wrapper_owned=false direct_kill_sent=false wrapper_kill_sent=false

    QEMU_CHILD_SAFELY_GONE=false
    if [ "$QEMU_LAUNCH_ATTEMPTED" = false ]; then
        QEMU_CHILD_SAFELY_GONE=true
        return 0
    fi
    if [ -n "$QPID" ] && running_shell_job "$QPID"; then
        wrapper_owned=true
    fi
    if assess_captured_qemu; then
        /bin/kill -TERM "$CAPTURED_QEMU_PID" 2>/dev/null || true
    elif [ "$wrapper_owned" = true ]; then
        # The timeout wrapper is a shell-owned job and safely forwards TERM.
        /bin/kill -TERM "$QPID" 2>/dev/null || true
    fi
    if [ -n "$QMP_PID" ] && running_shell_job "$QMP_PID"; then
        /bin/kill -TERM "$QMP_PID" 2>/dev/null || true
    fi
    for ((step = 0; step < 20; step++)); do
        assess_captured_qemu >/dev/null 2>&1 || true
        if [ "$CAPTURE_STATE" = "absent" ] || [ "$CAPTURE_STATE" = "different" ]; then
            QEMU_CHILD_SAFELY_GONE=true
            break
        fi
        if [ "$CAPTURE_STATE" = "uncaptured" ] && [ "$wrapper_owned" = true ] &&
           ! running_shell_job "$QPID"; then
            QEMU_CHILD_SAFELY_GONE=true
            break
        fi
        /bin/sleep 0.1
    done
    if assess_captured_qemu; then
        /bin/kill -KILL "$CAPTURED_QEMU_PID" 2>/dev/null || true
        direct_kill_sent=true
        for ((step = 0; step < 10; step++)); do
            assess_captured_qemu >/dev/null 2>&1 || true
            if [ "$CAPTURE_STATE" = "absent" ] || [ "$CAPTURE_STATE" = "different" ]; then
                QEMU_CHILD_SAFELY_GONE=true
                break
            fi
            /bin/sleep 0.1
        done
    fi
    if [ "$wrapper_owned" = true ] && running_shell_job "$QPID" &&
       { [ "$QEMU_CHILD_SAFELY_GONE" = true ] || [ "$direct_kill_sent" = true ]; }; then
        /bin/kill -KILL "$QPID" 2>/dev/null || true
        wrapper_kill_sent=true
    fi
    if [ "$wrapper_kill_sent" = true ]; then
        for ((step = 0; step < 10; step++)); do
            running_shell_job "$QPID" || break
            /bin/sleep 0.1
        done
        running_shell_job "$QPID" && return 1
    fi
    if [ -n "$QMP_PID" ] && running_shell_job "$QMP_PID"; then
        /bin/kill -KILL "$QMP_PID" 2>/dev/null || true
    fi
    if [ -n "$QPID" ] && ! running_shell_job "$QPID"; then
        wait "$QPID" 2>/dev/null || true
    fi
    if [ -n "$QMP_PID" ]; then wait "$QMP_PID" 2>/dev/null || true; fi
    QMP_PID=""
    if canonical_process_pid "$CAPTURED_QEMU_PID"; then
        assess_captured_qemu >/dev/null 2>&1 || true
        case "$CAPTURE_STATE" in
            absent|different) QEMU_CHILD_SAFELY_GONE=true ;;
            *) return 1 ;;
        esac
    else
        # With no captured child, only a normally reaped shell-owned wrapper
        # is sufficient to declare cleanup safe.
        if [ "$QEMU_LAUNCH_ATTEMPTED" = false ]; then
            QEMU_CHILD_SAFELY_GONE=true
        elif [ "$wrapper_owned" = true ] && ! running_shell_job "$QPID"; then
            QEMU_CHILD_SAFELY_GONE=true
        else
            return 1
        fi
    fi
    QPID=""
    QEMU_CHILD_PID=""
    return 0
}

remove_runtime_object() {
    local path=$1 expected=$2 owner links

    [ -n "$path" ] || return 0
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then return 0; fi
    case "$expected" in
        fifo) [ -p "$path" ] && [ ! -L "$path" ] || return 1 ;;
        socket) [ -S "$path" ] && [ ! -L "$path" ] || return 1 ;;
        file) [ -f "$path" ] && [ ! -L "$path" ] || return 1 ;;
        *) return 1 ;;
    esac
    owner="$(/usr/bin/stat -f '%u' "$path")" || return 1
    links="$(/usr/bin/stat -f '%l' "$path")" || return 1
    [ "$owner" = "$(/usr/bin/id -u)" ] && [ "$links" -eq 1 ] || return 1
    /bin/rm -f -- "$path"
}

release_lock() {
    local observed=""

    [ "$LOCK_ACQUIRED" = true ] || return 0
    [ -n "$LOCK_OWNER" ] && [ -f "$LOCK_OWNER" ] && [ ! -L "$LOCK_OWNER" ] || return 1
    IFS= read -r observed < "$LOCK_OWNER" || true
    [ "$observed" = "$LOCK_TOKEN" ] || return 1
    /bin/rm -f -- "$LOCK_OWNER" || return 1
    /bin/rmdir "$LOCK_DIR" 2>/dev/null || return 1
    LOCK_ACQUIRED=false
}

cleanup() {
    local cleanup_status=${1:-$?} overlay openers cleanup_snapshot
    local child_cleanup_safe=true

    if ! terminate_owned_jobs; then
        child_cleanup_safe=false
        cleanup_status=1
        echo "reboot probe: retaining VM controls because the captured QEMU child may survive" >&2
    fi
    exec 8>&- 8<&- 9>&- 9<&- 2>/dev/null || true
    if [ "$child_cleanup_safe" = true ]; then
        remove_runtime_object "$SERIAL_FIFO" fifo || cleanup_status=1
        remove_runtime_object "$QMP_FIFO" fifo || cleanup_status=1
        remove_runtime_object "$QMP_SOCKET" socket || cleanup_status=1
        if canonical_process_pid "$CAPTURED_QEMU_PID"; then
            if pid_file_matches_capture; then
                remove_runtime_object "$QEMU_PID_FILE" file || cleanup_status=1
            elif [ -n "$QEMU_PID_FILE" ]; then
                echo "reboot probe: refusing changed captured QEMU PID control" >&2
                cleanup_status=1
            fi
        else
            remove_runtime_object "$QEMU_PID_FILE" file || cleanup_status=1
        fi
        SERIAL_FIFO=""; QMP_FIFO=""; QMP_SOCKET=""; QEMU_PID_FILE=""
        for overlay in "${OVERLAY_PATHS[@]}"; do
            if [ -L "$overlay" ]; then
                echo "reboot probe: refusing replaced overlay symlink: $overlay" >&2
                cleanup_status=1
            elif [ -f "$overlay" ]; then
                if ! openers="$(lsof_openers "$overlay")"; then
                    cleanup_status=1
                elif [ -n "$openers" ]; then
                    echo "reboot probe: refusing overlay still open by pid(s): $openers" >&2
                    cleanup_status=1
                else
                    /bin/rm -f -- "$overlay" || cleanup_status=1
                fi
            elif [ -e "$overlay" ]; then
                cleanup_status=1
            fi
            [ ! -e "$overlay" ] && [ ! -L "$overlay" ] || cleanup_status=1
        done
    fi
    if [ "$PROTECTED_WINDOW_STARTED" = true ] && [ "$INPUTS_VERIFIED" = false ]; then
        cleanup_snapshot="$(snapshot_protected)" || cleanup_snapshot='[]'
        if verify_protected && [ "$cleanup_snapshot" = "$BASELINE_SNAPSHOT" ]; then
            INPUTS_VERIFIED=true
        else
            echo "reboot probe: protected input identity or content changed during cleanup" >&2
            cleanup_status=1
        fi
    fi
    if [ "$child_cleanup_safe" = true ]; then release_lock || cleanup_status=1; fi
    return "$cleanup_status"
}

cleanup_on_exit() {
    local original_status=$? cleanup_status=0

    trap - EXIT
    cleanup "$original_status" || cleanup_status=$?
    [ "$original_status" -eq 0 ] || cleanup_status=$original_status
    exit "$cleanup_status"
}
trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

normalize_console() {
    "$AWK" '
        {
            gsub(/\033\][^\007\033]*\007/, "")
            gsub(/\033\][^\007\033]*\033\\/, "")
            gsub(/\033\[[0-9;?]*[[:alpha:]]/, "")
            gsub(/\r/, "")
            print
        }
    ' "$1" > "$2"
}

# Print "normalized-count raw-unadorned-count".  Any difference means that
# an exact-looking marker existed only after ANSI/control normalization.
marker_stats() {
    local wanted=$1 file=$2

    "$AWK" -v wanted="$wanted" '
        {
            raw=$0
            gsub(/\r/, "", raw)
            normalized=$0
            gsub(/\033\][^\007\033]*\007/, "", normalized)
            gsub(/\033\][^\007\033]*\033\\/, "", normalized)
            gsub(/\033\[[0-9;?]*[[:alpha:]]/, "", normalized)
            gsub(/\r/, "", normalized)
            if (normalized == wanted) normalized_count++
            if (raw == wanted) raw_count++
        }
        END { print normalized_count + 0, raw_count + 0 }
    ' "$file"
}

marker_line() {
    local wanted=$1 occurrence=$2 file=$3

    "$AWK" -v wanted="$wanted" -v occurrence="$occurrence" '
        {
            line=$0
            gsub(/\033\][^\007\033]*\007/, "", line)
            gsub(/\033\][^\007\033]*\033\\/, "", line)
            gsub(/\033\[[0-9;?]*[[:alpha:]]/, "", line)
            gsub(/\r/, "", line)
            if (line == wanted && ++seen == occurrence) { print NR; exit }
        }
    ' "$file"
}

wait_for_marker_count() {
    local wanted=$1 expected=$2 step normalized raw

    for ((step = 0; step < CONTROL_STEPS; step++)); do
        read -r normalized raw <<< "$(marker_stats "$wanted" "$SERIAL_LOG")"
        [ "$normalized" -eq "$raw" ] || return 2
        [ "$normalized" -le "$expected" ] || return 3
        [ "$normalized" -eq "$expected" ] && return 0
        running_shell_job "$QPID" || return 1
        /bin/sleep 0.1
    done
    return 1
}

qmp_send() {
    printf '{"execute":"%s","id":"%s"}\r\n' "$1" "$2" >&9
}

qmp_greeting_count() {
    "$JQ" -s '[.[] | select(.QMP.version.qemu? != null)] | length' "$QMP_LOG" 2>/dev/null || printf '0\n'
}

qmp_success_count() {
    local request_id=$1

    "$JQ" -s --arg id "$request_id" \
        '[.[] | select(.id? == $id and has("return") and (has("error") | not))] | length' \
        "$QMP_LOG" 2>/dev/null || printf '0\n'
}

qmp_error_count() {
    local request_id=$1

    "$JQ" -s --arg id "$request_id" \
        '[.[] | select(.id? == $id and has("error"))] | length' \
        "$QMP_LOG" 2>/dev/null || printf '0\n'
}

qmp_running_response() {
    local request_id=$1

    "$JQ" -e -s --arg id "$request_id" '
        ([.[] | select(.id? == $id)] | length) == 1 and
        any(.[]; .id? == $id and .return.status? == "running" and .return.running? == true)
    ' "$QMP_LOG" >/dev/null 2>&1
}

qmp_reset_count() {
    "$JQ" -s '[.[] | select(.event? == "RESET")] | length' "$QMP_LOG" 2>/dev/null || printf '0\n'
}

qmp_guest_reset_event() {
    "$JQ" -e -s '
        ([.[] | select(.event? == "RESET")] | length) == 1 and
        any(.[]; .event? == "RESET" and .data.guest? == true and
            .data.reason? == "guest-reset")
    ' "$QMP_LOG" >/dev/null 2>&1
}

qmp_guest_reset_after() {
    local baseline=$1

    case "$baseline" in ''|*[!0-9]*) return 1 ;; esac
    "$JQ" -e -s --argjson baseline "$baseline" '
        [.[] | select(.event? == "RESET")] as $resets |
        ($resets | length) == ($baseline + 1) and
        $resets[$baseline].data.guest? == true and
        $resets[$baseline].data.reason? == "guest-reset"
    ' "$QMP_LOG" >/dev/null 2>&1
}

qmp_guest_shutdown_event() {
    "$JQ" -e -s '
        ([.[] | select(.event? == "SHUTDOWN")] | length) == 1 and
        any(.[]; .event? == "SHUTDOWN" and .data.guest? == true and
            .data.reason? == "guest-shutdown")
    ' "$QMP_LOG" >/dev/null 2>&1
}

wait_for_qmp_greeting() {
    local step count

    for ((step = 0; step < CONTROL_STEPS; step++)); do
        count="$(qmp_greeting_count)"
        [ "$count" -le 1 ] || return 2
        [ "$count" -eq 1 ] && return 0
        running_shell_job "$QMP_PID" && running_shell_job "$QPID" || return 1
        /bin/sleep 0.1
    done
    return 1
}

wait_for_qmp_response() {
    local request_id=$1 step count errors

    for ((step = 0; step < CONTROL_STEPS; step++)); do
        count="$(qmp_success_count "$request_id")"
        errors="$(qmp_error_count "$request_id")"
        [ "$errors" -eq 0 ] || return 3
        [ "$count" -le 1 ] || return 2
        [ "$count" -eq 1 ] && return 0
        running_shell_job "$QMP_PID" && running_shell_job "$QPID" || return 1
        /bin/sleep 0.1
    done
    return 1
}

wait_for_guest_reset_after() {
    local baseline=$1 step count expected

    case "$baseline" in ''|*[!0-9]*) return 1 ;; esac
    expected=$((baseline + 1))

    for ((step = 0; step < CONTROL_STEPS; step++)); do
        count="$(qmp_reset_count)"
        [ "$count" -le "$expected" ] || return 2
        if [ "$count" -eq "$expected" ]; then
            qmp_guest_reset_after "$baseline" && return 0
            return 3
        fi
        running_shell_job "$QMP_PID" && running_shell_job "$QPID" || return 1
        /bin/sleep 0.1
    done
    return 1
}

make_phase1_script() {
    local smp=$1 token=$2 reboot_gate=$3

    /bin/cat <<GUEST_EOF
set -eu
reboot_probe_failure() {
    rc=\$?
    trap - EXIT
    echo "M3_REBOOT_GUEST_ERROR phase=1 rc=\$rc"
    sync || true
    echo "M3_REBOOT_CLEAN_SHUTDOWN_REQUESTED phase=1 failure=true"
    systemctl poweroff || true
    sleep 300
}
trap reboot_probe_failure EXIT
umask 077
# macOS Terminal's OSC 3008 command-start record can prefix the first byte
# written by this shell.  Consume that record on a sacrificial blank line so
# the first evidence marker remains an exact raw line.
printf '\\n'
echo "M3_REBOOT_PHASE_BEGIN phase=1"
online=\$(getconf _NPROCESSORS_ONLN)
echo "M3_REBOOT_CPU phase=1 configured=$smp online=\$online"
[ "\$online" -eq "$smp" ]
state=/var/lib/m3-hvf-reboot
install -d -m 700 "\$state"
printf '%s\\n' '$token' > "\$state/.sentinel.\$\$"
chmod 600 "\$state/.sentinel.\$\$"
mv -f "\$state/.sentinel.\$\$" "\$state/sentinel"
boot_id=\$(/bin/cat /proc/sys/kernel/random/boot_id)
case "\$boot_id" in ''|*[!0-9a-f-]*) exit 21 ;; esac
case "\$boot_id" in ????????-????-????-????-????????????) ;; *) exit 21 ;; esac
printf '%s\\n' "\$boot_id" > "\$state/.phase-1-boot-id.\$\$"
chmod 600 "\$state/.phase-1-boot-id.\$\$"
mv -f "\$state/.phase-1-boot-id.\$\$" "\$state/phase-1-boot-id"
IFS= read -r observed_token < "\$state/sentinel"
IFS= read -r observed_boot < "\$state/phase-1-boot-id"
[ "\$observed_token" = '$token' ]
[ "\$observed_boot" = "\$boot_id" ]
boot_hash=\$(printf '%s' "\$boot_id" | sha256sum)
boot_hash=\${boot_hash%% *}
case "\$boot_hash" in *[!0-9a-f]*|'') exit 22 ;; esac
[ "\${#boot_hash}" -eq 64 ]
echo "M3_REBOOT_SENTINEL_WRITE_OK phase=1"
echo "M3_REBOOT_BOOT_ID phase=1 sha256=\$boot_hash"
echo "M3_REBOOT_PHASE_COMPLETE phase=1"
echo "M3_REBOOT_ARMED phase=1"
IFS= read -r reboot_gate < /dev/tty
[ "\$reboot_gate" = '$reboot_gate' ]
sync
echo "M3_REBOOT_REQUESTED phase=1"
trap - EXIT
systemctl reboot
sleep 300
exit 23
GUEST_EOF
}

make_phase2_script() {
    local smp=$1 token=$2

    /bin/cat <<GUEST_EOF
set -eu
reboot_probe_failure() {
    rc=\$?
    trap - EXIT
    echo "M3_REBOOT_GUEST_ERROR phase=2 rc=\$rc"
    sync || true
    echo "M3_REBOOT_CLEAN_SHUTDOWN_REQUESTED phase=2 failure=true"
    systemctl poweroff || true
    sleep 300
}
trap reboot_probe_failure EXIT
umask 077
# Keep the first phase-2 marker raw-exact even when the interactive shell
# emits an OSC 3008 command-start record immediately before script output.
printf '\\n'
echo "M3_REBOOT_PHASE_BEGIN phase=2"
online=\$(getconf _NPROCESSORS_ONLN)
echo "M3_REBOOT_CPU phase=2 configured=$smp online=\$online"
[ "\$online" -eq "$smp" ]
state=/var/lib/m3-hvf-reboot
[ -f "\$state/sentinel" ]
[ -f "\$state/phase-1-boot-id" ]
IFS= read -r observed_token < "\$state/sentinel"
IFS= read -r first_boot < "\$state/phase-1-boot-id"
second_boot=\$(/bin/cat /proc/sys/kernel/random/boot_id)
[ "\$observed_token" = '$token' ]
[ -n "\$first_boot" ]
[ -n "\$second_boot" ]
case "\$first_boot" in ????????-????-????-????-????????????) ;; *) exit 31 ;; esac
case "\$second_boot" in ????????-????-????-????-????????????) ;; *) exit 31 ;; esac
case "\$first_boot\$second_boot" in *[!0-9a-f-]*) exit 31 ;; esac
[ "\$first_boot" != "\$second_boot" ]
boot_hash=\$(printf '%s' "\$second_boot" | sha256sum)
boot_hash=\${boot_hash%% *}
case "\$boot_hash" in *[!0-9a-f]*|'') exit 31 ;; esac
[ "\${#boot_hash}" -eq 64 ]
echo "M3_REBOOT_SENTINEL_PERSISTED_OK phase=2"
echo "M3_REBOOT_BOOT_ID phase=2 sha256=\$boot_hash"
echo "M3_REBOOT_BOOT_ID_CHANGED_OK phase=2"
echo "M3_REBOOT_PHASE_COMPLETE phase=2"
echo "M3_REBOOT_CYCLE_COMPLETE"
sync
echo "M3_REBOOT_CLEAN_SHUTDOWN_REQUESTED phase=2"
trap - EXIT
systemctl poweroff
sleep 300
exit 32
GUEST_EOF
}

extract_online_count() {
    local phase=$1 configured=$2 file=$3

    "$AWK" -v phase="$phase" -v configured="$configured" '
        $1 == "M3_REBOOT_CPU" && $2 == "phase=" phase &&
        $3 == "configured=" configured && $4 ~ /^online=[0-9]+$/ {
            value=$4; sub(/^online=/, "", value); count++
        }
        END { if (count == 1) print value }
    ' "$file"
}

extract_boot_hash() {
    local phase=$1 file=$2

    "$AWK" -v phase="$phase" '
        $1 == "M3_REBOOT_BOOT_ID" && $2 == "phase=" phase &&
        $3 ~ /^sha256=[0-9a-f]{64}$/ {
            value=$3; sub(/^sha256=/, "", value); count++
        }
        END { if (count == 1) print value }
    ' "$file"
}

all_exact_markers() {
    local file=$1 marker normalized raw
    shift

    for marker in "$@"; do
        read -r normalized raw <<< "$(marker_stats "$marker" "$file")"
        [ "$normalized" -eq 1 ] && [ "$raw" -eq 1 ] || return 1
    done
}

classify_launch_status() {
    case "$1" in
        0) printf '%s\n' normal_exit ;;
        124) printf '%s\n' timeout_deadline_expired ;;
        125) printf '%s\n' timeout_wrapper_failure ;;
        126) printf '%s\n' command_not_invokable ;;
        127) printf '%s\n' command_not_found ;;
        137) printf '%s\n' sigkill_9_command_or_timeout_possible_kill_after ;;
        *) printf '%s\n' command_nonzero_exit ;;
    esac
}

# macOS ships its OS-owned /bin/ps setuid-root so it can inspect process
# metadata.  This is the sole privileged-tool exception: it is not
# configurable, must resolve to the platform's own /bin/ps file, and is
# accepted only with the narrow ownership/link/mode contract below.  Its
# content hash and filesystem identity remain protected by every checkpoint.
validate_macos_system_ps() {
    local candidate=$1 expected resolved uid gid links mode mode_value

    expected="$(/bin/realpath /bin/ps)" || return 1
    resolved="$(/bin/realpath "$candidate")" || return 1
    [ "$resolved" = "$expected" ] && [ "$resolved" -ef /bin/ps ] || return 1
    [ ! -L "$resolved" ] && [ -f "$resolved" ] && [ -x "$resolved" ] || return 1
    uid="$(/usr/bin/stat -f '%u' "$resolved")" || return 1
    gid="$(/usr/bin/stat -f '%g' "$resolved")" || return 1
    links="$(/usr/bin/stat -f '%l' "$resolved")" || return 1
    mode="$(/usr/bin/stat -f '%Lp' "$resolved")" || return 1
    case "$mode" in ''|*[!0-7]*) return 1 ;; esac
    mode_value=$((8#$mode))
    [ "$uid" -eq 0 ] && [ "$gid" -eq 0 ] && [ "$links" -eq 1 ] || return 1
    # stat %Lp reports the ordinary permission bits on macOS, so validate the
    # special bits with test(1): setuid is required and setgid is forbidden.
    # Group/other write permission remains forbidden.
    [ -u "$resolved" ] && [ ! -g "$resolved" ] || return 1
    [ $((mode_value & 00022)) -eq 0 ] || return 1
}

run_count() {
    local smp=$1 overlay_info expected_drive qemu_argv_json token token_sha256 reboot_gate
    local launch_identity=false qmp_ready=false
    local phase1_injected=false reboot_trigger_injected=false phase2_injected=false
    local reset_seen=false reset_boundary_captured=false
    local qmp_survived=false socket_same=false process_same=false
    local boot_boundary_ok=false markers_valid=false cpu_valid=false
    local boot_ids_changed=false qmp_shutdown=false overlay_removed=false
    local protected_final=false result=false failure_reason=""
    local qemu_status=125 timed_out=false kill_after_or_sigkill=false qmp_status=125
    local launch_status_classification="not_started"
    local pid_before=0 pid_after=0 start_before="" start_after=""
    local socket_before="" socket_after="" online1="" online2=""
    local boot1_hash="" boot2_hash="" first_login_line=""
    local reboot_line="" second_login_line="" reset_event=null shutdown_event=null
    local evidence evidence_tmp openers final_snapshot='[]'
    local before_overlay_snapshot='[]' before_launch_snapshot='[]'
    local post_process_snapshot='[]' final_identity_snapshot='[]'
    local phase1_script phase2_script pid_step socket_step
    local qmp_private=false pid_file_removed=false serial_fifo_removed=false
    local qmp_fifo_removed=false socket_removed=false
    local qmp_log_parseable=false
    local qmp_contract_final=false
    local child_gone_after_wait=false child_state_after_wait="uncaptured"
    local captured_command="" captured_uid="" captured_pid_file_identity=""
    local command_after="" uid_after=""
    local qmp_wait_step
    local reset_count_before=0 reset_count_check=0 qmp_boundary_bytes=0
    local qmp_boundary_identity="" qmp_final_identity=""

    COUNT_DIR="$RUN_DIR/smp-$smp"
    /bin/mkdir -m 700 "$COUNT_DIR"
    [ "$(/usr/bin/stat -f '%Lp' "$COUNT_DIR")" = "700" ] ||
        fail "per-count directory is not mode 0700"
    CURRENT_OVERLAY="$COUNT_DIR/root-smp${smp}.qcow2"
    SERIAL_FIFO="$COUNT_DIR/serial.in"
    SERIAL_LOG="$COUNT_DIR/serial.raw.log"
    CONSOLE_LOG="$COUNT_DIR/serial.console.txt"
    QMP_FIFO="$COUNT_DIR/qmp.in"
    QMP_SOCKET="$COUNT_DIR/qmp.sock"
    QMP_LOG="$COUNT_DIR/qmp.events.jsonl"
    QMP_ERROR="$COUNT_DIR/qmp.stderr.log"
    QEMU_PID_FILE="$COUNT_DIR/qemu.pid"
    evidence="$COUNT_DIR/evidence.json"
    evidence_tmp="$(/usr/bin/mktemp "$COUNT_DIR/.evidence.XXXXXX")"
    OVERLAY_PATHS+=("$CURRENT_OVERLAY")
    INPUTS_VERIFIED=false
    CAPTURED_QEMU_PID=""; CAPTURED_QEMU_START=""; CAPTURED_QEMU_COMMAND=""
    CAPTURED_QEMU_UID=""; CAPTURED_PID_FILE_IDENTITY=""
    CAPTURE_STATE="uncaptured"; QEMU_CHILD_SAFELY_GONE=false
    QEMU_LAUNCH_ATTEMPTED=false

    before_overlay_snapshot="$(snapshot_identities)" ||
        fail "could not inspect protected inputs before overlay creation"
    [ "$before_overlay_snapshot" = "$BASELINE_IDENTITIES" ] ||
        fail "protected input changed before overlay creation"
    "$QEMU_IMG" create -q -f qcow2 -F raw -b "$ROOTFS" "$CURRENT_OVERLAY"
    /bin/chmod 600 "$CURRENT_OVERLAY"
    overlay_info="$("$QEMU_IMG" info --output=json "$CURRENT_OVERLAY")"
    "$JQ" -e --arg rootfs "$ROOTFS" '
        .format == "qcow2" and .["backing-filename"] == $rootfs and
        .["backing-filename-format"] == "raw"
    ' <<< "$overlay_info" >/dev/null || fail "overlay backing contract failed"

    /usr/bin/mkfifo -m 600 "$SERIAL_FIFO"
    /usr/bin/mkfifo -m 600 "$QMP_FIFO"
    : > "$SERIAL_LOG"; : > "$CONSOLE_LOG"; : > "$QMP_LOG"; : > "$QMP_ERROR"
    : > "$QEMU_PID_FILE"; /bin/chmod 600 "$QEMU_PID_FILE"
    exec 8<> "$SERIAL_FIFO"
    exec 9<> "$QMP_FIFO"

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
        -qmp "unix:$QMP_SOCKET,server=on,wait=off"
        -nodefaults
    )
    qemu_argv_json="$("$JQ" -n --args '$ARGS.positional' -- "$QEMU" "${ARGS[@]}")"
    expected_drive="if=virtio,file=$CURRENT_OVERLAY,format=qcow2,cache=none"
    "$JQ" -e --arg qemu "$QEMU" --arg drive "$expected_drive" \
        --arg socket "$QMP_SOCKET" --arg rootfs "$ROOTFS" '
        . as $a | $a[0] == $qemu and
        ([range(0; length - 1) as $i | select($a[$i] == "-drive" and $a[$i+1] == $drive)] | length) == 1 and
        ([range(0; length - 1) as $i | select($a[$i] == "-qmp" and $a[$i+1] == ("unix:"+$socket+",server=on,wait=off"))] | length) == 1 and
        ([range(0; length - 1) as $i | select($a[$i] == "-nic" and $a[$i+1] == "none")] | length) == 1 and
        ([range(0; length - 1) as $i | select($a[$i] == "-display" and $a[$i+1] == "none")] | length) == 1 and
        ([range(0; length - 1) as $i | select($a[$i] == "-monitor" and $a[$i+1] == "none")] | length) == 1 and
        ([range(0; length - 1) as $i | select($a[$i] == "-serial" and $a[$i+1] == "stdio")] | length) == 1 and
        ($a | index("-nodefaults")) != null and ($a | index("-no-reboot")) == null and
        all($a[]; contains($rootfs) | not) and
        all(["-bios","-pflash","-firmware","-netdev","-device","-object"][];
            . as $forbidden | ($a | index($forbidden)) == null)
    ' <<< "$qemu_argv_json" >/dev/null || fail "internal QEMU argument contract failed"

    token="m3-hvf-reboot-smp${smp}-pid$$-$(/bin/date +%s)-$RANDOM$RANDOM"
    token_sha256="$(sha256_text "$token")"
    reboot_gate="M3_REBOOT_GO_${token}"
    phase1_script="$(make_phase1_script "$smp" "$token" "$reboot_gate")"
    phase2_script="$(make_phase2_script "$smp" "$token")"

    before_launch_snapshot="$(snapshot_identities)" ||
        fail "could not inspect protected inputs immediately before QEMU launch"
    [ "$before_launch_snapshot" = "$BASELINE_IDENTITIES" ] ||
        fail "protected input changed immediately before QEMU launch"
    echo "booting in-process reboot probe: ${smp} vCPUs, ${MEM} RAM -> $COUNT_DIR"
    set +e
    /usr/bin/env -i PATH="$PATH" TMPDIR="$COUNT_DIR" HOME="$COUNT_DIR" \
        "$TIMEOUT" --foreground --signal=TERM --kill-after=10 "$LAUNCH_TIMEOUT" \
        /bin/sh -c 'printf "%s\n" "$$" > "$1" || exit 125; shift; exec "$@"' \
        reboot-qemu-launch "$QEMU_PID_FILE" "$QEMU" "${ARGS[@]}" \
        <&8 > "$SERIAL_LOG" 2>&1 &
    QPID=$!
    QEMU_LAUNCH_ATTEMPTED=true
    set -e
    for ((pid_step = 0; pid_step < 100; pid_step++)); do
        [ -s "$QEMU_PID_FILE" ] && break
        running_shell_job "$QPID" || break
        /bin/sleep 0.05
    done
    if [ -s "$QEMU_PID_FILE" ] && [ -f "$QEMU_PID_FILE" ] && [ ! -L "$QEMU_PID_FILE" ]; then
        IFS= read -r QEMU_CHILD_PID < "$QEMU_PID_FILE" || true
    fi
    if capture_independent_qemu_identity; then
        launch_identity=true
        pid_before=$CAPTURED_QEMU_PID
        start_before=$CAPTURED_QEMU_START
        captured_command=$CAPTURED_QEMU_COMMAND
        captured_uid=$CAPTURED_QEMU_UID
        captured_pid_file_identity=$CAPTURED_PID_FILE_IDENTITY
    fi

    if [ "$launch_identity" = true ]; then
        for ((socket_step = 0; socket_step < 100; socket_step++)); do
            [ -S "$QMP_SOCKET" ] && [ ! -L "$QMP_SOCKET" ] && break
            running_shell_job "$QPID" || break
            /bin/sleep 0.05
        done
        if [ -S "$QMP_SOCKET" ] && [ ! -L "$QMP_SOCKET" ]; then
            /bin/chmod 600 "$QMP_SOCKET"
            if [ "$(/usr/bin/stat -f '%u' "$QMP_SOCKET")" = "$(/usr/bin/id -u)" ] &&
               [ "$(/usr/bin/stat -f '%Lp' "$QMP_SOCKET")" = "600" ]; then
                qmp_private=true
            fi
            socket_before="$(socket_identity "$QMP_SOCKET")" || socket_before=""
            "$NC" -U "$QMP_SOCKET" < "$QMP_FIFO" > "$QMP_LOG" 2> "$QMP_ERROR" &
            QMP_PID=$!
            if wait_for_qmp_greeting; then
                qmp_send qmp_capabilities capabilities
                if wait_for_qmp_response capabilities; then
                    qmp_send query-status pre-reset-status
                    if wait_for_qmp_response pre-reset-status &&
                       qmp_running_response pre-reset-status; then
                        qmp_ready=true
                    fi
                fi
            fi
        fi
    fi

    if [ "$qmp_ready" = true ] && wait_for_marker_count "$AUTOLOGIN_MARKER" 1; then
        first_login_line="$(marker_line "$AUTOLOGIN_MARKER" 1 "$SERIAL_LOG")"
        printf 'stty -echo\n' >&8
        printf "/bin/bash <<'M3_REBOOT_PHASE1_EOF'\n%s\nM3_REBOOT_PHASE1_EOF\n" "$phase1_script" >&8
        phase1_injected=true
    fi
    if [ "$phase1_injected" = true ] &&
       wait_for_marker_count "M3_REBOOT_ARMED phase=1" 1 &&
       "$JQ" -e -s 'all(.[]; type == "object")' "$QMP_LOG" >/dev/null 2>&1; then
        reset_count_before="$(qmp_reset_count)"
        qmp_boundary_bytes="$(file_size "$QMP_LOG")"
        qmp_boundary_identity="$(filesystem_identity "$QMP_LOG")" || qmp_boundary_identity=""
        reset_count_check="$(qmp_reset_count)"
        if [ "$reset_count_before" = "$reset_count_check" ] &&
           [ -n "$qmp_boundary_identity" ]; then
            reset_boundary_captured=true
            printf '%s\n' "$reboot_gate" >&8
            reboot_trigger_injected=true
        fi
    fi
    if [ "$reboot_trigger_injected" = true ] &&
       wait_for_marker_count "M3_REBOOT_REQUESTED phase=1" 1; then
        reboot_line="$(marker_line "M3_REBOOT_REQUESTED phase=1" 1 "$SERIAL_LOG")"
        if wait_for_guest_reset_after "$reset_count_before"; then reset_seen=true; fi
    fi
    if [ "$reset_seen" = true ]; then
        if assess_captured_qemu; then
            pid_after=$CAPTURED_QEMU_PID
            start_after="$(process_start_for_pid "$CAPTURED_QEMU_PID")" || start_after=""
            command_after="$(process_command_for_pid "$CAPTURED_QEMU_PID")" || command_after=""
            uid_after="$(process_uid_for_pid "$CAPTURED_QEMU_PID")" || uid_after=""
        fi
        if [ "$pid_before" -eq "$pid_after" ] && [ -n "$start_before" ] &&
           [ "$start_before" = "$start_after" ] &&
           [ "$captured_command" = "$command_after" ] &&
           [ "$captured_uid" = "$uid_after" ]; then process_same=true; fi
        socket_after="$(socket_identity "$QMP_SOCKET")" || socket_after=""
        [ -n "$socket_before" ] && [ "$socket_before" = "$socket_after" ] && socket_same=true
        if [ "$process_same" = true ] && [ "$socket_same" = true ] &&
           running_shell_job "$QMP_PID"; then
            qmp_send query-status post-reset-status
            if wait_for_qmp_response post-reset-status &&
               qmp_running_response post-reset-status; then qmp_survived=true; fi
        fi
    fi
    if [ "$qmp_survived" = true ] && wait_for_marker_count "$AUTOLOGIN_MARKER" 2; then
        second_login_line="$(marker_line "$AUTOLOGIN_MARKER" 2 "$SERIAL_LOG")"
        if [ -n "$first_login_line" ] && [ -n "$reboot_line" ] &&
           [ -n "$second_login_line" ] &&
           [ "$first_login_line" -lt "$reboot_line" ] &&
           [ "$reboot_line" -lt "$second_login_line" ]; then
            boot_boundary_ok=true
            printf 'stty -echo\n' >&8
            printf "/bin/bash <<'M3_REBOOT_PHASE2_EOF'\n%s\nM3_REBOOT_PHASE2_EOF\n" "$phase2_script" >&8
            phase2_injected=true
        fi
    fi
    if [ "$phase2_injected" = true ]; then
        wait_for_marker_count "M3_REBOOT_CYCLE_COMPLETE" 1 || true
        wait_for_marker_count "M3_REBOOT_CLEAN_SHUTDOWN_REQUESTED phase=2" 1 || true
    fi

    set +e
    if [ -n "$QPID" ]; then
        wait "$QPID"
        qemu_status=$?
    fi
    set -e
    [ "$qemu_status" -ne 124 ] || timed_out=true
    [ "$qemu_status" -ne 137 ] || kill_after_or_sigkill=true
    launch_status_classification="$(classify_launch_status "$qemu_status")"
    QPID=""
    assess_captured_qemu >/dev/null 2>&1 || true
    child_state_after_wait=$CAPTURE_STATE
    case "$CAPTURE_STATE" in
        absent|different)
            child_gone_after_wait=true
            QEMU_CHILD_SAFELY_GONE=true
            ;;
        *)
            if terminate_owned_jobs; then
                child_gone_after_wait=true
                child_state_after_wait=$CAPTURE_STATE
            fi
            ;;
    esac
    QEMU_CHILD_PID=""
    post_process_snapshot="$(snapshot_identities)" || post_process_snapshot='[]'
    exec 8>&- 8<&-
    exec 9>&- 9<&-
    if [ -n "$QMP_PID" ]; then
        for ((qmp_wait_step = 0; qmp_wait_step < 20; qmp_wait_step++)); do
            running_shell_job "$QMP_PID" || break
            /bin/sleep 0.05
        done
        if running_shell_job "$QMP_PID"; then
            /bin/kill -TERM "$QMP_PID" 2>/dev/null || true
        fi
        set +e
        wait "$QMP_PID"
        qmp_status=$?
        set -e
        QMP_PID=""
    fi

    normalize_console "$SERIAL_LOG" "$CONSOLE_LOG"
    if "$JQ" -e -s 'all(.[]; type == "object")' "$QMP_LOG" >/dev/null 2>&1; then
        qmp_log_parseable=true
        if qmp_guest_reset_event && qmp_guest_reset_after "$reset_count_before"; then
            reset_seen=true
        else
            reset_seen=false
        fi
        qmp_guest_shutdown_event && qmp_shutdown=true
        if [ "$(qmp_greeting_count)" -eq 1 ] &&
           [ "$(qmp_success_count capabilities)" -eq 1 ] &&
           [ "$(qmp_error_count capabilities)" -eq 0 ] &&
           qmp_running_response pre-reset-status &&
           qmp_running_response post-reset-status; then
            qmp_contract_final=true
        fi
        qmp_final_identity="$(filesystem_identity "$QMP_LOG")" || qmp_final_identity=""
        reset_event="$("$JQ" -c -s --argjson baseline "$reset_count_before" \
            '[.[] | select(.event? == "RESET")][$baseline] // null' "$QMP_LOG")"
        shutdown_event="$("$JQ" -c -s '[.[] | select(.event? == "SHUTDOWN")][0] // null' "$QMP_LOG")"
    fi
    online1="$(extract_online_count 1 "$smp" "$CONSOLE_LOG")"
    online2="$(extract_online_count 2 "$smp" "$CONSOLE_LOG")"
    if [ "$online1" = "$smp" ] && [ "$online2" = "$smp" ]; then cpu_valid=true; fi
    boot1_hash="$(extract_boot_hash 1 "$CONSOLE_LOG")"
    boot2_hash="$(extract_boot_hash 2 "$CONSOLE_LOG")"
    if [ -n "$boot1_hash" ] && [ -n "$boot2_hash" ] &&
       [ "$boot1_hash" != "$boot2_hash" ]; then boot_ids_changed=true; fi
    if all_exact_markers "$SERIAL_LOG" \
        "M3_REBOOT_PHASE_BEGIN phase=1" \
        "M3_REBOOT_CPU phase=1 configured=$smp online=$smp" \
        "M3_REBOOT_SENTINEL_WRITE_OK phase=1" \
        "M3_REBOOT_BOOT_ID phase=1 sha256=$boot1_hash" \
        "M3_REBOOT_PHASE_COMPLETE phase=1" \
        "M3_REBOOT_ARMED phase=1" \
        "M3_REBOOT_REQUESTED phase=1" \
        "M3_REBOOT_PHASE_BEGIN phase=2" \
        "M3_REBOOT_CPU phase=2 configured=$smp online=$smp" \
        "M3_REBOOT_SENTINEL_PERSISTED_OK phase=2" \
        "M3_REBOOT_BOOT_ID phase=2 sha256=$boot2_hash" \
        "M3_REBOOT_BOOT_ID_CHANGED_OK phase=2" \
        "M3_REBOOT_PHASE_COMPLETE phase=2" \
        "M3_REBOOT_CYCLE_COMPLETE" \
        "M3_REBOOT_CLEAN_SHUTDOWN_REQUESTED phase=2"; then
        read -r login_normalized login_raw <<< "$(marker_stats "$AUTOLOGIN_MARKER" "$SERIAL_LOG")"
        if [ "$login_normalized" -eq 2 ] && [ "$login_raw" -eq 2 ] &&
           [ "$("$AWK" '/^M3_REBOOT_GUEST_ERROR / {n++} END {print n+0}' "$CONSOLE_LOG")" -eq 0 ]; then
            markers_valid=true
        fi
    fi

    if [ "$child_gone_after_wait" = true ]; then
        if remove_runtime_object "$SERIAL_FIFO" fifo; then
            SERIAL_FIFO=""; serial_fifo_removed=true
        fi
        if remove_runtime_object "$QMP_FIFO" fifo; then
            QMP_FIFO=""; qmp_fifo_removed=true
        fi
        if remove_runtime_object "$QMP_SOCKET" socket; then QMP_SOCKET=""; socket_removed=true; fi
        if pid_file_matches_capture && remove_runtime_object "$QEMU_PID_FILE" file; then
            QEMU_PID_FILE=""; pid_file_removed=true
        fi
        if [ -f "$CURRENT_OVERLAY" ] && [ ! -L "$CURRENT_OVERLAY" ]; then
            openers="$(lsof_openers "$CURRENT_OVERLAY")" || openers="unknown"
            if [ -z "$openers" ] && /bin/rm -f -- "$CURRENT_OVERLAY" &&
               [ ! -e "$CURRENT_OVERLAY" ] && [ ! -L "$CURRENT_OVERLAY" ]; then
                overlay_removed=true
            fi
        fi
    fi
    if [ "$child_gone_after_wait" != true ] || [ "$overlay_removed" != true ] ||
       [ "$pid_file_removed" != true ] || [ "$socket_removed" != true ] ||
       [ "$serial_fifo_removed" != true ] || [ "$qmp_fifo_removed" != true ]; then
        STOP_AFTER_COUNT=true
    fi
    echo "verifying protected inputs after ${smp}-vCPU reboot test"
    final_identity_snapshot="$(snapshot_identities)" || final_identity_snapshot='[]'
    final_snapshot="$(snapshot_protected)" || final_snapshot='[]'
    if [ "$post_process_snapshot" = "$BASELINE_IDENTITIES" ] &&
       [ "$final_identity_snapshot" = "$BASELINE_IDENTITIES" ] &&
       [ "$final_snapshot" = "$BASELINE_SNAPSHOT" ]; then
        protected_final=true
        INPUTS_VERIFIED=true
    else
        STOP_AFTER_COUNT=true
    fi

    if [ "$qemu_status" -eq 0 ] && [ "$timed_out" = false ] &&
       [ "$launch_identity" = true ] && [ "$qmp_ready" = true ] &&
       [ "$phase1_injected" = true ] && [ "$reset_boundary_captured" = true ] &&
       [ "$reboot_trigger_injected" = true ] && [ "$reset_seen" = true ] &&
       [ "$qmp_survived" = true ] && [ "$phase2_injected" = true ] &&
       [ "$process_same" = true ] && [ "$socket_same" = true ] &&
       [ "$boot_boundary_ok" = true ] && [ "$markers_valid" = true ] &&
       [ "$cpu_valid" = true ] && [ "$boot_ids_changed" = true ] &&
       [ "$qmp_shutdown" = true ] && [ "$qmp_log_parseable" = true ] &&
       [ "$qmp_contract_final" = true ] &&
       [ "$qmp_boundary_identity" = "$qmp_final_identity" ] &&
       [ "$child_gone_after_wait" = true ] &&
       [ "$overlay_removed" = true ] && [ "$protected_final" = true ] &&
       [ "$qmp_private" = true ] && [ "$pid_file_removed" = true ] &&
       [ "$serial_fifo_removed" = true ] && [ "$qmp_fifo_removed" = true ] &&
       [ "$socket_removed" = true ]; then
        result=true
    elif [ "$protected_final" != true ]; then failure_reason="protected input content or identity changed"
    elif [ "$timed_out" = true ]; then failure_reason="bounded QEMU launch reached its deadline (status 124)"
    elif [ "$kill_after_or_sigkill" = true ]; then failure_reason="QEMU command or timeout wrapper received SIGKILL 9 (status 137; possible kill-after expiration)"
    elif [ "$qemu_status" -ne 0 ]; then failure_reason="QEMU launch failed: $launch_status_classification (status $qemu_status)"
    elif [ "$child_gone_after_wait" != true ]; then failure_reason="captured QEMU child could not be proven gone after wrapper exit"
    elif [ "$launch_identity" != true ]; then failure_reason="QEMU child identity was not verified"
    elif [ "$qmp_ready" != true ]; then failure_reason="private QMP channel did not become ready"
    elif [ "$reset_boundary_captured" != true ]; then failure_reason="QMP RESET boundary could not be captured before reboot release"
    elif [ "$reset_seen" != true ]; then failure_reason="exact new guest=true reason=guest-reset QMP RESET event was not observed after the boundary"
    elif [ "$process_same" != true ]; then failure_reason="QEMU PID or process start identity changed across reboot"
    elif [ "$qmp_survived" != true ]; then failure_reason="QMP socket or query-status did not survive reboot"
    elif [ "$boot_boundary_ok" != true ]; then failure_reason="second auto-login was not strictly after reboot boundary"
    elif [ "$cpu_valid" != true ]; then failure_reason="configured and online CPU counts differed"
    elif [ "$boot_ids_changed" != true ]; then failure_reason="boot ID was missing, malformed, or unchanged"
    elif [ "$markers_valid" != true ]; then failure_reason="a marker was missing, duplicate, or ANSI-contaminated"
    elif [ "$qmp_shutdown" != true ]; then failure_reason="clean guest QMP shutdown event was not observed"
    elif [ "$overlay_removed" != true ]; then failure_reason="disposable overlay could not be removed safely"
    else failure_reason="runtime cleanup or safety contract failed"
    fi

    "$JQ" -n \
        --argjson smp "$smp" --arg memory "$MEM" --argjson argv "$qemu_argv_json" \
        --arg qemu "$QEMU" --arg qemu_version "$QEMU_VERSION" \
        --arg ps_path "$PS" \
        --argjson qemu_status "$qemu_status" --argjson qmp_status "$qmp_status" \
        --arg launch_status_classification "$launch_status_classification" \
        --argjson kill_after_or_sigkill "$kill_after_or_sigkill" \
        --argjson pid_before "$pid_before" --argjson pid_after "$pid_after" \
        --arg start_before "$start_before" --arg start_after "$start_after" \
        --arg command_before "$captured_command" --arg command_after "$command_after" \
        --arg uid_before "$captured_uid" --arg uid_after "$uid_after" \
        --arg pid_file_identity "$captured_pid_file_identity" \
        --arg child_state_after_wait "$child_state_after_wait" \
        --argjson child_gone_after_wait "$child_gone_after_wait" \
        --arg socket_before "$socket_before" --arg socket_after "$socket_after" \
        --arg boot1 "$boot1_hash" --arg boot2 "$boot2_hash" \
        --arg token_sha256 "$token_sha256" --argjson reset_event "$reset_event" \
        --argjson shutdown_event "$shutdown_event" --arg failure "$failure_reason" \
        --argjson baseline "$BASELINE_SNAPSHOT" --argjson final "$final_snapshot" \
        --argjson before_overlay "$before_overlay_snapshot" \
        --argjson before_launch "$before_launch_snapshot" \
        --argjson post_process "$post_process_snapshot" \
        --argjson final_identities "$final_identity_snapshot" \
        --arg serial "$SERIAL_LOG" --arg console "$CONSOLE_LOG" \
        --arg qmp_log "$QMP_LOG" --arg qmp_error "$QMP_ERROR" --arg evidence "$evidence" \
        --argjson timeout "$LAUNCH_TIMEOUT" --arg threat_boundary "invoking account, OS-owned command directories, and local project/tool directories exclude concurrent untrusted writers" \
        --argjson result "$result" --argjson timed_out "$timed_out" \
        --argjson launch_identity "$launch_identity" --argjson process_same "$process_same" \
        --argjson socket_same "$socket_same" --argjson qmp_private "$qmp_private" \
        --argjson qmp_ready "$qmp_ready" --argjson reset_seen "$reset_seen" \
        --argjson qmp_survived "$qmp_survived" --argjson qmp_shutdown "$qmp_shutdown" \
        --argjson qmp_parseable "$qmp_log_parseable" \
        --argjson qmp_contract_final "$qmp_contract_final" \
        --argjson reset_boundary_captured "$reset_boundary_captured" \
        --argjson reset_count_before "$reset_count_before" \
        --argjson qmp_boundary_bytes "$qmp_boundary_bytes" \
        --arg qmp_boundary_identity "$qmp_boundary_identity" \
        --arg qmp_final_identity "$qmp_final_identity" \
        --argjson phase1 "$phase1_injected" \
        --argjson reboot_trigger "$reboot_trigger_injected" \
        --argjson phase2 "$phase2_injected" --argjson boundary "$boot_boundary_ok" \
        --argjson markers "$markers_valid" --argjson cpu "$cpu_valid" \
        --argjson boots "$boot_ids_changed" --argjson overlay_removed "$overlay_removed" \
        --argjson protected "$protected_final" \
        --argjson serial_fifo_removed "$serial_fifo_removed" \
        --argjson qmp_fifo_removed "$qmp_fifo_removed" \
        --argjson socket_removed "$socket_removed" --argjson pid_removed "$pid_file_removed" \
        --argjson first_line "${first_login_line:-0}" --argjson reboot_line "${reboot_line:-0}" \
        --argjson second_line "${second_login_line:-0}" '
        {
          schema_version:1, lifecycle_mode:"in_process_guest_reboot", smp:$smp, memory:$memory,
          qemu:{executable:$qemu,version:$qemu_version,argv:$argv,exit_status:$qemu_status,exit_classification:$launch_status_classification,timed_out:$timed_out,timed_out_status_124:$timed_out,sigkill_9_possible_kill_after_status_137:$kill_after_or_sigkill},
          process:{identity_source:"validated_pid_file_plus_ps_start_command_uid",pid_file_identity:$pid_file_identity,pre_reset:{pid:$pid_before,start_identity:$start_before,command_identity:$command_before,uid:$uid_before},post_reset:{pid:$pid_after,start_identity:$start_after,command_identity:$command_after,uid:$uid_after},same_verified_process:$process_same,state_after_wrapper_wait:$child_state_after_wait,proven_gone_after_wrapper_wait:$child_gone_after_wait},
          qmp:{transport:"private_unix_socket",client_exit_status:$qmp_status,private_permissions:$qmp_private,ready:$qmp_ready,socket_identity_pre_reset:$socket_before,socket_identity_post_reset:$socket_after,same_socket:$socket_same,reset_boundary:{captured:$reset_boundary_captured,reset_event_count_before:$reset_count_before,log_size_bytes:$qmp_boundary_bytes,log_identity:$qmp_boundary_identity,final_log_identity:$qmp_final_identity},reset_event:$reset_event,required_reset_contract:{exactly_one_new_after_boundary:true,guest:true,reason:"guest-reset"},guest_reset_seen:$reset_seen,query_status_survived:$qmp_survived,shutdown_event:$shutdown_event,guest_shutdown_seen:$qmp_shutdown,log_parseable:$qmp_parseable,final_contract_valid:$qmp_contract_final},
          cycle:{phase_1_injected:$phase1,reboot_trigger_injected_after_qmp_boundary:$reboot_trigger,phase_2_injected:$phase2,autologin_marker:"m3builder login: root (automatic login)",first_login_line:$first_line,reboot_request_marker:"M3_REBOOT_REQUESTED phase=1",reboot_request_line:$reboot_line,second_login_line:$second_line,completion_marker:"M3_REBOOT_CYCLE_COMPLETE",strict_reboot_boundary:$boundary,markers_exact_unique_ansi_free:$markers,configured_online_counts_exact:$cpu,sentinel_path:"/var/lib/m3-hvf-reboot/sentinel",phase_1_boot_id_path:"/var/lib/m3-hvf-reboot/phase-1-boot-id",sentinel_token_sha256:$token_sha256,phase_1_boot_id_sha256:$boot1,phase_2_boot_id_sha256:$boot2,boot_id_changed:$boots},
          protected_inputs:{baseline:$baseline,identity_checkpoints:{before_overlay_creation:$before_overlay,immediately_before_qemu_launch:$before_launch,immediately_after_qemu_exit:$post_process,final:$final_identities},final:$final,unchanged:$protected},
          safety:{single_qemu_process:true,single_disposable_overlay:true,rootfs_only_raw_read_only_backing:true,machine_virt_highmem:true,hvf_kernel_irqchip:true,cpu_host:true,no_reboot_omitted:true,no_network:true,no_display:true,no_firmware_or_pflash:true,no_build_drive:true,no_host_devices:true,qmp_not_exposed_outside_private_socket:true,one_bounded_timeout_wrapper:true,artifacts_bounded:true,artifact_file_size_limit_bytes:268435456,run_directory_mode_0700:true,per_count_directory_mode_0700:true,cleanup_identity_includes_pid_start_command_uid:true,runtime_controls_retained_unless_child_proven_gone:true,reset_event_temporally_bounded:true,macos_system_ps_exception:{path:$ps_path,verified:true,reason:"hardcoded OS ps is expected setuid-root; canonical path, root/wheel ownership, single-link regular-file type, special bits, and non-writable group/other mode were validated; content hash and identity remain checkpointed"},overlay_removed:$overlay_removed,serial_fifo_removed:$serial_fifo_removed,qmp_fifo_removed:$qmp_fifo_removed,qmp_socket_removed:$socket_removed,pid_file_removed:$pid_removed,threat_boundary:$threat_boundary},
          artifacts:{serial_raw:$serial,serial_normalized:$console,qmp_events:$qmp_log,qmp_stderr:$qmp_error,evidence:$evidence},
          launch_timeout_seconds:$timeout,pass:$result,failure_reason:(if $result then null else $failure end)
        }
    ' > "$evidence_tmp"
    "$JQ" -e '
        .schema_version == 1 and .lifecycle_mode == "in_process_guest_reboot" and
        (.qemu.argv | type == "array") and (.protected_inputs.baseline | length) > 0 and
        (.protected_inputs.final | type == "array") and (.pass | type == "boolean") and
        (.safety.no_reboot_omitted == true) and (.safety.no_network == true) and
        (.safety.qmp_not_exposed_outside_private_socket == true) and
        (.safety.macos_system_ps_exception.verified == true)
    ' "$evidence_tmp" >/dev/null || fail "generated reboot evidence failed validation"
    /bin/mv "$evidence_tmp" "$evidence"
    EVIDENCE_FILES+=("$evidence")
    COMPLETED_COUNTS+=("$smp")
    [ "$result" = true ] || OVERALL_PASS=false
    echo "reboot evidence: $evidence"
}

# Main program.
[ "$#" -eq 0 ] || fail "this runner takes no command-line arguments"
case "$LAUNCH_TIMEOUT" in ''|*[!0-9]*|0|0*) fail "LAUNCH_TIMEOUT must be a positive canonical integer" ;; esac
[ "$LAUNCH_TIMEOUT" -le 900 ] || fail "LAUNCH_TIMEOUT exceeds the 900-second safety limit"
CONTROL_STEPS=$((LAUNCH_TIMEOUT * 10))
case "$MEM" in
    *G) MEM_VALUE="${MEM%G}"; case "$MEM_VALUE" in ''|*[!0-9]*|0|0*) fail "invalid MEM: $MEM" ;; esac; [ "$MEM_VALUE" -le 64 ] || fail "MEM exceeds 64G" ;;
    *M) MEM_VALUE="${MEM%M}"; case "$MEM_VALUE" in ''|*[!0-9]*|0|0*) fail "invalid MEM: $MEM" ;; esac; [ "$MEM_VALUE" -le 65536 ] || fail "MEM exceeds 64G" ;;
    *) fail "MEM must be an integer number of M or G" ;;
esac
case "$SMP_LIST" in *$'\n'*|*$'\r'*) fail "SMP_LIST must be one whitespace-separated line" ;; esac
read -r -a SMP_COUNTS <<< "$SMP_LIST"
[ "${#SMP_COUNTS[@]}" -gt 0 ] || fail "SMP_LIST is empty"
SEEN=" "
for smp in "${SMP_COUNTS[@]}"; do
    case "$smp" in ''|*[!0-9]*|0|0*) fail "invalid vCPU count: $smp" ;; esac
    [ "$smp" -le 64 ] || fail "vCPU count exceeds 64: $smp"
    case "$SEEN" in *" $smp "*) fail "duplicate vCPU count: $smp" ;; esac
    SEEN="$SEEN$smp "
done
[ "$(/usr/bin/id -u)" -ne 0 ] || fail "refusing to run QEMU as host root"
for tool in "$QEMU" "$QEMU_IMG" "$TIMEOUT" "$NC"; do
    case "$tool" in /*) ;; *) fail "tool overrides must be absolute paths: $tool" ;; esac
done
[ ! -L "$OUT" ] || fail "refusing symlinked output root"
/bin/mkdir -p "$OUT"
[ "$(cd "$OUT" && pwd -P)" = "$OUT" ] || fail "output root is not canonical"
for tool in "$QEMU" "$QEMU_IMG" "$TIMEOUT" "$NC" "$JQ" "$AWK" "$LSOF"; do
    [ -x "$tool" ] || fail "missing executable: $tool"
    [ ! -u "$tool" ] && [ ! -g "$tool" ] || fail "refusing setuid/setgid executable: $tool"
done
validate_macos_system_ps "$PS" ||
    fail "hardcoded macOS /bin/ps failed its canonical root-owned setuid safety contract"
QEMU="$(/bin/realpath "$QEMU")"; QEMU_IMG="$(/bin/realpath "$QEMU_IMG")"
TIMEOUT="$(/bin/realpath "$TIMEOUT")"; NC="$(/bin/realpath "$NC")"
JQ="$(/bin/realpath "$JQ")"; AWK="$(/bin/realpath "$AWK")"
LSOF="$(/bin/realpath "$LSOF")"; PS="$(/bin/realpath "$PS")"
validate_macos_system_ps "$PS" ||
    fail "resolved macOS ps changed during privileged-tool validation"
require_safe_input "$KVER_FILE"
KVER="$(/bin/cat "$KVER_FILE")"
case "$KVER" in ''|.|..|*/*|*[!A-Za-z0-9.+_~-]*) fail "KVER contains unsafe characters" ;; esac
KERNEL="$OUT/Image-$KVER"; INITRD="$OUT/initrd.img-$KVER"
for input in "$KERNEL" "$INITRD" "$ROOTFS" "$HARNESS"; do require_safe_input "$input"; done
PROTECTED_NAMES=(kver kernel initrd rootfs harness qemu qemu_img timeout nc jq awk lsof ps)
PROTECTED_PATHS=("$KVER_FILE" "$KERNEL" "$INITRD" "$ROOTFS" "$HARNESS" "$QEMU" "$QEMU_IMG" "$TIMEOUT" "$NC" "$JQ" "$AWK" "$LSOF" "$PS")
for ((left = 0; left < 5; left++)); do
    for ((right = left + 1; right < 5; right++)); do
        [ ! "${PROTECTED_PATHS[$left]}" -ef "${PROTECTED_PATHS[$right]}" ] || fail "protected inputs alias"
    done
done
QEMU_VERSION="$("$QEMU" --version)"; QEMU_VERSION="${QEMU_VERSION%%$'\n'*}"
if ! /bin/mkdir "$LOCK_DIR" 2>/dev/null; then fail "another VM probe owns $LOCK_DIR"; fi
LOCK_ACQUIRED=true
LOCK_TOKEN="$$:$(/bin/date +%s):$RANDOM"
LOCK_OWNER="$LOCK_DIR/owner.$$"
printf '%s\n' "$LOCK_TOKEN" > "$LOCK_OWNER"
OPENERS="$(lsof_openers "$ROOTFS")" || fail "could not inspect rootfs openers"
[ -z "$OPENERS" ] || fail "vmroot.ext4 is already open by pid(s): $OPENERS"
RUN_DIR="$(/usr/bin/mktemp -d "$OUT/reboot-matrix.XXXXXX")"
/bin/chmod 700 "$RUN_DIR"
[ "$(/usr/bin/stat -f '%Lp' "$RUN_DIR")" = "700" ] || fail "run directory is not mode 0700"
MANIFEST="$RUN_DIR/manifest.json"
MANIFEST_TMP="$(/usr/bin/mktemp "$RUN_DIR/.manifest.XXXXXX")"
ulimit -f 524288
BASELINE_SNAPSHOT="$(snapshot_protected)" || fail "could not snapshot protected inputs"
BASELINE_IDENTITIES="$(snapshot_identities)" || fail "could not snapshot protected identities"
PROTECTED_WINDOW_STARTED=true
INPUTS_VERIFIED=true
EVIDENCE_FILES=(); COMPLETED_COUNTS=(); OVERALL_PASS=true; STOP_AFTER_COUNT=false
for smp in "${SMP_COUNTS[@]}"; do
    run_count "$smp"
    [ "$STOP_AFTER_COUNT" = false ] || break
done

"$JQ" -s --argjson requested "$("$JQ" -n --args '$ARGS.positional | map(tonumber)' -- "${SMP_COUNTS[@]}")" \
    --argjson completed "$("$JQ" -n --args '$ARGS.positional | map(tonumber)' -- "${COMPLETED_COUNTS[@]}")" \
    --arg run_dir "$RUN_DIR" '
    {
      schema_version:1,lifecycle_mode:"in_process_guest_reboot",requested_smp_counts:$requested,
      completed_smp_counts:$completed,
      results:map({smp,qemu_argv:.qemu.argv,
                   qemu_exit:{status:.qemu.exit_status,
                              classification:.qemu.exit_classification},
                   qmp_reset_boundary:.qmp.reset_boundary,
                   qmp_reset_event:.qmp.reset_event,
                   process_identity:.process,
                   boot_ids:{phase_1_sha256:.cycle.phase_1_boot_id_sha256,
                             phase_2_sha256:.cycle.phase_2_boot_id_sha256,
                             changed:.cycle.boot_id_changed},
                   cycle_markers:{first_login_line:.cycle.first_login_line,
                                  reboot_request_line:.cycle.reboot_request_line,
                                  second_login_line:.cycle.second_login_line,
                                  exact_unique_ansi_free:.cycle.markers_exact_unique_ansi_free},
                   safety,pass,evidence:.artifacts.evidence}),
      safety:{all_protected_inputs_unchanged:all(.[];.protected_inputs.unchanged),all_overlays_removed:all(.[];.safety.overlay_removed),all_qmp_sockets_removed:all(.[];.safety.qmp_socket_removed),all_private_qmp:all(.[];.qmp.private_permissions and .safety.qmp_not_exposed_outside_private_socket)},
      all_pass:(length == ($requested|length) and all(.[];.pass)),run_directory:$run_dir
    }
' "${EVIDENCE_FILES[@]}" > "$MANIFEST_TMP"
"$JQ" -e '.schema_version == 1 and (.all_pass | type == "boolean")' "$MANIFEST_TMP" >/dev/null || fail "manifest validation failed"
/bin/mv "$MANIFEST_TMP" "$MANIFEST"
cleanup 0 || fail "runtime cleanup failed"
trap - EXIT INT TERM HUP
echo "reboot manifest: $MANIFEST"
[ "$OVERALL_PASS" = true ] || exit 1

#!/bin/bash
# Start, stop, and connect to the validated stock-kernel Debian VM.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/out"
LAUNCHER="$HERE/scripts/test-vm.sh"
SESSION="debian-m3-vm"
KVER="${TEST_VM_STOCK_KVER:-7.1.12+deb14-arm64}"
VM_DISK="$OUT/testvm-debian-root.qcow2"
KERNEL="$OUT/Image-$KVER"
INITRD="$OUT/initrd.img-$KVER"
QMP_SOCKET="$OUT/.testvm-debian-qmp.sock"
LOCK_DIR="$OUT/.test-vm.lock"
SSH_PORT_VALUE="${SSH_PORT:-22022}"
SMP_VALUE="${SMP:-8}"
MEM_VALUE="${MEM:-8G}"
QMP_RESPONSE=""
LOCK_OWNER=""
QMP_STREAM_DIR=""
QMP_STREAM_FIFO=""
QMP_STREAM_OUTPUT=""
QMP_STREAM_PID=""
QMP_STREAM_FD_OPEN=0

usage() {
    cat <<'EOF'
usage: ./scripts/test-vm-console.sh start|stop|console|connect|status

  start    start the stock-kernel VM in a detached tmux session
  stop     request a clean guest shutdown and wait for it to finish
  console  connect to the serial console (alias: connect)
  status   report whether the VM is running

Leave the console without stopping the VM:
  outside tmux: Ctrl-B d
  inside tmux:  Ctrl-B L (return to the previous tmux session)

Environment: TEST_VM_STOCK_KVER, SSH_PORT, SMP, MEM, QEMU, QEMU_IMG
EOF
}

fail() {
    echo "test-vm-console: $*" >&2
    exit 1
}

cleanup_qmp_stream() {
    if [ "$QMP_STREAM_FD_OPEN" -eq 1 ]; then
        exec 9>&-
        QMP_STREAM_FD_OPEN=0
    fi
    if [ -n "$QMP_STREAM_PID" ]; then
        if kill -0 "$QMP_STREAM_PID" 2>/dev/null; then
            kill "$QMP_STREAM_PID" 2>/dev/null || true
        fi
        wait "$QMP_STREAM_PID" 2>/dev/null || true
        QMP_STREAM_PID=""
    fi
    if [ -n "$QMP_STREAM_FIFO" ]; then
        rm -f -- "$QMP_STREAM_FIFO"
        QMP_STREAM_FIFO=""
    fi
    if [ -n "$QMP_STREAM_OUTPUT" ]; then
        rm -f -- "$QMP_STREAM_OUTPUT"
        QMP_STREAM_OUTPUT=""
    fi
    if [ -n "$QMP_STREAM_DIR" ]; then
        rmdir "$QMP_STREAM_DIR" 2>/dev/null || true
        QMP_STREAM_DIR=""
    fi
}
trap cleanup_qmp_stream EXIT

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

session_running() {
    tmux has-session -t "=$SESSION" 2>/dev/null
}

qmp_request() {
    local execute="$1"
    local request_id="$2"
    local timeout_seconds="${3:-1}"
    local nc_status

    set +e
    QMP_RESPONSE="$({
        printf '{"execute":"qmp_capabilities","id":"caps"}\r\n'
        printf '{"execute":"%s","id":"%s"}\r\n' "$execute" "$request_id"
    } | nc -U -w "$timeout_seconds" "$QMP_SOCKET" 2>/dev/null)"
    nc_status=$?
    set -e

    if printf '%s\n' "$QMP_RESPONSE" | jq -e -s --arg request_id "$request_id" '
        def succeeded($id):
            any(.[]; .id? == $id and has("return") and (has("error") | not));
        any(.[]; .QMP.version.qemu? != null) and
        succeeded("caps") and
        succeeded($request_id)
    ' >/dev/null 2>&1; then
        return 0
    fi
    [ "$nc_status" -eq 0 ] || return "$nc_status"
    return 1
}

qmp_reports_running() {
    printf '%s\n' "$QMP_RESPONSE" | jq -e -s '
        any(.[];
            .id? == "status" and
            .return.status? == "running" and
            .return.running? == true)
    ' >/dev/null 2>&1
}

qmp_reports_shutdown() {
    printf '%s\n' "$QMP_RESPONSE" | jq -e -s '
        any(.[];
            .id? == "status" and
            .return.status? == "shutdown" and
            .return.running? == false)
    ' >/dev/null 2>&1
}

start_qmp_stream() {
    QMP_STREAM_DIR="$(mktemp -d "$OUT/.test-vm-qmp.XXXXXX")" ||
        fail "could not create a private QMP working directory"
    QMP_STREAM_FIFO="$QMP_STREAM_DIR/input"
    QMP_STREAM_OUTPUT="$QMP_STREAM_DIR/output"
    mkfifo -m 600 "$QMP_STREAM_FIFO" || fail "could not create QMP input FIFO"
    : > "$QMP_STREAM_OUTPUT"
    exec 9<>"$QMP_STREAM_FIFO"
    QMP_STREAM_FD_OPEN=1
    nc -U "$QMP_SOCKET" < "$QMP_STREAM_FIFO" > "$QMP_STREAM_OUTPUT" 2>/dev/null &
    QMP_STREAM_PID=$!
}

qmp_stream_greeted() {
    jq -e -s 'any(.[]; .QMP.version.qemu? != null)' \
        "$QMP_STREAM_OUTPUT" >/dev/null 2>&1
}

qmp_stream_send() {
    printf '{"execute":"%s","id":"%s"}\r\n' "$1" "$2" >&9
}

qmp_stream_succeeded() {
    jq -e -s --arg request_id "$1" '
        any(.[];
            .id? == $request_id and
            has("return") and
            (has("error") | not))
    ' "$QMP_STREAM_OUTPUT" >/dev/null 2>&1
}

qmp_stream_failed() {
    jq -e -s --arg request_id "$1" '
        any(.[]; .id? == $request_id and has("error"))
    ' "$QMP_STREAM_OUTPUT" >/dev/null 2>&1
}

qmp_stream_confirmed_guest_shutdown() {
    jq -e -s '
        any(.[];
            .event? == "SHUTDOWN" and
            .data.guest? == true and
            .data.reason? == "guest-shutdown")
    ' "$QMP_STREAM_OUTPUT" >/dev/null 2>&1
}

qmp_stream_reports_status() {
    jq -e -s --arg status "$1" '
        any(.[];
            .id? == "initial-status" and
            .return.status? == $status)
    ' "$QMP_STREAM_OUTPUT" >/dev/null 2>&1
}

wait_for_qmp_stream_response() {
    local request_id="$1"
    local limit="$2"
    local attempts=0

    while [ "$attempts" -lt "$limit" ]; do
        qmp_stream_succeeded "$request_id" && return 0
        qmp_stream_failed "$request_id" && return 2
        kill -0 "$QMP_STREAM_PID" 2>/dev/null || return 1
        sleep 0.1
        attempts=$((attempts + 1))
    done
    return 1
}

wait_for_qmp_stream_greeting() {
    local attempts=0

    while [ "$attempts" -lt 50 ]; do
        qmp_stream_greeted && return 0
        kill -0 "$QMP_STREAM_PID" 2>/dev/null || return 1
        sleep 0.1
        attempts=$((attempts + 1))
    done
    return 1
}

active_lock_owner() {
    local owner

    LOCK_OWNER=""
    [ ! -L "$LOCK_DIR" ] && [ -d "$LOCK_DIR" ] &&
        [ ! -L "$LOCK_DIR/pid" ] && [ -f "$LOCK_DIR/pid" ] || return 1
    IFS= read -r owner < "$LOCK_DIR/pid" || return 1
    case "$owner" in
        ""|*[!0-9]*) return 1 ;;
    esac
    kill -0 "$owner" 2>/dev/null || return 1
    LOCK_OWNER="$owner"
    return 0
}

prepare_qmp_socket() {
    if [ ! -e "$QMP_SOCKET" ] && [ ! -L "$QMP_SOCKET" ]; then
        return
    fi
    [ ! -L "$QMP_SOCKET" ] && [ -S "$QMP_SOCKET" ] ||
        fail "QMP path is not a regular Unix socket: $QMP_SOCKET"
    if qmp_request query-status status; then
        fail "QMP is already responding at $QMP_SOCKET"
    fi
    if active_lock_owner; then
        fail "launcher pid $LOCK_OWNER is active; refusing to remove its QMP socket"
    fi
    rm -- "$QMP_SOCKET"
    echo "Removed stale QMP socket: $QMP_SOCKET"
}

validate_artifacts() {
    [ -x "$LAUNCHER" ] || fail "launcher is not executable: $LAUNCHER"
    [ ! -L "$VM_DISK" ] && [ -f "$VM_DISK" ] ||
        fail "missing regular VM disk: $VM_DISK"
    [ ! -L "$KERNEL" ] && [ -f "$KERNEL" ] ||
        fail "missing regular kernel: $KERNEL"
    [ ! -L "$INITRD" ] && [ -f "$INITRD" ] ||
        fail "missing regular initrd: $INITRD"
}

start_vm() {
    local quoted
    local run_command=""
    local attempts=0
    local env_args=(
        "TEST_VM_DISK=$VM_DISK"
        "TEST_VM_KERNEL=$KERNEL"
        "TEST_VM_INITRD=$INITRD"
        "TEST_VM_QMP_SOCKET=$QMP_SOCKET"
        "TEST_VM_NO_SHUTDOWN=1"
        "SSH_PORT=$SSH_PORT_VALUE"
        "SMP=$SMP_VALUE"
        "MEM=$MEM_VALUE"
    )

    require_command tmux
    require_command nc
    require_command jq
    validate_artifacts
    if session_running; then
        echo "VM is already running in tmux session $SESSION"
        return
    fi
    prepare_qmp_socket
    if [ -n "${QEMU:-}" ]; then
        env_args+=("QEMU=$QEMU")
    fi
    if [ -n "${QEMU_IMG:-}" ]; then
        env_args+=("QEMU_IMG=$QEMU_IMG")
    fi

    printf -v quoted '%q ' env "${env_args[@]}" "$LAUNCHER" run
    run_command="umask 077; exec $quoted"
    tmux new-session -d -s "$SESSION" -c "$HERE" "$run_command"

    while [ "$attempts" -lt 100 ]; do
        if [ -S "$QMP_SOCKET" ] && qmp_request query-status status &&
            qmp_reports_running; then
            echo "VM started in tmux session $SESSION"
            echo "console: $0 console"
            echo "ssh:     ssh -p $SSH_PORT_VALUE root@127.0.0.1"
            return
        fi
        if ! session_running; then
            fail "tmux session exited before QMP became ready"
        fi
        sleep 0.1
        attempts=$((attempts + 1))
    done
    fail "VM did not make QMP ready within 10 seconds; check status and console"
}

stop_vm() {
    local attempts=0
    local shutdown_confirmed=0

    require_command tmux
    require_command nc
    require_command jq
    if ! session_running; then
        if [ -S "$QMP_SOCKET" ] && qmp_request query-status status; then
            fail "QMP responds, but the controller tmux session is absent"
        fi
        if active_lock_owner; then
            fail "tmux session is absent but launcher pid $LOCK_OWNER is active"
        fi
        if [ -e "$QMP_SOCKET" ] || [ -L "$QMP_SOCKET" ]; then
            fail "tmux session is absent but a stale or invalid QMP socket exists: $QMP_SOCKET"
        fi
        if [ -e "$LOCK_DIR" ] || [ -L "$LOCK_DIR" ]; then
            fail "tmux session is absent but a stale or invalid launcher lock exists: $LOCK_DIR"
        fi
        echo "VM is not running"
        return
    fi
    [ -S "$QMP_SOCKET" ] ||
        fail "VM state is inconsistent; QMP socket is unavailable: $QMP_SOCKET"

    start_qmp_stream
    wait_for_qmp_stream_greeting || fail "QMP did not send its greeting"
    qmp_stream_send qmp_capabilities caps
    wait_for_qmp_stream_response caps 50 ||
        fail "could not negotiate the QMP connection"
    qmp_stream_send query-status initial-status
    wait_for_qmp_stream_response initial-status 50 ||
        fail "could not read the initial VM run state"

    if qmp_stream_reports_status shutdown; then
        echo "Guest is already shut down; completing QEMU exit"
    elif qmp_stream_reports_status running; then
        qmp_stream_send system_powerdown powerdown
        wait_for_qmp_stream_response powerdown 50 ||
            fail "could not send the graceful power-down request"
        while [ "$attempts" -lt 650 ]; do
            if qmp_stream_confirmed_guest_shutdown; then
                shutdown_confirmed=1
                break
            fi
            kill -0 "$QMP_STREAM_PID" 2>/dev/null ||
                fail "QMP disconnected before confirming the guest shutdown"
            sleep 0.1
            attempts=$((attempts + 1))
        done
        [ "$shutdown_confirmed" -eq 1 ] ||
            fail "guest did not confirm shutdown within 65 seconds"
        echo "Guest-confirmed graceful power-down received"
    else
        fail "VM is neither running nor in the recoverable shutdown state"
    fi

    qmp_stream_send quit quit
    attempts=0

    while [ "$attempts" -lt 50 ]; do
        if ! session_running; then
            cleanup_qmp_stream
            echo "VM stopped"
            return
        fi
        sleep 0.1
        attempts=$((attempts + 1))
    done
    fail "guest shut down, but the tmux session did not exit within 5 seconds"
}

connect_console() {
    require_command tmux
    session_running || fail "VM is not running; start it with: $0 start"
    if [ -n "${TMUX:-}" ]; then
        echo "Switching to $SESSION; press Ctrl-B L to return"
        tmux switch-client -t "=$SESSION"
        return
    fi
    echo "Attaching to $SESSION; press Ctrl-B d to detach"
    exec tmux attach-session -t "=$SESSION"
}

show_status() {
    require_command tmux
    require_command nc
    require_command jq
    if session_running; then
        if [ -S "$QMP_SOCKET" ] && qmp_request query-status status &&
            qmp_reports_running; then
            echo "VM is running in tmux session $SESSION"
            echo "console: $0 console"
            echo "ssh:     ssh -p $SSH_PORT_VALUE root@127.0.0.1"
            return
        fi
        if qmp_reports_shutdown; then
            fail "guest is shut down but QEMU is still held; run: $0 stop"
        fi
        fail "tmux session exists, but QMP does not report a running VM"
    fi
    if [ -S "$QMP_SOCKET" ] && qmp_request query-status status; then
        fail "QMP responds, but the controller tmux session is absent"
    fi
    if active_lock_owner; then
        fail "tmux session is absent, but launcher pid $LOCK_OWNER is active"
    fi
    if [ -e "$QMP_SOCKET" ] || [ -L "$QMP_SOCKET" ]; then
        fail "VM is not running, but a stale or invalid QMP socket exists: $QMP_SOCKET"
    fi
    if [ -e "$LOCK_DIR" ] || [ -L "$LOCK_DIR" ]; then
        fail "VM is not running, but a stale or invalid launcher lock exists: $LOCK_DIR"
    fi
    echo "VM is stopped"
}

COMMAND="${1:-}"
[ "$#" -le 1 ] || { usage >&2; exit 2; }
case "$COMMAND" in
    start) start_vm ;;
    stop) stop_vm ;;
    console|connect) connect_console ;;
    status) show_status ;;
    -h|--help) usage ;;
    *) usage >&2; exit 2 ;;
esac

#!/bin/bash
# Launch the standalone UEFI Debian portable VM.
#
# This launcher deliberately has no kernel/initrd options: the guest must boot
# from its GPT disk through the UEFI firmware.  The disk, UEFI variable store,
# QMP socket, and optional serial log are all direct children of out/.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
OUT="${PORTABLE_VM_OUT:-$HERE/out}"
IMAGE="$OUT/debian-portable.qcow2"
VARS="$OUT/debian-portable-vars.fd"
VARS_SOURCE="${PORTABLE_VM_VARS_SOURCE:-/opt/homebrew/share/qemu/edk2-arm-vars.fd}"
CODE="${PORTABLE_VM_CODE:-/opt/homebrew/share/qemu/edk2-aarch64-code.fd}"
QMP_DEFAULT="$OUT/portable-qmp.sock"
QMP_SOCKET="${PORTABLE_VM_QMP_SOCKET:-$QMP_DEFAULT}"
SERIAL_LOG="${PORTABLE_VM_SERIAL_LOG:-}"
QEMU_IMG="${PORTABLE_VM_QEMU_IMG:-${QEMU_IMG:-/opt/homebrew/bin/qemu-img}}"
PROJECT_QEMU="$OUT/qemu-fork-vmnet-build/qemu-system-aarch64"
if [ -x "$PROJECT_QEMU" ]; then
    DEFAULT_QEMU="$PROJECT_QEMU"
else
    DEFAULT_QEMU="/opt/homebrew/bin/qemu-system-aarch64"
fi
QEMU="${PORTABLE_VM_QEMU:-${QEMU:-$DEFAULT_QEMU}}"
BRIDGE="${PORTABLE_VM_BRIDGE:-1}"
BRIDGE_IFACE="${PORTABLE_VM_BRIDGE_IFACE:-${PORTABLE_VM_BRIDGE_IFNAME:-${VMNET_IFNAME:-en0}}}"
SSH_PORT="${PORTABLE_VM_SSH_PORT:-22025}"
MGMT_MAC="52:54:00:12:35:61"
BRIDGE_MAC="52:54:00:12:35:62"
LOCK_DIR="$OUT/.portable-vm.lock"
LOCK_HELD=0
QEMU_PID=""

fail() {
    echo "portable-vm: $*" >&2
    exit 1
}

usage() {
    cat <<EOF
usage: ./scripts/portable-vm.sh run|info

  run   boot the existing disk through AArch64 UEFI
  info  validate and print the launch configuration

Defaults: 4 vCPUs, 4G RAM, HVF, UEFI code at $CODE,
          loopback SSH 127.0.0.1:$SSH_PORT, bridge on $BRIDGE_IFACE,
          QMP socket $QMP_DEFAULT.

Set PORTABLE_VM_BRIDGE=0 for management-only validation when vmnet is
unavailable.  Set PORTABLE_VM_QMP=0 to disable the default QMP socket.
EOF
}

COMMAND="${1:-}"
case "$COMMAND" in
    run|info) ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { usage >&2; exit 2; }

[ -d "$OUT" ] && [ ! -L "$OUT" ] || fail "output directory must be a real directory: $OUT"
OUT="$(cd "$OUT" && pwd -P)"
case "$OUT" in
    *','*|*'\'*) fail "output directory must not contain a comma or backslash: $OUT" ;;
esac
IMAGE="$OUT/debian-portable.qcow2"
VARS="$OUT/debian-portable-vars.fd"
QMP_DEFAULT="$OUT/portable-qmp.sock"
if [ -n "${PORTABLE_VM_QMP_SOCKET:-}" ] && [[ "$PORTABLE_VM_QMP_SOCKET" != /* ]]; then
    QMP_SOCKET="$OUT/$PORTABLE_VM_QMP_SOCKET"
elif [ -z "${PORTABLE_VM_QMP_SOCKET:-}" ]; then
    QMP_SOCKET="$QMP_DEFAULT"
fi
if [ -n "${PORTABLE_VM_QMP:-}" ]; then
    case "$PORTABLE_VM_QMP" in
        0) QMP_SOCKET="" ;;
        1) QMP_SOCKET="${PORTABLE_VM_QMP_SOCKET:-$QMP_DEFAULT}" ;;
        *) fail "PORTABLE_VM_QMP must be 0 or 1" ;;
    esac
fi

validate_direct_child() {
    local label="$1" path="$2" parent
    [ -n "$path" ] || fail "$label path is empty"
    parent="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)" ||
        fail "$label parent directory does not exist: $path"
    [ "$parent" = "$OUT" ] || fail "$label must be directly under $OUT: $path"
    case "$path" in
        *','*|*'\'*) fail "$label must not contain a comma or backslash: $path" ;;
    esac
    [ "$(basename "$path")" != "." ] && [ "$(basename "$path")" != ".." ] ||
        fail "$label has an invalid basename: $path"
}

validate_direct_child "disk" "$IMAGE"
validate_direct_child "UEFI variable store" "$VARS"
[ "$(basename "$IMAGE")" = "debian-portable.qcow2" ] || fail "invalid disk path"
[ "$(basename "$VARS")" = "debian-portable-vars.fd" ] || fail "invalid variable-store path"
if [ -n "$QMP_SOCKET" ]; then
    validate_direct_child "QMP socket" "$QMP_SOCKET"
    case "$(basename "$QMP_SOCKET")" in
        *.sock) ;;
        *) fail "QMP socket must have a .sock name: $QMP_SOCKET" ;;
    esac
fi
if [ -n "$SERIAL_LOG" ]; then
    [[ "$SERIAL_LOG" = /* ]] || SERIAL_LOG="$OUT/$SERIAL_LOG"
    validate_direct_child "serial log" "$SERIAL_LOG"
fi
case "$BRIDGE" in 0|1) ;; *) fail "PORTABLE_VM_BRIDGE must be 0 or 1" ;; esac
case "$BRIDGE_IFACE" in ""|*[!A-Za-z0-9._-]*) fail "invalid bridge interface: $BRIDGE_IFACE" ;; esac
case "$SSH_PORT" in ""|*[!0-9]*) fail "PORTABLE_VM_SSH_PORT must be numeric" ;; esac
[ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ] || fail "PORTABLE_VM_SSH_PORT must be 1..65535"

qemu_info() {
    "$QEMU_IMG" info --output=json "$1"
}

validate_qcow2() {
    local metadata
    [ ! -L "$IMAGE" ] && [ -f "$IMAGE" ] ||
        fail "disk must be a regular, non-symlink file: $IMAGE"
    [ -x "$QEMU_IMG" ] || fail "qemu-img is not executable: $QEMU_IMG"
    metadata="$(qemu_info "$IMAGE")" || fail "cannot inspect disk: $IMAGE"
    printf '%s\n' "$metadata" | grep -Eq '"format"[[:space:]]*:[[:space:]]*"qcow2"' ||
        fail "disk is not qcow2: $IMAGE"
    printf '%s\n' "$metadata" | grep -Eq '"(backing-filename|data-file|data-file-raw)"[[:space:]]*:' &&
        fail "disk has backing or external data; a standalone image is required"
    "$QEMU_IMG" check -q "$IMAGE" || fail "disk failed qcow2 integrity check: $IMAGE"
}

validate_firmware() {
    [ ! -L "$CODE" ] && [ -f "$CODE" ] || fail "UEFI code must be a regular file: $CODE"
    [ ! -L "$VARS_SOURCE" ] && [ -f "$VARS_SOURCE" ] ||
        fail "UEFI variable template must be a regular file: $VARS_SOURCE"
}

ensure_vars() {
    validate_firmware
    if [ -e "$VARS" ] || [ -L "$VARS" ]; then
        [ ! -L "$VARS" ] && [ -f "$VARS" ] || fail "UEFI variable store must be a regular file: $VARS"
        return
    fi
    # cp -n is intentional: a concurrent or pre-existing variable store is
    # never overwritten.  The launcher lock also serializes normal launches.
    cp -n -- "$VARS_SOURCE" "$VARS" || fail "could not create private UEFI variable store: $VARS"
    [ ! -L "$VARS" ] && [ -f "$VARS" ] || fail "private UEFI variable store was not created safely"
}

acquire_lock() {
    [ ! -L "$LOCK_DIR" ] || fail "lock path is a symlink: $LOCK_DIR"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        fail "lock exists: $LOCK_DIR (refusing stale locks; inspect/remove it manually)"
    fi
    LOCK_HELD=1
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
}

release_lock() {
    local owner
    if [ -n "$QEMU_PID" ]; then
        kill -TERM "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    if [ "$LOCK_HELD" -eq 1 ] && [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ]; then
        owner="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
        [ "$owner" = "$$" ] || return 0
        rm -f -- "$LOCK_DIR/pid"
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
}
trap release_lock EXIT

forward_signal() {
    [ -n "$QEMU_PID" ] && kill -"$1" "$QEMU_PID" 2>/dev/null || true
}
trap 'forward_signal HUP' HUP
trap 'forward_signal INT' INT
trap 'forward_signal QUIT' QUIT
trap 'forward_signal TERM' TERM

check_bridge() {
    [ "$BRIDGE" -eq 1 ] || return 0
    [ "$(id -u)" -ne 0 ] || fail "run the launcher as the target user, not root"
    command -v sudo >/dev/null 2>&1 || fail "sudo is required for vmnet bridge setup"
    local ifconfig_bin="${PORTABLE_VM_IFCONFIG:-/sbin/ifconfig}"
    [ -x "$ifconfig_bin" ] || ifconfig_bin="$(command -v ifconfig 2>/dev/null || true)"
    [ -n "$ifconfig_bin" ] || fail "ifconfig is unavailable for bridge interface $BRIDGE_IFACE"
    "$ifconfig_bin" "$BRIDGE_IFACE" >/dev/null 2>&1 || fail "bridge interface is unavailable: $BRIDGE_IFACE"
    "$QEMU" -M none -netdev help 2>&1 | grep -qx 'vmnet-bridged' ||
        fail "QEMU does not provide vmnet-bridged: $QEMU"
}

validate_qcow2
validate_firmware
if [ "$COMMAND" = "info" ]; then
    echo "qemu:    $QEMU"
    echo "qemu-img: $QEMU_IMG"
    echo "machine: virt,highmem=on"
    echo "accel:   hvf"
    echo "cpu:     host"
    echo "vcpus:   4"
    echo "memory:  4G"
    echo "uefi:    $CODE (readonly)"
    echo "vars:    $VARS (private writable copy)"
    echo "disk:    $IMAGE (GPT EFI + ext4 expected)"
    echo "network: management 127.0.0.1:$SSH_PORT ($MGMT_MAC)"
    if [ "$BRIDGE" -eq 1 ]; then echo "network: bridge $BRIDGE_IFACE ($BRIDGE_MAC)"; else echo "network: bridge disabled"; fi
    if [ -n "$QMP_SOCKET" ]; then echo "qmp:     $QMP_SOCKET"; else echo "qmp:     disabled"; fi
    [ -n "$SERIAL_LOG" ] && echo "serial:  $SERIAL_LOG"
    qemu_info "$IMAGE"
    exit 0
fi

[ -x "$QEMU" ] || fail "QEMU is not executable: $QEMU"
acquire_lock
ensure_vars
check_bridge
if [ -n "$QMP_SOCKET" ]; then
    [ ! -e "$QMP_SOCKET" ] && [ ! -L "$QMP_SOCKET" ] || fail "QMP socket path already exists: $QMP_SOCKET"
fi
if [ -n "$SERIAL_LOG" ]; then
    [ ! -e "$SERIAL_LOG" ] && [ ! -L "$SERIAL_LOG" ] || fail "serial log already exists: $SERIAL_LOG"
fi

ARGS=(
    -M virt,highmem=on
    -accel hvf
    -cpu host
    -smp 4
    -m 4G
    -drive "if=pflash,format=raw,readonly=on,file=$CODE"
    -drive "if=pflash,format=raw,file=$VARS"
    -drive "if=virtio,file=$IMAGE,format=qcow2,cache=none"
    -netdev "user,id=mgmt,ipv4=on,ipv6=on,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22"
    -device "virtio-net-pci,netdev=mgmt,mac=$MGMT_MAC"
    -nographic
)
if [ "$BRIDGE" -eq 1 ]; then
    ARGS+=(
        -netdev "vmnet-bridged,id=lan,ifname=$BRIDGE_IFACE"
        -device "virtio-net-pci,netdev=lan,mac=$BRIDGE_MAC"
    )
fi
[ -n "$QMP_SOCKET" ] && ARGS+=( -qmp "unix:$QMP_SOCKET,server=on,wait=off" )
if [ -n "$SERIAL_LOG" ]; then
    ARGS+=( -display none -monitor none -serial "file:$SERIAL_LOG" )
fi

QEMU_COMMAND=("$QEMU")
if [ "$BRIDGE" -eq 1 ]; then
    if ! sudo -n true 2>/dev/null; then
        [ -t 0 ] || fail "vmnet authorization is unavailable; run sudo -v first"
        sudo -v || fail "sudo authorization is required for vmnet"
    fi
    QEMU_COMMAND=(sudo -n "$QEMU")
    ARGS+=( -run-with "user=$(id -u):$(id -g)" )
fi

echo "==> portable UEFI VM: 4 vCPUs, 4G RAM"
echo "    disk: $IMAGE"
echo "    ssh:  ssh -p $SSH_PORT root@127.0.0.1"
[ "$BRIDGE" -eq 1 ] && echo "    lan:  bridged on $BRIDGE_IFACE ($BRIDGE_MAC)"
"${QEMU_COMMAND[@]}" "${ARGS[@]}" <&0 &
QEMU_PID=$!
set +e
wait "$QEMU_PID"
status=$?
set -e
QEMU_PID=""
exit "$status"

#!/bin/bash
# Control the recovered M5 Max Debian VM using localhost SSH and a serial socket.
set -euo pipefail
umask 077

HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
STATE="$HERE/out/m5-working"
BOOT="$HERE/out/m5-vm"
DISK="$STATE/debian-arm64.qcow2"
HOME_DISK="$STATE/home.qcow2"
HOME_REQUIRED="$STATE/home-disk-required"
PIDFILE="$STATE/qemu.pid"
CONSOLE="$STATE/console.sock"
QEMU="${QEMU:-/opt/homebrew/bin/qemu-system-aarch64}"
QEMU_IMG="${QEMU_IMG:-/opt/homebrew/bin/qemu-img}"
SSH_PORT="${M5_VM_SSH_PORT:-22026}"
SMP="${SMP:-4}"
MEM="${MEM:-4G}"
BRIDGE="${M5_VM_BRIDGE:-}"
if [ -z "$BRIDGE" ]; then
    if [ -f "$STATE/bridge-enabled" ]; then BRIDGE=1; else BRIDGE=0; fi
fi
BRIDGE_IFACE="${M5_VM_BRIDGE_IFACE:-en0}"

fail() { echo "m5-vm: $*" >&2; exit 1; }
vm_ssh() {
    ssh -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=1 \
        -o "UserKnownHostsFile=$STATE/known_hosts" \
        -o StrictHostKeyChecking=accept-new root@127.0.0.1 "$@"
}
running() {
    [ -f "$PIDFILE" ] || return 1
    local pid command
    pid="$(cat "$PIDFILE")"
    case "$pid" in ''|*[!0-9]*|0|1) return 1 ;; esac
    kill -0 "$pid" 2>/dev/null || return 1
    command="$(ps -p "$pid" -o command=)" || return 1
    case "$command" in *"-name debian-m5 "*"$DISK"*) return 0 ;; *) return 1 ;; esac
}

COMMAND="${1:-}"
[ "$#" -eq 0 ] || shift
case "$COMMAND" in
    start|run|stop|status|console|info) [ "$#" -eq 0 ] || fail "unexpected arguments" ;;
    ssh) ;;
    *) echo "usage: $0 start|run|stop|status|console|info|ssh [guest-command]"; exit 2 ;;
esac
case "$SSH_PORT" in ''|*[!0-9]*) fail "M5_VM_SSH_PORT must be numeric" ;; esac
[ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ] || fail "invalid SSH port"
case "$BRIDGE" in 0|1) ;; *) fail "M5_VM_BRIDGE must be 0 or 1" ;; esac
case "$BRIDGE_IFACE" in ''|*[!A-Za-z0-9._-]*) fail "invalid bridge interface" ;; esac

case "$COMMAND" in
    ssh) exec ssh -p "$SSH_PORT" -o ConnectTimeout=5 \
        -o "UserKnownHostsFile=$STATE/known_hosts" \
        -o StrictHostKeyChecking=accept-new root@127.0.0.1 "$@" ;;
    status)
        if running; then echo "Debian VM running (PID $(cat "$PIDFILE")), SSH 127.0.0.1:$SSH_PORT";
        else echo "Debian VM stopped"; fi
        exit 0 ;;
    console)
        running || fail "VM is stopped; run $0 start"
        echo "Serial console: press Enter for a prompt; Ctrl-C disconnects."
        exec /usr/bin/nc -U "$CONSOLE" ;;
    stop)
        running || { echo "Debian VM stopped"; exit 0; }
        vm_ssh systemctl poweroff
        for _ in {1..30}; do
            running || { echo "Debian VM stopped cleanly"; exit 0; }
            sleep 1
        done
        fail "shutdown is still in progress; inspect $STATE/console.log" ;;
esac

KVER="$(cat "$BOOT/KVER")"
KERNEL="$BOOT/Image-$KVER"
INITRD="$BOOT/initrd.img-$KVER"
for input in "$DISK" "$KERNEL" "$INITRD"; do
    [ -f "$input" ] && [ ! -L "$input" ] || fail "missing regular file: $input"
done
[ -x "$QEMU" ] && [ -x "$QEMU_IMG" ] || fail "QEMU executables are unavailable"
case "$STATE" in *','*|*'\'*) fail "project path contains unsupported QEMU separators" ;; esac
if [ -e "$HOME_REQUIRED" ] && [ ! -f "$HOME_DISK" ]; then
    fail "required home disk is missing: $HOME_DISK"
fi
if [ -e "$HOME_DISK" ] || [ -L "$HOME_DISK" ]; then
    [ -f "$HOME_DISK" ] && [ ! -L "$HOME_DISK" ] || fail "home disk must be a regular non-symlink file: $HOME_DISK"
fi

if [ "$COMMAND" = info ]; then
    echo "Debian M5: HVF, $SMP vCPUs, $MEM RAM, generic kernel $KVER"
    echo "disk: $DISK"
    [ -f "$HOME_DISK" ] && echo "home disk: $HOME_DISK"
    echo "SSH: $0 ssh"
    echo "console log: $STATE/console.log"
    if running; then
        echo "state: running (PID $(cat "$PIDFILE"))"
    else
        "$QEMU_IMG" info "$DISK"
    fi
    exit 0
fi
if running; then
    echo "Debian VM is already running; connect with $0 ssh"
    exit 0
fi
"$QEMU_IMG" check -q "$DISK" > "$STATE/disk-check.log" 2>&1 ||
    fail "disk check failed; inspect $STATE/disk-check.log"
if [ -f "$HOME_DISK" ]; then
    "$QEMU_IMG" check -q "$HOME_DISK" > "$STATE/home-disk-check.log" 2>&1 ||
        fail "home disk check failed; inspect $STATE/home-disk-check.log"
fi

ARGS=(
    -name debian-m5 -machine virt,highmem=on -accel hvf -cpu host
    -smp "$SMP" -m "$MEM"
    -kernel "$KERNEL" -initrd "$INITRD"
    -append "root=/dev/vda rootfstype=ext4 rw console=ttyAMA0"
    -drive "if=none,id=vmroot,file=$DISK,format=qcow2,cache=none"
    -device virtio-blk-pci,drive=vmroot,serial=m5-root
)
if [ -f "$HOME_DISK" ]; then
    ARGS+=( -drive "if=none,id=vmhome,file=$HOME_DISK,format=qcow2,cache=none"
            -device virtio-blk-pci,drive=vmhome,serial=m5-home )
fi
ARGS+=(
    -netdev "user,id=mgmt,ipv4=on,ipv6=on,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22"
    -device virtio-net-pci,netdev=mgmt,mac=52:54:00:15:00:61
    -display none -monitor none -pidfile "$PIDFILE"
)
QEMU_COMMAND=("$QEMU")
if [ "$BRIDGE" = 1 ]; then
    /sbin/ifconfig "$BRIDGE_IFACE" >/dev/null 2>&1 || fail "bridge interface unavailable: $BRIDGE_IFACE"
    "$QEMU" -M none -netdev help 2>&1 | grep -qx vmnet-bridged || fail "QEMU has no vmnet-bridged backend"
    if ! sudo -n true 2>/dev/null; then
        [ -t 0 ] || fail "vmnet requires authorization; run sudo -v in a terminal"
        sudo -v || fail "vmnet authorization failed"
    fi
    QEMU_COMMAND=(sudo -n "$QEMU")
    ARGS+=( -netdev "vmnet-bridged,id=lan,ifname=$BRIDGE_IFACE"
            -device virtio-net-pci,netdev=lan,mac=52:54:00:15:00:62
            -run-with "user=$(id -u):$(id -g)" )
fi
if [ "$COMMAND" = run ]; then
    exec "${QEMU_COMMAND[@]}" "${ARGS[@]}" -serial mon:stdio
fi
"${QEMU_COMMAND[@]}" "${ARGS[@]}" -daemonize \
    -chardev "socket,id=console,path=$CONSOLE,server=on,wait=off,logfile=$STATE/console.log,logappend=on" \
    -serial chardev:console
for _ in {1..20}; do
    if vm_ssh true 2>/dev/null; then
        echo "Debian VM ready: $0 ssh"
        exit 0
    fi
    running || fail "QEMU exited; inspect $STATE/console.log"
    sleep 1
done
fail "VM started but SSH is not ready; inspect $STATE/console.log or use $0 console"

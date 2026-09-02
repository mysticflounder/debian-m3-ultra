#!/bin/bash
# Launch a persistent, headless Debian test VM under HVF.
#
# The init command makes out/testvm-root.qcow2 as a standalone copy of
# rootfs.ext4.  The original rootfs is never attached to QEMU and later guest
# writes remain in the qcow2 image.  Ctrl-A X exits QEMU; a clean guest
# shutdown is better.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/out"
BASE_ROOTFS="$OUT/rootfs.ext4"
VM_DISK="$OUT/testvm-root.qcow2"
LOCK_DIR="$OUT/.test-vm.lock"
SCRIPTS_DIR="$HERE/scripts"
PROJECT_QEMU="$OUT/qemu-fork-pmintenclr-build/qemu-system-aarch64"
if [ -x "$PROJECT_QEMU" ]; then
    DEFAULT_QEMU="$PROJECT_QEMU"
else
    DEFAULT_QEMU="/opt/homebrew/bin/qemu-system-aarch64"
fi
QEMU="${QEMU:-$DEFAULT_QEMU}"
QEMU_IMG="${QEMU_IMG:-/opt/homebrew/bin/qemu-img}"
SMP="${SMP:-8}"
MEM="${MEM:-8G}"
SSH_PORT="${SSH_PORT:-22022}"

usage() {
    cat <<EOF
usage: ./scripts/test-vm.sh init|run|info

  init  create and validate a standalone persistent qcow2 disk
  run   launch the existing persistent VM on the serial console
  info  show the persistent disk metadata and launch configuration

Environment: QEMU, QEMU_IMG, SMP (default 8), MEM (default 8G),
             SSH_PORT (default 22022; forwarded on 127.0.0.1 only)

After boot, provision once (the operation is safe to repeat):
  mkdir -p /mnt/m3-scripts
  mount -o ro /dev/vdb1 /mnt/m3-scripts
  bash /mnt/m3-scripts/test-vm-provision.sh

Then connect from the host with:
  ssh -p $SSH_PORT root@127.0.0.1
EOF
}

fail() {
    echo "test-vm: $*" >&2
    exit 1
}

COMMAND="${1:-}"
case "$COMMAND" in
    init|run|info) ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
[ "$#" -le 1 ] || { usage >&2; exit 2; }

case "$SSH_PORT" in
    ""|*[!0-9]*) fail "SSH_PORT must be an integer from 1 through 65535" ;;
esac
[ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ] || \
    fail "SSH_PORT must be an integer from 1 through 65535"

[ -x "$QEMU_IMG" ] || fail "qemu-img is not executable: $QEMU_IMG"

LOCK_HELD=0
TEMP_DISK=""
QEMU_PID=""

release_lock() {
    local owner

    if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill -TERM "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    if [ "$LOCK_HELD" -eq 1 ] && [ ! -L "$LOCK_DIR" ] && [ -d "$LOCK_DIR" ]; then
        owner="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
        if [ -z "$owner" ] || [ "$owner" = "$$" ]; then
            rm -f -- "$LOCK_DIR/pid"
            rmdir "$LOCK_DIR" 2>/dev/null || true
        fi
    fi
    if [ -n "$TEMP_DISK" ] && { [ -e "$TEMP_DISK" ] || [ -L "$TEMP_DISK" ]; }; then
        rm -f -- "$TEMP_DISK"
    fi
}
trap release_lock EXIT

forward_signal() {
    if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill -"$1" "$QEMU_PID" 2>/dev/null || true
    fi
}
trap 'forward_signal HUP' HUP
trap 'forward_signal INT' INT
trap 'forward_signal QUIT' QUIT
trap 'forward_signal TERM' TERM

acquire_lock() {
    local owner

    if mkdir "$LOCK_DIR" 2>/dev/null; then
        LOCK_HELD=1
        printf '%s\n' "$$" > "$LOCK_DIR/pid"
        return
    fi

    [ ! -L "$LOCK_DIR" ] && [ -d "$LOCK_DIR" ] || \
        fail "lock path is not a real directory: $LOCK_DIR"

    if [ ! -f "$LOCK_DIR/pid" ]; then
        fail "lock exists without an owner: $LOCK_DIR (inspect it before removing it)"
    fi
    owner="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    case "$owner" in
        ""|*[!0-9]*)
            fail "lock has an invalid owner: $LOCK_DIR (inspect it before removing it)"
            ;;
    esac
    if kill -0 "$owner" 2>/dev/null; then
        fail "persistent test VM is already in use by launcher pid $owner"
    fi

    # The recorded launcher is gone.  Remove only the one known lock file and
    # the now-empty directory; unexpected contents cause a safe refusal.
    rm -f -- "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null || \
        fail "stale lock contains unexpected files: $LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || fail "another launcher acquired the VM lock"
    LOCK_HELD=1
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
}

image_info() {
    "$QEMU_IMG" info --output=json "$1"
}

validate_qcow2() {
    local info
    [ ! -L "$VM_DISK" ] && [ -f "$VM_DISK" ] || \
        fail "VM disk must be a regular, non-symlink file: $VM_DISK"
    info="$(image_info "$VM_DISK")" || fail "cannot inspect $VM_DISK"
    printf '%s\n' "$info" | grep -Eq '"format"[[:space:]]*:[[:space:]]*"qcow2"' || \
        fail "$VM_DISK is not qcow2"
    if printf '%s\n' "$info" | grep -Eq '"backing-filename"[[:space:]]*:'; then
        fail "$VM_DISK has a backing file; a standalone persistent image is required"
    fi
    if printf '%s\n' "$info" | grep -Eq '"data-file"[[:space:]]*:'; then
        fail "$VM_DISK has an external data file; a standalone persistent image is required"
    fi
    "$QEMU_IMG" check -q "$VM_DISK" || \
        fail "$VM_DISK failed the read-only qcow2 integrity check"
}

load_boot_artifacts() {
    [ -x "$QEMU" ] || fail "QEMU is not executable: $QEMU"
    [ -f "$OUT/KVER" ] || fail "missing $OUT/KVER; build or copy the rootfs artifacts first"

    KVER="$(cat "$OUT/KVER")"
    case "$KVER" in
        ""|*/*) fail "invalid kernel version in $OUT/KVER" ;;
    esac
    KERNEL="$OUT/Image-$KVER"
    INITRD="$OUT/initrd.img-$KVER"
    [ ! -L "$KERNEL" ] && [ -f "$KERNEL" ] || \
        fail "kernel must be a regular, non-symlink file: $KERNEL"
    [ ! -L "$INITRD" ] && [ -f "$INITRD" ] || \
        fail "initrd must be a regular, non-symlink file: $INITRD"
}

if [ "$COMMAND" = "info" ]; then
    load_boot_artifacts
    validate_qcow2
    echo "qemu:    $QEMU"
    echo "qemu-img: $QEMU_IMG"
    echo "machine: virt,highmem=on"
    echo "accel:   hvf"
    echo "cpu:     host"
    echo "vcpus:   $SMP"
    echo "memory:  $MEM"
    echo "kernel:  $KERNEL"
    echo "initrd:  $INITRD"
    echo "disk:    $VM_DISK"
    echo "network: user-mode NAT with virtio-net-pci"
    echo "ssh:     127.0.0.1:$SSH_PORT -> guest port 22"
    image_info "$VM_DISK"
    exit 0
fi

if [ "$COMMAND" = "init" ]; then
    [ ! -L "$BASE_ROOTFS" ] && [ -f "$BASE_ROOTFS" ] || \
        fail "base rootfs must be a regular, non-symlink file: $BASE_ROOTFS"
    acquire_lock

    if [ -e "$VM_DISK" ] || [ -L "$VM_DISK" ]; then
        validate_qcow2
        echo "persistent VM disk already exists and is valid: $VM_DISK"
        exit 0
    fi

    base_info="$(image_info "$BASE_ROOTFS")" || fail "cannot inspect $BASE_ROOTFS"
    printf '%s\n' "$base_info" | grep -Eq '"format"[[:space:]]*:[[:space:]]*"raw"' || \
        fail "$BASE_ROOTFS is not a raw filesystem image"

    TEMP_DISK="$VM_DISK.tmp.$$"
    [ ! -e "$TEMP_DISK" ] && [ ! -L "$TEMP_DISK" ] || \
        fail "temporary image already exists: $TEMP_DISK"
    echo "==> creating standalone persistent disk from rootfs.ext4"
    "$QEMU_IMG" convert -f raw -O qcow2 "$BASE_ROOTFS" "$TEMP_DISK"
    mv -n "$TEMP_DISK" "$VM_DISK"
    [ ! -e "$TEMP_DISK" ] && [ ! -L "$TEMP_DISK" ] || \
        fail "persistent disk path appeared during creation: $VM_DISK"
    TEMP_DISK=""
    echo "    $VM_DISK"
    validate_qcow2
    echo "persistent VM disk is ready: $VM_DISK"
    exit 0
fi

[ -d "$SCRIPTS_DIR" ] || fail "missing scripts directory: $SCRIPTS_DIR"
[ -e "$VM_DISK" ] || fail "missing $VM_DISK; run ./scripts/test-vm.sh init first"
load_boot_artifacts

acquire_lock
validate_qcow2

ARGS=(
    -M virt,highmem=on
    -accel hvf
    -cpu host
    -smp "$SMP"
    -m "$MEM"
    -kernel "$KERNEL"
    -initrd "$INITRD"
    -append "root=/dev/vda rootfstype=ext4 rw console=ttyAMA0 systemd.unit=multi-user.target"
    -drive "if=virtio,file=$VM_DISK,format=qcow2,cache=none"
    -drive "if=virtio,file=fat:ro:$SCRIPTS_DIR,format=raw,readonly=on"
    -netdev "user,id=net0,ipv4=on,ipv6=on,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22"
    -device virtio-net-pci,netdev=net0
    -nographic
)

cat <<EOF
==> persistent test VM: ${SMP} vCPUs, ${MEM} RAM
    disk: $VM_DISK
    ssh:  ssh -p $SSH_PORT root@127.0.0.1
    exit: shut down the guest, or press Ctrl-A X
EOF

# Keep the launcher in the foreground so its EXIT trap owns the complete lock
# lifetime.  The explicit stdin redirection preserves the interactive serial
# console for the asynchronous child.  QEMU also takes its native exclusive
# write lock on the qcow2 file.
"$QEMU" "${ARGS[@]}" <&0 &
QEMU_PID=$!
QEMU_STATUS=0
while :; do
    set +e
    wait "$QEMU_PID"
    QEMU_STATUS=$?
    set -e
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        break
    fi
done
QEMU_PID=""
exit "$QEMU_STATUS"

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
VM_DISK="${TEST_VM_DISK:-$OUT/testvm-root.qcow2}"
KERNEL_OVERRIDE="${TEST_VM_KERNEL:-}"
INITRD_OVERRIDE="${TEST_VM_INITRD:-}"
QMP_OVERRIDE="${TEST_VM_QMP_SOCKET:-}"
NO_SHUTDOWN="${TEST_VM_NO_SHUTDOWN:-0}"
LOCK_DIR="$OUT/.test-vm.lock"
SCRIPTS_DIR="$HERE/scripts"
PROJECT_QEMU="$OUT/qemu-fork-vmnet-build/qemu-system-aarch64"
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
VMNET_IFNAME="${VMNET_IFNAME:-en0}"
VMNET_USE_SUDO="${VMNET_USE_SUDO:-1}"
MGMT_MAC="52:54:00:12:34:56"
BRIDGE_MAC="52:54:00:12:34:57"

usage() {
    cat <<EOF
usage: ./scripts/test-vm.sh init|run|info

  init  create and validate a standalone persistent qcow2 disk
  run   launch the existing persistent VM on the serial console
  info  show the persistent disk metadata and launch configuration

Environment: QEMU, QEMU_IMG, SMP (default 8), MEM (default 8G),
             SSH_PORT (default 22022; forwarded on 127.0.0.1 only),
             VMNET_IFNAME (default en0; physical interface for bridged LAN),
             VMNET_USE_SUDO (default 1; initialize vmnet as root, then drop),
             TEST_VM_DISK (qcow2 directly under out/),
             TEST_VM_KERNEL and TEST_VM_INITRD (must be set together;
             matching Image-VERSION and initrd.img-VERSION files directly
             under out/), TEST_VM_QMP_SOCKET (optional QMP Unix socket
             directly under out/), TEST_VM_NO_SHUTDOWN (0 or 1; requires QMP)

After boot, provision once (the operation is safe to repeat):
  mkdir -p /mnt/m3-scripts
  mount -o ro /dev/vdb1 /mnt/m3-scripts
  bash /mnt/m3-scripts/test-vm-provision.sh

Then connect from the host with:
  ssh -p $SSH_PORT root@127.0.0.1

SSH password authentication is disabled. Install a public key through the
serial console before relying on SSH.
EOF
}

fail() {
    echo "test-vm: $*" >&2
    exit 1
}

normalize_project_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s\n' "$HERE/$1" ;;
    esac
}

validate_out_path() {
    local label="$1"
    local path="$2"
    local parent

    parent="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)" ||
        fail "$label parent directory does not exist: $path"
    [ "$parent" = "$OUT" ] ||
        fail "$label must be directly under $OUT: $path"
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

if [ -n "$KERNEL_OVERRIDE" ] || [ -n "$INITRD_OVERRIDE" ]; then
    [ -n "$KERNEL_OVERRIDE" ] && [ -n "$INITRD_OVERRIDE" ] ||
        fail "TEST_VM_KERNEL and TEST_VM_INITRD must be set together"
fi

case "$NO_SHUTDOWN" in
    0|1) ;;
    *) fail "TEST_VM_NO_SHUTDOWN must be 0 or 1" ;;
esac

case "$VMNET_USE_SUDO" in
    0|1) ;;
    *) fail "VMNET_USE_SUDO must be 0 or 1" ;;
esac

VM_DISK="$(normalize_project_path "$VM_DISK")"
validate_out_path "VM disk" "$VM_DISK"
case "$(basename "$VM_DISK")" in
    *','*|*'\'*) fail "VM disk name must not contain a comma or backslash: $VM_DISK" ;;
    *.qcow2) ;;
    *) fail "VM disk must have a .qcow2 name: $VM_DISK" ;;
esac

QMP_SOCKET=""
if [ -n "$QMP_OVERRIDE" ]; then
    QMP_SOCKET="$(normalize_project_path "$QMP_OVERRIDE")"
    validate_out_path "QMP socket" "$QMP_SOCKET"
    case "$(basename "$QMP_SOCKET")" in
        *','*|*'\'*) fail "QMP socket name must not contain a comma or backslash: $QMP_SOCKET" ;;
        *.sock) ;;
        *) fail "QMP socket must have a .sock name: $QMP_SOCKET" ;;
    esac
fi
[ "$NO_SHUTDOWN" -eq 0 ] || [ -n "$QMP_SOCKET" ] ||
    fail "TEST_VM_NO_SHUTDOWN=1 requires TEST_VM_QMP_SOCKET"

case "$VMNET_IFNAME" in
    ""|*[!A-Za-z0-9._-]*)
        fail "VMNET_IFNAME contains unsupported characters: $VMNET_IFNAME"
        ;;
esac

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

    if [ -n "$QEMU_PID" ]; then
        if [ "$VMNET_USE_SUDO" -eq 1 ]; then
            if sudo -n kill -0 "$QEMU_PID" 2>/dev/null; then
                sudo -n kill -TERM "$QEMU_PID" 2>/dev/null || true
            elif kill -0 "$QEMU_PID" 2>/dev/null; then
                kill -TERM "$QEMU_PID" 2>/dev/null || true
            fi
        elif kill -0 "$QEMU_PID" 2>/dev/null; then
            kill -TERM "$QEMU_PID" 2>/dev/null || true
        fi
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
    if [ -n "$QEMU_PID" ]; then
        if [ "$VMNET_USE_SUDO" -eq 1 ]; then
            sudo -n kill -"$1" "$QEMU_PID" 2>/dev/null ||
                kill -"$1" "$QEMU_PID" 2>/dev/null || true
        elif kill -0 "$QEMU_PID" 2>/dev/null; then
            kill -"$1" "$QEMU_PID" 2>/dev/null || true
        fi
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
    local kernel_name
    local initrd_name
    local override_version

    [ -x "$QEMU" ] || fail "QEMU is not executable: $QEMU"

    if [ -n "$KERNEL_OVERRIDE" ] || [ -n "$INITRD_OVERRIDE" ]; then
        KERNEL="$(normalize_project_path "$KERNEL_OVERRIDE")"
        INITRD="$(normalize_project_path "$INITRD_OVERRIDE")"
        validate_out_path "kernel" "$KERNEL"
        validate_out_path "initrd" "$INITRD"
        kernel_name="$(basename "$KERNEL")"
        initrd_name="$(basename "$INITRD")"
        case "$kernel_name" in
            Image-*) override_version="${kernel_name#Image-}" ;;
            vmlinuz-*) override_version="${kernel_name#vmlinuz-}" ;;
            *) fail "override kernel name must be Image-VERSION or vmlinuz-VERSION: $KERNEL" ;;
        esac
        [ -n "$override_version" ] ||
            fail "override kernel filename has an empty version: $KERNEL"
        [ "$initrd_name" = "initrd.img-$override_version" ] ||
            fail "override kernel and initrd filenames do not have the same version"
    else
        [ -f "$OUT/KVER" ] ||
            fail "missing $OUT/KVER; build or copy the rootfs artifacts first"
        KVER="$(cat "$OUT/KVER")"
        case "$KVER" in
            ""|*/*) fail "invalid kernel version in $OUT/KVER" ;;
        esac
        KERNEL="$OUT/Image-$KVER"
        INITRD="$OUT/initrd.img-$KVER"
    fi
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
    echo "network: bridged LAN on $VMNET_IFNAME ($BRIDGE_MAC)"
    echo "manage:  loopback-only user-mode NAT ($MGMT_MAC)"
    if [ "$VMNET_USE_SUDO" -eq 1 ]; then
        echo "privilege: root for vmnet initialization, then $(id -u):$(id -g)"
    else
        echo "privilege: direct (requires an authorized vmnet entitlement)"
    fi
    echo "ssh:     127.0.0.1:$SSH_PORT -> management NIC port 22"
    if [ -n "$QMP_SOCKET" ]; then
        echo "qmp:     $QMP_SOCKET"
    else
        echo "qmp:     disabled"
    fi
    if [ "$NO_SHUTDOWN" -eq 0 ]; then
        echo "exit on guest shutdown: yes"
    else
        echo "exit on guest shutdown: no"
    fi
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

/sbin/ifconfig "$VMNET_IFNAME" >/dev/null 2>&1 ||
    fail "vmnet bridge interface is unavailable: $VMNET_IFNAME"
"$QEMU" -M none -netdev help 2>&1 | grep -qx 'vmnet-bridged' ||
    fail "QEMU does not provide the vmnet-bridged backend: $QEMU"

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
    -netdev "user,id=mgmt,ipv4=on,ipv6=on,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22"
    -device "virtio-net-pci,netdev=mgmt,mac=$MGMT_MAC"
    -netdev "vmnet-bridged,id=lan,ifname=$VMNET_IFNAME"
    -device "virtio-net-pci,netdev=lan,mac=$BRIDGE_MAC"
    -nographic
)

QEMU_COMMAND=("$QEMU")
if [ "$VMNET_USE_SUDO" -eq 1 ]; then
    [ "$(id -u)" -ne 0 ] ||
        fail "run the launcher as the target user, not as root"
    command -v sudo >/dev/null 2>&1 || fail "sudo is required for vmnet"
    if ! sudo -n true 2>/dev/null; then
        [ -t 0 ] || fail "vmnet authorization is unavailable; run sudo -v first"
        sudo -v || fail "sudo authorization is required for vmnet"
    fi
    QEMU_COMMAND=(sudo -n "$QEMU")
    ARGS+=(
        -run-with "user=$(id -u):$(id -g)"
    )
fi

if [ -n "$QMP_SOCKET" ]; then
    [ ! -e "$QMP_SOCKET" ] && [ ! -L "$QMP_SOCKET" ] ||
        fail "QMP socket path already exists: $QMP_SOCKET"
    ARGS+=(
        -qmp "unix:$QMP_SOCKET,server=on,wait=off"
    )
fi

if [ "$NO_SHUTDOWN" -eq 1 ]; then
    ARGS+=(
        -no-shutdown
    )
fi

cat <<EOF
==> persistent test VM: ${SMP} vCPUs, ${MEM} RAM
    disk: $VM_DISK
    lan:  bridged on $VMNET_IFNAME ($BRIDGE_MAC)
    ssh:  ssh -p $SSH_PORT root@127.0.0.1
    exit: shut down the guest, or press Ctrl-A X
EOF

# Keep the launcher in the foreground so its EXIT trap owns the complete lock
# lifetime.  The explicit stdin redirection preserves the interactive serial
# console for the asynchronous child.  QEMU also takes its native exclusive
# write lock on the qcow2 file.
"${QEMU_COMMAND[@]}" "${ARGS[@]}" <&0 &
QEMU_PID=$!
if [ -n "$QMP_SOCKET" ] && [ "$VMNET_USE_SUDO" -eq 1 ]; then
    QMP_OWNER_READY=0
    QMP_ATTEMPTS=0
    while [ "$QMP_ATTEMPTS" -lt 100 ]; do
        if [ -S "$QMP_SOCKET" ]; then
            sudo -n chown "$(id -u):$(id -g)" "$QMP_SOCKET" ||
                fail "could not transfer QMP socket ownership: $QMP_SOCKET"
            chmod 0600 "$QMP_SOCKET" ||
                fail "could not secure QMP socket: $QMP_SOCKET"
            QMP_OWNER_READY=1
            break
        fi
        sleep 0.1
        QMP_ATTEMPTS=$((QMP_ATTEMPTS + 1))
    done
    [ "$QMP_OWNER_READY" -eq 1 ] ||
        fail "QEMU did not create its QMP socket within 10 seconds"
fi
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

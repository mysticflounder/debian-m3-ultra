#!/bin/bash
# Build a standalone GPT/UEFI Debian arm64 disk from a temporary helper VM.
#
# This script is intentionally guest-only.  It accepts exactly one destructive
# operation, --build, and will only write the explicitly identified /dev/vdb
# virtio disk.  The helper root must be /dev/vda; no host path or host device is
# consulted or opened.
set -euo pipefail

SOURCE=/dev/vda
TARGET=/dev/vdb
# Virtio serials are limited to 20 characters by the helper VM's presentation.
EXPECTED_TARGET_SERIAL=DEBIAN_PORTABLE_TARG
EXPECTED_TARGET_BYTES=122010000384
ESP_DECIMAL_BYTES=2000000000
ROOT_DECIMAL_BYTES=120000000000
ESP_MIB=1907
ROOT_MIB=114440

fail() {
    echo "prepare-portable-root-guest: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
usage: prepare-portable-root-guest.sh --build

Run only inside the temporary Debian helper VM.  The helper root must be
/dev/vda and the blank target must be the /dev/vdb disk whose virtio serial is
DEBIAN_PORTABLE_TARG (the 20-character presentation of the requested
DEBIAN_PORTABLE_TARGET sentinel).
EOF
}

[ "${1:-}" = "--build" ] && [ "$#" -eq 1 ] || {
    usage >&2
    exit 2
}
[ "$(id -u)" -eq 0 ] || fail "must run as root inside the helper VM"

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

for command_name in \
    awk basename blkid blockdev chroot chmod chown cmp cp find findmnt grep \
    install lsblk mkfs.ext4 mkfs.vfat mount mktemp readlink rm rsync sed \
    seq sfdisk sleep touch tr umount udevadm wipefs; do
    require_command "$command_name"
done

ROOT_SOURCE="$(findmnt -n -o SOURCE --target / 2>/dev/null || true)"
[ "$ROOT_SOURCE" = "$SOURCE" ] ||
    fail "helper root must be mounted from $SOURCE, got: ${ROOT_SOURCE:-<none>}"

[ -b "$SOURCE" ] || fail "helper root source is not a block device: $SOURCE"
[ -b "$TARGET" ] || fail "target is not a block device: $TARGET"
[ "$(lsblk -dnro TYPE "$SOURCE")" = "disk" ] ||
    fail "helper root source is not a whole disk: $SOURCE"
[ "$(lsblk -dnro TYPE "$TARGET")" = "disk" ] ||
    fail "target is not a whole disk: $TARGET"

TARGET_SERIAL="$(lsblk -dnro SERIAL "$TARGET" | sed 's/[[:space:]]*$//')"
[ "$TARGET_SERIAL" = "$EXPECTED_TARGET_SERIAL" ] ||
    fail "target serial mismatch: expected $EXPECTED_TARGET_SERIAL, got ${TARGET_SERIAL:-<none>}"

TARGET_BYTES="$(blockdev --getsize64 "$TARGET")"
[ "$TARGET_BYTES" = "$EXPECTED_TARGET_BYTES" ] ||
    fail "target size mismatch: expected $EXPECTED_TARGET_BYTES bytes, got $TARGET_BYTES"

[ "$(readlink -f "$SOURCE")" != "$(readlink -f "$TARGET")" ] ||
    fail "source and target resolve to the same device"

if lsblk -nrpo NAME,MOUNTPOINT "$TARGET" | awk 'NF >= 2 && $2 != "" { found = 1 } END { exit found ? 0 : 1 }'; then
    fail "target or one of its children is mounted"
fi

TARGET_CHILDREN="$(lsblk -nrpo NAME,TYPE "$TARGET" | awk '$1 != "'"$TARGET"'" { print }')"
[ -z "$TARGET_CHILDREN" ] || fail "target is not unpartitioned: $TARGET_CHILDREN"

WIPEFS_OUTPUT="$(wipefs -n -- "$TARGET" 2>/dev/null)" ||
    fail "could not inspect target signatures with wipefs"
[ -z "$WIPEFS_OUTPUT" ] ||
    fail "target already has signatures; refusing to overwrite: $WIPEFS_OUTPUT"

[ -f /root/.ssh/authorized_keys ] && [ -s /root/.ssh/authorized_keys ] ||
    fail "helper root has no non-empty /root/.ssh/authorized_keys to preserve"

SOURCE_ROOT_UUID="$(blkid -s UUID -o value "$SOURCE" 2>/dev/null || true)"
SOURCE_AUTHORIZED_KEYS=/root/.ssh/authorized_keys

# A decimal 2 GB ESP rounds to 1907 MiB; the decimal 120 GB root is rounded
# down to 114440 MiB.  The GPT starts both partitions on MiB boundaries and
# deliberately leaves the remaining target tail unallocated.
SECTOR_SIZE="$(blockdev --getss "$TARGET")"
[ "$SECTOR_SIZE" -gt 0 ] && [ $((1048576 % SECTOR_SIZE)) -eq 0 ] ||
    fail "target sector size does not divide one MiB: $SECTOR_SIZE"
MIB_SECTORS=$((1048576 / SECTOR_SIZE))
ESP_SECTORS=$((ESP_MIB * MIB_SECTORS))
ROOT_SECTORS=$((ROOT_MIB * MIB_SECTORS))
FIRST_START=$MIB_SECTORS
SECOND_START=$((FIRST_START + ESP_SECTORS))
DISK_SECTORS=$((TARGET_BYTES / SECTOR_SIZE))
SECOND_END=$((SECOND_START + ROOT_SECTORS - 1))
[ "$SECOND_END" -lt $((DISK_SECTORS - 33)) ] ||
    fail "requested partitions do not fit before the GPT backup area"

echo "==> validated helper root $SOURCE and blank target $TARGET"
echo "    target serial: $TARGET_SERIAL"
echo "    target bytes:  $TARGET_BYTES"
echo "    ESP: ${ESP_MIB} MiB (from ${ESP_DECIMAL_BYTES} decimal bytes)"
echo "    root: ${ROOT_MIB} MiB (from ${ROOT_DECIMAL_BYTES} decimal bytes, rounded down)"

sfdisk --no-reread --wipe never "$TARGET" <<EOF
label: gpt
unit: sectors
first-lba: $FIRST_START
1 : start=$FIRST_START, size=$ESP_SECTORS, type=U, name="EFI System Partition"
2 : start=$SECOND_START, size=$ROOT_SECTORS, type=L, name="Debian portable root"
EOF

blockdev --rereadpt "$TARGET"
udevadm settle
ESP_PART=""
ROOT_PART=""
for _ in $(seq 1 50); do
    ESP_PART="$(lsblk -nrpo NAME,PARTN "$TARGET" | awk '$2 == 1 { print $1; exit }')"
    ROOT_PART="$(lsblk -nrpo NAME,PARTN "$TARGET" | awk '$2 == 2 { print $1; exit }')"
    [ -n "$ESP_PART" ] && [ -n "$ROOT_PART" ] && break
    sleep 0.1
done
[ -b "$ESP_PART" ] && [ -b "$ROOT_PART" ] ||
    fail "kernel did not expose the new target partitions"

mkfs.vfat -F 32 -n EFI -- "$ESP_PART"
mkfs.ext4 -F -L debian-portable -- "$ROOT_PART"
ESP_UUID="$(blkid -s UUID -o value "$ESP_PART")"
ROOT_UUID="$(blkid -s UUID -o value "$ROOT_PART")"
[ -n "$ESP_UUID" ] && [ -n "$ROOT_UUID" ] || fail "new filesystem UUIDs are unavailable"
[ "$ROOT_UUID" != "$SOURCE_ROOT_UUID" ] || fail "new root UUID unexpectedly equals source root UUID"

WORKDIR="$(mktemp -d /run/debian-portable.XXXXXX)"
NEWROOT="$WORKDIR/root"
mkdir -p "$NEWROOT" "$WORKDIR/efi"
MOUNTED_ROOT=0
MOUNTED_ESP=0
MOUNTED_DEV=0
MOUNTED_PROC=0
MOUNTED_SYS=0

cleanup() {
    local script_status=$?
    local cleanup_status=0
    set +e
    if [ "$MOUNTED_SYS" -eq 1 ]; then
        umount -R "$NEWROOT/sys" || cleanup_status=1
    fi
    if [ "$MOUNTED_DEV" -eq 1 ]; then
        umount -R "$NEWROOT/dev" || cleanup_status=1
    fi
    if [ "$MOUNTED_PROC" -eq 1 ]; then
        umount "$NEWROOT/proc" || cleanup_status=1
    fi
    if [ "$MOUNTED_ESP" -eq 1 ]; then
        umount "$NEWROOT/boot/efi" || cleanup_status=1
    fi
    if [ "$MOUNTED_ROOT" -eq 1 ]; then
        umount "$NEWROOT" || cleanup_status=1
    fi
    if [ "$cleanup_status" -ne 0 ]; then
        echo "prepare-portable-root-guest: cleanup failed; workdir retained: $WORKDIR" >&2
        exit 1
    fi
    exit "$script_status"
}
trap cleanup EXIT

mount "$ROOT_PART" "$NEWROOT"
MOUNTED_ROOT=1
mkdir -p "$NEWROOT/boot/efi"

WORKDIR_REL="${WORKDIR#/}"
rsync -aHAXx --numeric-ids \
    --exclude='/dev/***' \
    --exclude='/proc/***' \
    --exclude='/sys/***' \
    --exclude='/run/***' \
    --exclude='/boot/efi/***' \
    --exclude="/$WORKDIR_REL/***" \
    / "$NEWROOT/"

mount "$ESP_PART" "$NEWROOT/boot/efi"
MOUNTED_ESP=1

[ -f "$NEWROOT/root/.ssh/authorized_keys" ] &&
    cmp -s "$SOURCE_AUTHORIZED_KEYS" "$NEWROOT/root/.ssh/authorized_keys" ||
    fail "root authorized_keys was not preserved exactly"

mkdir -p "$NEWROOT/dev" "$NEWROOT/proc" "$NEWROOT/sys" "$NEWROOT/run"
mount --rbind /dev "$NEWROOT/dev"
mount --make-rslave "$NEWROOT/dev"
MOUNTED_DEV=1
mount -t proc proc "$NEWROOT/proc"
MOUNTED_PROC=1
mount --rbind /sys "$NEWROOT/sys"
mount --make-rslave "$NEWROOT/sys"
MOUNTED_SYS=1
# Give apt the helper's resolver only for the chroot operation, then restore
# the target's original resolver link/file before leaving the helper.
RESOLV_PATH="$NEWROOT/etc/resolv.conf"
RESOLV_STATE="$WORKDIR/resolv.state"
if [ -L "$RESOLV_PATH" ]; then
    printf 'link\n%s\n' "$(readlink "$RESOLV_PATH")" > "$RESOLV_STATE"
    rm -f "$RESOLV_PATH"
elif [ -e "$RESOLV_PATH" ]; then
    printf 'file\n' > "$RESOLV_STATE"
    cp -a "$RESOLV_PATH" "$WORKDIR/resolv.saved"
else
    printf 'absent\n' > "$RESOLV_STATE"
fi
cp -L /etc/resolv.conf "$RESOLV_PATH"

chroot_run() {
    chroot "$NEWROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive "$@"
}

PACKAGES=()
for package in grub-efi-arm64-bin grub2-common dosfstools initramfs-tools openssh-server; do
    if ! chroot_run dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null | grep -q '^ii '; then
        PACKAGES+=("$package")
    fi
done
if ! find "$NEWROOT/boot" -maxdepth 1 -type f -name 'vmlinuz-*' -print -quit | grep -q . ||
   ! find "$NEWROOT/lib/modules" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null | grep -q .; then
    PACKAGES+=(linux-image-arm64)
fi
if [ "${#PACKAGES[@]}" -gt 0 ]; then
    chroot_run apt-get update
    chroot_run apt-get install -y --no-install-recommends "${PACKAGES[@]}"
fi

mkdir -p "$NEWROOT/etc/initramfs-tools"
if [ -f "$NEWROOT/etc/initramfs-tools/initramfs.conf" ]; then
    if grep -q '^MODULES=' "$NEWROOT/etc/initramfs-tools/initramfs.conf"; then
        sed -i 's/^MODULES=.*/MODULES=most/' "$NEWROOT/etc/initramfs-tools/initramfs.conf"
    else
        printf '\nMODULES=most\n' >> "$NEWROOT/etc/initramfs-tools/initramfs.conf"
    fi
else
    printf 'MODULES=most\n' > "$NEWROOT/etc/initramfs-tools/initramfs.conf"
fi
touch "$NEWROOT/etc/initramfs-tools/modules"
for module in virtio virtio_pci virtio_blk virtio_net; do
    grep -qxF "$module" "$NEWROOT/etc/initramfs-tools/modules" ||
        printf '%s\n' "$module" >> "$NEWROOT/etc/initramfs-tools/modules"
done

# The portable image gets fresh machine/SSH identities; the root login key is
# the one deliberately preserved from the helper.  Generate machine-id from
# the helper kernel RNG, never from a copied helper runtime/random seed.
rm -f "$NEWROOT/etc/machine-id" "$NEWROOT/var/lib/dbus/machine-id"
rm -f "$NEWROOT/var/lib/systemd/random-seed"
MACHINE_ID="$(tr -d '-' < /proc/sys/kernel/random/uuid)"
printf '%s\n' "$MACHINE_ID" > "$NEWROOT/etc/machine-id"
printf '%s\n' "$MACHINE_ID" | grep -Eq '^[0-9a-f]{32}$' ||
    fail "generated machine-id is invalid"
rm -f "$NEWROOT/etc/ssh/ssh_host_"*
chroot_run ssh-keygen -A
printf 'debian-portable\n' > "$NEWROOT/etc/hostname"

install -d -m 0755 "$NEWROOT/etc/ssh/sshd_config.d"
cat > "$NEWROOT/etc/ssh/sshd_config.d/90-debian-portable-keyonly.conf" <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF
chmod 0644 "$NEWROOT/etc/ssh/sshd_config.d/90-debian-portable-keyonly.conf"
install -d -m 0700 "$NEWROOT/root/.ssh"
chmod 0600 "$NEWROOT/root/.ssh/authorized_keys"
chown -R 0:0 "$NEWROOT/root/.ssh"

# Replace inherited root/boot UUID references with only the newly formatted
# filesystems.  This also avoids carrying helper-specific /dev/vda entries.
cat > "$NEWROOT/etc/fstab" <<EOF
UUID=$ROOT_UUID / ext4 defaults 0 1
UUID=$ESP_UUID /boot/efi vfat umask=0077 0 2
EOF

GRUB_DEFAULTS="$NEWROOT/etc/default/grub"
mkdir -p "$NEWROOT/etc/default"
touch "$GRUB_DEFAULTS"
set_grub_value() {
    local key="$1"
    local value="$2"
    if grep -q "^${key}=" "$GRUB_DEFAULTS"; then
        sed -i "s#^${key}=.*#${key}=\"${value}\"#" "$GRUB_DEFAULTS"
    else
        printf '%s="%s"\n' "$key" "$value" >> "$GRUB_DEFAULTS"
    fi
}
set_grub_value GRUB_CMDLINE_LINUX_DEFAULT 'console=ttyAMA0,115200n8 systemd.unit=multi-user.target'
set_grub_value GRUB_CMDLINE_LINUX 'console=ttyAMA0,115200n8'
set_grub_value GRUB_TERMINAL 'console'
set_grub_value GRUB_SERIAL_COMMAND 'serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1'
set_grub_value GRUB_DISABLE_OS_PROBER 'true'
mkdir -p "$NEWROOT/etc/systemd/system/getty.target.wants"
ln -sfn /lib/systemd/system/serial-getty@.service \
    "$NEWROOT/etc/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service"

for module_dir in "$NEWROOT"/lib/modules/*; do
    [ -d "$module_dir" ] || continue
    kernel_version="$(basename "$module_dir")"
    if [ -e "$NEWROOT/boot/initrd.img-$kernel_version" ]; then
        chroot_run update-initramfs -u -k "$kernel_version"
    else
        chroot_run update-initramfs -c -k "$kernel_version"
    fi
done

chroot_run grub-install --target=arm64-efi --efi-directory=/boot/efi \
    --removable --no-nvram --recheck
chroot_run update-grub

if [ -n "$SOURCE_ROOT_UUID" ]; then
    : > "$WORKDIR/source-uuid.matches"
    for config in \
        "$NEWROOT/etc/fstab" \
        "$NEWROOT/etc/default/grub" \
        "$NEWROOT/boot/grub/grub.cfg"; do
        [ -f "$config" ] || continue
        grep -F -n -- "$SOURCE_ROOT_UUID" "$config" >> "$WORKDIR/source-uuid.matches" || true
    done
    if [ -s "$WORKDIR/source-uuid.matches" ]; then
        fail "source root UUID remains in target boot/config files: $SOURCE_ROOT_UUID"
    fi
fi

# Restore the target's pre-copy resolver representation.
rm -f "$RESOLV_PATH"
case "$(sed -n '1p' "$RESOLV_STATE")" in
    link)
        link_target="$(sed -n '2p' "$RESOLV_STATE")"
        ln -s "$link_target" "$RESOLV_PATH"
        ;;
    file) cp -a "$WORKDIR/resolv.saved" "$RESOLV_PATH" ;;
    absent) : ;;
    *) fail "invalid saved resolver state" ;;
esac

echo "portable Debian arm64 GPT/UEFI root prepared"
echo "  target: $TARGET"
echo "  ESP UUID:  $ESP_UUID"
echo "  root UUID: $ROOT_UUID"
echo "  source root UUID was not copied into fstab or GRUB configuration"

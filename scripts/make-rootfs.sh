#!/bin/bash
# Runs INSIDE a privileged debian:unstable arm64 container (image m3build:deps).
# Builds a minimal Debian sid arm64 rootfs with the linux-asahi kernel installed,
# then exports vmlinuz, initrd and an ext4 image for a QEMU boot test.
set -euo pipefail

R="${R:-/build/rootfs}"
OUT="${OUT:-/build/out}"
IMG_SIZE="${IMG_SIZE:-6G}"
SUITE="${SUITE:-sid}"

# This script deliberately replaces its build tree.  Keep both configurable
# paths inside the dedicated container workspace and require recognizable
# artifact-directory names so a typo cannot turn the cleanup into a broad rm.
case "$R" in
    /build/rootfs) ;;
    /build/rootfs-*)
        R_SUFFIX="${R#/build/rootfs-}"
        case "$R_SUFFIX" in
            ""|*/*|*[![:alnum:]_.-]*)
                echo "make-rootfs: R must be a simple direct child of /build" >&2
                exit 2
                ;;
        esac
        ;;
    *)
        echo "make-rootfs: R must be /build/rootfs or /build/rootfs-*" >&2
        exit 2
        ;;
esac
case "$OUT" in
    /build/out) ;;
    /build/out-*)
        OUT_SUFFIX="${OUT#/build/out-}"
        case "$OUT_SUFFIX" in
            ""|*/*|*[![:alnum:]_.-]*)
                echo "make-rootfs: OUT must be a simple direct child of /build" >&2
                exit 2
                ;;
        esac
        ;;
    *)
        echo "make-rootfs: OUT must be /build/out or /build/out-*" >&2
        exit 2
        ;;
esac

[ ! -L "$R" ] || {
    echo "make-rootfs: refusing symlinked rootfs directory: $R" >&2
    exit 2
}
[ ! -e "$R" ] || [ -d "$R" ] || {
    echo "make-rootfs: rootfs path exists but is not a directory: $R" >&2
    exit 2
}
[ ! -L "$OUT" ] || {
    echo "make-rootfs: refusing symlinked output directory: $OUT" >&2
    exit 2
}

# Refuse the cleanup if this tree contains any mount, including same-device
# bind mounts that rm --one-file-system cannot distinguish from ordinary
# directories.  Stale proc/sys/dev mounts must be handled explicitly first.
MOUNT_TARGETS="$(findmnt -rn -o TARGET)" || {
    echo "make-rootfs: cannot enumerate mounts safely" >&2
    exit 2
}
while IFS= read -r MOUNT_TARGET; do
    case "$MOUNT_TARGET" in
        "$R"|"$R"/*)
            echo "make-rootfs: refusing mounted path below rootfs: $MOUNT_TARGET" >&2
            exit 2
            ;;
    esac
done <<< "$MOUNT_TARGETS"
[ ! -e "$OUT" ] || [ -d "$OUT" ] || {
    echo "make-rootfs: output path exists but is not a directory: $OUT" >&2
    exit 2
}

echo "==> tooling"
export DEBIAN_FRONTEND=noninteractive
apt-get install -y --no-install-recommends debootstrap e2fsprogs >/dev/null

echo "==> debootstrap $SUITE"
rm -rf --one-file-system -- "$R"
debootstrap --arch=arm64 --variant=minbase \
  --include=systemd-sysv,udev,initramfs-tools,iproute2,kmod,pciutils,less,nano,ca-certificates \
  "$SUITE" "$R" http://deb.debian.org/debian

echo "==> add bananas archive to the rootfs"
install -d "$R/etc/apt/keyrings"
cp /etc/apt/keyrings/bananas-archive-keyring.gpg "$R/etc/apt/keyrings/"
cp /etc/apt/sources.list.d/bananas.sources      "$R/etc/apt/sources.list.d/"
cp /etc/apt/preferences.d/bananas.pref          "$R/etc/apt/preferences.d/"

cleanup() {
    for m in dev/pts dev sys proc; do
        mountpoint -q "$R/$m" && umount -l "$R/$m" || true
    done
}
trap cleanup EXIT

mount -t proc  proc   "$R/proc"
mount -t sysfs sysfs  "$R/sys"
mount --bind   /dev   "$R/dev"
mount -t devpts devpts "$R/dev/pts"

echo "==> install the linux-asahi kernel"
chroot "$R" apt-get update -qq
chroot "$R" env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends linux-image-asahi

echo "==> provision persistent headless test-VM services"
install -m 0755 /scripts/test-vm-provision.sh "$R/tmp/test-vm-provision.sh"
chroot "$R" env TEST_VM_BUILD_CHROOT=1 /tmp/test-vm-provision.sh
rm -f "$R/tmp/test-vm-provision.sh"

echo "==> configure login on the serial console"
chroot "$R" bash -c 'echo "root:root" | chpasswd'
echo "m3test" > "$R/etc/hostname"
install -d "$R/etc/systemd/system/serial-getty@ttyAMA0.service.d"
cat > "$R/etc/systemd/system/serial-getty@ttyAMA0.service.d/autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I 115200 linux
EOF
printf '/dev/vda / ext4 defaults 0 1\n' > "$R/etc/fstab"

echo "==> export kernel and initrd"
mkdir -p "$OUT"
KVER="$(chroot "$R" bash -c 'ls /lib/modules | head -1')"
case "$KVER" in
    ""|*/*)
        echo "make-rootfs: invalid kernel version: $KVER" >&2
        exit 1
        ;;
esac
echo "    kernel version: $KVER"
rm -f -- "$OUT/vmlinuz-$KVER" "$OUT/initrd.img-$KVER" "$OUT/Image-$KVER"
cp "$R/boot/vmlinuz-$KVER" "$OUT/vmlinuz-$KVER"
cp "$R/boot/initrd.img-$KVER" "$OUT/initrd.img-$KVER"

# Apple Silicon VM bootloaders need an uncompressed arm64 Image.
if file "$OUT/vmlinuz-$KVER" | grep -q 'gzip compressed'; then
    echo "    decompressing vmlinuz -> Image"
    gzip -dc "$OUT/vmlinuz-$KVER" > "$OUT/Image-$KVER"
else
    cp "$OUT/vmlinuz-$KVER" "$OUT/Image-$KVER"
fi

cleanup
trap - EXIT

echo "==> build ext4 image ($IMG_SIZE)"
rm -f -- "$OUT/rootfs.ext4"
mkfs.ext4 -q -F -L m3root -d "$R" -b 4096 "$OUT/rootfs.ext4" "$IMG_SIZE"

echo "==> done"
rm -f -- "$OUT/KVER"
echo "$KVER" > "$OUT/KVER"
ls -la "$OUT"

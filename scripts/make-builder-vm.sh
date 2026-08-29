#!/bin/bash
# Runs INSIDE a privileged debian:unstable arm64 container (image m3build:deps).
#
# Builds a self-contained Debian builder VM:
#   - rootfs.ext4  Debian sid + linux-asahi kernel + all linux-asahi build deps
#                  + a systemd unit that runs the build at boot and powers off
#   - build.ext4   a pristine linux-asahi source tree, on its own disk
#
# The VM then needs no network and no Docker.
set -euo pipefail

R="${R:-/build/vmroot}"
B="${B:-/build/vmbuild}"
OUT="${OUT:-/build/out}"
SUITE="${SUITE:-sid}"
ROOT_SIZE="${ROOT_SIZE:-14G}"
BUILD_SIZE="${BUILD_SIZE:-60G}"
JOBS="${JOBS:-8}"
PROFILES="${PROFILES:-pkg.linux.nokerneldbginfo pkg.linux.notools nodoc}"

echo "==> tooling"
export DEBIAN_FRONTEND=noninteractive
apt-get install -y --no-install-recommends debootstrap e2fsprogs >/dev/null

echo "==> debootstrap $SUITE"
rm -rf "$R"
debootstrap --arch=arm64 --variant=minbase \
  --include=systemd-sysv,udev,initramfs-tools,iproute2,kmod,ca-certificates,less,nano,time \
  "$SUITE" "$R" http://deb.debian.org/debian

echo "==> apt config in the rootfs"
install -d "$R/etc/apt/keyrings"
cp /etc/apt/keyrings/bananas-archive-keyring.gpg "$R/etc/apt/keyrings/"
cp /etc/apt/sources.list.d/bananas.sources      "$R/etc/apt/sources.list.d/"
cp /etc/apt/preferences.d/bananas.pref          "$R/etc/apt/preferences.d/"
# debootstrap writes either the old sources.list or a deb822 .sources file.
# Source packages need a deb-src entry in whichever one exists.
if [ -f "$R/etc/apt/sources.list.d/debian.sources" ]; then
    sed -i 's/^Types: deb$/Types: deb deb-src/' "$R/etc/apt/sources.list.d/debian.sources"
else
    sed -n 's/^deb \(.*\)$/deb-src \1/p' "$R/etc/apt/sources.list" >> "$R/etc/apt/sources.list"
fi
grep -h . "$R/etc/apt/sources.list" "$R/etc/apt/sources.list.d/"*.sources 2>/dev/null | head

cleanup() {
    for m in dev/pts dev sys proc; do
        mountpoint -q "$R/$m" && umount -l "$R/$m" || true
    done
}
trap cleanup EXIT
mount -t proc   proc   "$R/proc"
mount -t sysfs  sysfs  "$R/sys"
mount --bind    /dev   "$R/dev"
mount -t devpts devpts "$R/dev/pts"

echo "==> install kernel and build dependencies (this is the slow part)"
chroot "$R" apt-get update -qq
chroot "$R" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    --no-install-recommends linux-image-asahi
chroot "$R" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    --no-install-recommends build-essential fakeroot devscripts quilt dpkg-dev
chroot "$R" env DEBIAN_FRONTEND=noninteractive apt-get build-dep -y linux-asahi

echo "==> install the in-VM build job"
cat > "$R/usr/local/sbin/m3-build.sh" <<EOF
#!/bin/bash
# Runs at boot inside the builder VM. Builds linux-asahi, then powers off.
set -uo pipefail
JOBS=$JOBS
PROFILES="$PROFILES"
EOF
cat >> "$R/usr/local/sbin/m3-build.sh" <<'EOF'

mkdir -p /build
mount /dev/vdb /build || { echo "FATAL: cannot mount /dev/vdb"; poweroff -f; }
LOG=/build/build.log
exec > >(tee -a "$LOG") 2>&1

echo "=== m3 builder VM ==="
uname -a
nproc; free -g | head -2
df -h /build | tail -1

SRC=$(ls -d /build/linux-asahi-*/ 2>/dev/null | head -1)
if [ -z "$SRC" ]; then echo "FATAL: no source tree on /dev/vdb"; poweroff -f; fi
cd "$SRC"
echo "source: $SRC"
echo "profiles: $PROFILES"
echo "jobs: $JOBS"

START=$(date +%s)
env DEB_BUILD_PROFILES="$PROFILES" DEB_BUILD_OPTIONS="parallel=$JOBS" \
    dpkg-buildpackage -b -uc -us
RC=$?
END=$(date +%s)

echo "=== BUILD EXIT: $RC ==="
echo "=== ELAPSED: $((END-START))s ==="
echo "=== ARTIFACTS ==="
ls -la /build/*.deb 2>/dev/null | tail -30
ls /build/*.deb 2>/dev/null | wc -l | sed 's/^/deb count: /'
echo "$RC" > /build/BUILD_RC
sync
echo "=== M3BUILD DONE ==="
# Unmount before the forced poweroff, otherwise the journal is left dirty and
# the host cannot mount the build disk read-only afterwards.
cd /
exec > /dev/console 2>&1
umount /build || umount -l /build
sync
poweroff -f
EOF
chmod +x "$R/usr/local/sbin/m3-build.sh"

cat > "$R/etc/systemd/system/m3-build.service" <<'EOF'
[Unit]
Description=linux-asahi package build
After=local-fs.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/m3-build.sh
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=infinity
[Install]
WantedBy=multi-user.target
EOF
chroot "$R" systemctl enable m3-build.service

echo "==> console login (for the interactive case)"
chroot "$R" bash -c 'echo "root:root" | chpasswd'
echo "m3builder" > "$R/etc/hostname"
install -d "$R/etc/systemd/system/serial-getty@ttyAMA0.service.d"
printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin root --noclear %%I 115200 linux\n' \
  > "$R/etc/systemd/system/serial-getty@ttyAMA0.service.d/autologin.conf"
printf '/dev/vda / ext4 defaults 0 1\n' > "$R/etc/fstab"

echo "==> export kernel and initrd"
mkdir -p "$OUT"
KVER="$(chroot "$R" bash -c 'ls /lib/modules | head -1')"
cp "$R/boot/vmlinuz-$KVER"   "$OUT/vmlinuz-$KVER"
cp "$R/boot/initrd.img-$KVER" "$OUT/initrd.img-$KVER"
if file "$OUT/vmlinuz-$KVER" | grep -q 'gzip compressed'; then
    gzip -dc "$OUT/vmlinuz-$KVER" > "$OUT/Image-$KVER"
else
    cp "$OUT/vmlinuz-$KVER" "$OUT/Image-$KVER"
fi
echo "$KVER" > "$OUT/KVER"

cleanup
trap - EXIT

echo "==> stage a pristine source tree for the build disk"
rm -rf "$B"; mkdir -p "$B"
cd "$B"
dpkg-source -x /build/linux-asahi_7.1.10-1-1.dsc >/dev/null
ls -d "$B"/linux-asahi-*/

echo "==> build the two disk images"
rm -f "$OUT/vmroot.ext4" "$OUT/build.ext4"
mkfs.ext4 -q -F -L m3root  -d "$R" -b 4096 "$OUT/vmroot.ext4" "$ROOT_SIZE"
mkfs.ext4 -q -F -L m3build -d "$B" -b 4096 "$OUT/build.ext4"  "$BUILD_SIZE"

echo "==> done"
du -h --apparent-size "$OUT"/*.ext4 | sed 's/^/apparent  /'
du -h "$OUT"/*.ext4 | sed 's/^/actual    /'

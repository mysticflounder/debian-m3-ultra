#!/bin/bash
# Acceptance checks inside the new portable VM, never the build helper.
set -euo pipefail
case "${1:-}" in record|verify) ;; *) echo 'usage: check-portable-root-guest.sh record|verify' >&2; exit 2;; esac
test -d /sys/firmware/efi
test "$(findmnt -n -o SOURCE /)" = /dev/vda2
test "$(findmnt -n -o SOURCE /boot/efi)" = /dev/vda1
test "$(hostname)" = debian-portable
test -f /boot/efi/EFI/BOOT/BOOTAA64.EFI
test -s /root/.ssh/authorized_keys
ssh_config="$(sshd -T)"
grep -qix 'passwordauthentication no' <<< "$ssh_config"
grep -qix 'kbdinteractiveauthentication no' <<< "$ssh_config"
grep -qixE 'permitrootlogin (without-password|prohibit-password)' <<< "$ssh_config"
timeout 20 getent ahosts deb.debian.org >/dev/null
curl --fail --silent --show-error --max-time 30 --output /dev/null https://deb.debian.org/debian/README
state=/var/lib/debian-portable-validation
if [ "$1" = record ]; then
    test ! -e "$state"
    install -d -m 0700 "$state"
    cat /proc/sys/kernel/random/boot_id > "$state/first-boot-id"
    cp /etc/machine-id "$state/machine-id"
    ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub > "$state/ssh-fingerprint"
    printf 'persistent-root-uefi-validation\n' > "$state/marker"
    sync
else
    grep -qx persistent-root-uefi-validation "$state/marker"
    test "$(cat /proc/sys/kernel/random/boot_id)" != "$(cat "$state/first-boot-id")"
    cmp /etc/machine-id "$state/machine-id"
    test "$(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub)" = "$(cat "$state/ssh-fingerprint")"
fi
echo "PASS: $1 UEFI, root/EFI mounts, key-only SSH, DNS, HTTPS, identity/persistence"
uname -r
cat /proc/cmdline
lsblk -b -o NAME,SIZE,FSTYPE,UUID
df -B1 / /boot/efi
ip -br address
systemctl --failed --no-legend

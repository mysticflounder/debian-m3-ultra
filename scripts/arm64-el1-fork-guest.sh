#!/bin/bash
# Injected into a disposable guest; never executed on the host.
set -euo pipefail
[ "$#" = 2 ] || exit 2
smp=$1; token=$2
case "$smp" in 1|8|16|24|32) ;; *) exit 2;; esac
case "$token" in ''|*[!A-Za-z0-9-]*) exit 2;; esac
guest_fail() {
    rc=$?
    echo "EL1_FORK_GUEST_ERROR token=$token rc=$rc"
    trap - EXIT
    poweroff -f
    exit "$rc"
}
trap guest_fail EXIT
[ "$(id -u)" = 0 ]
[ "$(getconf _NPROCESSORS_ONLN)" = "$smp" ]
mkdir -p /mnt/el1-build /mnt/el1-source
mount -o ro,noload /dev/vdb /mnt/el1-build
mount -o ro /dev/vdc1 /mnt/el1-source
[ "$(blockdev --getro /dev/vdb)" = 1 ]
[ "$(blockdev --getro /dev/vdc)" = 1 ]
findmnt -n -o OPTIONS /mnt/el1-build | grep -qw ro
findmnt -n -o OPTIONS /mnt/el1-source | grep -qw ro
work="$(mktemp -d /root/arm64-el1-fork.XXXXXX)"
cp /mnt/el1-source/arm64-el1-probe.c "$work/"
cp /mnt/el1-source/arm64-el1-probe.Makefile "$work/Makefile"
kernel_source="$(find /mnt/el1-build -maxdepth 2 -type d -name 'linux-asahi-*' -print -quit)"
[ -n "$kernel_source" ]
if [ -d "$kernel_source/debian/build/source_none" ]; then kernel_source="$kernel_source/debian/build/source_none"; fi
kernel_build="$work/kbuild"
mkdir -p "$kernel_build"
cp "/boot/config-$(uname -r)" "$kernel_build/.config"
"$kernel_source/scripts/config" --file "$kernel_build/.config" -d MODULE_SIG_ALL -d MODULE_SIG_FORCE
make -s -C "$kernel_source" O="$kernel_build" KERNELRELEASE="$(uname -r)" olddefconfig modules_prepare
make -s -C "$kernel_source" O="$kernel_build" M="$work" KERNELRELEASE="$(uname -r)" KBUILD_MODPOST_WARN=1 modules
test -s "$work/arm64-el1-probe.ko"
printf '\nEL1_FORK_READY token=%s smp=%s\n' "$token" "$smp"
IFS= read -r command
[ "$command" = "GO $token" ]
# Suppress unsolicited console duplicates; emit exact kernel records once.
dmesg -n 1
dmesg -C
insmod "$work/arm64-el1-probe.ko"
rmmod arm64_el1_probe
dmesg > "$work/kernel.log"
printf '\nEL1_FORK_BEGIN token=%s\n' "$token"
awk 'match($0, /EL1_PROBE_/) {print substr($0,RSTART)}' "$work/kernel.log"
printf 'EL1_FORK_END token=%s\n' "$token"
umount /mnt/el1-source
umount /mnt/el1-build
printf 'EL1_FORK_COMPLETE token=%s smp=%s\n' "$token" "$smp"
IFS= read -r command
[ "$command" = POWEROFF ]
trap - EXIT
poweroff -f

#!/bin/bash
# Run scripts/bench.c inside the builder VM and print the result.
# Inject the source first:
#   docker run --rm --privileged --platform linux/arm64 \
#     -v "$PWD/out:/out" -v "$PWD/scripts:/scripts:ro" m3build:deps \
#     bash -c 'mkdir -p /mnt/b && mount -o loop /out/build.ext4 /mnt/b &&
#              cp /scripts/bench.c /mnt/b/ && sync && umount /mnt/b'
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/out"
KVER="$(cat "$OUT/KVER")"
QEMU="${QEMU:-/opt/homebrew/bin/qemu-system-aarch64}"
SMP="${SMP:-8}"
MEM="${MEM:-32G}"
LOG="$OUT/bench.log"

if pgrep -f "qemu-system-aarch64.*vmroot.ext4" >/dev/null; then
    echo "a VM already holds the disk lock; stop it first" >&2; exit 1
fi

GUEST='
mount /dev/vdb /build 2>/dev/null || { mkdir -p /build && mount /dev/vdb /build; }
cd /build
echo "=== BENCH START ==="
gcc --version | head -1
nproc | sed "s/^/nproc: /"
grep -m1 "CPU implementer" /proc/cpuinfo
grep -m1 "CPU part" /proc/cpuinfo
dmesg | grep -m1 -i "TSO memory model" || echo "(no Apple TSO line)"
gcc -O2 -pthread -o /tmp/bench bench.c && echo "guest build ok"
/tmp/bench 1
/tmp/bench 8
echo "=== BENCH END ==="
sync; umount /build; poweroff -f
'

( sleep 30; printf '%s\n' "$GUEST" ) | "$QEMU" \
  -M virt,highmem=on -accel hvf -cpu host -smp "$SMP" -m "$MEM" \
  -kernel "$OUT/Image-$KVER" -initrd "$OUT/initrd.img-$KVER" \
  -append "root=/dev/vda rootfstype=ext4 rw console=ttyAMA0 systemd.unit=multi-user.target systemd.mask=m3-build.service" \
  -drive "if=virtio,file=$OUT/vmroot.ext4,format=raw" \
  -drive "if=virtio,file=$OUT/build.ext4,format=raw" \
  -nographic > "$LOG" 2>&1 &
QPID=$!

for _ in $(seq 1 300); do
    grep -aq "BENCH END" "$LOG" 2>/dev/null && break
    kill -0 "$QPID" 2>/dev/null || break
    sleep 1
done
sleep 3
kill "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true

tr -d '\r' < "$LOG" | sed -n '/=== BENCH START ===/,/=== BENCH END ===/p' \
  | sed -e 's/\x1b\][0-9;]*;[^\x07\x1b]*\(\x07\|\x1b\\\)//g' -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' \
  | grep -vE '^root@|^$'

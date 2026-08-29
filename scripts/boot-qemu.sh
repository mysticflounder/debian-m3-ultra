#!/bin/bash
# Boot the Debian linux-asahi kernel in QEMU on macOS with HVF acceleration.
#   ./scripts/boot-qemu.sh            interactive (Ctrl-A X to quit)
#   ./scripts/boot-qemu.sh --auto     run a probe script, log to out/boot.log, power off
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/out"
KVER="$(cat "$OUT/KVER")"
QEMU="${QEMU:-/opt/homebrew/bin/qemu-system-aarch64}"
SMP="${SMP:-8}"
MEM="${MEM:-8G}"

ARGS=(
  -M virt,highmem=on
  -accel hvf
  -cpu host
  -smp "$SMP"
  -m "$MEM"
  -kernel "$OUT/Image-$KVER"
  -initrd "$OUT/initrd.img-$KVER"
  -append "root=/dev/vda rootfstype=ext4 rw console=ttyAMA0"
  -drive "if=virtio,file=$OUT/rootfs.ext4,format=raw"
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0
  -nographic
)

if [ "${1:-}" != "--auto" ]; then
    exec "$QEMU" "${ARGS[@]}"
fi

LOG="$OUT/boot.log"
PROBE='
echo "=== PROBE START ==="
uname -a
cat /etc/debian_version
echo "--- apple platform modules shipped by this kernel ---"
find /lib/modules/$(uname -r)/kernel/drivers -path "*apple*" -name "*.ko*" | sed "s#.*/##" | sort | head -30
echo "--- apple drivers that actually bound to hardware ---"
ls /sys/bus/platform/drivers/ | grep -i apple || echo "(none - no Apple hardware in this VM)"
echo "--- what the kernel found instead ---"
ls /sys/bus/ ; cat /sys/firmware/devicetree/base/compatible 2>/dev/null | tr "\0" "\n"
echo "--- asahi/apple lines in dmesg ---"
dmesg | grep -icE "apple|asahi" | sed "s/^/matches: /"
echo "=== PROBE END ==="
poweroff
'

( sleep 35; printf '%s\n' "$PROBE" ) | "$QEMU" "${ARGS[@]}" > "$LOG" 2>&1 &
QPID=$!

for _ in $(seq 1 120); do
    kill -0 "$QPID" 2>/dev/null || break
    grep -q "PROBE END" "$LOG" 2>/dev/null && break
    sleep 1
done
sleep 3
kill -0 "$QPID" 2>/dev/null && kill "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true

echo "log: $LOG ($(wc -l < "$LOG") lines)"

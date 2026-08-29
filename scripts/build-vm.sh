#!/bin/bash
# Boot the builder VM. It runs dpkg-buildpackage on linux-asahi at boot,
# writes the .debs to the build disk, then powers off.
#   ./scripts/build-vm.sh              run the build, log to out/vmbuild.log
#   ./scripts/build-vm.sh --shell      boot to a root shell instead
#   ./scripts/build-vm.sh --peek       shell on a throwaway copy, safe while a build runs
#   ./scripts/build-vm.sh --log        follow the live console of a running build
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/out"
KVER="$(cat "$OUT/KVER")"
QEMU="${QEMU:-/opt/homebrew/bin/qemu-system-aarch64}"
SMP="${SMP:-8}"
MEM="${MEM:-32G}"
LOG="${LOG:-$OUT/vmbuild.log}"

MODE="${1:-}"

running_pid() { pgrep -f "qemu-system-aarch64.*vmroot.ext4" | head -1; }

if [ "$MODE" = "--log" ]; then
    exec tail -f "$LOG"
fi

# QEMU takes a write lock on each image. A second VM on the same disks would
# corrupt them, so refuse early with a useful message instead of a lock error.
if [ "$MODE" != "--peek" ] && [ -n "$(running_pid)" ]; then
    cat >&2 <<EOF
A builder VM is already running (pid $(running_pid)) and holds the disk lock.

  ./scripts/build-vm.sh --log     follow its console
  ./scripts/build-vm.sh --peek    shell on a throwaway copy of the disks
  kill $(running_pid)             stop it

EOF
    exit 1
fi

APPEND="root=/dev/vda rootfstype=ext4 rw console=ttyAMA0"
NOBUILD="systemd.unit=multi-user.target systemd.mask=m3-build.service"
case "$MODE" in
    --shell) APPEND="$APPEND $NOBUILD" ;;
    --peek)  APPEND="$APPEND $NOBUILD" ;;
esac

ARGS=(
  -M virt,highmem=on -accel hvf -cpu host
  -smp "$SMP" -m "$MEM"
  -kernel "$OUT/Image-$KVER"
  -initrd "$OUT/initrd.img-$KVER"
  -append "$APPEND"
  -drive "if=virtio,file=$OUT/vmroot.ext4,format=raw"
  -drive "if=virtio,file=$OUT/build.ext4,format=raw"
  -nographic
)

if [ "$MODE" = "--peek" ]; then
    # -snapshot sends every write to a throwaway overlay, so the running build's
    # disks are never touched. Reads of a live filesystem can still be stale or
    # inconsistent: treat what you see as a hint, not as fact.
    echo "peek mode: writes are discarded; the live filesystem may look inconsistent"
    exec "$QEMU" "${ARGS[@]}" -snapshot
fi

if [ "$MODE" = "--shell" ]; then
    exec "$QEMU" "${ARGS[@]}"
fi

# Keep the previous console log. A rerun used to truncate a finished build's log.
if [ -s "$LOG" ]; then
    mv "$LOG" "$LOG.$(date +%Y%m%d-%H%M%S)"
fi

echo "booting builder VM: ${SMP} cpus, ${MEM} ram -> $LOG"
"$QEMU" "${ARGS[@]}" > "$LOG" 2>&1
echo "qemu exited"
# The console prefixes every line with a kernel timestamp and the unit name,
# so the markers are never at the start of a line.
tr -d '\r' < "$LOG" \
  | sed -e 's/^\[[^]]*\] m3-build.sh\[[0-9]*\]: //' \
  | grep -aE '^=== (BUILD EXIT|ELAPSED|M3BUILD DONE)|^deb count:' \
  || echo "no completion marker in $LOG"

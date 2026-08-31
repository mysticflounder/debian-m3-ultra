#!/bin/bash
# Boot the existing builder VM on a throwaway overlay, compile the guest CPU
# probe from a read-only vvfat share, and extract its JSON result.
#
#   ./scripts/cpu-probe-vm.sh
#
# Environment: QEMU, SMP (default 8), MEM (default 8G), LOG, JSON_OUT.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/out"
KVER="$(cat "$OUT/KVER")"
QEMU="${QEMU:-/opt/homebrew/bin/qemu-system-aarch64}"
SMP="${SMP:-8}"
MEM="${MEM:-8G}"
LOG="${LOG:-$OUT/cpu-probe.log}"
JSON_OUT="${JSON_OUT:-$OUT/cpu-probe-guest.json}"
SOURCE="$HERE/scripts/arm64-guest-cpu.c"

for required in \
    "$OUT/Image-$KVER" \
    "$OUT/initrd.img-$KVER" \
    "$OUT/vmroot.ext4" \
    "$SOURCE"; do
    if [ ! -r "$required" ]; then
        echo "missing required input: $required" >&2
        exit 1
    fi
done

running_pid() {
    local pid

    pid="$(pgrep -f "qemu-system-aarch64.*vmroot.ext4" 2>/dev/null | head -1 || true)"
    if [ -n "$pid" ]; then
        printf '%s\n' "$pid"
        return
    fi

    # -ww is required on macOS; otherwise the image path can be truncated.
    ps ax -ww -o pid=,command= 2>/dev/null \
        | awk '/qemu-system-aarch64/ && /vmroot\.ext4/ { print $1; exit }' \
        || true
}

VM_PID="$(running_pid)"
if [ -n "$VM_PID" ]; then
    echo "VM pid $VM_PID already uses vmroot.ext4; stop it before collecting evidence" >&2
    exit 1
fi

mkdir -p "$OUT"

GUEST='
mkdir -p /mnt/cpu-probe
if ! mount -o ro /dev/vdb /mnt/cpu-probe; then
    echo "cpu probe: failed to mount read-only source drive" >&2
    poweroff -f
    exit 1
fi
if ! gcc -O2 -Wall -Wextra -Werror -std=gnu11 \
    -o /tmp/arm64-guest-cpu /mnt/cpu-probe/arm64-guest-cpu.c; then
    echo "cpu probe: guest compilation failed" >&2
    poweroff -f
    exit 1
fi
START_MARKER="$(printf "=== CPU PROBE JSON %s ===" START)"
END_MARKER="$(printf "=== CPU PROBE JSON %s ===" END)"
stty -echo
printf "%s\n" "$START_MARKER"
/tmp/arm64-guest-cpu
printf "%s\n" "$END_MARKER"
stty echo
umount /mnt/cpu-probe
poweroff -f
'

ARGS=(
    -M virt,highmem=on
    -accel hvf
    -cpu host
    -smp "$SMP"
    -m "$MEM"
    -kernel "$OUT/Image-$KVER"
    -initrd "$OUT/initrd.img-$KVER"
    -append "root=/dev/vda rootfstype=ext4 rw console=ttyAMA0 systemd.unit=multi-user.target systemd.mask=m3-build.service"
    -drive "if=virtio,file=$OUT/vmroot.ext4,format=raw"
    -drive "if=virtio,file=fat:ro:$HERE/scripts,format=raw"
    -snapshot
    -nographic
)

echo "booting read-only CPU probe VM: ${SMP} vCPUs, ${MEM} RAM -> $LOG"
( sleep 30; printf '%s\n' "$GUEST" ) | "$QEMU" "${ARGS[@]}" > "$LOG" 2>&1 &
QPID=$!

cleanup() {
    if kill -0 "$QPID" 2>/dev/null; then
        kill "$QPID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

for _ in $(seq 1 300); do
    grep -aq "CPU PROBE JSON END" "$LOG" 2>/dev/null && break
    kill -0 "$QPID" 2>/dev/null || break
    sleep 1
done

if kill -0 "$QPID" 2>/dev/null; then
    sleep 3
    cleanup
fi
wait "$QPID" 2>/dev/null || true
trap - EXIT

CONSOLE="$OUT/.cpu-probe-console.$$"
JSON_TMP="$OUT/.cpu-probe-json.$$"
cleanup_files() {
    rm -f "$CONSOLE" "$JSON_TMP"
}
trap cleanup_files EXIT

tr -d '\r' < "$LOG" \
    | sed -e 's/\x1b\][0-9;]*;[^\x07\x1b]*\(\x07\|\x1b\\\)//g' \
          -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' \
    > "$CONSOLE"

awk '
    /=== CPU PROBE JSON START ===/ {
        capture = 1
        count = 0
        delete lines
        next
    }
    /=== CPU PROBE JSON END ===/ && capture {
        for (i = 1; i <= count; i++) {
            print lines[i]
        }
        exit
    }
    capture {
        lines[++count] = $0
    }
' "$CONSOLE" > "$JSON_TMP"

if ! jq -e '
    type == "object" and
    .schema_version == 1 and
    (.registers | type == "object")
' "$JSON_TMP" >/dev/null; then
    echo "guest probe did not produce valid JSON; inspect $LOG" >&2
    exit 1
fi

mv "$JSON_TMP" "$JSON_OUT"
echo "guest CPU fingerprint: $JSON_OUT"
echo "console log: $LOG"

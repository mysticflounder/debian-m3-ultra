#!/bin/bash
# Build and run the raw EL1 CPU-register collector inside an isolated QEMU
# guest. Every guest write lands in an explicit disposable qcow2 overlay.
# The host base images and the read-only source share are never passed writable.
#
#   SMP=8 ./scripts/el1-probe-vm.sh
#
# Environment: SMP (default 8), MEM (default 8G).
set -euo pipefail
umask 077

HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
OUT="$HERE/out"
QEMU="/opt/homebrew/bin/qemu-system-aarch64"
QEMU_IMG="/opt/homebrew/bin/qemu-img"
TIMEOUT="/opt/homebrew/bin/gtimeout"
SMP="${SMP:-8}"
MEM="${MEM:-8G}"
KVER_FILE="$OUT/KVER"
ROOTFS="$OUT/vmroot.ext4"
BUILD_DISK="$OUT/build.ext4"
MODULE_SOURCE="$HERE/scripts/arm64-el1-probe.c"
MODULE_MAKEFILE="$HERE/scripts/arm64-el1-probe.Makefile"
LOCK_DIR="$OUT/.vmroot.ext4.probe.lock"

RUN_DIR=""
ROOT_OVERLAY=""
SERIAL_FIFO=""
QPID=""
FEED_PID=""
LOCK_ACQUIRED=false
LOCK_OWNER=""
LOCK_TOKEN=""
HASHES_READY=false
INPUTS_VERIFIED=false

release_lock() {
    local observed_token=""

    if [ "$LOCK_ACQUIRED" = true ] && [ -n "$LOCK_OWNER" ] &&
       [ -f "$LOCK_OWNER" ]; then
        IFS= read -r observed_token < "$LOCK_OWNER" || true
        if [ "$observed_token" = "$LOCK_TOKEN" ]; then
            rm -f -- "$LOCK_OWNER"
            rmdir "$LOCK_DIR" 2>/dev/null || true
        fi
    fi
    LOCK_ACQUIRED=false
}

verify_protected_inputs() {
    KERNEL_SHA256_AFTER="$(sha256_file "$KERNEL")"
    INITRD_SHA256_AFTER="$(sha256_file "$INITRD")"
    ROOTFS_SHA256_AFTER="$(sha256_file "$ROOTFS")"
    BUILD_STATE_AFTER="$(file_state "$BUILD_DISK")"
    SOURCE_SHA256_AFTER="$(sha256_file "$MODULE_SOURCE")"
    MAKEFILE_SHA256_AFTER="$(sha256_file "$MODULE_MAKEFILE")"

    [ "$KERNEL_SHA256_BEFORE" = "$KERNEL_SHA256_AFTER" ] &&
        [ "$INITRD_SHA256_BEFORE" = "$INITRD_SHA256_AFTER" ] &&
        [ "$ROOTFS_SHA256_BEFORE" = "$ROOTFS_SHA256_AFTER" ] &&
        [ "$BUILD_STATE_BEFORE" = "$BUILD_STATE_AFTER" ] &&
        [ "$SOURCE_SHA256_BEFORE" = "$SOURCE_SHA256_AFTER" ] &&
        [ "$MAKEFILE_SHA256_BEFORE" = "$MAKEFILE_SHA256_AFTER" ]
}

cleanup() {
    local cleanup_status=$?

    if [ -n "$FEED_PID" ] && kill -0 "$FEED_PID" 2>/dev/null; then
        kill "$FEED_PID" 2>/dev/null || true
        wait "$FEED_PID" 2>/dev/null || true
    fi
    if [ -n "$QPID" ] && kill -0 "$QPID" 2>/dev/null; then
        kill "$QPID" 2>/dev/null || true
        wait "$QPID" 2>/dev/null || true
    fi
    exec 9>&- 9<&- 2>/dev/null || true
    if [ -n "$SERIAL_FIFO" ] && [ -p "$SERIAL_FIFO" ]; then
        rm -f -- "$SERIAL_FIFO"
    fi
    if [ -n "$ROOT_OVERLAY" ] && [ -f "$ROOT_OVERLAY" ]; then
        rm -f -- "$ROOT_OVERLAY"
    fi
    if [ "$HASHES_READY" = true ] && [ "$INPUTS_VERIFIED" = false ]; then
        if verify_protected_inputs; then
            INPUTS_VERIFIED=true
        else
            echo "EL1 probe: a protected input changed during cleanup" >&2
            cleanup_status=1
        fi
    fi
    release_lock
    return "$cleanup_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

fail() {
    echo "EL1 probe: $*" >&2
    exit 1
}

sha256_file() {
    local digest remainder

    IFS=' ' read -r digest remainder < <(shasum -a 256 "$1")
    case "$digest" in
        ''|*[!0-9a-f]*) return 1 ;;
    esac
    [ "${#digest}" -eq 64 ] || return 1
    printf '%s\n' "$digest"
}

file_size() {
    stat -f '%z' "$1"
}

file_state() {
    stat -f '%d:%i:%z:%m:%c' "$1"
}

require_safe_input() {
    local input=$1
    local links

    if [ -L "$input" ] || [ ! -f "$input" ] || [ ! -r "$input" ]; then
        fail "required input must be a readable regular non-symlink file: $input"
    fi
    links="$(stat -f '%l' "$input")"
    [ "$links" -eq 1 ] || fail "required input is multiply linked: $input"
}

case "$SMP" in
    ''|*[!0-9]*|0|0*) fail "SMP must be a positive canonical integer: $SMP" ;;
esac
[ "$SMP" -le 64 ] || fail "SMP exceeds the 64-vCPU safety limit: $SMP"

case "$MEM" in
    *G)
        MEM_VALUE="${MEM%G}"
        case "$MEM_VALUE" in ''|*[!0-9]*|0|0*) fail "invalid MEM value: $MEM" ;; esac
        [ "$MEM_VALUE" -le 64 ] || fail "MEM exceeds the 64G safety limit: $MEM"
        ;;
    *M)
        MEM_VALUE="${MEM%M}"
        case "$MEM_VALUE" in ''|*[!0-9]*|0|0*) fail "invalid MEM value: $MEM" ;; esac
        [ "$MEM_VALUE" -le 65536 ] || fail "MEM exceeds the 64G safety limit: $MEM"
        ;;
    *) fail "MEM must be an integer number of M or G: $MEM" ;;
esac

[ "$(id -u)" -ne 0 ] || fail "refusing to run QEMU as host root"
HOST_UID="$(id -u)"
if [ -L "$OUT" ]; then
    fail "refusing symlinked output root: $OUT"
fi
mkdir -p "$OUT"
[ "$(cd "$OUT" && pwd -P)" = "$OUT" ] || fail "output root is not canonical: $OUT"

for tool in "$QEMU" "$QEMU_IMG" "$TIMEOUT"; do
    [ -x "$tool" ] || fail "missing pinned executable: $tool"
    [ ! -u "$tool" ] && [ ! -g "$tool" ] || fail "refusing setuid/setgid executable: $tool"
done
QEMU_REAL="$(realpath "$QEMU")"
QEMU_IMG_REAL="$(realpath "$QEMU_IMG")"
TIMEOUT_REAL="$(realpath "$TIMEOUT")"
for tool in "$QEMU_REAL" "$QEMU_IMG_REAL" "$TIMEOUT_REAL"; do
    [ -f "$tool" ] && [ -x "$tool" ] || fail "pinned executable resolves unsafely: $tool"
done

require_safe_input "$KVER_FILE"
KVER="$(cat "$KVER_FILE")"
case "$KVER" in
    ''|.|..|*/*|*[!A-Za-z0-9.+_~-]*) fail "KVER contains unsafe characters: $KVER" ;;
esac
KERNEL="$OUT/Image-$KVER"
INITRD="$OUT/initrd.img-$KVER"
for input in \
    "$KERNEL" \
    "$INITRD" \
    "$ROOTFS" \
    "$BUILD_DISK" \
    "$MODULE_SOURCE" \
    "$MODULE_MAKEFILE"; do
    require_safe_input "$input"
done

QEMU_VERSION="$($QEMU --version | head -1)"
case "$QEMU_VERSION" in
    'QEMU emulator version 11.1.1'*) ;;
    *) fail "expected pinned QEMU 11.1.1, got: $QEMU_VERSION" ;;
esac

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    fail "another EL1 probe owns $LOCK_DIR; inspect it rather than deleting it blindly"
fi
LOCK_ACQUIRED=true
LOCK_TOKEN="$$:$(date +%s):$RANDOM"
LOCK_OWNER="$LOCK_DIR/owner.$$"
printf '%s\n' "$LOCK_TOKEN" > "$LOCK_OWNER"
if command -v lsof >/dev/null 2>&1; then
    OPENERS="$(lsof -t -- "$ROOTFS" 2>/dev/null || true)"
    [ -z "$OPENERS" ] || fail "vmroot.ext4 is already open by pid(s): $OPENERS"
fi

RUN_DIR="$(mktemp -d "$OUT/el1-probe-smp${SMP}.XXXXXX")"
chmod 700 "$RUN_DIR"
LOG="$RUN_DIR/serial.log"
CONSOLE="$RUN_DIR/console.txt"
MARKERS="$RUN_DIR/markers.txt"
RAW_JSON="$RUN_DIR/raw.json"
FINAL_JSON="$RUN_DIR/evidence.json"
FINAL_TMP="$(mktemp "$RUN_DIR/.evidence.XXXXXX")"
ROOT_OVERLAY="$RUN_DIR/root.qcow2"
SERIAL_FIFO="$RUN_DIR/serial.in"
: > "$LOG"
: > "$CONSOLE"
: > "$MARKERS"
: > "$RAW_JSON"
mkfifo -m 600 "$SERIAL_FIFO"
# Bound both the serial log and disposable overlay even if the guest misbehaves.
ulimit -f 1048576

echo "hashing protected inputs before launch"
KERNEL_SHA256_BEFORE="$(sha256_file "$KERNEL")"
INITRD_SHA256_BEFORE="$(sha256_file "$INITRD")"
ROOTFS_SHA256_BEFORE="$(sha256_file "$ROOTFS")"
BUILD_STATE_BEFORE="$(file_state "$BUILD_DISK")"
SOURCE_SHA256_BEFORE="$(sha256_file "$MODULE_SOURCE")"
MAKEFILE_SHA256_BEFORE="$(sha256_file "$MODULE_MAKEFILE")"
QEMU_SHA256="$(sha256_file "$QEMU_REAL")"
QEMU_IMG_SHA256="$(sha256_file "$QEMU_IMG_REAL")"
HASHES_READY=true

"$QEMU_IMG" create -q -f qcow2 -F raw -b "$ROOTFS" "$ROOT_OVERLAY"
chmod 600 "$ROOT_OVERLAY"

GUEST=$(cat <<'GUEST_EOF'
set -eu
WORK=""
guest_cleanup() {
    rc=$?
    set +e
    if [ "$rc" -ne 0 ]; then
        echo "EL1_GUEST_ERROR rc=$rc"
    fi
    rmmod arm64_el1_probe 2>/dev/null || true
    umount /mnt/el1-source 2>/dev/null || true
    umount /mnt/el1-build 2>/dev/null || true
    trap - EXIT
    poweroff -f
}
trap guest_cleanup EXIT

mkdir -p /mnt/el1-build /mnt/el1-source
mount -o ro,noload /dev/vdb /mnt/el1-build
mount -o ro /dev/vdc1 /mnt/el1-source
[ "$(blockdev --getro /dev/vdb)" = 1 ]
[ "$(blockdev --getro /dev/vdc)" = 1 ]
findmnt -n -o OPTIONS /mnt/el1-build | grep -qw ro
findmnt -n -o OPTIONS /mnt/el1-source | grep -qw ro
if touch /mnt/el1-source/.el1-write-must-fail 2>/dev/null; then
    echo "EL1_GUEST_ERROR source_write_succeeded"
    exit 1
fi

WORK="$(mktemp -d /tmp/arm64-el1-probe.XXXXXX)"
cp /mnt/el1-source/arm64-el1-probe.c "$WORK/"
cp /mnt/el1-source/arm64-el1-probe.Makefile "$WORK/Makefile"
KERNEL_SOURCE="$(find /mnt/el1-build -maxdepth 2 -type d -name 'linux-asahi-*' -print -quit)"
[ -n "$KERNEL_SOURCE" ]
if [ -d "$KERNEL_SOURCE/debian/build/source_none" ]; then
    KERNEL_SOURCE="$KERNEL_SOURCE/debian/build/source_none"
fi
KERNEL_BUILD="$WORK/kbuild"
mkdir -p "$KERNEL_BUILD"
cp "/boot/config-$(uname -r)" "$KERNEL_BUILD/.config"
for required in \
    "$KERNEL_SOURCE/Makefile" \
    "$KERNEL_SOURCE/scripts/config" \
    "$KERNEL_BUILD/.config"; do
    [ -r "$required" ]
done

echo "EL1_GUEST_BUILD source=$KERNEL_SOURCE output=$KERNEL_BUILD"
"$KERNEL_SOURCE/scripts/config" --file "$KERNEL_BUILD/.config" \
    -d MODULE_SIG_ALL -d MODULE_SIG_FORCE
make -s -C "$KERNEL_SOURCE" O="$KERNEL_BUILD" \
    KERNELRELEASE="$(uname -r)" olddefconfig modules_prepare
make -s -C "$KERNEL_SOURCE" O="$KERNEL_BUILD" M="$WORK" \
    KERNELRELEASE="$(uname -r)" KBUILD_MODPOST_WARN=1 modules
test -s "$WORK/arm64-el1-probe.ko"
modinfo -F vermagic "$WORK/arm64-el1-probe.ko"
dmesg -n 8
insmod "$WORK/arm64-el1-probe.ko"
rmmod arm64_el1_probe
echo "EL1_GUEST_COMPLETE"
umount /mnt/el1-source
umount /mnt/el1-build
trap - EXIT
poweroff -f
GUEST_EOF
)

ARGS=(
    -M virt,highmem=on
    -accel hvf
    -cpu host
    -smp "$SMP,sockets=1,cores=$SMP,threads=1"
    -m "$MEM"
    -kernel "$KERNEL"
    -initrd "$INITRD"
    -append "root=/dev/vda rootfstype=ext4 rw console=ttyAMA0 systemd.unit=multi-user.target systemd.mask=m3-build.service"
    -drive "if=virtio,file=$ROOT_OVERLAY,format=qcow2,cache=none"
    -drive "if=virtio,file=$BUILD_DISK,format=raw,readonly=on,cache=none"
    -drive "if=virtio,file=fat:ro:$HERE/scripts,format=raw,readonly=on"
    -nic none
    -display none
    -monitor none
    -serial stdio
    -no-reboot
)
QEMU_ARGV_JSON="$(jq -n --args '$ARGS.positional' -- "$QEMU" "${ARGS[@]}")"

exec 9<> "$SERIAL_FIFO"
echo "booting isolated EL1 probe: ${SMP} vCPUs, ${MEM} RAM -> $RUN_DIR"
(
    sleep 30
    printf 'stty -echo\n' >&9
    sleep 1
    printf '%s\n' "$GUEST" >&9
) &
FEED_PID=$!

set +e
env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin \
    TMPDIR="$RUN_DIR" \
    HOME="$RUN_DIR" \
    "$TIMEOUT" --signal=TERM --kill-after=10 300 \
    "$QEMU" "${ARGS[@]}" <&9 > "$LOG" 2>&1 &
QPID=$!
wait "$QPID"
QEMU_STATUS=$?
set -e
QPID=""
if kill -0 "$FEED_PID" 2>/dev/null; then
    kill "$FEED_PID" 2>/dev/null || true
fi
wait "$FEED_PID" 2>/dev/null || true
FEED_PID=""
exec 9>&- 9<&-
rm -f -- "$SERIAL_FIFO"
SERIAL_FIFO=""

rm -f -- "$ROOT_OVERLAY"
ROOT_OVERLAY=""
[ ! -e "$RUN_DIR/root.qcow2" ] || fail "disposable overlay still exists after removal"

echo "verifying protected inputs after shutdown"
verify_protected_inputs || fail "a protected input changed during the EL1 probe"
INPUTS_VERIFIED=true

if [ "$QEMU_STATUS" -eq 124 ]; then
    fail "QEMU timed out after 300 seconds; inspect $LOG"
fi
if [ "$QEMU_STATUS" -ne 0 ]; then
    fail "QEMU exited with status $QEMU_STATUS; inspect $LOG"
fi
tr -d '\r' < "$LOG" \
    | sed -e 's/\x1b\][0-9;]*;[^\x07\x1b]*\(\x07\|\x1b\\\)//g' \
          -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' \
    > "$CONSOLE"

if rg -q 'EL1_GUEST_ERROR (rc=[0-9]+|source_write_succeeded)$' "$CONSOLE"; then
    fail "guest reported an EL1 probe error; inspect $LOG"
fi

awk '
    match($0, /EL1_PROBE_(START|CPU|REG|END) /) {
        print substr($0, RSTART)
    }
' "$CONSOLE" > "$MARKERS"

jq -Rn --argjson requested_smp "$SMP" '
    def cpu_row:
        capture("^EL1_PROBE_CPU cpu=(?<cpu>[0-9]+) observed_cpu=(?<observed_cpu>[0-9]+) status=(?<status>read|not_read)$") |
        {cpu: (.cpu | tonumber), observed_cpu: (.observed_cpu | tonumber), status};
    def reg_row:
        capture("^EL1_PROBE_REG cpu=(?<cpu>[0-9]+) name=(?<name>[A-Z0-9_]+) status=(?<status>read|not_read) value=(?<value>0x[0-9a-f]{16})$") |
        {
            cpu: (.cpu | tonumber),
            name,
            status,
            value: (if .status == "read" then .value else null end)
        };
    [inputs] as $lines |
    ([$lines[] | select(startswith("EL1_PROBE_START ")) |
        capture("^EL1_PROBE_START schema_version=(?<schema>[0-9]+) online_cpu_count=(?<count>[0-9]+)$") |
        {schema: (.schema | tonumber), count: (.count | tonumber)}]) as $starts |
    ([$lines[] | select(startswith("EL1_PROBE_CPU ")) | cpu_row] | sort_by(.cpu)) as $cpus |
    ([$lines[] | select(startswith("EL1_PROBE_REG ")) | reg_row]) as $regs |
    ([$lines[] | select(startswith("EL1_PROBE_END ")) |
        capture("^EL1_PROBE_END sampled_cpu_count=(?<count>[0-9]+) status=(?<status>[a-z]+)$") |
        {count: (.count | tonumber), status}]) as $ends |
    {
        schema_version: 1,
        requested_smp: $requested_smp,
        module_start: $starts,
        module_end: $ends,
        register_row_count: ($regs | length),
        cpus: [
            $cpus[] as $cpu |
            {
                cpu: $cpu.cpu,
                observed_cpu: $cpu.observed_cpu,
                status: $cpu.status,
                register_row_count: ([$regs[] | select(.cpu == $cpu.cpu)] | length),
                registers:
                    (reduce ($regs[] | select(.cpu == $cpu.cpu)) as $reg
                        ({}; .[$reg.name] = {status: $reg.status, value: $reg.value}))
            }
        ]
    }
' < "$MARKERS" > "$RAW_JSON"

if ! jq -e --argjson smp "$SMP" '
    def expected_registers: [
        "MPIDR_EL1", "CLIDR_EL1", "CTR_EL0", "DCZID_EL0",
        "ID_AA64PFR0_EL1", "ID_AA64PFR1_EL1",
        "ID_AA64DFR0_EL1", "ID_AA64DFR1_EL1",
        "ID_AA64ISAR0_EL1", "ID_AA64ISAR1_EL1",
        "ID_AA64MMFR0_EL1", "ID_AA64MMFR1_EL1", "ID_AA64MMFR2_EL1",
        "ID_AA64SMFR0_EL1", "ID_AA64ZFR0_EL1"
    ];
    .schema_version == 1 and
    .requested_smp == $smp and
    .module_start == [{schema: 1, count: $smp}] and
    .module_end == [{count: $smp, status: "ok"}] and
    .register_row_count == ($smp * (expected_registers | length)) and
    (.cpus | length) == $smp and
    [.cpus[].cpu] == [range(0; $smp)] and
    [.cpus[].observed_cpu] == [range(0; $smp)] and
    all(.cpus[];
        .status == "read" and
        .register_row_count == (expected_registers | length) and
        (.registers | length) == (expected_registers | length) and
        ([expected_registers[] as $name | .registers[$name] != null] | all) and
        all(.registers[];
            (.status == "read" and (.value | test("^0x[0-9a-f]{16}$"))) or
            (.status == "not_read" and .value == null)))
' "$RAW_JSON" >/dev/null; then
    fail "module markers failed strict validation; inspect $MARKERS"
fi

COLLECTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
jq \
    --arg collected_at "$COLLECTED_AT" \
    --argjson host_uid "$HOST_UID" \
    --arg memory "$MEM" \
    --arg run_directory "$RUN_DIR" \
    --arg qemu_path "$QEMU_REAL" \
    --arg qemu_version "$QEMU_VERSION" \
    --arg qemu_sha256 "$QEMU_SHA256" \
    --arg qemu_img_path "$QEMU_IMG_REAL" \
    --arg qemu_img_sha256 "$QEMU_IMG_SHA256" \
    --argjson qemu_argv "$QEMU_ARGV_JSON" \
    --arg kernel_path "$KERNEL" \
    --arg kernel_sha256 "$KERNEL_SHA256_BEFORE" \
    --argjson kernel_size "$(file_size "$KERNEL")" \
    --arg initrd_path "$INITRD" \
    --arg initrd_sha256 "$INITRD_SHA256_BEFORE" \
    --argjson initrd_size "$(file_size "$INITRD")" \
    --arg rootfs_path "$ROOTFS" \
    --arg rootfs_sha256 "$ROOTFS_SHA256_BEFORE" \
    --argjson rootfs_size "$(file_size "$ROOTFS")" \
    --arg build_disk_path "$BUILD_DISK" \
    --arg build_disk_state "$BUILD_STATE_BEFORE" \
    --argjson build_disk_size "$(file_size "$BUILD_DISK")" \
    --arg source_path "$MODULE_SOURCE" \
    --arg source_sha256 "$SOURCE_SHA256_BEFORE" \
    --arg makefile_path "$MODULE_MAKEFILE" \
    --arg makefile_sha256 "$MAKEFILE_SHA256_BEFORE" '
    . + {
        collected_at: $collected_at,
        run: {
            memory: $memory,
            directory: $run_directory,
            safety: {
                host_uid: $host_uid,
                host_privilege_required: false,
                explicit_disposable_overlay: true,
                root_backing_opened_via_overlay: true,
                build_drive_read_only: true,
                source_drive_read_only: true,
                network_disabled: true,
                monitor_disabled: true,
                firmware_or_pflash_attached: false,
                host_devices_attached: false,
                protected_inputs_unchanged: true,
                overlay_removed_after_shutdown: true
            },
            qemu: {
                path: $qemu_path,
                version: $qemu_version,
                sha256: $qemu_sha256,
                argv: $qemu_argv
            },
            qemu_img: {
                path: $qemu_img_path,
                sha256: $qemu_img_sha256
            }
        },
        inputs: {
            kernel: {path: $kernel_path, sha256: $kernel_sha256, size: $kernel_size},
            initrd: {path: $initrd_path, sha256: $initrd_sha256, size: $initrd_size},
            rootfs: {path: $rootfs_path, sha256: $rootfs_sha256, size: $rootfs_size},
            build_disk: {path: $build_disk_path, state: $build_disk_state, size: $build_disk_size},
            module_source: {path: $source_path, sha256: $source_sha256},
            module_makefile: {path: $makefile_path, sha256: $makefile_sha256}
        },
        consistency: {
            configured_cpu_count_matches: ((.cpus | length) == .requested_smp),
            observed_cpu_ids_match:
                ([.cpus[].observed_cpu] == [range(0; .requested_smp)]),
            mpidr_values_unique:
                (([.cpus[].registers.MPIDR_EL1.value] | unique | length) == .requested_smp),
            register_contract_homogeneous:
                (([.cpus[].registers | del(.MPIDR_EL1)] | unique | length) == 1)
        }
    }
' "$RAW_JSON" > "$FINAL_TMP"

if ! jq -e '
    def expected_consistency: [
        "configured_cpu_count_matches", "observed_cpu_ids_match",
        "mpidr_values_unique", "register_contract_homogeneous"
    ];
    .run.safety.host_privilege_required == false and
    .run.safety.explicit_disposable_overlay == true and
    .run.safety.root_backing_opened_via_overlay == true and
    .run.safety.build_drive_read_only == true and
    .run.safety.source_drive_read_only == true and
    .run.safety.network_disabled == true and
    .run.safety.monitor_disabled == true and
    .run.safety.firmware_or_pflash_attached == false and
    .run.safety.host_devices_attached == false and
    .run.safety.protected_inputs_unchanged == true and
    .run.safety.overlay_removed_after_shutdown == true and
    ((.consistency | keys | sort) == (expected_consistency | sort)) and
    ([.consistency[] | type == "boolean" and .] | all)
' "$FINAL_TMP" >/dev/null; then
    fail "final EL1 evidence failed consistency validation"
fi
if rg -qi 'machineid|bootid|serial[_ -]?number' "$FINAL_TMP"; then
    fail "EL1 evidence contains a prohibited machine or boot identifier"
fi

mv "$FINAL_TMP" "$FINAL_JSON"
trap - EXIT
cleanup
echo "EL1 evidence: $FINAL_JSON"
echo "serial log: $LOG"

#!/bin/bash
# Reproduce QEMU/HVF PMINTENCLR_EL1 clear semantics in an isolated guest.
# The single PMU write occurs only in a disposable one-vCPU VM. Host firmware,
# devices, and base images are never attached writable.
#
#   ./scripts/pmintenclr-probe-vm.sh
#
# Environment: MEM (default 4G), QEMU, QEMU_IMG, TIMEOUT, and
# QEMU_EXPECT_VERSION (default 11.1.1; set empty for a development build).
set -euo pipefail
umask 077

HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
OUT="$HERE/out"
QEMU="${QEMU-/opt/homebrew/bin/qemu-system-aarch64}"
QEMU_IMG="/opt/homebrew/bin/qemu-img"
TIMEOUT="/opt/homebrew/bin/gtimeout"
QEMU_EXPECT_VERSION="${QEMU_EXPECT_VERSION-11.1.1}"
LSOF="/usr/sbin/lsof"
MEM="${MEM:-4G}"
KVER_FILE="$OUT/KVER"
ROOTFS="$OUT/vmroot.ext4"
BUILD_DISK="$OUT/build.ext4"
MODULE_SOURCE="$HERE/scripts/arm64-pmintenclr-probe.c"
MODULE_MAKEFILE="$HERE/scripts/arm64-pmintenclr-probe.Makefile"
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
LAUNCH_STARTED=false
INPUTS_VERIFIED=false

fail() {
    echo "PMINTENCLR probe: $*" >&2
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

lsof_openers() {
    local path=$1
    local output status

    if output="$("$LSOF_REAL" -t -- "$path" 2>&1)"; then
        status=0
    else
        status=$?
    fi
    if [ "$status" -eq 0 ]; then
        printf '%s\n' "$output"
        return 0
    fi
    if [ "$status" -eq 1 ] && [ -z "$output" ]; then
        return 0
    fi
    echo "PMINTENCLR probe: lsof failed for $path (status $status): $output" >&2
    return 1
}

release_lock() {
    local observed_token=""

    if [ "$LOCK_ACQUIRED" != true ]; then
        return 0
    fi
    if [ -z "$LOCK_OWNER" ] || [ ! -f "$LOCK_OWNER" ]; then
        echo "PMINTENCLR probe: owned lock marker is missing: $LOCK_OWNER" >&2
        LOCK_ACQUIRED=false
        return 1
    fi
    IFS= read -r observed_token < "$LOCK_OWNER" || true
    if [ "$observed_token" != "$LOCK_TOKEN" ]; then
        echo "PMINTENCLR probe: lock token changed; leaving lock intact" >&2
        LOCK_ACQUIRED=false
        return 1
    fi
    if ! rm -f -- "$LOCK_OWNER" || ! rmdir "$LOCK_DIR" 2>/dev/null; then
        echo "PMINTENCLR probe: failed to release $LOCK_DIR" >&2
        LOCK_ACQUIRED=false
        return 1
    fi
    LOCK_ACQUIRED=false
}

verify_protected_inputs() {
    [ "$KVER_SHA256_BEFORE" = "$(sha256_file "$KVER_FILE")" ] &&
        [ "$KERNEL_SHA256_BEFORE" = "$(sha256_file "$KERNEL")" ] &&
        [ "$INITRD_SHA256_BEFORE" = "$(sha256_file "$INITRD")" ] &&
        [ "$ROOTFS_SHA256_BEFORE" = "$(sha256_file "$ROOTFS")" ] &&
        [ "$BUILD_STATE_BEFORE" = "$(file_state "$BUILD_DISK")" ] &&
        [ "$SOURCE_SHA256_BEFORE" = "$(sha256_file "$MODULE_SOURCE")" ] &&
        [ "$MAKEFILE_SHA256_BEFORE" = "$(sha256_file "$MODULE_MAKEFILE")" ] &&
        [ "$QEMU_SHA256_BEFORE" = "$(sha256_file "$QEMU_REAL")" ] &&
        [ "$QEMU_IMG_SHA256_BEFORE" = "$(sha256_file "$QEMU_IMG_REAL")" ]
}

cleanup() {
    local cleanup_status=$?

    if [ -n "$QPID" ]; then
        if kill -0 "$QPID" 2>/dev/null; then
            kill "$QPID" 2>/dev/null || true
        fi
        wait "$QPID" 2>/dev/null || true
        QPID=""
    fi
    if [ -n "$FEED_PID" ]; then
        if kill -0 "$FEED_PID" 2>/dev/null; then
            kill "$FEED_PID" 2>/dev/null || true
        fi
        wait "$FEED_PID" 2>/dev/null || true
        FEED_PID=""
    fi
    { exec 9>&- 9<&-; } 2>/dev/null || true
    if [ -n "$SERIAL_FIFO" ] && [ -p "$SERIAL_FIFO" ]; then
        rm -f -- "$SERIAL_FIFO" || cleanup_status=1
    fi
    if [ -n "$ROOT_OVERLAY" ] && [ -f "$ROOT_OVERLAY" ]; then
        if ! OVERLAY_OPENERS="$(lsof_openers "$ROOT_OVERLAY")"; then
            cleanup_status=1
        elif [ -n "$OVERLAY_OPENERS" ]; then
            echo "PMINTENCLR probe: overlay remains open by pid(s): $OVERLAY_OPENERS" >&2
            cleanup_status=1
        else
            rm -f -- "$ROOT_OVERLAY" || cleanup_status=1
        fi
    fi
    if [ -n "$ROOT_OVERLAY" ] && [ -e "$ROOT_OVERLAY" ]; then
        echo "PMINTENCLR probe: disposable overlay remains: $ROOT_OVERLAY" >&2
        cleanup_status=1
    fi
    if [ "$LAUNCH_STARTED" = true ] && [ "$HASHES_READY" = true ] &&
       [ "$INPUTS_VERIFIED" = false ]; then
        if verify_protected_inputs; then
            INPUTS_VERIFIED=true
        else
            echo "PMINTENCLR probe: a protected input changed" >&2
            cleanup_status=1
        fi
    fi
    release_lock || cleanup_status=1
    return "$cleanup_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

case "$MEM" in
    *G)
        MEM_VALUE="${MEM%G}"
        case "$MEM_VALUE" in ''|*[!0-9]*|0|0*) fail "invalid MEM value: $MEM" ;; esac
        [ "$MEM_VALUE" -le 16 ] || fail "MEM exceeds the 16G probe limit: $MEM"
        ;;
    *M)
        MEM_VALUE="${MEM%M}"
        case "$MEM_VALUE" in ''|*[!0-9]*|0|0*) fail "invalid MEM value: $MEM" ;; esac
        [ "$MEM_VALUE" -le 16384 ] || fail "MEM exceeds the 16G probe limit: $MEM"
        ;;
    *) fail "MEM must be an integer number of M or G: $MEM" ;;
esac

[ "$(id -u)" -ne 0 ] || fail "refusing to run QEMU as host root"
[ ! -L "$OUT" ] || fail "refusing symlinked output root: $OUT"
mkdir -p "$OUT"
[ "$(cd "$OUT" && pwd -P)" = "$OUT" ] || fail "output root is not canonical"

for tool in "$QEMU" "$QEMU_IMG" "$TIMEOUT" "$LSOF"; do
    [ -x "$tool" ] || fail "missing executable: $tool"
    [ ! -u "$tool" ] && [ ! -g "$tool" ] || fail "refusing setuid/setgid tool: $tool"
done
QEMU_REAL="$(realpath "$QEMU")"
QEMU_IMG_REAL="$(realpath "$QEMU_IMG")"
TIMEOUT_REAL="$(realpath "$TIMEOUT")"
LSOF_REAL="$(realpath "$LSOF")"
for tool in "$QEMU_REAL" "$QEMU_IMG_REAL" "$TIMEOUT_REAL" "$LSOF_REAL"; do
    [ -f "$tool" ] && [ -x "$tool" ] || fail "tool resolves unsafely: $tool"
done

require_safe_input "$KVER_FILE"
KVER="$(cat "$KVER_FILE")"
case "$KVER" in
    ''|.|..|*/*|*[!A-Za-z0-9.+_~-]*) fail "KVER contains unsafe characters: $KVER" ;;
esac
KERNEL="$OUT/Image-$KVER"
INITRD="$OUT/initrd.img-$KVER"
for input in "$KERNEL" "$INITRD" "$ROOTFS" "$BUILD_DISK" \
             "$MODULE_SOURCE" "$MODULE_MAKEFILE"; do
    require_safe_input "$input"
done

QEMU_VERSION="$("$QEMU_REAL" --version | head -1)"
if [ -n "$QEMU_EXPECT_VERSION" ]; then
    case "$QEMU_VERSION" in
        "QEMU emulator version $QEMU_EXPECT_VERSION"|\
        "QEMU emulator version $QEMU_EXPECT_VERSION "*) ;;
        *) fail "expected QEMU $QEMU_EXPECT_VERSION, got: $QEMU_VERSION" ;;
    esac
fi

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    fail "another VM probe owns $LOCK_DIR; inspect it rather than deleting it"
fi
LOCK_ACQUIRED=true
LOCK_TOKEN="$$:$(date +%s):$RANDOM"
LOCK_OWNER="$LOCK_DIR/owner.$$"
printf '%s\n' "$LOCK_TOKEN" > "$LOCK_OWNER"
ROOTFS_OPENERS="$(lsof_openers "$ROOTFS")" || fail "could not inspect rootfs openers"
[ -z "$ROOTFS_OPENERS" ] || fail "vmroot.ext4 is already open by pid(s): $ROOTFS_OPENERS"

RUN_DIR="$(mktemp -d "$OUT/pmintenclr-probe.XXXXXX")"
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
mkfifo -m 600 "$SERIAL_FIFO"
ulimit -f 1048576

echo "hashing protected inputs before launch"
KVER_SHA256_BEFORE="$(sha256_file "$KVER_FILE")"
KERNEL_SHA256_BEFORE="$(sha256_file "$KERNEL")"
INITRD_SHA256_BEFORE="$(sha256_file "$INITRD")"
ROOTFS_SHA256_BEFORE="$(sha256_file "$ROOTFS")"
BUILD_STATE_BEFORE="$(file_state "$BUILD_DISK")"
SOURCE_SHA256_BEFORE="$(sha256_file "$MODULE_SOURCE")"
MAKEFILE_SHA256_BEFORE="$(sha256_file "$MODULE_MAKEFILE")"
QEMU_SHA256_BEFORE="$(sha256_file "$QEMU_REAL")"
QEMU_IMG_SHA256_BEFORE="$(sha256_file "$QEMU_IMG_REAL")"
HASHES_READY=true

"$QEMU_IMG_REAL" create -q -f qcow2 -F raw -b "$ROOTFS" "$ROOT_OVERLAY"
chmod 600 "$ROOT_OVERLAY"

GUEST=$(cat <<'GUEST_EOF'
set -eu
guest_cleanup() {
    rc=$?
    set +e
    if [ "$rc" -ne 0 ]; then
        echo "PMINTENCLR_GUEST_ERROR rc=$rc"
    fi
    rmmod arm64_pmintenclr_probe 2>/dev/null || true
    umount /mnt/pmintenclr-source 2>/dev/null || true
    umount /mnt/pmintenclr-build 2>/dev/null || true
    trap - EXIT
    poweroff -f
}
trap guest_cleanup EXIT

mkdir -p /mnt/pmintenclr-build /mnt/pmintenclr-source
mount -o ro,noload /dev/vdb /mnt/pmintenclr-build
mount -o ro /dev/vdc1 /mnt/pmintenclr-source
[ "$(blockdev --getro /dev/vdb)" = 1 ]
[ "$(blockdev --getro /dev/vdc)" = 1 ]
findmnt -n -o OPTIONS /mnt/pmintenclr-build | grep -qw ro
findmnt -n -o OPTIONS /mnt/pmintenclr-source | grep -qw ro
if touch /mnt/pmintenclr-source/.write-must-fail 2>/dev/null; then
    echo "PMINTENCLR_GUEST_ERROR source_write_succeeded"
    exit 1
fi

WORK="$(mktemp -d /tmp/arm64-pmintenclr-probe.XXXXXX)"
cp /mnt/pmintenclr-source/arm64-pmintenclr-probe.c "$WORK/"
cp /mnt/pmintenclr-source/arm64-pmintenclr-probe.Makefile "$WORK/Makefile"
KERNEL_SOURCE="$(find /mnt/pmintenclr-build -maxdepth 2 -type d -name 'linux-asahi-*' -print -quit)"
[ -n "$KERNEL_SOURCE" ]
if [ -d "$KERNEL_SOURCE/debian/build/source_none" ]; then
    KERNEL_SOURCE="$KERNEL_SOURCE/debian/build/source_none"
fi
KERNEL_BUILD="$WORK/kbuild"
mkdir -p "$KERNEL_BUILD"
cp "/boot/config-$(uname -r)" "$KERNEL_BUILD/.config"
for required in "$KERNEL_SOURCE/Makefile" "$KERNEL_SOURCE/scripts/config" \
                "$KERNEL_BUILD/.config"; do
    [ -r "$required" ]
done

echo "PMINTENCLR_GUEST_BUILD source=$KERNEL_SOURCE output=$KERNEL_BUILD"
"$KERNEL_SOURCE/scripts/config" --file "$KERNEL_BUILD/.config" \
    -d MODULE_SIG_ALL -d MODULE_SIG_FORCE
make -s -C "$KERNEL_SOURCE" O="$KERNEL_BUILD" \
    KERNELRELEASE="$(uname -r)" olddefconfig modules_prepare
make -s -C "$KERNEL_SOURCE" O="$KERNEL_BUILD" M="$WORK" \
    KERNELRELEASE="$(uname -r)" KBUILD_MODPOST_WARN=1 modules
test -s "$WORK/arm64-pmintenclr-probe.ko"
modinfo -F vermagic "$WORK/arm64-pmintenclr-probe.ko"
dmesg -n 8
insmod "$WORK/arm64-pmintenclr-probe.ko" allow_hidden_pmu=1
rmmod arm64_pmintenclr_probe
echo "PMINTENCLR_GUEST_COMPLETE"
umount /mnt/pmintenclr-source
umount /mnt/pmintenclr-build
trap - EXIT
poweroff -f
GUEST_EOF
)

ARGS=(
    -M virt,highmem=on
    -accel hvf,kernel-irqchip=off
    -cpu host
    -smp 1,sockets=1,cores=1,threads=1
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
QEMU_ARGV_JSON="$(jq -n --args '$ARGS.positional' -- "$QEMU_REAL" "${ARGS[@]}")"
if ! jq -e '
    . as $argv |
    $argv[0] != "" and
    ([$argv[] | select(. == "-accel")] | length) == 1 and
    ([$argv[] | select(. == "hvf,kernel-irqchip=off")] | length) == 1 and
    ([$argv[] | select(. == "-nic")] | length) == 1 and
    ([$argv[] | select(. == "none")] | length) >= 3 and
    ($argv | index("-no-reboot") != null) and
    all(["-bios", "-pflash", "-firmware", "-netdev", "-device", "-object"][];
        . as $forbidden | ($argv | index($forbidden)) == null)
' <<<"$QEMU_ARGV_JSON" >/dev/null; then
    fail "internal QEMU argument safety contract failed"
fi

exec 9<> "$SERIAL_FIFO"
echo "booting isolated PMINTENCLR probe: 1 vCPU, $MEM RAM -> $RUN_DIR"
(
    sleep 30
    printf 'stty -echo\n' >&9
    sleep 1
    printf '%s\n' "$GUEST" >&9
) &
FEED_PID=$!

LAUNCH_STARTED=true
set +e
env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin \
    TMPDIR="$RUN_DIR" \
    HOME="$RUN_DIR" \
    "$TIMEOUT_REAL" --foreground --signal=TERM --kill-after=10 300 \
    "$QEMU_REAL" "${ARGS[@]}" <&9 > "$LOG" 2>&1 &
QPID=$!
wait "$QPID"
QEMU_STATUS=$?
set -e
QPID=""
wait "$FEED_PID" 2>/dev/null || true
FEED_PID=""
exec 9>&- 9<&-
rm -f -- "$SERIAL_FIFO"
SERIAL_FIFO=""

OVERLAY_OPENERS="$(lsof_openers "$ROOT_OVERLAY")" || fail "could not inspect overlay openers"
[ -z "$OVERLAY_OPENERS" ] || fail "overlay remains open by pid(s): $OVERLAY_OPENERS"
rm -f -- "$ROOT_OVERLAY"
ROOT_OVERLAY=""
verify_protected_inputs || fail "a protected input changed during the probe"
INPUTS_VERIFIED=true

[ "$QEMU_STATUS" -ne 124 ] || fail "QEMU timed out; inspect $LOG"
[ "$QEMU_STATUS" -eq 0 ] || fail "QEMU exited with status $QEMU_STATUS; inspect $LOG"
tr -d '\r' < "$LOG" > "$CONSOLE"
if rg -q 'PMINTENCLR_GUEST_ERROR (rc=[0-9]+|source_write_succeeded)$' "$CONSOLE"; then
    fail "guest reported an error; inspect $LOG"
fi
[ "$(awk '$0 ~ /PMINTENCLR_GUEST_COMPLETE$/ {n++} END {print n+0}' "$CONSOLE")" -eq 1 ] ||
    fail "guest completion marker contract failed"
awk '
    match($0, /PMINTENCLR_PROBE_(START|STATE|RESULT|END) /) {
        print substr($0, RSTART)
    }
' "$CONSOLE" > "$MARKERS"

jq -Rn '
    [inputs] as $lines |
    ([$lines[] | select(startswith("PMINTENCLR_PROBE_START ")) |
      capture("^PMINTENCLR_PROBE_START schema_version=(?<schema>[0-9]+)$") |
      {schema_version: (.schema | tonumber)}]) as $start |
    ([$lines[] | select(startswith("PMINTENCLR_PROBE_STATE ")) |
      capture("^PMINTENCLR_PROBE_STATE requested_cpu=(?<requested>[0-9]+) observed_cpu=(?<observed>[0-9]+) id_aa64dfr0=(?<dfr0>0x[0-9a-f]{16}) pmuver=(?<pmuver>[0-9]+) hidden_pmu_opt_in=(?<opt_in>yes|no) pmcr=(?<pmcr>0x[0-9a-f]{16}) pmcr_disabled=(?<pmcr_disabled>0x[0-9a-f]{16}) pmcr_after=(?<pmcr_after>0x[0-9a-f]{16}) pminten_before=(?<pminten>0x[0-9a-f]{16}) pmovs_before=(?<pmovs>0x[0-9a-f]{16})$") |
      {requested_cpu: (.requested | tonumber), observed_cpu: (.observed | tonumber),
       id_aa64dfr0: .dfr0, pmuver: (.pmuver | tonumber),
       hidden_pmu_opt_in: (.opt_in == "yes"), pmcr: .pmcr,
       pmcr_disabled: .pmcr_disabled, pmcr_after: .pmcr_after,
       pminten_before: .pminten, pmovs_before: .pmovs}]) as $state |
    ([$lines[] | select(startswith("PMINTENCLR_PROBE_RESULT ")) |
      capture("^PMINTENCLR_PROBE_RESULT target_bit=(?<bit>[0-9]+) pminten_after=(?<after>0x[0-9a-f]{16}) status=(?<status>pass|fail|skipped_dirty_state|skipped_no_opt_in|skipped_unexpected_pmuver|skipped_disable_failed|not_run) guest_state_restored=(?<restored>yes|no|unchanged)$") |
      {target_bit: (.bit | tonumber), pminten_after: .after, status,
       guest_state_restored: .restored}]) as $result |
    ([$lines[] | select(startswith("PMINTENCLR_PROBE_END ")) |
      capture("^PMINTENCLR_PROBE_END status=(?<status>[a-z_]+)( code=(?<code>-?[0-9]+))?$") |
      {status, code: (if .code == null then null else (.code | tonumber) end)}]) as $end |
    if ($start | length) != 1 or ($state | length) != 1 or
       ($result | length) != 1 or ($end | length) != 1
    then error("marker cardinality contract failed")
    else {
        schema_version: 1,
        module_start: $start[0],
        module_end: $end[0],
        state: $state[0],
        result: $result[0],
        expected_semantics: "writing bit 31 to PMINTENCLR_EL1 clears that bit"
    }
    end
' < "$MARKERS" > "$RAW_JSON"

jq \
    --arg collected_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg memory "$MEM" \
    --arg run_directory "$RUN_DIR" \
    --argjson host_uid "$(id -u)" \
    --arg qemu_path "$QEMU_REAL" \
    --arg qemu_version "$QEMU_VERSION" \
    --arg qemu_sha256 "$QEMU_SHA256_BEFORE" \
    --arg qemu_img_path "$QEMU_IMG_REAL" \
    --arg qemu_img_sha256 "$QEMU_IMG_SHA256_BEFORE" \
    --argjson qemu_argv "$QEMU_ARGV_JSON" \
    --arg kernel_path "$KERNEL" \
    --arg kernel_sha256 "$KERNEL_SHA256_BEFORE" \
    --arg initrd_path "$INITRD" \
    --arg initrd_sha256 "$INITRD_SHA256_BEFORE" \
    --arg rootfs_path "$ROOTFS" \
    --arg rootfs_sha256 "$ROOTFS_SHA256_BEFORE" \
    --arg build_disk_path "$BUILD_DISK" \
    --arg build_disk_state "$BUILD_STATE_BEFORE" \
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
                one_vcpu_only: true,
                qemu_irqchip_off_only: true,
                guest_register_write: "PMINTENCLR_EL1 bit 31 only",
                write_precondition_requires_clear_interrupt_and_overflow: true,
                explicit_disposable_overlay: true,
                root_backing_opened_via_overlay: true,
                build_drive_read_only: true,
                source_drive_read_only: true,
                network_disabled: true,
                monitor_disabled: true,
                firmware_or_pflash_attached: false,
                host_devices_attached: false,
                protected_content_hashes_unchanged: true,
                build_disk_metadata_unchanged: true,
                overlay_removed_after_shutdown: true
            },
            qemu: {path: $qemu_path, version: $qemu_version,
                   sha256: $qemu_sha256, argv: $qemu_argv},
            qemu_img: {path: $qemu_img_path, sha256: $qemu_img_sha256}
        },
        inputs: {
            kernel: {path: $kernel_path, sha256: $kernel_sha256},
            initrd: {path: $initrd_path, sha256: $initrd_sha256},
            rootfs: {path: $rootfs_path, sha256: $rootfs_sha256},
            build_disk: {path: $build_disk_path, state: $build_disk_state},
            module_source: {path: $source_path, sha256: $source_sha256},
            module_makefile: {path: $makefile_path, sha256: $makefile_sha256}
        }
    }
' "$RAW_JSON" > "$FINAL_TMP"

if ! jq -e '
    .schema_version == 1 and
    .module_start.schema_version == 1 and
    .module_end.status == "complete" and
    .state.requested_cpu == 0 and .state.observed_cpu == 0 and
    .state.pmuver == 0 and .state.hidden_pmu_opt_in == true and
    .result.target_bit == 31 and
    (.result.status == "pass" or .result.status == "fail" or
     (.result.status | startswith("skipped_"))) and
    (if .result.status == "pass"
     then .result.guest_state_restored == "yes"
     else true end) and
    .run.safety.host_privilege_required == false and
    .run.safety.one_vcpu_only == true and
    .run.safety.qemu_irqchip_off_only == true and
    .run.safety.network_disabled == true and
    .run.safety.firmware_or_pflash_attached == false and
    .run.safety.host_devices_attached == false and
    .run.safety.protected_content_hashes_unchanged == true and
    .run.safety.build_disk_metadata_unchanged == true and
    .run.safety.overlay_removed_after_shutdown == true
' "$FINAL_TMP" >/dev/null; then
    fail "final evidence failed consistency validation"
fi
if rg -qi 'machineid|bootid|serial[_ -]?number' "$FINAL_TMP"; then
    fail "evidence contains a prohibited machine or boot identifier"
fi

mv "$FINAL_TMP" "$FINAL_JSON"
RESULT_STATUS="$(jq -r '.result.status' "$FINAL_JSON")"
trap - EXIT
cleanup
echo "PMINTENCLR evidence: $FINAL_JSON"
echo "serial log: $LOG"
case "$RESULT_STATUS" in
    pass) exit 0 ;;
    fail) exit 2 ;;
    skipped_*) exit 3 ;;
    *) exit 1 ;;
esac

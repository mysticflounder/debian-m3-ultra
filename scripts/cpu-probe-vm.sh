#!/bin/bash
# Boot the existing builder VM on a throwaway overlay, compile the guest CPU
# probe from a read-only vvfat share, and extract its JSON result.
#
#   ./scripts/cpu-probe-vm.sh
#
# Environment: QEMU, SMP (default 8), MEM (default 8G), LOG, JSON_OUT,
#              ROOTFS_SHA256 (optional expected digest for matrix runs).
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
OUT="$HERE/out"
QEMU="${QEMU:-/opt/homebrew/bin/qemu-system-aarch64}"
SMP="${SMP:-8}"
MEM="${MEM:-8G}"
LOG_INPUT="${LOG:-$OUT/cpu-probe.log}"
JSON_OUT_INPUT="${JSON_OUT:-$OUT/cpu-probe-guest.json}"
ROOTFS_SHA256_EXPECTED="${ROOTFS_SHA256:-}"
LOCK_DIR="$OUT/.vmroot.ext4.probe.lock"
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

if [ "$(id -u)" -eq 0 ]; then
    echo "refusing to run QEMU as host root" >&2
    exit 1
fi

if [ -L "$OUT" ]; then
    echo "refusing symlinked output root: $OUT" >&2
    exit 1
fi
mkdir -p "$OUT"
OUT_REAL="$(cd "$OUT" && pwd -P)"

resolve_safe_output() {
    local input candidate parent parent_real link_count

    input="$1"
    case "$input" in
        /*) candidate="$input" ;;
        *)  candidate="$HERE/$input" ;;
    esac
    case "$candidate/" in
        *"/../"*|*"/./"*|*"//"*)
            echo "output path contains an unsafe component: $input" >&2
            return 1
            ;;
    esac
    case "$candidate" in
        "$OUT"/*) ;;
        *)
            echo "output path must stay under $OUT: $input" >&2
            return 1
            ;;
    esac
    parent="${candidate%/*}"
    if [ ! -d "$parent" ]; then
        echo "output directory does not exist: $parent" >&2
        return 1
    fi
    parent_real="$(cd "$parent" && pwd -P)"
    case "$parent_real" in
        "$OUT_REAL"|"$OUT_REAL"/*) ;;
        *)
            echo "output directory resolves outside $OUT: $parent" >&2
            return 1
            ;;
    esac
    if [ -L "$candidate" ] || { [ -e "$candidate" ] && [ ! -f "$candidate" ]; }; then
        echo "refusing non-regular or symlinked output: $candidate" >&2
        return 1
    fi
    if [ -e "$candidate" ]; then
        link_count="$(stat -f '%l' "$candidate")"
        if [ "$link_count" -ne 1 ]; then
            echo "refusing multiply linked output: $candidate" >&2
            return 1
        fi
    fi
    printf '%s\n' "$candidate"
}

LOG="$(resolve_safe_output "$LOG_INPUT")"
JSON_OUT="$(resolve_safe_output "$JSON_OUT_INPUT")"
if [ "$LOG" = "$JSON_OUT" ]; then
    echo "LOG and JSON_OUT must be different files" >&2
    exit 1
fi

KVER_FILE="$OUT/KVER"
if [ -L "$KVER_FILE" ] || [ ! -f "$KVER_FILE" ]; then
    echo "KVER must be a regular, non-symlink input: $KVER_FILE" >&2
    exit 1
fi
KVER="$(cat "$KVER_FILE")"
case "$KVER" in
    ''|.|..|*/*|*[!A-Za-z0-9.+_~-]*)
        echo "KVER contains unsafe characters: $KVER" >&2
        exit 1
        ;;
esac
SOURCE="$HERE/scripts/arm64-guest-cpu.c"
KERNEL="$OUT/Image-$KVER"
INITRD="$OUT/initrd.img-$KVER"
ROOTFS="$OUT/vmroot.ext4"

for protected in "$KVER_FILE" "$SOURCE" "$KERNEL" "$INITRD" "$ROOTFS"; do
    if [ "$LOG" = "$protected" ] || [ "$JSON_OUT" = "$protected" ] ||
       { [ -e "$LOG" ] && [ "$LOG" -ef "$protected" ]; } ||
       { [ -e "$JSON_OUT" ] && [ "$JSON_OUT" -ef "$protected" ]; }; then
        echo "output path collides with protected input: $protected" >&2
        exit 1
    fi
done

case "$SMP" in
    ''|*[!0-9]*)
        echo "SMP must be a positive integer, got: $SMP" >&2
        exit 1
        ;;
esac
if [ "$SMP" -lt 1 ]; then
    echo "SMP must be at least 1" >&2
    exit 1
fi
if [ "$SMP" -gt 64 ]; then
    echo "SMP exceeds the 64-vCPU safety limit: $SMP" >&2
    exit 1
fi
case "$MEM" in
    *G)
        MEM_VALUE="${MEM%G}"
        case "$MEM_VALUE" in ''|*[!0-9]*|0|0*) echo "invalid MEM value: $MEM" >&2; exit 1 ;; esac
        [ "$MEM_VALUE" -le 64 ] || { echo "MEM exceeds the 64G safety limit: $MEM" >&2; exit 1; }
        ;;
    *M)
        MEM_VALUE="${MEM%M}"
        case "$MEM_VALUE" in ''|*[!0-9]*|0|0*) echo "invalid MEM value: $MEM" >&2; exit 1 ;; esac
        [ "$MEM_VALUE" -le 65536 ] || { echo "MEM exceeds the 64G safety limit: $MEM" >&2; exit 1; }
        ;;
    *) echo "MEM must be an integer number of M or G: $MEM" >&2; exit 1 ;;
esac

for required in \
    "$KERNEL" \
    "$INITRD" \
    "$ROOTFS" \
    "$SOURCE"; do
    if [ -L "$required" ] || [ ! -f "$required" ] || [ ! -r "$required" ]; then
        echo "required input must be a readable regular non-symlink file: $required" >&2
        exit 1
    fi
done

sha256_file() {
    shasum -a 256 "$1" | awk '{print $1}'
}

file_size() {
    stat -f '%z' "$1"
}

verify_protected_inputs() {
    KERNEL_SHA256_AFTER="$(sha256_file "$KERNEL")"
    INITRD_SHA256_AFTER="$(sha256_file "$INITRD")"
    ROOTFS_SHA256_AFTER="$(sha256_file "$ROOTFS")"
    SOURCE_SHA256_AFTER="$(sha256_file "$SOURCE")"

    [ "$KERNEL_SHA256_BEFORE" = "$KERNEL_SHA256_AFTER" ] &&
        [ "$INITRD_SHA256_BEFORE" = "$INITRD_SHA256_AFTER" ] &&
        [ "$ROOTFS_SHA256_BEFORE" = "$ROOTFS_SHA256_AFTER" ] &&
        [ "$SOURCE_SHA256_BEFORE" = "$SOURCE_SHA256_AFTER" ]
}

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
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "another CPU probe owns $LOCK_DIR; inspect it rather than deleting it blindly" >&2
    exit 1
fi
LOCK_ACQUIRED=true
LOCK_TOKEN="$$:$(date +%s):$RANDOM"
LOCK_OWNER="$LOCK_DIR/owner.$$"
printf '%s\n' "$LOCK_TOKEN" > "$LOCK_OWNER"
trap release_lock EXIT
if command -v lsof >/dev/null 2>&1; then
    OPENERS="$(lsof -t -- "$ROOTFS" 2>/dev/null || true)"
    if [ -n "$OPENERS" ]; then
        echo "vmroot.ext4 is already open by pid(s): $OPENERS" >&2
        exit 1
    fi
fi

echo "hashing protected inputs before launch"
KERNEL_SHA256_BEFORE="$(sha256_file "$KERNEL")"
INITRD_SHA256_BEFORE="$(sha256_file "$INITRD")"
ROOTFS_SHA256_BEFORE="$(sha256_file "$ROOTFS")"
SOURCE_SHA256_BEFORE="$(sha256_file "$SOURCE")"
HASHES_READY=true
if [ -n "$ROOTFS_SHA256_EXPECTED" ] &&
   [ "$ROOTFS_SHA256_EXPECTED" != "$ROOTFS_SHA256_BEFORE" ]; then
    echo "rootfs SHA-256 does not match the expected matrix digest" >&2
    exit 1
fi

GUEST='
mkdir -p /mnt/cpu-probe
if ! mount -o ro /dev/vdb1 /mnt/cpu-probe; then
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
    -smp "$SMP,sockets=1,cores=$SMP,threads=1"
    -m "$MEM"
    -kernel "$KERNEL"
    -initrd "$INITRD"
    -append "root=/dev/vda rootfstype=ext4 rw console=ttyAMA0 systemd.unit=multi-user.target systemd.mask=m3-build.service"
    -drive "if=virtio,file=$ROOTFS,format=raw"
    -drive "if=virtio,file=fat:ro:$HERE/scripts,format=raw,readonly=on"
    -snapshot
    -nic none
    -monitor none
    -nographic
)

echo "booting read-only CPU probe VM: ${SMP} vCPUs, ${MEM} RAM -> $LOG"
( sleep 30; printf '%s\n' "$GUEST" ) | "$QEMU" "${ARGS[@]}" > "$LOG" 2>&1 &
QPID=$!

cleanup() {
    local cleanup_status=$?
    local wait_step

    if [ -n "${QPID:-}" ] && kill -0 "$QPID" 2>/dev/null; then
        kill "$QPID" 2>/dev/null || true
        for wait_step in $(seq 1 10); do
            kill -0 "$QPID" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "$QPID" 2>/dev/null; then
            kill -KILL "$QPID" 2>/dev/null || true
        fi
        wait "$QPID" 2>/dev/null || true
    fi
    if [ "$HASHES_READY" = true ] && [ "$INPUTS_VERIFIED" = false ]; then
        if verify_protected_inputs; then
            INPUTS_VERIFIED=true
        else
            echo "cpu probe: a protected input changed during cleanup" >&2
            cleanup_status=1
        fi
    fi
    release_lock
    return "$cleanup_status"
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
QPID=""
release_lock
trap - EXIT

CONSOLE="$(mktemp "$OUT/.cpu-probe-console.XXXXXX")"
JSON_TMP="$(mktemp "$OUT/.cpu-probe-json.XXXXXX")"
FINAL_TMP="$(mktemp "$OUT/.cpu-probe-final.XXXXXX")"
KMSG_TMP="$(mktemp "$OUT/.cpu-probe-kmsg.XXXXXX")"
cleanup_files() {
    rm -f "$CONSOLE" "$JSON_TMP" "$FINAL_TMP" "$KMSG_TMP"
}
trap cleanup_files EXIT

tr -d '\r' < "$LOG" \
    | sed -e 's/\x1b\][0-9;]*;[^\x07\x1b]*\(\x07\|\x1b\\\)//g' \
          -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' \
    > "$CONSOLE"

awk '
    /=== CPU PROBE JSON START ===/ {
        armed = 1
        capture = 0
        complete = 0
        count = 0
        delete lines
        next
    }
    /=== CPU PROBE JSON END ===/ && armed {
        if (complete) {
            for (i = 1; i <= count; i++) {
                print lines[i]
            }
        }
        exit
    }
    armed && !capture && index($0, "{") {
        sub(/^[^{]*/, "")
        capture = 1
    }
    capture && !complete {
        lines[++count] = $0
        if ($0 == "}") {
            complete = 1
        }
    }
' "$CONSOLE" > "$JSON_TMP"

if ! jq -e --argjson smp "$SMP" '
    def register_names: [
        "CLIDR_EL1",
        "CTR_EL0",
        "DCZID_EL0",
        "ID_AA64DFR0_EL1",
        "ID_AA64DFR1_EL1",
        "ID_AA64ISAR0_EL1",
        "ID_AA64ISAR1_EL1",
        "ID_AA64ISAR2_EL1",
        "ID_AA64MMFR0_EL1",
        "ID_AA64MMFR1_EL1",
        "ID_AA64MMFR2_EL1",
        "ID_AA64MMFR3_EL1",
        "ID_AA64MMFR4_EL1",
        "ID_AA64PFR0_EL1",
        "ID_AA64PFR1_EL1",
        "ID_AA64PFR2_EL1",
        "ID_AA64SMFR0_EL1",
        "ID_AA64ZFR0_EL1",
        "MIDR_EL1",
        "MPIDR_EL1"
    ];

    type == "object" and
    .schema_version == 2 and
    .read_only == true and
    .auxv.HWCAP_CPUID == true and
    .collector_state.sigill_install.status == "available" and
    .collector_state.sigill_restore.status == "available" and
    .affinity.enumeration.status == "available" and
    .affinity.restore.status == "available" and
    .affinity.online_mask_stability.matches == true and
    .affinity.cpus == [range(0; $smp)] and
    (.cpus | length) == $smp and
    ([.cpus[].observed_cpu.value] | unique | length) == $smp and
    all(.cpus[];
        .pin.status == "available" and
        .pin_validation.matches == true and
        .requested_cpu == .observed_cpu.value and
        (.registers | keys) == register_names and
        ([.registers[].status] |
            all(. == "available" or . == "unavailable"))
    )
' "$JSON_TMP" >/dev/null; then
    echo "guest probe did not produce valid JSON; inspect $LOG" >&2
    exit 1
fi

awk '
    /^\[[[:space:]]*[0-9.]+\]/ {
        line = $0
        lower = tolower(line)
        if (lower ~ /(cpu feature|cache|pmu|sve|sme|tso|atomic|pointer auth|bti|gic|timer|dczva)/) {
            sub(/^\[[^]]*\][[:space:]]*/, "", line)
            if (!seen[line]++)
                print line
        }
    }
' "$CONSOLE" > "$KMSG_TMP"

COLLECTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
QEMU_VERSION="$("$QEMU" --version | head -1)"
QEMU_ARGV_JSON="$(jq -n --args '$ARGS.positional' -- "$QEMU" "${ARGS[@]}")"
verify_protected_inputs || {
    echo "a protected input changed during the CPU probe" >&2
    exit 1
}
INPUTS_VERIFIED=true
KERNEL_SHA256="$KERNEL_SHA256_AFTER"
INITRD_SHA256="$INITRD_SHA256_AFTER"
ROOTFS_SHA256="$ROOTFS_SHA256_AFTER"
SOURCE_SHA256="$SOURCE_SHA256_AFTER"
KERNEL_SIZE="$(file_size "$KERNEL")"
INITRD_SIZE="$(file_size "$INITRD")"
ROOTFS_SIZE="$(file_size "$ROOTFS")"
SOURCE_SIZE="$(file_size "$SOURCE")"

jq \
    --arg collected_at "$COLLECTED_AT" \
    --argjson requested_smp "$SMP" \
    --arg memory "$MEM" \
    --arg qemu_path "$QEMU" \
    --arg qemu_version "$QEMU_VERSION" \
    --argjson qemu_argv "$QEMU_ARGV_JSON" \
    --arg kernel_path "$KERNEL" \
    --arg kernel_sha256 "$KERNEL_SHA256" \
    --arg kernel_size "$KERNEL_SIZE" \
    --arg initrd_path "$INITRD" \
    --arg initrd_sha256 "$INITRD_SHA256" \
    --arg initrd_size "$INITRD_SIZE" \
    --arg rootfs_path "$ROOTFS" \
    --arg rootfs_sha256 "$ROOTFS_SHA256" \
    --arg rootfs_size "$ROOTFS_SIZE" \
    --arg source_path "$SOURCE" \
    --arg source_sha256 "$SOURCE_SHA256" \
    --arg source_size "$SOURCE_SIZE" \
    --rawfile kernel_messages "$KMSG_TMP" \
    '. + {
        run: {
            collected_at_utc: $collected_at,
            requested_smp: $requested_smp,
            memory: $memory,
            safety: {
                snapshot: true,
                source_drive_read_only: true,
                host_privilege_required: false
            },
            qemu: {
                path: $qemu_path,
                version: $qemu_version,
                argv: $qemu_argv
            },
            inputs: {
                kernel: {
                    path: $kernel_path,
                    sha256: $kernel_sha256,
                    size_bytes: ($kernel_size | tonumber)
                },
                initrd: {
                    path: $initrd_path,
                    sha256: $initrd_sha256,
                    size_bytes: ($initrd_size | tonumber)
                },
                rootfs: {
                    path: $rootfs_path,
                    sha256: $rootfs_sha256,
                    size_bytes: ($rootfs_size | tonumber)
                },
                probe_source: {
                    path: $source_path,
                    sha256: $source_sha256,
                    size_bytes: ($source_size | tonumber)
                }
            }
        },
        kernel_feature_messages: {
            status: (if ($kernel_messages | length) > 0 then
                        "available"
                     else
                        "missing"
                     end),
            source: "filtered_serial_console",
            lines: ($kernel_messages | split("\n") |
                    map(select(length > 0)))
        },
        consistency: {
            requested_smp_matches_cpu_count:
                ((.cpus | length) == $requested_smp),
            affinity_cpu_list_matches:
                (.affinity.cpus == [range(0; $requested_smp)]),
            online_mask_stable:
                (.affinity.online_mask_stability.matches == true),
            all_pins_match:
                all(.cpus[]; .pin_validation.matches == true),
            observed_cpus_unique:
                (([.cpus[].observed_cpu.value] | unique | length) ==
                 $requested_smp),
            register_contract_homogeneous:
                (([.cpus[].registers | del(.MPIDR_EL1)] | unique | length) == 1),
            sysfs_identification_homogeneous:
                (([.cpus[].sysfs_identification] | unique | length) == 1)
        },
        observations: {
            mpidr_userspace_values_available:
                ([.cpus[].registers.MPIDR_EL1.status] |
                    all(. == "available")),
            mpidr_userspace_values_unique:
                (([.cpus[].registers.MPIDR_EL1.status] |
                    all(. == "available")) and
                 (([.cpus[].registers.MPIDR_EL1.value] | unique | length) ==
                  $requested_smp))
        }
    }' "$JSON_TMP" > "$FINAL_TMP"

if rg -qi 'machineid|bootid|serial[_ -]?number' "$FINAL_TMP"; then
    echo "guest evidence contains a prohibited host or VM identifier" >&2
    exit 1
fi

CONSISTENCY_STATUS=0
if ! jq -e '
    .run.safety.snapshot == true and
    .run.safety.source_drive_read_only == true and
    ([.consistency[]] | all(. == true))
' "$FINAL_TMP" >/dev/null; then
    CONSISTENCY_STATUS=1
fi

mv "$FINAL_TMP" "$JSON_OUT"
echo "guest CPU fingerprint: $JSON_OUT"
echo "console log: $LOG"

if [ "$CONSISTENCY_STATUS" -ne 0 ]; then
    echo "guest evidence was preserved, but one or more consistency checks failed" >&2
    exit "$CONSISTENCY_STATUS"
fi

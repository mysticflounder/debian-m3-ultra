#!/bin/bash
# Collect the Phase 3 host/guest CPU evidence matrix sequentially.
#
#   ./scripts/cpu-probe-matrix.sh
#
# Environment: SMP_LIST (default "1 8 16 24 32"), OUT_DIR, MEM, QEMU,
#              CC, HOST_CPU_NAME.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
OUT_ROOT="$HERE/out"
SMP_LIST="${SMP_LIST:-1 8 16 24 32}"
OUT_DIR_INPUT="${OUT_DIR:-out/cpu-matrix}"

if [ -L "$OUT_ROOT" ]; then
    echo "refusing symlinked output root: $OUT_ROOT" >&2
    exit 1
fi
mkdir -p "$OUT_ROOT"

case "$OUT_DIR_INPUT" in
    "$OUT_ROOT"/*) OUT_DIR_NAME="${OUT_DIR_INPUT#"$OUT_ROOT/"}" ;;
    out/*) OUT_DIR_NAME="${OUT_DIR_INPUT#out/}" ;;
    *)
        echo "OUT_DIR must be a direct child of $OUT_ROOT: $OUT_DIR_INPUT" >&2
        exit 1
        ;;
esac
case "$OUT_DIR_NAME" in
    ''|.|..|*/*|*[!A-Za-z0-9._-]*)
        echo "OUT_DIR must use one safe directory name under $OUT_ROOT: $OUT_DIR_INPUT" >&2
        exit 1
        ;;
esac
OUT_DIR_PATH="$OUT_ROOT/$OUT_DIR_NAME"
if [ -L "$OUT_DIR_PATH" ] || { [ -e "$OUT_DIR_PATH" ] && [ ! -d "$OUT_DIR_PATH" ]; }; then
    echo "refusing non-directory or symlinked output directory: $OUT_DIR_PATH" >&2
    exit 1
fi
mkdir -p "$OUT_DIR_PATH"

ROOTFS="$HERE/out/vmroot.ext4"
HOST_JSON="$OUT_DIR_PATH/host.json"
SUMMARY_JSON="$OUT_DIR_PATH/summary.json"
RUN_ROWS="$(mktemp "$OUT_DIR_PATH/.summary-runs.XXXXXX")"
SUMMARY_TMP="$(mktemp "$OUT_DIR_PATH/.summary.XXXXXX")"

cleanup() {
    rm -f "$RUN_ROWS" "$SUMMARY_TMP"
}
trap cleanup EXIT

if [ ! -r "$ROOTFS" ]; then
    echo "missing required input: $ROOTFS" >&2
    exit 1
fi

VALIDATED_SMP=""
RUN_COUNT=0
for smp in $SMP_LIST; do
    case "$smp" in
        ''|*[!0-9]*|0|0*)
            echo "each SMP value must be a positive canonical integer, got: $smp" >&2
            exit 1
            ;;
    esac
    case " $VALIDATED_SMP " in
        *" $smp "*)
            echo "duplicate SMP value would overwrite its artifacts: $smp" >&2
            exit 1
            ;;
    esac
    VALIDATED_SMP="${VALIDATED_SMP}${VALIDATED_SMP:+ }$smp"
    RUN_COUNT=$((RUN_COUNT + 1))
done

if [ "$RUN_COUNT" -eq 0 ]; then
    echo "SMP_LIST must contain at least one positive integer" >&2
    exit 1
fi

: > "$RUN_ROWS"

echo "hashing rootfs once"
ROOTFS_SHA256="$(shasum -a 256 "$ROOTFS" | awk '{print $1}')"
case "$ROOTFS_SHA256" in
    ''|*[!0-9a-f]*)
        echo "failed to compute rootfs SHA-256" >&2
        exit 1
        ;;
    *) ;;
esac
if [ "${#ROOTFS_SHA256}" -ne 64 ]; then
    echo "rootfs SHA-256 has an unexpected length" >&2
    exit 1
fi

echo "collecting host fingerprint"
BIN="$OUT_DIR_PATH/hvf-host-cpu" \
JSON_OUT="$HOST_JSON" \
    "$HERE/scripts/cpu-probe-host.sh"

if ! jq -e '
    type == "object" and
    .schema_version == 1 and
    (.host | type == "object") and
    (.feature_registers | type == "array") and
    (.ccsidr_el1 | type == "array")
' "$HOST_JSON" >/dev/null; then
    echo "host fingerprint failed matrix validation" >&2
    exit 1
fi
HOST_SHA256="$(shasum -a 256 "$HOST_JSON" | awk '{print $1}')"

# Deliberately sequential: cpu-probe-vm.sh owns vmroot.ext4 for each run.
for smp in $VALIDATED_SMP; do
    guest_name="guest-smp${smp}.json"
    log_name="guest-smp${smp}.log"
    guest_json="$OUT_DIR_PATH/$guest_name"
    guest_log="$OUT_DIR_PATH/$log_name"

    echo "collecting ${smp}-vCPU guest fingerprint"
    SMP="$smp" \
    ROOTFS_SHA256="$ROOTFS_SHA256" \
    JSON_OUT="$guest_json" \
    LOG="$guest_log" \
        "$HERE/scripts/cpu-probe-vm.sh"

    if ! jq -e --argjson smp "$smp" --arg rootfs_sha256 "$ROOTFS_SHA256" '
        type == "object" and
        .schema_version == 2 and
        .read_only == true and
        .run.requested_smp == $smp and
        (.cpus | type == "array") and
        (.cpus | length) == $smp and
        .run.inputs.rootfs.sha256 == $rootfs_sha256 and
        .run.safety.snapshot == true and
        .run.safety.source_drive_read_only == true and
        .run.safety.host_privilege_required == false and
        (.consistency | type == "object") and
        (.consistency | length) > 0 and
        ([.consistency[]] | all(. == true))
    ' "$guest_json" >/dev/null; then
        echo "${smp}-vCPU guest fingerprint failed matrix validation" >&2
        exit 1
    fi

    guest_sha256="$(shasum -a 256 "$guest_json" | awk '{print $1}')"
    log_sha256="$(shasum -a 256 "$guest_log" | awk '{print $1}')"

    jq -c \
        --arg json_path "$guest_name" \
        --arg json_sha256 "$guest_sha256" \
        --arg log_path "$log_name" \
        --arg log_sha256 "$log_sha256" \
        '{
            requested_smp: .run.requested_smp,
            observed_cpu_count: (.cpus | length),
            artifacts: {
                guest: {path: $json_path, sha256: $json_sha256},
                console_log: {path: $log_path, sha256: $log_sha256}
            },
            safety: .run.safety,
            consistency: .consistency,
            mpidr_observation: {
                userspace_values_available:
                    .observations.mpidr_userspace_values_available,
                userspace_values_unique:
                    .observations.mpidr_userspace_values_unique,
                values: [.cpus[].registers.MPIDR_EL1.value]
            },
            _hwcap_contract: {
                AT_HWCAP: .auxv.AT_HWCAP,
                AT_HWCAP2: .auxv.AT_HWCAP2,
                HWCAP_CPUID: .auxv.HWCAP_CPUID,
                HWCAP_CPUID_status: .auxv.HWCAP_CPUID_status
            },
            _first_cpu_register_contract:
                (.cpus[0].registers | del(.MPIDR_EL1)),
            _first_cpu_sysfs_identification:
                .cpus[0].sysfs_identification
        }' "$guest_json" >> "$RUN_ROWS"
done

jq -s \
    --arg host_path "host.json" \
    --arg host_sha256 "$HOST_SHA256" \
    --arg rootfs_sha256 "$ROOTFS_SHA256" \
    --argjson expected_runs "$RUN_COUNT" '
    . as $rows |
    {
        schema_version: 1,
        host: {path: $host_path, sha256: $host_sha256},
        rootfs_sha256: $rootfs_sha256,
        configured_smp: [$rows[].requested_smp],
        runs: [
            $rows[] |
            del(._hwcap_contract,
                ._first_cpu_register_contract,
                ._first_cpu_sysfs_identification)
        ],
        cross_run_checks: {
            all_configured_runs_present: (($rows | length) == $expected_runs),
            hwcap_identical:
                (([$rows[]._hwcap_contract] | unique | length) == 1),
            first_cpu_register_contract_excluding_mpidr_identical:
                (([$rows[]._first_cpu_register_contract] | unique | length) == 1),
            first_cpu_sysfs_identification_identical:
                (([$rows[]._first_cpu_sysfs_identification] | unique | length) == 1)
        }
    }
' "$RUN_ROWS" > "$SUMMARY_TMP"

mv "$SUMMARY_TMP" "$SUMMARY_JSON"

if ! jq -e --argjson expected_runs "$RUN_COUNT" '
    type == "object" and
    .schema_version == 1 and
    (.configured_smp | length) == $expected_runs and
    (.runs | length) == $expected_runs and
    ([.cross_run_checks[]] | all(. == true))
' "$SUMMARY_JSON" >/dev/null; then
    echo "cross-run CPU contract differs; individual evidence was preserved" >&2
    exit 1
fi

echo "CPU matrix complete: $SUMMARY_JSON"

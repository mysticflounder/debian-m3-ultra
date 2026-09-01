#!/bin/bash
# Compare the host HVF register fingerprint with CPU 0 from one guest matrix run.
# This script only reads evidence files and writes REPORT_JSON; it never starts QEMU.
#
# Environment: HOST_JSON, GUEST_JSON, REPORT_JSON, SUMMARY_JSON.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
OUT_ROOT="$HERE/out"
HOST_JSON_INPUT="${HOST_JSON:-out/cpu-matrix/host.json}"
GUEST_JSON_INPUT="${GUEST_JSON:-out/cpu-matrix/guest-smp8.json}"
REPORT_JSON_INPUT="${REPORT_JSON:-out/cpu-matrix/gap-report.json}"

resolve_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *)  printf '%s/%s\n' "$HERE" "$1" ;;
    esac
}

if [ -L "$OUT_ROOT" ]; then
    echo "refusing symlinked output root: $OUT_ROOT" >&2
    exit 1
fi
mkdir -p "$OUT_ROOT"

resolve_safe_report() {
    local input candidate relative directory_name file_name report_dir link_count

    input="$1"
    candidate="$(resolve_path "$input")"
    case "$candidate/" in
        *"/../"*|*"/./"*|*"//"*)
            echo "report path contains an unsafe component: $input" >&2
            return 1
            ;;
    esac
    case "$candidate" in
        "$OUT_ROOT"/*) relative="${candidate#"$OUT_ROOT/"}" ;;
        *)
            echo "REPORT_JSON must stay under $OUT_ROOT: $input" >&2
            return 1
            ;;
    esac
    case "$relative" in
        */*)
            directory_name="${relative%/*}"
            file_name="${relative##*/}"
            ;;
        *)
            directory_name=""
            file_name="$relative"
            ;;
    esac
    case "$directory_name" in
        '' ) report_dir="$OUT_ROOT" ;;
        .|..|*/*|*[!A-Za-z0-9._-]*)
            echo "REPORT_JSON may use at most one safe directory under $OUT_ROOT: $input" >&2
            return 1
            ;;
        *) report_dir="$OUT_ROOT/$directory_name" ;;
    esac
    case "$file_name" in
        ''|.|..|*[!A-Za-z0-9._-]*)
            echo "REPORT_JSON has an unsafe file name: $input" >&2
            return 1
            ;;
    esac
    if [ -L "$report_dir" ] || { [ -e "$report_dir" ] && [ ! -d "$report_dir" ]; }; then
        echo "refusing non-directory or symlinked report directory: $report_dir" >&2
        return 1
    fi
    mkdir -p "$report_dir"
    if [ -L "$candidate" ] || { [ -e "$candidate" ] && [ ! -f "$candidate" ]; }; then
        echo "refusing non-regular or symlinked report output: $candidate" >&2
        return 1
    fi
    if [ -e "$candidate" ]; then
        link_count="$(stat -f '%l' "$candidate")"
        if [ "$link_count" -ne 1 ]; then
            echo "refusing multiply linked report output: $candidate" >&2
            return 1
        fi
    fi
    printf '%s\n' "$candidate"
}

HOST_JSON_PATH="$(resolve_path "$HOST_JSON_INPUT")"
GUEST_JSON_PATH="$(resolve_path "$GUEST_JSON_INPUT")"
REPORT_JSON_PATH="$(resolve_safe_report "$REPORT_JSON_INPUT")"
SUMMARY_JSON_INPUT="${SUMMARY_JSON:-out/cpu-matrix/summary.json}"
SUMMARY_JSON_PATH="$(resolve_path "$SUMMARY_JSON_INPUT")"

for input in "$HOST_JSON_PATH" "$GUEST_JSON_PATH"; do
    if [ ! -r "$input" ]; then
        echo "missing required input: $input" >&2
        exit 1
    fi
done

sha256_file() {
    local digest remainder

    IFS=' ' read -r digest remainder < <(shasum -a 256 "$1")
    case "$digest" in
        ''|*[!0-9a-f]*) return 1 ;;
    esac
    if [ "${#digest}" -ne 64 ]; then
        return 1
    fi
    printf '%s\n' "$digest"
}

HOST_SHA256="$(sha256_file "$HOST_JSON_PATH")"
GUEST_SHA256="$(sha256_file "$GUEST_JSON_PATH")"

# The comparison contract is deliberately narrower than the complete probe
# schemas. It rejects malformed inputs while allowing a guest register to be
# absent so that absence can be represented as raw_result "missing".
if ! jq -e '
    def host_names: [
        "ID_AA64PFR0_EL1", "ID_AA64PFR1_EL1",
        "ID_AA64DFR0_EL1", "ID_AA64DFR1_EL1",
        "ID_AA64ISAR0_EL1", "ID_AA64ISAR1_EL1",
        "ID_AA64MMFR0_EL1", "ID_AA64MMFR1_EL1",
        "ID_AA64MMFR2_EL1", "CTR_EL0", "CLIDR_EL1", "DCZID_EL0",
        "ID_AA64SMFR0_EL1", "ID_AA64ZFR0_EL1"
    ];
    def hex64: type == "string" and test("^0x[0-9a-f]{16}$");
    type == "object" and
    .schema_version == 1 and
    .config.status == "ok" and
    (.host | type == "object") and
    (.feature_registers | type == "array") and
    (.feature_registers | length) == 14 and
    ([.feature_registers[].name] == host_names) and
    (([.feature_registers[].name] | unique | length) == 14) and
    ([.feature_registers[] |
        type == "object" and
        (.name | type == "string") and
        (.status == "ok" or .status == "error") and
        (if .status == "ok" then (.value | hex64) else .value == null end)
    ] | all)
' "$HOST_JSON_PATH" >/dev/null; then
    echo "host fingerprint failed strict comparison validation: $HOST_JSON_PATH" >&2
    exit 1
fi

if ! jq -e '
    def valid_register:
        type == "object" and
        (.status == "available" or .status == "unavailable") and
        (if .status == "available"
         then (.value | type == "string" and test("^0x[0-9a-f]{16}$"))
         else .value == null
         end);
    type == "object" and
    .schema_version == 2 and
    .read_only == true and
    (.run.requested_smp | type == "number" and . >= 1 and floor == .) and
    .run.safety.snapshot == true and
    .run.safety.source_drive_read_only == true and
    .run.safety.host_privilege_required == false and
    (.cpus | type == "array") and
    (.cpus | length) == .run.requested_smp and
    (.cpus | length) > 0 and
    ([.cpus[] |
        (.requested_cpu | type == "number") and
        (.registers | type == "object") and
        ([.registers[] | valid_register] | all)
    ] | all) and
    (.consistency | type == "object") and
    (.consistency | length) > 0 and
    ([.consistency[] | type == "boolean" and .] | all)
' "$GUEST_JSON_PATH" >/dev/null; then
    echo "guest fingerprint failed strict comparison validation: $GUEST_JSON_PATH" >&2
    exit 1
fi

SUMMARY_SOURCE="/dev/null"
SUMMARY_SHA256=""
if [ -e "$SUMMARY_JSON_PATH" ]; then
    if [ ! -r "$SUMMARY_JSON_PATH" ]; then
        echo "matrix summary exists but is not readable: $SUMMARY_JSON_PATH" >&2
        exit 1
    fi
    SUMMARY_SHA256="$(sha256_file "$SUMMARY_JSON_PATH")"
    SUMMARY_SOURCE="$SUMMARY_JSON_PATH"

    if ! jq -e \
        --arg host_sha256 "$HOST_SHA256" \
        --arg guest_sha256 "$GUEST_SHA256" \
        --slurpfile guest "$GUEST_JSON_PATH" '
        def sha256: type == "string" and test("^[0-9a-f]{64}$");
        type == "object" and
        .schema_version == 1 and
        (.host | type == "object") and
        (.host.sha256 | sha256) and
        .host.sha256 == $host_sha256 and
        (.rootfs_sha256 | sha256) and
        .rootfs_sha256 == $guest[0].run.inputs.rootfs.sha256 and
        (.configured_smp | type == "array") and
        (.configured_smp | length) > 0 and
        ((.configured_smp | unique | length) == (.configured_smp | length)) and
        ([.configured_smp[] | type == "number" and . >= 1 and floor == .] | all) and
        (.runs | type == "array") and
        (.runs | length) == (.configured_smp | length) and
        ([.runs[].requested_smp] == .configured_smp) and
        ([.runs[] |
            .observed_cpu_count == .requested_smp and
            (.artifacts.guest.sha256 | sha256) and
            .safety.snapshot == true and
            .safety.source_drive_read_only == true and
            .safety.host_privilege_required == false and
            (.consistency | type == "object") and
            (.consistency | length) > 0 and
            ([.consistency[] | type == "boolean" and .] | all)
        ] | all) and
        ([.runs[] |
            select(.requested_smp == $guest[0].run.requested_smp) |
            .artifacts.guest.sha256
        ] == [$guest_sha256]) and
        (.cross_run_checks | type == "object") and
        (.cross_run_checks | length) > 0 and
        ([.cross_run_checks[] | type == "boolean" and .] | all)
    ' "$SUMMARY_JSON_PATH" >/dev/null; then
        echo "matrix summary failed strict cross-run validation: $SUMMARY_JSON_PATH" >&2
        exit 1
    fi
fi

REPORT_DIR="${REPORT_JSON_PATH%/*}"
REPORT_TMP="$(mktemp "$REPORT_DIR/.cpu-probe-gap-report.XXXXXX")"
cleanup() {
    rm -f "$REPORT_TMP"
}
trap cleanup EXIT

jq -n \
    --arg host_path "$HOST_JSON_INPUT" \
    --arg host_sha256 "$HOST_SHA256" \
    --arg guest_path "$GUEST_JSON_INPUT" \
    --arg guest_sha256 "$GUEST_SHA256" \
    --arg summary_path "$SUMMARY_JSON_INPUT" \
    --arg summary_sha256 "$SUMMARY_SHA256" \
    --slurpfile host "$HOST_JSON_PATH" \
    --slurpfile guest "$GUEST_JSON_PATH" \
    --slurpfile summary "$SUMMARY_SOURCE" '
    def changed_nibbles($host_value; $guest_value):
        [range(0; 16) as $nibble |
         ($host_value[(17 - $nibble):(18 - $nibble)]) as $host_nibble |
         ($guest_value[(17 - $nibble):(18 - $nibble)]) as $guest_nibble |
         select($host_nibble != $guest_nibble) |
         {
             lsb: ($nibble * 4),
             width: 4,
             host: ("0x" + $host_nibble),
             guest: ("0x" + $guest_nibble)
         }];

    def linux_el0_hidden_nibbles($name):
        if $name == "ID_AA64PFR0_EL1" then [28, 56, 60]
        elif $name == "ID_AA64PFR1_EL1" then [32]
        elif $name == "ID_AA64DFR0_EL1" then [12, 20, 28]
        elif $name == "ID_AA64ISAR0_EL1" then [56]
        elif $name == "ID_AA64ISAR1_EL1" then [40]
        elif $name == "ID_AA64MMFR0_EL1" then [0, 20, 28, 32, 36, 40, 44]
        elif $name == "ID_AA64MMFR1_EL1" then [12, 16, 20, 24, 28]
        elif $name == "ID_AA64MMFR2_EL1" then [0, 4, 12, 24, 36, 48, 60]
        else []
        end;

    ($host[0].feature_registers |
        reduce .[] as $register ({}; .[$register.name] = $register)) as $host_by_name |
    $guest[0].cpus[0].registers as $guest_by_name |
    [$host[0].feature_registers[].name as $name |
        $host_by_name[$name] as $host_register |
        $guest_by_name[$name] as $guest_register |
        (if $host_register == null or $guest_register == null then "missing"
         elif $host_register.status != "ok" then "host_unavailable"
         elif $guest_register.status != "available" then "guest_unavailable"
         elif $host_register.value == $guest_register.value then "exact"
         else "different"
         end) as $raw_result |
        (if $raw_result == "different"
         then changed_nibbles($host_register.value; $guest_register.value)
         else []
         end) as $changed_nibbles |
        ($changed_nibbles | map(.lsb)) as $changed_lsbs |
        (($raw_result == "different") and
         (($changed_lsbs | length) > 0) and
         ((($changed_lsbs - linux_el0_hidden_nibbles($name)) | length) == 0)) as $linux_el0_sanitized |
        {
            name: $name,
            host: {
                status: ($host_register.status // "missing"),
                value: ($host_register.value // null)
            },
            guest: {
                status: ($guest_register.status // "missing"),
                value: ($guest_register.value // null)
            },
            raw_result: $raw_result,
            classification:
                (if $raw_result == "exact" then "exact-el0-observation"
                 elif $linux_el0_sanitized then "linux-el0-sanitized"
                 elif $raw_result == "guest_unavailable" and $name == "CLIDR_EL1"
                 then "observation-unavailable"
                 else "pending"
                 end),
            reason:
                (if $linux_el0_sanitized then "linux_el0_cpu_feature_abi_sanitization"
                 elif $raw_result == "different" then "unexpected_field_difference"
                 elif $raw_result == "guest_unavailable" and $name == "CLIDR_EL1"
                 then "outside_linux_el0_cpu_feature_abi"
                 elif $raw_result == "guest_unavailable" then "linux_userspace_unavailable"
                 elif $raw_result == "host_unavailable" then "host_probe_unavailable"
                 elif $raw_result == "missing" then "input_register_missing"
                 else null
                 end),
            changed_nibbles: $changed_nibbles
        }
    ] as $rows |
    {
        schema_version: 2,
        inputs: {
            host: {path: $host_path, sha256: $host_sha256},
            guest: {path: $guest_path, sha256: $guest_sha256},
            summary:
                (if ($summary | length) == 1
                 then {path: $summary_path, sha256: $summary_sha256}
                 else {path: $summary_path, sha256: null}
                 end)
        },
        guest_run: {
            requested_smp: $guest[0].run.requested_smp,
            compared_cpu: $guest[0].cpus[0].requested_cpu
        },
        matrix: {
            summary_available: (($summary | length) == 1),
            configured_run_count:
                (if ($summary | length) == 1 then ($summary[0].configured_smp | length) else null end),
            recorded_run_count:
                (if ($summary | length) == 1 then ($summary[0].runs | length) else null end),
            cross_run_checks:
                (if ($summary | length) == 1 then $summary[0].cross_run_checks else null end)
        },
        registers: $rows,
        summary: {
            total: ($rows | length),
            exact: ([$rows[] | select(.raw_result == "exact")] | length),
            different: ([$rows[] | select(.raw_result == "different")] | length),
            guest_unavailable: ([$rows[] | select(.raw_result == "guest_unavailable")] | length),
            host_unavailable: ([$rows[] | select(.raw_result == "host_unavailable")] | length),
            missing: ([$rows[] | select(.raw_result == "missing")] | length),
            exact_el0_observation:
                ([$rows[] | select(.classification == "exact-el0-observation")] | length),
            linux_el0_sanitized:
                ([$rows[] | select(.classification == "linux-el0-sanitized")] | length),
            observation_unavailable:
                ([$rows[] | select(.classification == "observation-unavailable")] | length),
            pending: ([$rows[] | select(.classification == "pending")] | length)
        }
    }
' > "$REPORT_TMP"

if ! jq -e '
    type == "object" and
    .schema_version == 2 and
    (.registers | type == "array" and length == 14) and
    .summary.total == 14 and
    (.summary.exact + .summary.different + .summary.guest_unavailable +
     .summary.host_unavailable + .summary.missing) == .summary.total and
    (.summary.exact_el0_observation + .summary.linux_el0_sanitized +
     .summary.observation_unavailable + .summary.pending) == .summary.total
' "$REPORT_TMP" >/dev/null; then
    echo "generated gap report failed validation" >&2
    exit 1
fi

mv "$REPORT_TMP" "$REPORT_JSON_PATH"
trap - EXIT
echo "CPU register gap report complete: $REPORT_JSON_PATH"

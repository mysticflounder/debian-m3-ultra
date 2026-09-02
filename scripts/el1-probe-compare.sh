#!/bin/bash
# Compare one raw guest EL1 sample with the host HVF configuration-register
# sample. This classifies observations; it does not change QEMU or the guest.
#
#   ./scripts/el1-probe-compare.sh out/el1-probe-smp8.XXXXXX/evidence.json
#
# Environment: HOST_JSON (default out/cpu-matrix/host.json), REPORT_JSON.
set -euo pipefail
umask 077

HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
OUT="$HERE/out"
EL1_INPUT="${1:-}"
HOST_INPUT="${HOST_JSON:-out/cpu-matrix/host.json}"

if [ -z "$EL1_INPUT" ] || [ "$#" -gt 1 ]; then
    echo "usage: $0 EL1_EVIDENCE_JSON" >&2
    exit 2
fi

resolve_input() {
    local input=$1 candidate links

    case "$input" in
        /*) candidate="$input" ;;
        *) candidate="$HERE/$input" ;;
    esac
    if [ -L "$candidate" ] || [ ! -f "$candidate" ] || [ ! -r "$candidate" ]; then
        echo "input must be a readable regular non-symlink file: $candidate" >&2
        return 1
    fi
    links="$(stat -f '%l' "$candidate")"
    [ "$links" -eq 1 ] || {
        echo "input must have exactly one hard link: $candidate" >&2
        return 1
    }
    printf '%s\n' "$candidate"
}

HOST_PATH="$(resolve_input "$HOST_INPUT")"
EL1_PATH="$(resolve_input "$EL1_INPUT")"
REPORT_INPUT="${REPORT_JSON:-${EL1_PATH%/*}/host-comparison.json}"
case "$REPORT_INPUT" in
    /*) REPORT_PATH="$REPORT_INPUT" ;;
    *) REPORT_PATH="$HERE/$REPORT_INPUT" ;;
esac
case "$REPORT_PATH" in
    "$OUT"/*) ;;
    *) echo "REPORT_JSON must stay under $OUT" >&2; exit 1 ;;
esac
REPORT_PARENT="${REPORT_PATH%/*}"
[ -d "$REPORT_PARENT" ] && [ ! -L "$REPORT_PARENT" ] || {
    echo "report parent must be an existing non-symlink directory: $REPORT_PARENT" >&2
    exit 1
}
[ "$(cd "$REPORT_PARENT" && pwd -P)" = "$REPORT_PARENT" ] || {
    echo "report parent resolves through a symlink: $REPORT_PARENT" >&2
    exit 1
}
if [ -L "$REPORT_PATH" ] || { [ -e "$REPORT_PATH" ] && [ ! -f "$REPORT_PATH" ]; }; then
    echo "refusing non-regular or symlinked report: $REPORT_PATH" >&2
    exit 1
fi
if [ -e "$REPORT_PATH" ] && [ "$(stat -f '%l' "$REPORT_PATH")" -ne 1 ]; then
    echo "refusing multiply linked report: $REPORT_PATH" >&2
    exit 1
fi
for input in "$HOST_PATH" "$EL1_PATH"; do
    if [ "$REPORT_PATH" = "$input" ] ||
       { [ -e "$REPORT_PATH" ] && [ "$REPORT_PATH" -ef "$input" ]; }; then
        echo "report path collides with an input: $input" >&2
        exit 1
    fi
done

if ! jq -e '
    def expected_names: [
        "ID_AA64PFR0_EL1", "ID_AA64PFR1_EL1",
        "ID_AA64DFR0_EL1", "ID_AA64DFR1_EL1",
        "ID_AA64ISAR0_EL1", "ID_AA64ISAR1_EL1",
        "ID_AA64MMFR0_EL1", "ID_AA64MMFR1_EL1",
        "ID_AA64MMFR2_EL1", "CTR_EL0", "CLIDR_EL1", "DCZID_EL0",
        "ID_AA64SMFR0_EL1", "ID_AA64ZFR0_EL1"
    ];
    def hex24:
        .[-6:] | explode |
        reduce .[] as $digit
            (0;
             . * 16 +
             (if $digit >= 48 and $digit <= 57 then $digit - 48
              elif $digit >= 97 and $digit <= 102 then $digit - 87
              else error("non-hex digit") end));
    def clidr_ctype($root; $level):
        ($root.feature_registers[] | select(.name == "CLIDR_EL1") |
            .value | hex24) as $clidr |
        (($clidr / [1, 8, 64, 512, 4096, 32768, 262144][$level - 1]) |
            floor) % 8;
    . as $root |
    type == "object" and .schema_version == 1 and .config.status == "ok" and
    (.feature_registers | type == "array" and length == 14) and
    ([.feature_registers[].name] == expected_names) and
    all(.feature_registers[];
        .status == "ok" and (.value | test("^0x[0-9a-f]{16}$"))) and
    (.ccsidr_el1 | type == "array" and length == 2) and
    [.ccsidr_el1[].cache_type] == ["data_or_unified", "instruction"] and
    all(.ccsidr_el1[];
        ((keys | sort) == (["cache_type", "status", "values"] | sort)) and
        .status == "ok" and (.values | type == "array" and length == 8) and
        all(.values[]; test("^0x[0-9a-f]{16}$"))) and
    all(range(1; 8);
        . as $level |
        if clidr_ctype($root; $level) == 0 then
            all($root.ccsidr_el1[];
                .values[$level - 1] == "0x0000000000000000")
        elif clidr_ctype($root; $level) == 1 then
            ($root.ccsidr_el1[] | select(.cache_type == "data_or_unified") |
                .values[$level - 1]) == "0x0000000000000000"
        elif clidr_ctype($root; $level) == 2 or
             clidr_ctype($root; $level) == 4 then
            ($root.ccsidr_el1[] | select(.cache_type == "instruction") |
                .values[$level - 1]) == "0x0000000000000000"
        else clidr_ctype($root; $level) == 3 end)
' "$HOST_PATH" >/dev/null; then
    echo "host evidence failed strict validation: $HOST_PATH" >&2
    exit 1
fi

if ! jq -e '
    def expected_registers: [
        "MPIDR_EL1", "CLIDR_EL1", "CTR_EL0", "DCZID_EL0",
        "ID_AA64PFR0_EL1", "ID_AA64PFR1_EL1",
        "ID_AA64DFR0_EL1", "ID_AA64DFR1_EL1",
        "ID_AA64ISAR0_EL1", "ID_AA64ISAR1_EL1",
        "ID_AA64MMFR0_EL1", "ID_AA64MMFR1_EL1",
        "ID_AA64MMFR2_EL1", "ID_AA64ZFR0_EL1", "ID_AA64SMFR0_EL1"
    ];
    def expected_consistency: [
        "configured_cpu_count_matches", "observed_cpu_ids_match",
        "mpidr_values_unique", "register_contract_homogeneous",
        "cache_contract_homogeneous"
    ];
    def hex24:
        .[-6:] | explode |
        reduce .[] as $digit
            (0;
             . * 16 +
             (if $digit >= 48 and $digit <= 57 then $digit - 48
              elif $digit >= 97 and $digit <= 102 then $digit - 87
              else error("non-hex digit") end));
    def clidr_ctype($value; $level):
        ($value | hex24) as $clidr |
        (($clidr / [1, 8, 64, 512, 4096, 32768, 262144][$level - 1]) |
            floor) % 8;
    def cache_group_valid:
        length >= 1 and
        (map(.ctype) | unique | length) == 1 and
        .[0].ctype as $ctype |
        if $ctype == 1 then
            length == 1 and .[0].ind == 1 and .[0].cache_type == "instruction"
        elif $ctype == 2 or $ctype == 4 then
            length == 1 and .[0].ind == 0 and .[0].cache_type == "data_or_unified"
        elif $ctype == 3 then
            length == 2 and [.[].ind] == [0, 1] and
            [.[].cache_type] == ["data_or_unified", "instruction"]
        else false
        end;
    def cache_entry_valid:
        (.level | type == "number" and floor == . and . >= 1 and . <= 7) and
        (.ctype | type == "number" and floor == . and . >= 1 and . <= 4) and
        (.ind == 0 or .ind == 1) and
        .selector == ((.level - 1) * 2 + .ind) and
        ((.ind == 0 and .cache_type == "data_or_unified" and
            (.ctype == 2 or .ctype == 3 or .ctype == 4)) or
         (.ind == 1 and .cache_type == "instruction" and
            (.ctype == 1 or .ctype == 3))) and
        ((.status == "read" and (.value | test("^0x[0-9a-f]{16}$"))) or
         (.status == "not_read" and .value == null));
    def required_safety: [
        .run.safety.host_privilege_required == false,
        .run.safety.explicit_disposable_overlay == true,
        .run.safety.root_backing_opened_via_overlay == true,
        .run.safety.build_drive_read_only == true,
        .run.safety.source_drive_read_only == true,
        .run.safety.network_disabled == true,
        .run.safety.monitor_disabled == true,
        .run.safety.firmware_or_pflash_attached == false,
        .run.safety.host_devices_attached == false,
        .run.safety.protected_inputs_unchanged == true,
        .run.safety.overlay_removed_after_shutdown == true
    ];
    type == "object" and .schema_version == 2 and
    (.requested_smp | type == "number" and . >= 1 and floor == .) and
    (.cpus | length) == .requested_smp and
    (.cache_row_count | type == "number" and floor == . and . >= 0) and
    .cache_row_count == ([.cpus[].cache_registers.entries[]] | length) and
    (required_safety | all) and
    ((.consistency | keys | sort) == (expected_consistency | sort)) and
    ([.consistency[]] | all(. == true)) and
    all(.cpus[];
        . as $cpu |
        .status == "read" and
        (.registers | type == "object" and length == 15) and
        ((.registers | keys | sort) == (expected_registers | sort)) and
        all(.registers[];
            (.status == "read" and (.value | test("^0x[0-9a-f]{16}$"))) or
            (.status == "not_read" and .value == null)) and
        (.cache_registers | type == "object") and
        ((.cache_registers | keys | sort) ==
            (["selector_before", "selector_after", "selector_restored", "entries"] | sort)) and
        (.cache_registers.selector_before | test("^0x[0-9a-f]{16}$")) and
        .cache_registers.selector_after == .cache_registers.selector_before and
        .cache_registers.selector_restored == true and
        (.cache_registers.entries | type == "array") and
        ([.cache_registers.entries[] | [.level, .cache_type] | join(":")] |
            unique | length) == (.cache_registers.entries | length) and
        all(.cache_registers.entries[];
            ((keys | sort) ==
                (["level", "ctype", "cache_type", "ind", "selector", "status", "value"] | sort)) and
            cache_entry_valid) and
        all(.cache_registers.entries | group_by(.level)[]; cache_group_valid) and
        all(range(1; 8);
            clidr_ctype($cpu.registers.CLIDR_EL1.value; .) <= 4) and
        ([range(1; 8) as $level |
            clidr_ctype($cpu.registers.CLIDR_EL1.value; $level) as $ctype |
            select($ctype >= 1 and $ctype <= 4) | [$level, $ctype]] ==
         [$cpu.cache_registers.entries | group_by(.level)[] |
            [.[0].level, .[0].ctype]]))
' "$EL1_PATH" >/dev/null; then
    echo "EL1 evidence failed strict validation: $EL1_PATH" >&2
    exit 1
fi

sha256_file() {
    shasum -a 256 "$1" | awk '{print $1}'
}

HOST_SHA256="$(sha256_file "$HOST_PATH")"
EL1_SHA256="$(sha256_file "$EL1_PATH")"
TMP="$(mktemp "$REPORT_PARENT/.host-comparison.XXXXXX")"
cleanup() { rm -f -- "$TMP"; }
trap cleanup EXIT

jq -n \
    --slurpfile host "$HOST_PATH" \
    --slurpfile el1 "$EL1_PATH" \
    --arg host_path "$HOST_PATH" \
    --arg host_sha256 "$HOST_SHA256" \
    --arg el1_path "$EL1_PATH" \
    --arg el1_sha256 "$EL1_SHA256" '
    def host_rows: $host[0].feature_registers;
    def guest_regs: $el1[0].cpus[0].registers;
    def guest_cache_entries: $el1[0].cpus[0].cache_registers.entries;
    def hex24:
        .[-6:] | explode |
        reduce .[] as $digit
            (0;
             . * 16 +
             (if $digit >= 48 and $digit <= 57 then $digit - 48
              elif $digit >= 97 and $digit <= 102 then $digit - 87
              else error("non-hex digit") end));
    def host_clidr_ctype($root; $level):
        ($root.feature_registers[] | select(.name == "CLIDR_EL1") |
            .value | hex24) as $clidr |
        (($clidr / [1, 8, 64, 512, 4096, 32768, 262144][$level - 1]) |
            floor) % 8;
    def classify($h; $g):
        if $g.status == "not_read" and
           ($h.name == "ID_AA64ZFR0_EL1" or $h.name == "ID_AA64SMFR0_EL1") and
           $h.value == "0x0000000000000000"
        then "feature_absent_not_read"
        elif $g.status == "read" and $h.value == $g.value
        then "exact_raw_match"
        elif $h.name == "ID_AA64DFR0_EL1" and
             $h.value == "0x0000000010305006" and
             $g.value == "0x0000000010305106"
        then "known_hvf_minimal_virtual_pmu"
        else "difference_requires_investigation"
        end;
    def classify_cache($host_present; $host_status; $host_value; $guest):
        if ($host_present | not) or $host_status != "ok" or
           $guest.status != "read"
        then "unavailable"
        elif $host_value == $guest.value
        then "exact"
        else "mismatch"
        end;
    $host[0] as $host_root |
    [host_rows[] as $h |
        (guest_regs[$h.name] // {status: "not_read", value: null}) as $g |
        {
            name: $h.name,
            host_hvf_config_value: $h.value,
            guest_el1_status: $g.status,
            guest_el1_value: $g.value,
            classification: classify($h; $g),
            qemu_patch_candidate:
                (classify($h; $g) == "difference_requires_investigation")
        }
    ] as $rows |
    [guest_cache_entries[] as $guest |
        ($host_root.ccsidr_el1[] |
            select(.cache_type == $guest.cache_type)) as $host_cache |
        (host_clidr_ctype($host_root; $guest.level) != 0) as $host_present |
        (if $host_present
         then $host_cache.values[$guest.level - 1]
         else null
         end) as $host_value |
        {
            level: $guest.level,
            cache_type: $guest.cache_type,
            ctype: $guest.ctype,
            ind: $guest.ind,
            selector: $guest.selector,
            host_level_present: $host_present,
            host_status: (if $host_present then $host_cache.status else "unavailable" end),
            host_value: $host_value,
            guest_status: $guest.status,
            guest_value: $guest.value,
            classification:
                classify_cache($host_present; $host_cache.status;
                    $host_value; $guest)
        }
    ] as $cache_rows |
    {
        schema_version: 2,
        inputs: {
            host: {path: $host_path, sha256: $host_sha256},
            guest_el1: {path: $el1_path, sha256: $el1_sha256,
                        requested_smp: $el1[0].requested_smp}
        },
        comparison_scope:
            "HVF configuration API versus raw EL1 values from an instantiated QEMU/HVF vCPU",
        rows: $rows,
        cache_rows: $cache_rows,
        summary: {
            exact_raw_matches: ([$rows[] | select(.classification == "exact_raw_match")] | length),
            feature_absent_not_read: ([$rows[] | select(.classification == "feature_absent_not_read")] | length),
            known_hvf_minimal_virtual_pmu: ([$rows[] | select(.classification == "known_hvf_minimal_virtual_pmu")] | length),
            differences_requiring_investigation: ([$rows[] | select(.classification == "difference_requires_investigation")] | length),
            qemu_patch_candidate: any($rows[]; .qemu_patch_candidate),
            cache_exact: ([$cache_rows[] | select(.classification == "exact")] | length),
            cache_mismatch: ([$cache_rows[] | select(.classification == "mismatch")] | length),
            cache_unavailable:
                ([$cache_rows[] | select(.classification == "unavailable")] | length)
        },
        cache_note:
            "Cache comparisons are descriptive only. Host CCSIDR zero padding at CLIDR-absent levels is classified unavailable, not as a match or mismatch.",
        pmu_note:
            "DFR0.PMUVer differs across HVF API layers: host config reports 0 while the instantiated guest exposes QEMU/HVF minimal virtual PMU version 1. Instrument the instantiated-vCPU path before proposing a patch."
    }
' > "$TMP"

if ! jq -e '
    .schema_version == 2 and
    .summary.exact_raw_matches == 11 and
    .summary.feature_absent_not_read == 2 and
    .summary.known_hvf_minimal_virtual_pmu == 1 and
    .summary.differences_requiring_investigation == 0 and
    .summary.qemu_patch_candidate == false and
    (.cache_rows | type == "array") and
    ([.cache_rows[] | [.level, .cache_type] | join(":")] | unique | length) ==
        (.cache_rows | length) and
    all(.cache_rows[];
        ((keys | sort) ==
            (["level", "cache_type", "ctype", "ind", "selector",
              "host_level_present", "host_status", "host_value",
              "guest_status", "guest_value", "classification"] | sort)) and
        (.classification == "exact" or .classification == "mismatch" or
            .classification == "unavailable") and
        (.level | type == "number" and floor == . and . >= 1 and . <= 7) and
        (.ctype | type == "number" and floor == . and . >= 1 and . <= 4) and
        (.ind == 0 or .ind == 1) and
        .selector == ((.level - 1) * 2 + .ind) and
        (.cache_type == "data_or_unified" or .cache_type == "instruction") and
        ((.ind == 0 and .cache_type == "data_or_unified") or
         (.ind == 1 and .cache_type == "instruction")) and
        (.host_level_present | type == "boolean") and
        (.host_status == "ok" or .host_status == "unavailable") and
        (.host_value == null or (.host_value | test("^0x[0-9a-f]{16}$"))) and
        (.guest_status == "read" or .guest_status == "not_read") and
        (.guest_value == null or (.guest_value | test("^0x[0-9a-f]{16}$"))) and
        (if .classification == "exact" then
             .host_level_present and .host_status == "ok" and
             .guest_status == "read" and .host_value == .guest_value
         elif .classification == "mismatch" then
             .host_level_present and .host_status == "ok" and
             .guest_status == "read" and .host_value != .guest_value
         else
             ((.host_level_present | not) or .host_status != "ok" or
              .guest_status != "read")
         end)) and
    (.summary.cache_exact + .summary.cache_mismatch +
        .summary.cache_unavailable) == (.cache_rows | length)
' "$TMP" >/dev/null; then
    echo "raw EL1 comparison found an unexpected difference; report not installed" >&2
    exit 1
fi

mv -- "$TMP" "$REPORT_PATH"
echo "EL1 host comparison: $REPORT_PATH"

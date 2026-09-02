#!/bin/bash
# Sequentially collect and compare the raw guest EL1 evidence matrix.
# Each el1-probe-vm.sh invocation owns the shared VM-root lock and uses its own
# disposable overlay.
#
#   ./scripts/el1-probe-matrix.sh
#
# Environment: SMP_LIST (default "1 8 16 24 32"), MEM (default 8G).
set -euo pipefail
set -f
umask 077

HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
OUT="$HERE/out"
SMP_LIST="${SMP_LIST:-1 8 16 24 32}"
MEM="${MEM:-8G}"
SUMMARY="$OUT/el1-probe-matrix-summary.json"

[ "$(id -u)" -ne 0 ] || {
    echo "refusing to run QEMU as host root" >&2
    exit 1
}
if [ -L "$OUT" ]; then
    echo "refusing symlinked output root: $OUT" >&2
    exit 1
fi
mkdir -p "$OUT"
[ "$(cd "$OUT" && pwd -P)" = "$OUT" ] || {
    echo "output root is not canonical: $OUT" >&2
    exit 1
}
if [ -L "$SUMMARY" ] || { [ -e "$SUMMARY" ] && [ ! -f "$SUMMARY" ]; }; then
    echo "refusing non-regular or symlinked summary: $SUMMARY" >&2
    exit 1
fi
if [ -e "$SUMMARY" ] && [ "$(stat -f '%l' "$SUMMARY")" -ne 1 ]; then
    echo "refusing multiply linked summary: $SUMMARY" >&2
    exit 1
fi

VALIDATED_SMP=""
RUN_COUNT=0
for smp in $SMP_LIST; do
    case "$smp" in
        ''|*[!0-9]*|0|0*)
            echo "each SMP value must be a positive canonical integer: $smp" >&2
            exit 1
            ;;
    esac
    [ "$smp" -le 64 ] || {
        echo "SMP exceeds the 64-vCPU safety limit: $smp" >&2
        exit 1
    }
    case " $VALIDATED_SMP " in
        *" $smp "*)
            echo "duplicate SMP value: $smp" >&2
            exit 1
            ;;
    esac
    VALIDATED_SMP="${VALIDATED_SMP}${VALIDATED_SMP:+ }$smp"
    RUN_COUNT=$((RUN_COUNT + 1))
done
[ "$RUN_COUNT" -gt 0 ] || {
    echo "SMP_LIST must contain at least one vCPU count" >&2
    exit 1
}

ROWS="$(mktemp "$OUT/.el1-matrix-rows.XXXXXX")"
RUN_OUTPUT="$(mktemp "$OUT/.el1-matrix-run.XXXXXX")"
SUMMARY_TMP="$(mktemp "$OUT/.el1-matrix-summary.XXXXXX")"
cleanup() {
    rm -f -- "$ROWS" "$RUN_OUTPUT" "$SUMMARY_TMP"
}
trap cleanup EXIT
: > "$ROWS"

sha256_file() {
    shasum -a 256 "$1" | awk '{print $1}'
}

for smp in $VALIDATED_SMP; do
    : > "$RUN_OUTPUT"
    echo "collecting raw EL1 evidence for ${smp} vCPU(s)"
    SMP="$smp" MEM="$MEM" "$HERE/scripts/el1-probe-vm.sh" | tee "$RUN_OUTPUT"

    evidence_count="$(awk '/^EL1 evidence: / {count++} END {print count+0}' "$RUN_OUTPUT")"
    [ "$evidence_count" -eq 1 ] || {
        echo "runner did not emit exactly one evidence path" >&2
        exit 1
    }
    evidence="$(awk '/^EL1 evidence: / {sub(/^EL1 evidence: /, ""); print}' "$RUN_OUTPUT")"
    case "$evidence" in
        "$OUT/el1-probe-smp${smp}."*/evidence.json) ;;
        *) echo "runner emitted an unexpected evidence path: $evidence" >&2; exit 1 ;;
    esac
    if [ -L "$evidence" ] || [ ! -f "$evidence" ] || [ ! -r "$evidence" ]; then
        echo "runner evidence is not a safe regular file: $evidence" >&2
        exit 1
    fi
    evidence_parent="${evidence%/*}"
    if [ -L "$evidence_parent" ] ||
       [ "$(cd "$evidence_parent" && pwd -P)" != "$evidence_parent" ]; then
        echo "runner evidence parent resolves unsafely: $evidence_parent" >&2
        exit 1
    fi
    [ "$(stat -f '%l' "$evidence")" -eq 1 ] || {
        echo "runner evidence must have exactly one hard link: $evidence" >&2
        exit 1
    }

    if ! jq -e --argjson smp "$smp" '
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
        .schema_version == 2 and .requested_smp == $smp and
        (.cpus | length) == $smp and
        (.cache_row_count | type == "number" and floor == . and . >= 0) and
        .cache_row_count == ([.cpus[].cache_registers.entries[]] | length) and
        ((.consistency | keys | sort) == (expected_consistency | sort)) and
        ([.consistency[]] | all(. == true)) and
        all(.cpus[];
            . as $cpu |
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
                [.[0].level, .[0].ctype]])) and
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
        .run.safety.overlay_removed_after_shutdown == true
    ' "$evidence" >/dev/null; then
        echo "EL1 evidence failed matrix validation: $evidence" >&2
        exit 1
    fi

    comparison="${evidence%/*}/host-comparison.json"
    REPORT_JSON="$comparison" "$HERE/scripts/el1-probe-compare.sh" "$evidence"
    register_contract_sha256="$(
        jq -cS '.cpus[0].registers | del(.MPIDR_EL1)' "$evidence" |
            shasum -a 256 | awk '{print $1}'
    )"
    cache_contract_sha256="$(
        jq -cS '.cpus[0].cache_registers.entries' "$evidence" |
            shasum -a 256 | awk '{print $1}'
    )"

    jq -nc \
        --argjson smp "$smp" \
        --arg evidence "$evidence" \
        --arg evidence_sha256 "$(sha256_file "$evidence")" \
        --arg comparison "$comparison" \
        --arg comparison_sha256 "$(sha256_file "$comparison")" \
        --arg register_contract_sha256 "$register_contract_sha256" \
        --arg cache_contract_sha256 "$cache_contract_sha256" \
        --slurpfile report "$comparison" '
        {
            requested_smp: $smp,
            evidence: {path: $evidence, sha256: $evidence_sha256},
            comparison: {
                path: $comparison,
                sha256: $comparison_sha256,
                schema_version: $report[0].schema_version,
                summary: $report[0].summary
            },
            register_contract_sha256: $register_contract_sha256,
            cache_contract_sha256: $cache_contract_sha256
        }
    ' >> "$ROWS"
done

jq -s \
    --arg collected_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg memory "$MEM" '
    . as $runs |
    {
        schema_version: 2,
        collected_at_utc: $collected_at,
        memory: $memory,
        run_count: ($runs | length),
        requested_smp_values: [$runs[].requested_smp],
        runs: $runs,
        consistency: {
            register_contract_homogeneous:
                (([$runs[].register_contract_sha256] | unique | length) == 1),
            cache_contract_homogeneous:
                (([$runs[].cache_contract_sha256] | unique | length) == 1),
            every_comparison_has_no_unexpected_difference:
                all($runs[];
                    .comparison.summary.differences_requiring_investigation == 0 and
                    .comparison.summary.qemu_patch_candidate == false)
        },
        safety_scope:
            "QEMU/HVF disposable guests only; project outputs and disposable overlays are the only intended host writes"
    }
' "$ROWS" > "$SUMMARY_TMP"

if ! jq -e '
    .schema_version == 2 and .run_count > 0 and
    ([.consistency[]] | all(. == true)) and
    all(.runs[];
        .comparison.schema_version == 2 and
        .comparison.summary.exact_raw_matches == 11 and
        .comparison.summary.feature_absent_not_read == 2 and
        .comparison.summary.known_hvf_minimal_virtual_pmu == 1 and
        (.comparison.summary.cache_exact | type == "number" and . >= 0) and
        (.comparison.summary.cache_mismatch | type == "number" and . >= 0) and
        (.comparison.summary.cache_unavailable | type == "number" and . >= 0))
' "$SUMMARY_TMP" >/dev/null; then
    echo "EL1 matrix consistency validation failed" >&2
    exit 1
fi

mv -- "$SUMMARY_TMP" "$SUMMARY"
echo "EL1 matrix summary: $SUMMARY"

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
            "mpidr_values_unique", "register_contract_homogeneous"
        ];
        .schema_version == 1 and .requested_smp == $smp and
        (.cpus | length) == $smp and
        ((.consistency | keys | sort) == (expected_consistency | sort)) and
        ([.consistency[]] | all(. == true)) and
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

    jq -nc \
        --argjson smp "$smp" \
        --arg evidence "$evidence" \
        --arg evidence_sha256 "$(sha256_file "$evidence")" \
        --arg comparison "$comparison" \
        --arg comparison_sha256 "$(sha256_file "$comparison")" \
        --arg register_contract_sha256 "$register_contract_sha256" \
        --slurpfile report "$comparison" '
        {
            requested_smp: $smp,
            evidence: {path: $evidence, sha256: $evidence_sha256},
            comparison: {
                path: $comparison,
                sha256: $comparison_sha256,
                summary: $report[0].summary
            },
            register_contract_sha256: $register_contract_sha256
        }
    ' >> "$ROWS"
done

jq -s \
    --arg collected_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg memory "$MEM" '
    . as $runs |
    {
        schema_version: 1,
        collected_at_utc: $collected_at,
        memory: $memory,
        run_count: ($runs | length),
        requested_smp_values: [$runs[].requested_smp],
        runs: $runs,
        consistency: {
            register_contract_homogeneous:
                (([$runs[].register_contract_sha256] | unique | length) == 1),
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
    .run_count > 0 and
    ([.consistency[]] | all(. == true)) and
    all(.runs[];
        .comparison.summary.exact_raw_matches == 11 and
        .comparison.summary.feature_absent_not_read == 2 and
        .comparison.summary.known_hvf_minimal_virtual_pmu == 1)
' "$SUMMARY_TMP" >/dev/null; then
    echo "EL1 matrix consistency validation failed" >&2
    exit 1
fi

mv -- "$SUMMARY_TMP" "$SUMMARY"
echo "EL1 matrix summary: $SUMMARY"

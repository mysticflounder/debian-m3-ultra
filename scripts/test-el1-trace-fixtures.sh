#!/bin/bash
# No-VM fixtures for the bounded EL1 trace-control parser and QMP checks.
set -euo pipefail
umask 077

HERE="$(cd "$(/usr/bin/dirname "$0")/.." && pwd -P)"
PARSER="$HERE/scripts/el1-trace-parser.sh"
[ -f "$PARSER" ] && [ ! -L "$PARSER" ] || exit 1

/bin/mkdir -p "$HERE/scratch"
fixture_dir="$(/usr/bin/mktemp -d "$HERE/scratch/el1-trace-fixtures.XXXXXX")"

source "$PARSER"
JQ=/usr/bin/jq
tests=0

write_markers() {
    local smp=$1 output=$2 nonzero=$3 cpu value
    : > "$output"
    for ((cpu = 0; cpu < smp; cpu++)); do
        printf 'EL1_PROBE_TRACE_CONTROL_ATTEMPT cpu=%d name=OSLSR_EL1\n' "$cpu" >> "$output"
        if [ "$nonzero" -eq 1 ]; then
            printf -v value '0x%016x' "$((cpu + 1))"
        else
            value=0x0000000000000000
        fi
        printf 'EL1_PROBE_TRACE_CONTROL_VALUE cpu=%d name=OSLSR_EL1 status=read value=%s\n' \
            "$cpu" "$value" >> "$output"
    done
}

expect_marker_valid() {
    local label=$1 smp=$2 input=$3 nonzero=$4 output="$fixture_dir/$1.json"
    parse_trace_control_json "$smp" "$input" "$output"
    "$JQ" -e --argjson smp "$smp" --argjson nonzero "$nonzero" '
      .schema_version == 1 and .requested_smp == $smp and
      .row_count == $smp and .all_reads_completed == true and
      (.samples|length) == $smp and
      all(.samples[]; .name == "OSLSR_EL1" and .status == "read" and
        (.value|test("^0x[0-9a-f]{16}$"))) and
      [.samples[].cpu] == [range(0; $smp)] and
      (if $nonzero == 0 then
         all(.samples[]; .value == "0x0000000000000000")
       else
         any(.samples[]; .value != "0x0000000000000000")
       end)
    ' "$output" >/dev/null
    tests=$((tests + 1))
}

expect_marker_rejected() {
    local label=$1 input=$2 smp=${3:-1} output="$fixture_dir/$1.json"
    printf '%s\n' '{"schema_version":1,"all_reads_completed":true}' > "$output"
    if parse_trace_control_json "$smp" "$input" "$output" >/dev/null 2>&1; then
        echo "accepted malformed trace-control fixture: $label" >&2
        exit 1
    fi
    [ ! -e "$output" ] || {
        echo "left output artifact after rejection: $label" >&2
        exit 1
    }
    tests=$((tests + 1))
}

valid_zero="$fixture_dir/valid-zero.log"
valid_nonzero="$fixture_dir/valid-nonzero.log"
valid_8="$fixture_dir/valid-8-nonzero.log"
write_markers 1 "$valid_zero" 0
write_markers 1 "$valid_nonzero" 1
write_markers 8 "$valid_8" 1
expect_marker_valid valid-zero 1 "$valid_zero" 0
expect_marker_valid valid-nonzero 1 "$valid_nonzero" 1
expect_marker_valid valid-8-nonzero 8 "$valid_8" 1

truncated="$fixture_dir/truncated.log"
/usr/bin/sed '$d' "$valid_zero" > "$truncated"
expect_marker_rejected truncated "$truncated"

reordered="$fixture_dir/reordered.log"
{
    /usr/bin/sed -n '2p' "$valid_zero"
    /usr/bin/sed -n '1p' "$valid_zero"
} > "$reordered"
expect_marker_rejected reordered "$reordered"

duplicate="$fixture_dir/duplicate.log"
{
    /usr/bin/sed -n '1p' "$valid_zero"
    /usr/bin/sed -n '1p' "$valid_zero"
} > "$duplicate"
expect_marker_rejected duplicate "$duplicate"

unknown="$fixture_dir/unknown.log"
/usr/bin/sed '1s/OSLSR_EL1/UNKNOWN_EL1/' "$valid_zero" > "$unknown"
expect_marker_rejected unknown "$unknown"

not_read="$fixture_dir/not-read.log"
/usr/bin/sed '2s/status=read/status=not_read/' "$valid_zero" > "$not_read"
expect_marker_rejected not-read "$not_read"

bad_value="$fixture_dir/bad-value.log"
/usr/bin/sed '2s/0000000000000000/000000000000000G/' "$valid_zero" > "$bad_value"
expect_marker_rejected bad-value "$bad_value"

qmp_valid="$fixture_dir/qmp-valid.jsonl"
{
    printf '%s\n' '{"QMP":{"version":1}}'
    printf '%s\n' '{"id":"trace-state","return":[{"name":"OSLSR_EL1","state":"enabled","extra":true}]}'
    printf '%s\n' '{"event":"RESUME"}'
} > "$qmp_valid"

expect_state_valid() {
    validate_trace_state_json "$1" trace-state OSLSR_EL1
    tests=$((tests + 1))
}

expect_state_rejected() {
    local label=$1 input=$2
    if validate_trace_state_json "$input" trace-state OSLSR_EL1 >/dev/null 2>&1; then
        echo "accepted malformed QMP state fixture: $label" >&2
        exit 1
    fi
    tests=$((tests + 1))
}

expect_state_valid "$qmp_valid"

qmp_error="$fixture_dir/qmp-error.jsonl"
printf '%s\n' '{"id":"trace-state","error":{"class":"GenericError","desc":"failed"}}' > "$qmp_error"
expect_state_rejected errors "$qmp_error"

qmp_duplicate="$fixture_dir/qmp-duplicate.jsonl"
{
    /usr/bin/sed -n '2p' "$qmp_valid"
    /usr/bin/sed -n '2p' "$qmp_valid"
} > "$qmp_duplicate"
expect_state_rejected duplicate-qmp "$qmp_duplicate"

qmp_disabled="$fixture_dir/qmp-disabled.jsonl"
/usr/bin/sed 's/"enabled"/"disabled"/' "$qmp_valid" > "$qmp_disabled"
expect_state_rejected disabled "$qmp_disabled"

qmp_missing="$fixture_dir/qmp-missing.jsonl"
printf '%s\n' '{"id":"other-request","return":[{"name":"OSLSR_EL1","state":"enabled"}]}' > "$qmp_missing"
expect_state_rejected missing "$qmp_missing"

qmp_extra="$fixture_dir/qmp-extra-event.jsonl"
printf '%s\n' '{"id":"trace-state","return":[{"name":"OSLSR_EL1","state":"enabled"},{"name":"OTHER","state":"enabled"}]}' > "$qmp_extra"
expect_state_rejected extraevent "$qmp_extra"

expect_trace_log_count() {
    local label=$1 expected=$2 input=$3
    if [ "$expected" -eq 1 ]; then
        validate_trace_log "$input"
    elif validate_trace_log "$input"; then
        echo "accepted invalid trace-log count: $label" >&2
        exit 1
    fi
    tests=$((tests + 1))
}

for count in 0 1 2 3; do
    log="$fixture_dir/trace-count-$count.log"
    : > "$log"
    for ((line = 0; line < count; line++)); do
        printf 'qmp_enter_query_status {"id":"trace-%d"}\n' "$line" >> "$log"
    done
    printf 'hvf_sysreg_read sysreg read 0x00000000 (op0=3 op1=0 crn=0 crm=0 op2=0) = 0x0000000000000000\n' >> "$log"
    if [ "$count" -eq 2 ]; then expected=1; else expected=0; fi
    expect_trace_log_count "count-$count" "$expected" "$log"
done

/bin/bash -n "$PARSER" "$0"
echo "EL1 trace fixtures passed: $tests cases; strict markers, QMP state, and trace-count checks"
echo "fixture artifacts: $fixture_dir"

#!/bin/bash
# No-VM fixtures for the bounded newer-ID marker parser.
set -euo pipefail
umask 077

HERE="$(cd "$(/usr/bin/dirname "$0")/.." && pwd -P)"
PARSER="$HERE/scripts/el1-new-id-parser.sh"
[ -f "$PARSER" ] && [ ! -L "$PARSER" ] || exit 1

/bin/mkdir -p "$HERE/scratch"
fixture_dir="$(/usr/bin/mktemp -d "$HERE/scratch/el1-new-id-fixtures.XXXXXX")"

source "$PARSER"
JQ=/usr/bin/jq
tests=0

write_valid() {
    local smp=$1 output=$2 nonzero=$3 cpu name value
    local names=(ID_AA64PFR2_EL1 ID_AA64ISAR2_EL1 ID_AA64MMFR3_EL1 ID_AA64MMFR4_EL1)
    : > "$output"
    for ((cpu = 0; cpu < smp; cpu++)); do
        for name in "${names[@]}"; do
            printf 'EL1_PROBE_NEW_ID_ATTEMPT cpu=%d name=%s\n' "$cpu" "$name" >> "$output"
            if [ "$nonzero" -eq 1 ]; then
                printf -v value '0x%016x' "$((cpu + 1))"
            else
                value=0x0000000000000000
            fi
            printf 'EL1_PROBE_NEW_ID_VALUE cpu=%d name=%s status=read value=%s\n' \
                "$cpu" "$name" "$value" >> "$output"
        done
    done
}

expect_valid() {
    local label=$1 smp=$2 input=$3 nonzero=$4 homogeneous=$5 output="$fixture_dir/$1.json"
    parse_new_id_json "$smp" "$input" "$output"
    "$JQ" -e --argjson smp "$smp" --argjson nonzero "$nonzero" \
      --argjson homogeneous "$homogeneous" '
      .schema_version == 1 and .requested_smp == $smp and
      .row_count == (4 * $smp) and .all_reads_completed == true and
      .register_contract_homogeneous == $homogeneous and
      (.cpus|length) == $smp and
      all(.cpus[]; (.registers|keys|length) == 4 and
        all(.registers[]; .status == "read" and
          (.value|test("^0x[0-9a-f]{16}$")))) and
      (if $nonzero == 0 then
         all(.cpus[].registers[]; .value == "0x0000000000000000")
       else
         any(.cpus[].registers[]; .value != "0x0000000000000000")
       end)
    ' "$output" >/dev/null
    tests=$((tests + 1))
}

expect_rejected() {
    local label=$1 input=$2 smp=${3:-1} output="$fixture_dir/$1.json"
    printf '%s\n' '{"schema_version":1,"all_reads_completed":true}' > "$output"
    if parse_new_id_json "$smp" "$input" "$output" >/dev/null 2>&1; then
        echo "accepted malformed newer-ID fixture: $label" >&2
        exit 1
    fi
    [ ! -s "$output" ] || {
        echo "left output artifact after rejection: $label" >&2
        exit 1
    }
    tests=$((tests + 1))
}

valid_zero="$fixture_dir/valid-zero.log"
valid_nonzero="$fixture_dir/valid-nonzero.log"
valid_8_zero="$fixture_dir/valid-8-zero.log"
valid_8_nonzero="$fixture_dir/valid-8-nonzero.log"
write_valid 1 "$valid_zero" 0
write_valid 1 "$valid_nonzero" 1
write_valid 8 "$valid_8_zero" 0
write_valid 8 "$valid_8_nonzero" 1
expect_valid valid-zero 1 "$valid_zero" 0 true
expect_valid valid-nonzero 1 "$valid_nonzero" 1 true
expect_valid valid-8-zero 8 "$valid_8_zero" 0 true
expect_valid valid-8-nonzero 8 "$valid_8_nonzero" 1 false

incomplete="$fixture_dir/incomplete-after-attempt.log"
/usr/bin/sed '$d' "$valid_zero" > "$incomplete"
expect_rejected incomplete-after-attempt "$incomplete"

trailing_partial="$fixture_dir/trailing-partial.log"
{
    /usr/bin/sed '$d' "$valid_zero"
    printf '%s' 'EL1_PROBE_NEW_ID_VALUE cpu=0 name=ID_AA64MMFR4_EL1 status=read value=0x000000000000000'
} > "$trailing_partial"
expect_rejected trailing-partial "$trailing_partial"

missing="$fixture_dir/missing-pair.log"
/usr/bin/sed '5,6d' "$valid_zero" > "$missing"
expect_rejected missing-pair "$missing"

duplicate="$fixture_dir/duplicate-marker.log"
{
    /usr/bin/sed -n '1,6p' "$valid_zero"
    /usr/bin/sed -n '5p' "$valid_zero"
    /usr/bin/sed -n '8p' "$valid_zero"
} > "$duplicate"
expect_rejected duplicate-marker "$duplicate"

extra="$fixture_dir/extra-marker.log"
{
    /bin/cat "$valid_zero"
    /usr/bin/sed -n '1p' "$valid_zero"
} > "$extra"
expect_rejected extra-marker "$extra"

wrongcpu="$fixture_dir/wrong-cpu.log"
/usr/bin/sed '2s/cpu=0/cpu=1/' "$valid_zero" > "$wrongcpu"
expect_rejected wrong-cpu "$wrongcpu"

reorder="$fixture_dir/reordered.log"
{
    /usr/bin/sed -n '3,4p' "$valid_zero"
    /usr/bin/sed -n '1,2p' "$valid_zero"
    /usr/bin/sed -n '5,8p' "$valid_zero"
} > "$reorder"
expect_rejected reordered "$reorder"

reversed_pair="$fixture_dir/reversed-pair.log"
{
    /usr/bin/sed -n '2p' "$valid_zero"
    /usr/bin/sed -n '1p' "$valid_zero"
    /usr/bin/sed -n '3,8p' "$valid_zero"
} > "$reversed_pair"
expect_rejected reversed-pair "$reversed_pair"

attempt_in_value="$fixture_dir/attempt-in-value-slot.log"
{
    /usr/bin/sed -n '1p' "$valid_zero"
    /usr/bin/sed -n '1p' "$valid_zero"
    /usr/bin/sed -n '3,8p' "$valid_zero"
} > "$attempt_in_value"
expect_rejected attempt-in-value-slot "$attempt_in_value"

value_in_attempt="$fixture_dir/value-in-attempt-slot.log"
{
    /usr/bin/sed -n '2p' "$valid_zero"
    /usr/bin/sed -n '2,8p' "$valid_zero"
} > "$value_in_attempt"
expect_rejected value-in-attempt-slot "$value_in_attempt"

unknown="$fixture_dir/unknown-register.log"
/usr/bin/sed '1s/ID_AA64PFR2_EL1/ID_AA64SOMETHING_EL1/' "$valid_zero" > "$unknown"
expect_rejected unknown-register "$unknown"

malformedhex="$fixture_dir/malformed-hex.log"
/usr/bin/sed '2s/0000000000000000/000000000000000G/' "$valid_zero" > "$malformedhex"
expect_rejected malformed-hex "$malformedhex"

exception="$fixture_dir/exception-status.log"
/usr/bin/sed '2s/status=read/status=exception/' "$valid_zero" > "$exception"
expect_rejected exception-status "$exception"

/bin/bash -n "$PARSER" "$0"
echo "EL1 newer-ID fixtures passed: $tests cases; strict ordered parser and failure cleanup"
echo "fixture artifacts: $fixture_dir"

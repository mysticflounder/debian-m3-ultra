#!/bin/bash
# Source-only fixtures for the selftest serial protocol and TAP composition.
# This script must never launch QEMU.
set -euo pipefail
umask 077

HERE="$(cd "$(/usr/bin/dirname "$0")/.." && pwd -P)"

# Import the real host validators/extractor without entering selftest_main.
SELFTEST_SOURCE_ONLY=1 source "$HERE/scripts/selftest-vm.sh"
trap - EXIT INT TERM HUP

AWK="${AWK:-/usr/bin/awk}"
JQ="${JQ:-/usr/bin/jq}"
VALIDATOR="$HERE/scripts/validate-kselftest.awk"
[ -f "$VALIDATOR" ] && [ ! -L "$VALIDATOR" ] || exit 1

/bin/mkdir -p "$HERE/scratch"
fixture_dir="$(/usr/bin/mktemp -d "$HERE/scratch/selftest-fixtures.XXXXXX")"
[ -d "$fixture_dir" ] && [ ! -L "$fixture_dir" ] || exit 1
tests=0

pass_case() { tests=$((tests + 1)); }

expect_valid() {
    local label=$1 expected=$2 file=$3 actual
    actual="$("$AWK" -f "$VALIDATOR" "$file")"
    [ "$actual" = "$expected" ] || {
        echo "unexpected parser output for $label: $actual" >&2
        exit 1
    }
    pass_case
}

expect_rejected() {
    local label=$1 file=$2
    if "$AWK" -f "$VALIDATOR" "$file" >/dev/null 2>&1; then
        echo "accepted rejected fixture: $label" >&2
        exit 1
    fi
    pass_case
}

expect_true() {
    local label=$1
    shift
    if ! "$@"; then
        echo "rejected valid fixture: $label" >&2
        exit 1
    fi
    pass_case
}

expect_false() {
    local label=$1
    shift
    if "$@"; then
        echo "accepted rejected fixture: $label" >&2
        exit 1
    fi
    pass_case
}

write_lines() {
    local file=$1
    shift
    printf '%s\n' "$@" > "$file"
    [ -f "$file" ] && [ ! -L "$file" ] || exit 1
}

token=fixture-selftest-token
write_lines "$fixture_dir/digest-input" abc
# Exact known vectors (no trailing newline) and missing-file behavior.
printf '' > "$fixture_dir/digest-input"
[ "$(sha256_file "$fixture_dir/digest-input")" = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ]
pass_case
printf abc > "$fixture_dir/digest-input"
[ "$(sha256_file "$fixture_dir/digest-input")" = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad ]
pass_case
expect_false 'missing digest input' sha256_file "$fixture_dir/missing-input" 2>/dev/null
nonce=0123456789abcdef0123456789abcdef0123456789abcdef
boot=01234567-89ab-cdef-0123-456789abcdef

# READY/DONE/PASS validators must retain the guest identity and exact SMP
# count across every supported host selection.
for smp in 1 8 16 24 32; do
    ready="M3_SELFTEST_READY token=$token pid=4242 boot=$boot cpus=$smp"
    done_line="M3_SELFTEST_DONE token=$token cpus=$smp"
    pass_line="M3_SELFTEST_PASS nonce=$nonce pid=4242 boot=$boot cpus=$smp"
    wrong_smp=1
    [ "$smp" = 1 ] && wrong_smp=8
    expect_true "READY cpu count $smp" selftest_validate_ready "$ready" "$token" "$smp"
    expect_true "DONE cpu count $smp" selftest_validate_done "$done_line" "$token" "$smp"
    expect_true "PASS identity $smp" selftest_validate_pass "$ready" "$pass_line" "$nonce"
    expect_false "READY token $smp" selftest_validate_ready \
        "${ready/token=$token/token=wrong-token}" "$token" "$smp"
    expect_false "DONE count $smp" selftest_validate_done \
        "${done_line/cpus=$smp/cpus=$wrong_smp}" "$token" "$smp"
    expect_false "PASS pid $smp" selftest_validate_pass "$ready" \
        "${pass_line/pid=4242/pid=4243}" "$nonce"
    expect_false "PASS nonce $smp" selftest_validate_pass "$ready" \
        "${pass_line/nonce=$nonce/nonce=old}" "$nonce"
done

# Exact BEGIN records include the test name so CPU 1 cannot match CPU 10.
SERIAL_LOG="$fixture_dir/serial.log"
cpu1_begin="M3_SELFTEST_BEGIN token=$token cpu=1 test=hwcap"
cpu1_end="M3_SELFTEST_END token=$token cpu=1 status=0"
cpu10_begin="M3_SELFTEST_BEGIN token=$token cpu=10 test=hwcap"
cpu10_end="M3_SELFTEST_END token=$token cpu=10 status=0"
write_lines "$SERIAL_LOG" \
    "$cpu1_begin" 'TAP version 13' '1..2' 'ok 1 cpu1-pass' \
    'ok 2 cpu1-skip # SKIP unavailable' \
    '# Totals: pass:1 fail:0 xfail:0 xpass:0 skip:1 error:0' \
    "$cpu1_end" \
    "$cpu10_begin" 'TAP version 13' '1..1' 'ok 1 cpu10-pass' \
    '# Totals: pass:1 fail:0 xfail:0 xpass:0 skip:0 error:0' \
    "$cpu10_end"

cpu1_tap="$fixture_dir/cpu-1.tap"
cpu10_tap="$fixture_dir/cpu-10.tap"
selftest_extract_tap "$cpu1_begin" "$cpu1_end" "$cpu1_tap"
selftest_extract_tap "$cpu10_begin" "$cpu10_end" "$cpu10_tap"
expect_valid 'cpu 1 extraction' '{"plan":2,"pass":1,"skip":1,"fail":0}' "$cpu1_tap"
expect_valid 'cpu 10 extraction' '{"plan":1,"pass":1,"skip":0,"fail":0}' "$cpu10_tap"

# Compose actual parser JSON, retaining pass and skip as distinct totals.
summary1="$("$AWK" -f "$VALIDATOR" "$cpu1_tap")"
summary10="$("$AWK" -f "$VALIDATOR" "$cpu10_tap")"
composed="$("$JQ" -c -n --argjson one "$summary1" --argjson ten "$summary10" \
    '{plan:($one.plan+$ten.plan),pass:($one.pass+$ten.pass),skip:($one.skip+$ten.skip),fail:($one.fail+$ten.fail)}')"
[ "$composed" = '{"plan":3,"pass":2,"skip":1,"fail":0}' ] || {
    echo "unexpected composed parser totals: $composed" >&2
    exit 1
}
pass_case

# Complete-line scanning ignores a partial final marker, normalizes CRLF, and
# rejects duplicates/missing boundaries through the actual exact extractor.
partial="$fixture_dir/partial.log"
printf '%s' "$cpu1_begin" > "$partial"
[ -z "$(selftest_complete_lines "$cpu1_begin" "$partial")" ] || exit 1
pass_case
printf '%s\r\n%s\r\n' "$cpu1_begin" "$cpu1_end" > "$partial"
[ "$(selftest_complete_lines "$cpu1_begin" "$partial")" = "$cpu1_begin" ] || exit 1
pass_case

write_lines "$fixture_dir/duplicate.log" "$cpu1_begin" 'TAP version 13' "$cpu1_begin" '1..1' 'ok 1 duplicate' "$cpu1_end"
SERIAL_LOG="$fixture_dir/duplicate.log"
expect_false 'duplicate BEGIN' selftest_extract_tap "$cpu1_begin" "$cpu1_end" "$fixture_dir/duplicate.tap"
write_lines "$fixture_dir/missing-end.log" "$cpu1_begin" 'TAP version 13' '1..1' 'ok 1 missing end'
SERIAL_LOG="$fixture_dir/missing-end.log"
expect_false 'missing END' selftest_extract_tap "$cpu1_begin" "$cpu1_end" "$fixture_dir/missing-end.tap"
write_lines "$fixture_dir/extra-end.log" "$cpu1_begin" 'TAP version 13' '1..1' 'ok 1 extra end' "$cpu1_end" "$cpu1_end"
SERIAL_LOG="$fixture_dir/extra-end.log"
expect_false 'duplicate END' selftest_extract_tap "$cpu1_begin" "$cpu1_end" "$fixture_dir/extra-end.tap"
SERIAL_LOG="$fixture_dir/serial.log"

# A CPU-10 marker is an extra record, never a CPU-1 match; this also guards
# against reverting to a prefix-only BEGIN lookup.
expect_false 'missing exact CPU-1 marker' selftest_extract_tap \
    "M3_SELFTEST_BEGIN token=$token cpu=1" "$cpu1_end" "$fixture_dir/prefix.tap"

echo "selftest fixtures passed: $tests cases; no VM launched"
echo "fixture artifacts: $fixture_dir"

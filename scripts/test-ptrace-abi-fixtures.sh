#!/bin/bash
# Source-only fixtures for the bounded ptrace ABI host validators.
set -euo pipefail
umask 077

HERE="$(cd "$(/usr/bin/dirname "$0")/.." && pwd -P)"
PTRACE_SCRIPT="$HERE/scripts/ptrace-abi-vm.sh"
VALIDATOR="$HERE/scripts/validate-kselftest.awk"
[ -f "$PTRACE_SCRIPT" ] && [ ! -L "$PTRACE_SCRIPT" ] || exit 1
[ -f "$VALIDATOR" ] && [ ! -L "$VALIDATOR" ] || exit 1

/bin/mkdir -p "$HERE/scratch"
fixture_dir="$(/usr/bin/mktemp -d "$HERE/scratch/ptrace-abi-fixtures.XXXXXX")"

# Import host helpers only; never enter ptrace_main or start QEMU.  The
# extracted reboot definitions install traps while being sourced, so remove
# those traps before creating fixtures.
PTRACE_ABI_SOURCE_ONLY=1 source "$PTRACE_SCRIPT"
trap - EXIT INT TERM HUP
AWK=/usr/bin/awk
JQ=/usr/bin/jq
TAP_VALIDATOR="$VALIDATOR"

tests=0
pass_case() { tests=$((tests + 1)); }

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

expect_tap_valid() {
    local label=$1 expected=$2 tap=$3 summary=$4 actual
    ptrace_validate_tap "$tap" "$summary"
    actual="$(/bin/cat "$summary")"
    [ "$actual" = "$expected" ] || {
        echo "unexpected TAP summary for $label: $actual" >&2
        exit 1
    }
    pass_case
}

expect_tap_rejected() {
    local label=$1 tap=$2 summary=$3
    if ptrace_validate_tap "$tap" "$summary"; then
        echo "accepted rejected TAP fixture: $label" >&2
        exit 1
    fi
    pass_case
}

write_tap() {
    local file=$1 plan=$2 mode=$3 i pass_count skip_count fail_count
    pass_count=0; skip_count=0; fail_count=0
    {
        printf '%s\n' 'TAP version 13' "1..$plan"
        for ((i = 1; i <= plan; i++)); do
            if [ "$mode" = skips ] && [ "$i" -gt 8 ]; then
                printf 'ok %d # SKIP unavailable\n' "$i"
                skip_count=$((skip_count + 1))
            elif [ "$mode" = failure ] && [ "$i" -eq "$plan" ]; then
                printf 'not ok %d failed ptrace case\n' "$i"
                fail_count=$((fail_count + 1))
            else
                printf 'ok %d ptrace case %d\n' "$i" "$i"
                pass_count=$((pass_count + 1))
            fi
        done
        printf '# Totals: pass:%d fail:%d xfail:0 xpass:0 skip:%d error:0\n' \
            "$pass_count" "$fail_count" "$skip_count"
} > "$file"
}

write_allskip_tap() {
    local file=$1 i
    {
        printf '%s\n' 'TAP version 13' '1..11'
        for ((i = 1; i <= 11; i++)); do
            printf 'ok %d # SKIP unavailable\n' "$i"
        done
        printf '%s\n' '# Totals: pass:0 fail:0 xfail:0 xpass:0 skip:11 error:0'
    } > "$file"
}

allpass="$fixture_dir/all-pass.tap"
write_tap "$allpass" 11 allpass
expect_tap_valid all-pass \
    '{"plan":11,"pass":11,"skip":0,"fail":0}' "$allpass" "$fixture_dir/all-pass.json"

eightpass="$fixture_dir/eight-pass-three-skip.tap"
write_tap "$eightpass" 11 skips
expect_tap_valid eight-pass-three-skip \
    '{"plan":11,"pass":8,"skip":3,"fail":0}' "$eightpass" "$fixture_dir/eight-pass-three-skip.json"

plan10="$fixture_dir/plan-10.tap"
write_tap "$plan10" 10 allpass
expect_tap_rejected plan-10 "$plan10" "$fixture_dir/plan-10.json"

plan12="$fixture_dir/plan-12.tap"
write_tap "$plan12" 12 allpass
expect_tap_rejected plan-12 "$plan12" "$fixture_dir/plan-12.json"

failure="$fixture_dir/failure-row.tap"
write_tap "$failure" 11 failure
expect_tap_rejected failure-row-even-with-zero-exit "$failure" "$fixture_dir/failure.json"

wrong_totals="$fixture_dir/wrong-totals.tap"
write_tap "$wrong_totals" 11 allpass
/usr/bin/sed -i '' 's/pass:11/pass:10/' "$wrong_totals"
expect_tap_rejected wrong-totals "$wrong_totals" "$fixture_dir/wrong-totals.json"

allskip="$fixture_dir/all-skipped.tap"
write_allskip_tap "$allskip"
expect_tap_rejected all-skipped "$allskip" "$fixture_dir/all-skipped.json"

truncated="$fixture_dir/truncated.tap"
{
    printf '%s\n' 'TAP version 13' '1..11'
    for ((i = 1; i <= 10; i++)); do printf 'ok %d ptrace case %d\n' "$i" "$i"; done
    printf '%s\n' '# Totals: pass:10 fail:0 xfail:0 xpass:0 skip:0 error:0'
} > "$truncated"
expect_tap_rejected truncated "$truncated" "$fixture_dir/truncated.json"

# Exercise the real one-CPU protocol validators, including identity drift.
token=fixture-ptrace-token
nonce=0123456789abcdef0123456789abcdef0123456789abcdef
boot=01234567-89ab-cdef-0123-456789abcdef
ready="M3_SELFTEST_READY token=$token pid=4242 boot=$boot cpus=1"
done_line="M3_SELFTEST_DONE token=$token cpus=1"
pass_line="M3_SELFTEST_PASS nonce=$nonce pid=4242 boot=$boot cpus=1"
expect_true ready ptrace_validate_ready "$ready" "$token"
expect_true done ptrace_validate_done "$done_line" "$token"
expect_true pass-identity ptrace_validate_pass "$ready" "$pass_line" "$nonce"
expect_false ready-token-drift ptrace_validate_ready \
    "${ready/token=$token/token=wrong-token}" "$token"
expect_false ready-cpu-drift ptrace_validate_ready \
    "${ready/cpus=1/cpus=2}" "$token"
expect_false done-token-drift ptrace_validate_done \
    "${done_line/token=$token/token=wrong-token}" "$token"
expect_false done-cpu-drift ptrace_validate_done \
    "${done_line/cpus=1/cpus=2}" "$token"
expect_false pass-pid-drift ptrace_validate_pass "$ready" \
    "${pass_line/pid=4242/pid=4243}" "$nonce"
expect_false pass-boot-drift ptrace_validate_pass "$ready" \
    "${pass_line/boot=$boot/boot=76543210-fedc-ba98-7654-3210fedcba98}" "$nonce"
expect_false pass-nonce-drift ptrace_validate_pass "$ready" \
    "${pass_line/nonce=$nonce/nonce=old-nonce}" "$nonce"

# Exercise exact BEGIN/END extraction, including CRLF normalization and
# duplicate/missing boundaries.  Marker-looking text with another test name
# must not be accepted as the ptrace boundary.
begin="M3_SELFTEST_BEGIN token=$token cpu=0 test=ptrace"
end="M3_SELFTEST_END token=$token cpu=0 status=0"
serial="$fixture_dir/serial-crlf.log"
printf '%s\r\n' "$begin" > "$serial"
while IFS= read -r line; do printf '%s\r\n' "$line"; done < "$allpass" >> "$serial"
printf '%s\r\n' "$end" >> "$serial"
SERIAL_LOG="$serial"
extracted="$fixture_dir/extracted.tap"
ptrace_extract_tap "$begin" "$end" "$extracted"
expect_tap_valid extracted-crlf \
    '{"plan":11,"pass":11,"skip":0,"fail":0}' "$extracted" "$fixture_dir/extracted.json"

duplicate="$fixture_dir/duplicate-boundary.log"
printf '%s\n' "$begin" "$begin" 'TAP version 13' '1..11' \
    'ok 1 ptrace case' '# Totals: pass:1 fail:0 xfail:0 xpass:0 skip:0 error:0' "$end" > "$duplicate"
SERIAL_LOG="$duplicate"
expect_false duplicate-begin ptrace_extract_tap "$begin" "$end" "$fixture_dir/duplicate.tap"

missing="$fixture_dir/missing-boundary.log"
printf '%s\n' "$begin" 'TAP version 13' '1..11' \
    'ok 1 ptrace case' '# Totals: pass:1 fail:0 xfail:0 xpass:0 skip:0 error:0' > "$missing"
SERIAL_LOG="$missing"
expect_false missing-end ptrace_extract_tap "$begin" "$end" "$fixture_dir/missing.tap"

wrong_test="$fixture_dir/wrong-test.log"
printf '%s\n' "${begin/test=ptrace/test=other}" 'TAP version 13' '1..11' \
    'ok 1 ptrace case' '# Totals: pass:1 fail:0 xfail:0 xpass:0 skip:0 error:0' "$end" > "$wrong_test"
SERIAL_LOG="$wrong_test"
expect_false wrong-test-boundary ptrace_extract_tap "$begin" "$end" "$fixture_dir/wrong-test.tap"

/bin/bash -n "$HERE/scripts/test-ptrace-abi-fixtures.sh"
echo "ptrace ABI fixtures passed: $tests cases; no VM launched"
echo "fixture artifacts: $fixture_dir"

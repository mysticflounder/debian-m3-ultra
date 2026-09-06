#!/bin/bash
# Source-only fixtures for the strict Linux kselftest TAP validator.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
AWK=/usr/bin/awk
VALIDATOR="$HERE/scripts/validate-kselftest.awk"

mkdir -p "$HERE/scratch"
fixture_dir="$(mktemp -d "$HERE/scratch/kselftest-fixtures.XXXXXX")"

tests=0
pass_count() {
    tests=$((tests + 1))
}

expect_valid() {
    local label=$1 expected=$2 file=$3 actual
    actual="$($AWK -f "$VALIDATOR" "$file")"
    if [ "$actual" != "$expected" ]; then
        echo "unexpected validator output for $label: $actual" >&2
        exit 1
    fi
    pass_count
}

expect_rejected() {
    local label=$1 file=$2
    if "$AWK" -f "$VALIDATOR" "$file" >/dev/null 2>&1; then
        echo "accepted rejected fixture: $label" >&2
        exit 1
    fi
    pass_count
}

make_fixture() {
    local name=$1
    shift
    printf '%s\n' "$@" > "$fixture_dir/$name.tap"
}

# The summary spelling and the no-hyphen test descriptions mirror
# scratch/linux-selftests-v6.12/kselftest.h and hwcap.c.
make_fixture basic \
    'TAP version 13' \
    '1..2' \
    'ok 1 AES instructions' \
    'ok 2 CRC instructions' \
    '# Totals: pass:2 fail:0 xfail:0 xpass:0 skip:0 error:0'
expect_valid basic '{"plan":2,"pass":2,"skip":0,"fail":0}' "$fixture_dir/basic.tap"

make_fixture skips \
    'TAP version 13' \
    '1..3' \
    'ok 1 AES instructions' \
    'ok 2 unavailable # SKIP feature absent' \
    'ok 3 optional probe # SKIP unsupported kernel' \
    '# Totals: pass:1 fail:0 xfail:0 xpass:0 skip:2 error:0'
expect_valid skips '{"plan":3,"pass":1,"skip":2,"fail":0}' "$fixture_dir/skips.tap"

make_fixture failure \
    'TAP version 13' \
    '1..2' \
    'ok 1 first test' \
    'not ok 2 failed test' \
    '# Totals: pass:1 fail:1 xfail:0 xpass:0 skip:0 error:0'
expect_rejected failure "$fixture_dir/failure.tap"

make_fixture partial \
    'TAP version 13' \
    '1..3' \
    'ok 1 first test' \
    'ok 2 second test'
expect_rejected partial "$fixture_dir/partial.tap"

make_fixture truncated \
    'TAP version 13' \
    '1..2' \
    'ok 1 first test'
expect_rejected truncated "$fixture_dir/truncated.tap"

make_fixture duplicates \
    'TAP version 13' \
    '1..2' \
    'ok 1 first test' \
    'ok 1 duplicate test'
expect_rejected duplicates "$fixture_dir/duplicates.tap"

make_fixture badnumber \
    'TAP version 13' \
    '1..2' \
    'ok 2 out of order' \
    'ok 3 wrong number'
expect_rejected badnumber "$fixture_dir/badnumber.tap"

make_fixture totals-mismatch \
    'TAP version 13' \
    '1..2' \
    'ok 1 first test' \
    'ok 2 second test' \
    '# Totals: pass:1 fail:0 xfail:0 xpass:0 skip:0 error:0'
expect_rejected totals-mismatch "$fixture_dir/totals-mismatch.tap"

make_fixture missing-totals \
    'TAP version 13' \
    '1..1' \
    'ok 1 complete test'
expect_rejected missing-totals "$fixture_dir/missing-totals.tap"

make_fixture all-skipped \
    'TAP version 13' \
    '1..1' \
    'ok 1 unavailable # SKIP no feature' \
    '# Totals: pass:0 fail:0 xfail:0 xpass:0 skip:1 error:0'
expect_rejected all-skipped "$fixture_dir/all-skipped.tap"

make_fixture todo \
    'TAP version 13' \
    '1..1' \
    'ok 1 deferred # TODO investigate'
expect_rejected todo "$fixture_dir/todo.tap"

make_fixture not-ok-skip \
    'TAP version 13' \
    '1..1' \
    'not ok 1 unavailable # SKIP unsupported kernel'
expect_rejected not-ok-skip "$fixture_dir/not-ok-skip.tap"

make_fixture trailing-comment \
    'TAP version 13' \
    '1..1' \
    'ok 1 complete test' \
    '# Totals: pass:1 fail:0 xfail:0 xpass:0 skip:0 error:0' \
    '# trailing output is not permitted'
expect_rejected trailing-comment "$fixture_dir/trailing-comment.tap"

make_fixture trailing-record \
    'TAP version 13' \
    '1..1' \
    'ok 1 complete test' \
    '# Totals: pass:1 fail:0 xfail:0 xpass:0 skip:0 error:0' \
    'ok 2 trailing output'
expect_rejected trailing-record "$fixture_dir/trailing-record.tap"

make_fixture garbage \
    'TAP version 13' \
    '1..1' \
    'ok 1 valid test' \
    'Bail out! kernel crashed'
expect_rejected garbage "$fixture_dir/garbage.tap"

"$AWK" -f "$VALIDATOR" /dev/null >/dev/null 2>&1 && {
    echo 'empty input incorrectly accepted' >&2
    exit 1
} || :
/bin/bash -n "$HERE/scripts/test-kselftest-fixtures.sh"

echo "kselftest TAP fixtures passed: $tests cases; awk syntax and source-only checks passed"
echo "fixture artifacts: $fixture_dir"

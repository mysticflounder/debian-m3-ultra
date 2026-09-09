#!/bin/bash
# Source-only TPIDR2 result classification and serial protocol fixtures.
set -euo pipefail
umask 077
HERE="$(cd "$(/usr/bin/dirname "$0")/.." && pwd -P)"
[ ! -L "$HERE/scratch" ] || exit 1
/bin/mkdir -p "$HERE/scratch"
fixture_dir="$(/usr/bin/mktemp -d "$HERE/scratch/tpidr2-abi-fixtures.XXXXXX")"
TPIDR2_ABI_SOURCE_ONLY=1 source "$HERE/scripts/tpidr2-abi-vm.sh"
trap - EXIT INT TERM HUP
AWK=/usr/bin/awk
JQ=/usr/bin/jq
TAP_VALIDATOR="$HERE/scripts/validate-kselftest.awk"
tests=0
expect_true() {
    local label=$1
    shift
    "$@" >/dev/null || { echo "rejected valid fixture: $label" >&2; exit 1; }
    tests=$((tests + 1))
}
expect_false() {
    local label=$1
    shift
    if "$@" >/dev/null 2>&1; then echo "accepted invalid fixture: $label" >&2; exit 1; fi
    tests=$((tests + 1))
}
write_tap() {
    local mode=$1 i=0 name
    printf '%s\n' 'TAP version 13' '1..5' '# PID: 123'
    [ "$mode" != skipped ] || printf '%s\n' '# SME support not present'
    for name in default_value write_read write_sleep_read write_fork_read write_clone_read; do
        i=$((i + 1))
        if [ "$mode" = skipped ]; then printf 'ok %s # SKIP %s\n' "$i" "$name"
        else printf 'ok %s %s\n' "$i" "$name"; fi
    done
    if [ "$mode" = skipped ]; then
        printf '%s\n' '# Totals: pass:0 fail:0 xfail:0 xpass:0 skip:5 error:0'
    else
        printf '%s\n' '# Totals: pass:5 fail:0 xfail:0 xpass:0 skip:0 error:0'
    fi
}
for outcome in passed skipped; do
    write_tap "$outcome" > "$fixture_dir/$outcome.tap"
    expect_true "$outcome-valid" tpidr2_validate_tap "$fixture_dir/$outcome.tap" "$fixture_dir/$outcome.json"
    expect_true "$outcome-classification" "$JQ" -e --arg outcome "$outcome" '.plan==5 and .fail==0 and .outcome==$outcome and .abi_pass==($outcome=="passed")' "$fixture_dir/$outcome.json"
    while IFS= read -r line; do printf '%s\r\n' "$line"; done < "$fixture_dir/$outcome.tap" > "$fixture_dir/$outcome-crlf.tap"
    expect_true "$outcome-crlf" tpidr2_validate_tap "$fixture_dir/$outcome-crlf.tap" "$fixture_dir/$outcome-crlf.json"
done
expect_true skipped-not-passed "$JQ" -e '.abi_pass==false and .pass==0 and .skip==5' "$fixture_dir/skipped.json"
/usr/bin/sed '/^# SME support not present/d' "$fixture_dir/skipped.tap" > "$fixture_dir/no-sme-reason.tap"
expect_false missing-skip-reason tpidr2_validate_tap "$fixture_dir/no-sme-reason.tap" "$fixture_dir/no-sme-reason.json"
{ printf '%s\n' 'ok 1 # SKIP default_value'; /usr/bin/sed '/^ok 1 /d' "$fixture_dir/skipped.tap"; } > "$fixture_dir/skip-before-header.tap"
expect_false skip-before-header tpidr2_validate_tap "$fixture_dir/skip-before-header.tap" "$fixture_dir/skip-before-header.json"
/usr/bin/sed '/^# PID:/a\
# Totals: malformed
' "$fixture_dir/skipped.tap" > "$fixture_dir/skip-malformed-totals.tap"
expect_false malformed-extra-totals tpidr2_validate_tap "$fixture_dir/skip-malformed-totals.tap" "$fixture_dir/skip-malformed-totals.json"
passed="$fixture_dir/passed.tap"
/usr/bin/sed 's/^ok 5 /not ok 5 /;s/pass:5 fail:0/pass:4 fail:1/' "$passed" > "$fixture_dir/failure.tap"
expect_false failure tpidr2_validate_tap "$fixture_dir/failure.tap" "$fixture_dir/failure.json"
/usr/bin/sed 's/^ok 5 /ok 5 # SKIP /;s/pass:5/pass:4/;s/skip:0/skip:1/' "$passed" > "$fixture_dir/mixed.tap"
expect_false mixed tpidr2_validate_tap "$fixture_dir/mixed.tap" "$fixture_dir/mixed.json"
/usr/bin/sed '/^ok 5 /d' "$passed" > "$fixture_dir/truncated.tap"
expect_false truncated tpidr2_validate_tap "$fixture_dir/truncated.tap" "$fixture_dir/truncated.json"
/usr/bin/sed '/^# Totals:/d' "$passed" > "$fixture_dir/no-totals.tap"
expect_false no-totals tpidr2_validate_tap "$fixture_dir/no-totals.tap" "$fixture_dir/no-totals.json"
/usr/bin/sed 's/default_value/wrong_name/' "$passed" > "$fixture_dir/wrong-name.tap"
expect_false wrong-name tpidr2_validate_tap "$fixture_dir/wrong-name.tap" "$fixture_dir/wrong-name.json"
/usr/bin/sed 's/write_read/default_value/' "$passed" > "$fixture_dir/duplicate-name.tap"
expect_false duplicate-name tpidr2_validate_tap "$fixture_dir/duplicate-name.tap" "$fixture_dir/duplicate-name.json"
/usr/bin/sed 's/1\.\.5/1..4/' "$passed" > "$fixture_dir/wrong-plan.tap"
expect_false wrong-plan tpidr2_validate_tap "$fixture_dir/wrong-plan.tap" "$fixture_dir/wrong-plan.json"
/usr/bin/sed 's/pass:5/pass:4/' "$passed" > "$fixture_dir/wrong-totals.tap"
expect_false wrong-totals tpidr2_validate_tap "$fixture_dir/wrong-totals.tap" "$fixture_dir/wrong-totals.json"
/usr/bin/sed 's/^ok 5 /ok 4 /' "$passed" > "$fixture_dir/duplicate-number.tap"
expect_false duplicate-number tpidr2_validate_tap "$fixture_dir/duplicate-number.tap" "$fixture_dir/duplicate-number.json"
{ /bin/cat "$passed"; printf '%s\n' 'Bail out! fixture'; } > "$fixture_dir/bailout.tap"
expect_false bailout tpidr2_validate_tap "$fixture_dir/bailout.tap" "$fixture_dir/bailout.json"
token=fixture-tpidr2
nonce=0123456789abcdef0123456789abcdef0123456789abcdef
boot=01234567-89ab-cdef-0123-456789abcdef
ready="M3_SELFTEST_READY token=$token pid=4242 boot=$boot cpus=1"
pass_line="M3_SELFTEST_PASS nonce=$nonce pid=4242 boot=$boot cpus=1"
expect_true ready tpidr2_validate_ready "$ready" "$token"
expect_true done tpidr2_validate_done "M3_SELFTEST_DONE token=$token cpus=1" "$token"
expect_true identity tpidr2_validate_pass "$ready" "$pass_line" "$nonce"
expect_false cpu-drift tpidr2_validate_ready "${ready/cpus=1/cpus=8}" "$token"
expect_false pid-drift tpidr2_validate_pass "$ready" "${pass_line/pid=4242/pid=4243}" "$nonce"
expect_false nonce-drift tpidr2_validate_pass "$ready" "${pass_line/nonce=$nonce/nonce=old}" "$nonce"
expect_false boot-drift tpidr2_validate_pass "$ready" "${pass_line/boot=$boot/boot=deadbeef}" "$nonce"
expect_false ready-token tpidr2_validate_ready "${ready/token=$token/token=wrong}" "$token"
begin="M3_SELFTEST_BEGIN token=$token cpu=0 test=tpidr2"
end="M3_SELFTEST_END token=$token cpu=0 status=0"
SERIAL_LOG="$fixture_dir/serial.log"
{ printf '%s\r\n' "$begin"; /bin/cat "$fixture_dir/skipped-crlf.tap"; printf '%s\r\n' "$end"; } > "$SERIAL_LOG"
expect_true extract-skip tpidr2_extract_tap "$begin" "$end" "$fixture_dir/extracted.tap"
expect_true classify-extracted-skip tpidr2_validate_tap "$fixture_dir/extracted.tap" "$fixture_dir/extracted.json"
printf '%s\n' "$begin" "$begin" "$end" > "$SERIAL_LOG"
expect_false duplicate-begin tpidr2_extract_tap "$begin" "$end" "$fixture_dir/duplicate.tap"
printf '%s\n' "$end" "$begin" > "$SERIAL_LOG"
expect_false reversed tpidr2_extract_tap "$begin" "$end" "$fixture_dir/reversed.tap"
for script in "$HERE/scripts/tpidr2-abi-vm.sh" "$HERE/scripts/arm64-tpidr2-abi-guest.sh" "$0"; do /bin/bash -n "$script"; done
echo "TPIDR2 ABI fixtures passed: $tests cases; no VM launched"
echo "fixture artifacts: $fixture_dir"

#!/bin/bash
# Source-only matrix protocol coverage; never launch QEMU.
set -euo pipefail
umask 077
HERE="$(cd "$(/usr/bin/dirname "$0")/.." && pwd -P)"
[ ! -L "$HERE/scratch" ] || exit 1
/bin/mkdir -p "$HERE/scratch"
fixture_dir="$(/usr/bin/mktemp -d "$HERE/scratch/abi-matrix-fixtures.XXXXXX")"
ABI_MATRIX_SOURCE_ONLY=1 source "$HERE/scripts/abi-matrix-vm.sh"
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
token=fixture-abi-matrix
expect_true counts abi_parse_counts '1 8 16 24 32'
expect_true single-count abi_parse_counts 1
for invalid in '' ' ' '1 1' '1 2' '*' '01' $'1\n8' $'1\r8'; do
    expect_false invalid-count-list abi_parse_counts "$invalid"
done
nonce=0123456789abcdef0123456789abcdef0123456789abcdef
boot=01234567-89ab-cdef-0123-456789abcdef
write_tap() {
    local test=$1 i
    printf '%s\n' 'TAP version 13'
    if [ "$test" = ptrace ]; then
        printf '%s\n' '1..11'
        for ((i=1; i<=11; i++)); do printf 'ok %d ptrace fixture\n' "$i"; done
        printf '%s\n' '# Totals: pass:11 fail:0 xfail:0 xpass:0 skip:0 error:0'
    else
        printf '%s\n' '1..2' 'ok 1 getpid() FPSIMD' 'ok 2 sched_yield() FPSIMD' \
            '# Totals: pass:2 fail:0 xfail:0 xpass:0 skip:0 error:0'
    fi
}
write_serial() {
    local smp=$1 cpu test
    for ((cpu=0; cpu<smp; cpu++)); do
        for test in ptrace syscall-abi; do
            printf 'M3_SELFTEST_BEGIN token=%s cpu=%s test=%s\n' "$token" "$cpu" "$test"
            write_tap "$test"
            printf 'M3_SELFTEST_END token=%s cpu=%s test=%s status=0\n' "$token" "$cpu" "$test"
        done
    done
}
for smp in 1 8 16 24 32; do
    ready="M3_SELFTEST_READY token=$token pid=4242 boot=$boot cpus=$smp"
    done_line="M3_SELFTEST_DONE token=$token cpus=$smp"
    pass_line="M3_SELFTEST_PASS nonce=$nonce pid=4242 boot=$boot cpus=$smp"
    expect_true "ready-$smp" abi_validate_ready "$ready" "$token" "$smp"
    expect_true "done-$smp" abi_validate_done "$done_line" "$token" "$smp"
    expect_true "pass-$smp" abi_validate_pass "$ready" "$pass_line" "$nonce" "$smp"
    expect_false "ready-token-$smp" abi_validate_ready "${ready/token=$token/token=wrong}" "$token" "$smp"
    expect_false "done-cpus-$smp" abi_validate_done "${done_line/cpus=$smp/cpus=99}" "$token" "$smp"
    expect_false "pass-cpus-$smp" abi_validate_pass "$ready" "${pass_line/cpus=$smp/cpus=99}" "$nonce" "$smp"
    expect_false "pass-pid-$smp" abi_validate_pass "$ready" "${pass_line/pid=4242/pid=4243}" "$nonce" "$smp"
    expect_false "pass-boot-$smp" abi_validate_pass "$ready" "${pass_line/boot=$boot/boot=deadbeef}" "$nonce" "$smp"
    expect_false "pass-nonce-$smp" abi_validate_pass "$ready" "${pass_line/nonce=$nonce/nonce=old}" "$nonce" "$smp"
    serial="$fixture_dir/serial-$smp.log"
    write_serial "$smp" > "$serial"
    expect_true "complete-$smp" abi_validate_streams "$serial" "$token" "$smp"
    expect_false "missing-cpus-$smp" abi_validate_streams "$serial" "$token" 99
done
serial="$fixture_dir/serial-8.log"
while IFS= read -r line; do printf '%s\r\n' "$line"; done < "$serial" > "$fixture_dir/crlf.log"
expect_true crlf abi_validate_streams "$fixture_dir/crlf.log" "$token" 8
/usr/bin/sed '/cpu=7 test=syscall-abi/d' "$serial" > "$fixture_dir/missing.log"
expect_false missing-final-stream abi_validate_streams "$fixture_dir/missing.log" "$token" 8
{ /bin/cat "$serial"; /bin/cat "$serial"; } > "$fixture_dir/duplicate.log"
expect_false duplicate-streams abi_validate_streams "$fixture_dir/duplicate.log" "$token" 8
/usr/bin/sed 's/cpu=7/cpu=8/g' "$serial" > "$fixture_dir/wrong-cpu.log"
expect_false wrong-cpu abi_validate_streams "$fixture_dir/wrong-cpu.log" "$token" 8
/usr/bin/sed 's/test=syscall-abi/test=hwcap/g' "$serial" > "$fixture_dir/wrong-test.log"
expect_false wrong-test abi_validate_streams "$fixture_dir/wrong-test.log" "$token" 8
/usr/bin/sed "s/token=$token/token=wrong/g" "$serial" > "$fixture_dir/wrong-token.log"
expect_false wrong-token abi_validate_streams "$fixture_dir/wrong-token.log" "$token" 8
/usr/bin/sed 's/status=0/status=1/' "$serial" > "$fixture_dir/failure.log"
expect_false failure-exit abi_validate_streams "$fixture_dir/failure.log" "$token" 8
/usr/bin/sed '$s/status=0/status=1/' "$serial" > "$fixture_dir/final-failure.log"
expect_false final-marker-failure abi_validate_streams "$fixture_dir/final-failure.log" "$token" 8
{ /bin/cat "$serial"; printf 'M3_SELFTEST_BEGIN token=foreign cpu=0 test=ptrace\n'; } > "$fixture_dir/foreign-extra.log"
expect_false foreign-extra abi_validate_streams "$fixture_dir/foreign-extra.log" "$token" 8
# Reordering whole CPU blocks must not pass simply because the counts match.
{
    /usr/bin/awk '/^M3_SELFTEST_BEGIN .*cpu=1 / { inside=1 } /^M3_SELFTEST_BEGIN .*cpu=2 / { inside=0 } inside' "$serial"
    /usr/bin/awk '/^M3_SELFTEST_BEGIN .*cpu=1 / { inside=1 } /^M3_SELFTEST_BEGIN .*cpu=2 / { inside=0 } !inside' "$serial"
} > "$fixture_dir/reordered.log"
expect_false reordered-cpus abi_validate_streams "$fixture_dir/reordered.log" "$token" 8
printf '%s\n' "M3_SELFTEST_END token=$token cpu=0 test=ptrace status=0" > "$fixture_dir/reversed.log"
/bin/cat "$serial" >> "$fixture_dir/reversed.log"
expect_false premature-end abi_validate_streams "$fixture_dir/reversed.log" "$token" 8
for test in ptrace syscall-abi; do
    tap="$fixture_dir/$test.tap"
    write_tap "$test" > "$tap"
    expect_true "$test-tap" abi_validate_tap "$test" "$tap" "$fixture_dir/$test.json"
    /usr/bin/sed 's/^ok 1 /not ok 1 /' "$tap" > "$fixture_dir/$test-fail.tap"
    expect_false "$test-failure" abi_validate_tap "$test" "$fixture_dir/$test-fail.tap" "$fixture_dir/$test-fail.json"
done
expect_false unknown-test abi_validate_tap hwcap "$fixture_dir/syscall-abi.tap" "$fixture_dir/unknown.json"
# Exercise production extraction as well as marker counting.
SERIAL_LOG="$fixture_dir/crlf.log"
begin="M3_SELFTEST_BEGIN token=$token cpu=7 test=syscall-abi"
end="M3_SELFTEST_END token=$token cpu=7 test=syscall-abi status=0"
expect_true extract-final-cpu abi_extract_tap "$begin" "$end" "$fixture_dir/extracted.tap"
expect_true extracted-final-tap abi_validate_tap syscall-abi "$fixture_dir/extracted.tap" "$fixture_dir/extracted.json"
SERIAL_LOG="$fixture_dir/duplicate.log"
expect_false extract-duplicate abi_extract_tap "$begin" "$end" "$fixture_dir/extract-duplicate.tap"
SERIAL_LOG="$fixture_dir/missing.log"
expect_false extract-missing abi_extract_tap "$begin" "$end" "$fixture_dir/extract-missing.tap"
for script in "$HERE/scripts/abi-matrix-vm.sh" "$HERE/scripts/arm64-abi-matrix-guest.sh" "$0"; do /bin/bash -n "$script"; done
echo "ABI matrix fixtures passed: $tests cases; no VM launched"
echo "fixture artifacts: $fixture_dir"

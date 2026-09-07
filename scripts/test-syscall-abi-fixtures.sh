#!/bin/bash
# Exercise the real syscall ABI host helpers without launching a VM.
set -euo pipefail
umask 077
HERE="$(cd "$(/usr/bin/dirname "$0")/.." && pwd -P)"
HOST="$HERE/scripts/syscall-abi-vm.sh"
VALIDATOR="$HERE/scripts/validate-kselftest.awk"
[ -f "$HOST" ] && [ ! -L "$HOST" ] || exit 1
[ ! -L "$HERE/scratch" ] || exit 1
/bin/mkdir -p "$HERE/scratch"
[ "$(cd "$HERE/scratch" && pwd -P)" = "$HERE/scratch" ] || exit 1
fixture_dir="$(/usr/bin/mktemp -d "$HERE/scratch/syscall-abi-fixtures.XXXXXX")"
SYSCALL_ABI_SOURCE_ONLY=1 source "$HOST"
trap - EXIT INT TERM HUP
AWK=/usr/bin/awk
JQ=/usr/bin/jq
TAP_VALIDATOR="$VALIDATOR"
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
    if "$@"; then echo "accepted invalid fixture: $label" >&2; exit 1; fi
    tests=$((tests + 1))
}
write_tap() {
    local file=$1 plan=$2 mode=$3 i pass_count=0 skip_count=0 fail_count=0
    {
        printf '%s\n' 'TAP version 13' "1..$plan"
        for ((i=1; i<=plan; i++)); do
            if [ "$mode" = allskip ] || { [ "$mode" = partialskip ] && [ "$i" -gt 2 ]; }; then
                printf 'ok %d # SKIP fixture unavailable\n' "$i"
                skip_count=$((skip_count + 1))
            elif [ "$mode" = failure ] && [ "$i" = "$plan" ]; then
                printf 'not ok %d register mismatch\n' "$i"
                fail_count=$((fail_count + 1))
            else
                if [ "$i" -eq 1 ]; then
                    printf 'ok %d getpid() FPSIMD\n' "$i"
                elif [ "$i" -eq "$((plan / 2 + 1))" ]; then
                    printf 'ok %d sched_yield() FPSIMD\n' "$i"
                else
                    printf 'ok %d syscall ABI fixture %d\n' "$i" "$i"
                fi
                pass_count=$((pass_count + 1))
            fi
        done
        printf '# Totals: pass:%d fail:%d xfail:0 xpass:0 skip:%d error:0\n' "$pass_count" "$fail_count" "$skip_count"
    } > "$file"
}
baseline="$fixture_dir/baseline.tap"
write_tap "$baseline" 2 pass
expect_true baseline syscall_validate_tap "$baseline" "$fixture_dir/baseline.json"
expect_true baseline-summary "$JQ" -e '.plan==2 and .pass==2 and .skip==0 and .fail==0' "$fixture_dir/baseline.json"
while IFS= read -r line; do printf '%s\r\n' "$line"; done < "$baseline" > "$fixture_dir/baseline-crlf.tap"
expect_true direct-crlf-tap syscall_validate_tap "$fixture_dir/baseline-crlf.tap" "$fixture_dir/baseline-crlf.json"
write_tap "$fixture_dir/dynamic.tap" 4 pass
expect_true dynamic-plan syscall_validate_tap "$fixture_dir/dynamic.tap" "$fixture_dir/dynamic.json"
write_tap "$fixture_dir/partialskip.tap" 4 partialskip
expect_false partial-skip-not-emitted-by-source syscall_validate_tap "$fixture_dir/partialskip.tap" "$fixture_dir/partialskip.json"
write_tap "$fixture_dir/allskip.tap" 2 allskip
expect_false all-skipped syscall_validate_tap "$fixture_dir/allskip.tap" "$fixture_dir/allskip.json"
write_tap "$fixture_dir/failure.tap" 2 failure
expect_false failure-despite-zero-exit syscall_validate_tap "$fixture_dir/failure.tap" "$fixture_dir/failure.json"
/usr/bin/sed 's/pass:2/pass:1/' "$baseline" > "$fixture_dir/wrong-totals.tap"
expect_false wrong-totals syscall_validate_tap "$fixture_dir/wrong-totals.tap" "$fixture_dir/wrong-totals.json"
/usr/bin/sed '/^ok 2 /d' "$baseline" > "$fixture_dir/truncated.tap"
expect_false truncated syscall_validate_tap "$fixture_dir/truncated.tap" "$fixture_dir/truncated.json"
/usr/bin/sed '/^# Totals:/d' "$baseline" > "$fixture_dir/no-totals.tap"
expect_false missing-totals syscall_validate_tap "$fixture_dir/no-totals.tap" "$fixture_dir/no-totals.json"
/usr/bin/sed 's/^ok 2 /ok 1 /' "$baseline" > "$fixture_dir/duplicate.tap"
expect_false duplicate-number syscall_validate_tap "$fixture_dir/duplicate.tap" "$fixture_dir/duplicate.json"
{ /bin/cat "$baseline"; printf '%s\n' 'Bail out! fixture'; } > "$fixture_dir/bailout.tap"
expect_false bailout syscall_validate_tap "$fixture_dir/bailout.tap" "$fixture_dir/bailout.json"
{ printf '%s\n' 'TAP version 13' '1..0 # SKIP unavailable'; } > "$fixture_dir/zero-plan.tap"
expect_false zero-plan syscall_validate_tap "$fixture_dir/zero-plan.tap" "$fixture_dir/zero-plan.json"
for plan in 1 3 18 194; do
    write_tap "$fixture_dir/plan-$plan.tap" "$plan" pass
    expect_false "unreachable-plan-$plan" syscall_validate_tap "$fixture_dir/plan-$plan.tap" "$fixture_dir/plan-$plan.json"
done
write_tap "$fixture_dir/max-plan.tap" 192 pass
expect_true bounded-maximum-plan syscall_validate_tap "$fixture_dir/max-plan.tap" "$fixture_dir/max-plan.json"
/usr/bin/sed 's/getpid() FPSIMD/wrong-case FPSIMD/' "$baseline" > "$fixture_dir/missing-getpid.tap"
expect_false missing-getpid-baseline syscall_validate_tap "$fixture_dir/missing-getpid.tap" "$fixture_dir/missing-getpid.json"
/usr/bin/sed 's/sched_yield() FPSIMD/getpid() FPSIMD/' "$baseline" > "$fixture_dir/duplicate-getpid.tap"
expect_false duplicate-getpid-baseline syscall_validate_tap "$fixture_dir/duplicate-getpid.tap" "$fixture_dir/duplicate-getpid.json"
/usr/bin/sed 's/sched_yield() FPSIMD/wrong-case FPSIMD/' "$baseline" > "$fixture_dir/missing-yield.tap"
expect_false missing-yield-baseline syscall_validate_tap "$fixture_dir/missing-yield.tap" "$fixture_dir/missing-yield.json"

token=fixture-syscall-token
nonce=0123456789abcdef0123456789abcdef0123456789abcdef
boot=01234567-89ab-cdef-0123-456789abcdef
ready="M3_SELFTEST_READY token=$token pid=4242 boot=$boot cpus=1"
done_line="M3_SELFTEST_DONE token=$token cpus=1"
pass_line="M3_SELFTEST_PASS nonce=$nonce pid=4242 boot=$boot cpus=1"
expect_true ready syscall_validate_ready "$ready" "$token"
expect_true done syscall_validate_done "$done_line" "$token"
expect_true identity syscall_validate_pass "$ready" "$pass_line" "$nonce"
expect_false ready-token syscall_validate_ready "${ready/token=$token/token=wrong}" "$token"
expect_false ready-cpus syscall_validate_ready "${ready/cpus=1/cpus=2}" "$token"
expect_false done-token syscall_validate_done "${done_line/token=$token/token=wrong}" "$token"
expect_false done-cpus syscall_validate_done "${done_line/cpus=1/cpus=2}" "$token"
expect_false pass-pid syscall_validate_pass "$ready" "${pass_line/pid=4242/pid=4243}" "$nonce"
expect_false pass-boot syscall_validate_pass "$ready" "${pass_line/boot=$boot/boot=76543210-fedc-ba98-7654-3210fedcba98}" "$nonce"
expect_false pass-nonce syscall_validate_pass "$ready" "${pass_line/nonce=$nonce/nonce=old}" "$nonce"

begin="M3_SELFTEST_BEGIN token=$token cpu=0 test=syscall-abi"
end="M3_SELFTEST_END token=$token cpu=0 status=0"
SERIAL_LOG="$fixture_dir/serial.log"
{
    printf '%s\r\n' "$begin"
    while IFS= read -r line; do printf '%s\r\n' "$line"; done < "$baseline"
    printf '%s\r\n' "$end"
} > "$SERIAL_LOG"
expect_true crlf-extraction syscall_extract_tap "$begin" "$end" "$fixture_dir/extracted.tap"
expect_true crlf-tap syscall_validate_tap "$fixture_dir/extracted.tap" "$fixture_dir/extracted.json"
printf '%s\n' "$begin" "$begin" "$end" > "$SERIAL_LOG"
expect_false duplicate-begin syscall_extract_tap "$begin" "$end" "$fixture_dir/duplicate-boundary.tap"
printf '%s\n' "$begin" "$end" "$end" > "$SERIAL_LOG"
expect_false duplicate-end syscall_extract_tap "$begin" "$end" "$fixture_dir/duplicate-end.tap"
printf '%s\n' "$begin" > "$SERIAL_LOG"
expect_false missing-end syscall_extract_tap "$begin" "$end" "$fixture_dir/missing.tap"
printf '%s\n' "${begin/test=syscall-abi/test=ptrace}" "$end" > "$SERIAL_LOG"
expect_false wrong-test syscall_extract_tap "$begin" "$end" "$fixture_dir/wrong-test.tap"
printf '%s\n' "$end" "$begin" > "$SERIAL_LOG"
expect_false reversed-boundaries syscall_extract_tap "$begin" "$end" "$fixture_dir/reversed.tap"
for script in "$HOST" "$HERE/scripts/arm64-syscall-abi-guest.sh" "$0"; do
    /bin/bash -n "$script"
done
echo "syscall ABI fixtures passed: $tests cases; no VM launched"
echo "fixture artifacts: $fixture_dir"

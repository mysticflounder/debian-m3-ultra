#!/bin/bash
# No VM, QEMU, or git: exercise the stress protocol validators and serial gates.
set -euo pipefail
umask 077

HERE="$(cd "$(/usr/bin/dirname "$0")/.." && pwd -P)"

# Keep the source path anchored to this script.  stress-vm.sh installs the
# reboot helper's real marker-count implementation while source-only is set.
STRESS_SOURCE_ONLY=1 source "$HERE/scripts/stress-vm.sh"
trap - EXIT INT TERM HUP

/bin/mkdir -p "$HERE/scratch"
fixture_dir="$(/usr/bin/mktemp -d "$HERE/scratch/stress-fixtures.XXXXXX")"
tests=0

pass() {
    tests=$((tests + 1))
}

reject() {
    local label=$1
    shift
    if ( "$@" ) >/dev/null 2>&1; then
        echo "accepted rejected fixture: $label" >&2
        exit 1
    fi
    pass
}

token=fixture-stress-token
nonce=0123456789abcdef0123456789abcdef0123456789abcdef
boot=01234567-89ab-cdef-0123-456789abcdef

# Validate every supported count with the exact host validators.
for smp in 1 8 16 24 32; do
    ready="M3_STRESS_READY token=$token pid=4242 boot=$boot cpus=$smp bytes_per_cpu=16777216 passes=8"
    stress_validate_ready "$ready" "$token" "$smp"
    pass

    cpu_expected=0
    cpu_line="M3_STRESS_CPU token=$token cpu=$cpu_expected passes=8 bytes=16777216"
    stress_validate_cpu "$cpu_line" "$token" "$cpu_expected"
    pass
    if [ "$smp" -gt 1 ]; then
        cpu_expected=$((smp - 1))
        cpu_line="M3_STRESS_CPU token=$token cpu=$cpu_expected passes=8 bytes=16777216"
        stress_validate_cpu "$cpu_line" "$token" "$cpu_expected"
        pass
    fi
    wrong_cpu=1
    [ "$cpu_expected" -eq 1 ] && wrong_cpu=0

    memory_bytes=$((smp * 16777216))
    atomic_count=$((smp * 8 * 10000))
    done_line="M3_STRESS_DONE token=$token cpus=$smp passes=8 memory_bytes=$memory_bytes atomic_count=$atomic_count"
    stress_validate_done "$done_line" "$token" "$smp"
    pass

    pass_line="M3_STRESS_PASS nonce=$nonce pid=4242 boot=$boot cpus=$smp bytes_per_cpu=16777216 passes=8"
    stress_validate_pass "$ready" "$pass_line" "$nonce"
    pass

    # READY rejects token/count/pass/bytes drift and non-lowercase boot text.
    reject "ready token $smp" stress_validate_ready \
        "${ready/token=$token/token=wrong-token}" "$token" "$smp"
    wrong_smp=1
    [ "$smp" -eq 1 ] && wrong_smp=8
    reject "ready CPU count $smp" stress_validate_ready \
        "${ready/cpus=$smp/cpus=$wrong_smp}" "$token" "$smp"
    reject "ready passes $smp" stress_validate_ready \
        "${ready/passes=8/passes=7}" "$token" "$smp"
    reject "ready bytes $smp" stress_validate_ready \
        "${ready/bytes_per_cpu=16777216/bytes_per_cpu=1}" "$token" "$smp"
    reject "ready boot case $smp" stress_validate_ready \
        "${ready/boot=$boot/boot=01234567-89AB-cdef-0123-456789abcdef}" "$token" "$smp"
    reject "ready extra payload $smp" stress_validate_ready \
        "$ready extra" "$token" "$smp"

    # CPU evidence is exact, including token, CPU number, pass count, and size.
    reject "cpu token $smp" stress_validate_cpu \
        "${cpu_line/token=$token/token=wrong-token}" "$token" "$cpu_expected"
    reject "cpu number $smp" stress_validate_cpu \
        "${cpu_line/cpu=$cpu_expected/cpu=$wrong_cpu}" "$token" "$cpu_expected"
    reject "cpu passes $smp" stress_validate_cpu \
        "${cpu_line/passes=8/passes=7}" "$token" "$cpu_expected"
    reject "cpu bytes $smp" stress_validate_cpu \
        "${cpu_line/bytes=16777216/bytes=1}" "$token" "$cpu_expected"
    reject "cpu extra payload $smp" stress_validate_cpu \
        "$cpu_line extra" "$token" "$cpu_expected"

    # DONE checks token, CPU count, passes, memory bytes, and atomic count.
    reject "done token $smp" stress_validate_done \
        "${done_line/token=$token/token=wrong-token}" "$token" "$smp"
    reject "done CPU count $smp" stress_validate_done \
        "${done_line/cpus=$smp/cpus=$wrong_smp}" "$token" "$smp"
    reject "done passes $smp" stress_validate_done \
        "${done_line/passes=8/passes=7}" "$token" "$smp"
    reject "done bytes $smp" stress_validate_done \
        "${done_line/memory_bytes=$memory_bytes/memory_bytes=1}" "$token" "$smp"
    reject "done atomic count $smp" stress_validate_done \
        "${done_line/atomic_count=$atomic_count/atomic_count=1}" "$token" "$smp"
    reject "done extra payload $smp" stress_validate_done \
        "$done_line extra" "$token" "$smp"

    # PASS must retain the READY process identity and exact nonce.
    reject "pass PID $smp" stress_validate_pass "$ready" \
        "${pass_line/pid=4242/pid=4243}" "$nonce"
    reject "pass boot $smp" stress_validate_pass "$ready" \
        "${pass_line/boot=$boot/boot=76543210-fedc-ba98-7654-3210fedcba98}" "$nonce"
    reject "pass nonce $smp" stress_validate_pass "$ready" \
        "${pass_line/nonce=$nonce/nonce=old-nonce}" "$nonce"
    reject "pass extra payload $smp" stress_validate_pass "$ready" \
        "$pass_line extra" "$nonce"
done

# A serial marker is incomplete until its newline arrives; CRLF is normalized.
serial_log="$fixture_dir/serial.log"
serial_prefix="M3_STRESS_PASS nonce=$nonce "
serial_suffix="pid=4242 boot=$boot cpus=8 bytes_per_cpu=16777216 passes=8"
serial_marker="$serial_prefix$serial_suffix"
printf '%s' "$serial_prefix" > "$serial_log"
[ -z "$(stress_complete_lines "$serial_prefix" "$serial_log")" ]
pass
printf '%s\r\n' "$serial_suffix" >> "$serial_log"
[ "$(stress_complete_lines "$serial_prefix" "$serial_log")" = "$serial_marker" ]
pass

# The real wait_for_marker_count helper is used by stress_wait_serial_prefix;
# no test double is installed.  An already complete marker succeeds without
# needing a live job because the helper observes its exact count immediately.
SERIAL_LOG="$serial_log"
CONTROL_STEPS=1
QPID=1
stress_wait_serial_prefix "$serial_prefix"
[ "$STRESS_LINE" = "$serial_marker" ]
pass

# Missing, partial, duplicate, and extra-payload records must all fail the
# exact-prefix waiter.  Keep each failing call in a subshell because fail()
# intentionally exits the host harness process.
printf '%s\n' 'unrelated serial output' > "$serial_log"
reject "missing marker" stress_wait_serial_prefix "$serial_prefix"
printf '%s' "$serial_marker" > "$serial_log"
reject "partial marker" stress_wait_serial_prefix "$serial_prefix"
printf '%s\n%s\n' "$serial_marker" "$serial_marker" > "$serial_log"
reject "duplicate marker" stress_wait_serial_prefix "$serial_prefix"
printf '%s extra\n' "$serial_marker" > "$serial_log"
reject "extra payload marker count" wait_for_marker_count "$serial_marker" 1

/bin/bash -n "$HERE/scripts/stress-vm.sh"
/bin/bash -n "$HERE/scripts/test-stress-fixtures.sh"
echo "stress: $tests protocol/validator fixtures passed; Bash syntax passed; no VM launched"
echo "fixture artifacts: $fixture_dir"

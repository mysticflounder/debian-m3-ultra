#!/bin/bash
# No VM, QEMU, or disk image: exercise protocol gates and a native FIFO fixture.
set -euo pipefail
HERE="$(cd "$(/usr/bin/dirname "$0")/.." && pwd -P)"
export IDLE_SOURCE_ONLY=1
source "$HERE/scripts/idle-vm.sh"
trap - EXIT INT TERM HUP

/bin/mkdir -p "$HERE/scratch"
fixture_dir="$(/usr/bin/mktemp -d "$HERE/scratch/idle-fixtures.XXXXXX")"
tests=0
pass() { tests=$((tests + 1)); }
reject() {
    local expected=$1
    shift
    if ( "$@" ) >/dev/null 2>&1; then
        echo "accepted rejected fixture: $expected" >&2
        exit 1
    fi
    pass
}

# A partial stderr/serial record is not a marker until its newline arrives.
printf '%s' 'OBSERVER_BEGIN sample_id=x workload=idle' > "$fixture_dir/observer.log"
[ -z "$(idle_complete_lines 'OBSERVER_BEGIN sample_id=x workload=idle' "$fixture_dir/observer.log")" ]
printf '\n' >> "$fixture_dir/observer.log"
[ "$(idle_complete_lines 'OBSERVER_BEGIN sample_id=x workload=idle' "$fixture_dir/observer.log")" = \
  'OBSERVER_BEGIN sample_id=x workload=idle' ]
pass

# Duplicate guest markers are rejected by the exact-prefix waiter.
printf '%s\n%s\n' \
  'M3_IDLE_DONE token=t cpus=8 wakes=24 checksum=0123456789abcdef' \
  'M3_IDLE_DONE token=t cpus=8 wakes=24 checksum=0123456789abcdef' > "$fixture_dir/serial.log"
SERIAL_LOG="$fixture_dir/serial.log"
CONTROL_STEPS=1
reject duplicate_done idle_wait_serial_prefix 'M3_IDLE_DONE token=t cpus=8 '

# Accounting accepts one finite, nonnegative, stable idle row.
IDLE_SMP=8
IDLE_OBSERVER_RAW="$fixture_dir/accounting.jsonl"
cat > "$IDLE_OBSERVER_RAW" <<'JSON'
{"sample_id":"s","workload":"idle","host_wall_seconds":30.125,"qemu_process_cpu_seconds":0.25,"qemu_vcpu_cpu_seconds":0.20,"qemu_management_cpu_seconds":0.05,"vcpu_thread_count":8,"vcpu_thread_set_stable":true,"accounting_status":"ok","boundary_source":"observer-handshake","sampling_uncertainty_seconds":0.00001,"counter_skew_clamped_seconds":0}
JSON
idle_validate_accounting s
pass

bad_row() {
    local expression=$1
    sed "$expression" "$fixture_dir/accounting.jsonl" > "$fixture_dir/bad.jsonl"
    IDLE_OBSERVER_RAW="$fixture_dir/bad.jsonl"
    idle_validate_accounting s
}
reject wrong_thread_count bad_row 's/"vcpu_thread_count":8/"vcpu_thread_count":7/'

cp "$fixture_dir/accounting.jsonl" "$fixture_dir/duplicate.jsonl"
cat "$fixture_dir/accounting.jsonl" >> "$fixture_dir/duplicate.jsonl"
IDLE_OBSERVER_RAW="$fixture_dir/duplicate.jsonl"
reject duplicate_accounting idle_validate_accounting s

reject wrong_boundary bad_row 's/"boundary_source":"observer-handshake"/"boundary_source":"serial-marker-receipt"/'
reject excess_skew bad_row 's/"counter_skew_clamped_seconds":0/"counter_skew_clamped_seconds":1/'
reject impossible_occupancy bad_row 's/"qemu_process_cpu_seconds":0.25/"qemu_process_cpu_seconds":10000.05/;s/"qemu_vcpu_cpu_seconds":0.20/"qemu_vcpu_cpu_seconds":10000/'
reject short_wall bad_row 's/"host_wall_seconds":30.125/"host_wall_seconds":29/'

cat > "$fixture_dir/negative.jsonl" <<'JSON'
{"sample_id":"s","workload":"idle","host_wall_seconds":30,"qemu_process_cpu_seconds":-1,"qemu_vcpu_cpu_seconds":0,"qemu_management_cpu_seconds":0,"vcpu_thread_count":8,"vcpu_thread_set_stable":true,"accounting_status":"ok","boundary_source":"observer-handshake","sampling_uncertainty_seconds":0.00001,"counter_skew_clamped_seconds":0}
JSON
IDLE_OBSERVER_RAW="$fixture_dir/negative.jsonl"
reject negative_cpu idle_validate_accounting s

cat > "$fixture_dir/zero.jsonl" <<'JSON'
{"sample_id":"s","workload":"idle","host_wall_seconds":30,"qemu_process_cpu_seconds":0,"qemu_vcpu_cpu_seconds":0,"qemu_management_cpu_seconds":0,"vcpu_thread_count":8,"vcpu_thread_set_stable":true,"accounting_status":"ok","boundary_source":"observer-handshake","sampling_uncertainty_seconds":0.00001,"counter_skew_clamped_seconds":0}
JSON
IDLE_OBSERVER_RAW="$fixture_dir/zero.jsonl"
idle_validate_accounting s
pass

# Per-CPU evidence is exact: CPU number, three wakes, reviewed checksum, and
# a positive idle delta whose arithmetic agrees with before/after counters.
idle_validate_cpu_line \
  'M3_IDLE_CPU token=s cpu=0 wakes=3 checksum=c4fa5bc401b5bac2 idle_ticks_before=10 idle_ticks_after=15 idle_ticks_delta=5' s 0
pass
reject cpu_checksum idle_validate_cpu_line \
  'M3_IDLE_CPU token=s cpu=0 wakes=3 checksum=0000000000000000 idle_ticks_before=10 idle_ticks_after=15 idle_ticks_delta=5' s 0
reject cpu_number idle_validate_cpu_line \
  'M3_IDLE_CPU token=s cpu=1 wakes=3 checksum=c4fa5bc401b5bac2 idle_ticks_before=10 idle_ticks_after=15 idle_ticks_delta=5' s 0
reject cpu_token idle_validate_cpu_line \
  'M3_IDLE_CPU token=old cpu=0 wakes=3 checksum=c4fa5bc401b5bac2 idle_ticks_before=10 idle_ticks_after=15 idle_ticks_delta=5' s 0
reject cpu_wakes idle_validate_cpu_line \
  'M3_IDLE_CPU token=s cpu=0 wakes=2 checksum=c4fa5bc401b5bac2 idle_ticks_before=10 idle_ticks_after=15 idle_ticks_delta=5' s 0
reject cpu_delta idle_validate_cpu_line \
  'M3_IDLE_CPU token=s cpu=0 wakes=3 checksum=c4fa5bc401b5bac2 idle_ticks_before=10 idle_ticks_after=15 idle_ticks_delta=4' s 0
reject cpu_zero_delta idle_validate_cpu_line \
  'M3_IDLE_CPU token=s cpu=0 wakes=3 checksum=c4fa5bc401b5bac2 idle_ticks_before=10 idle_ticks_after=10 idle_ticks_delta=0' s 0

# Reopening the serial FIFO after QEMU has toggled its inherited OFD must
# restore blocking writes, and closing every writer must deliver EOF.
FIFO_SYSROOT=/
if [ -x /usr/bin/xcrun ]; then
    FIFO_SYSROOT="$(/usr/bin/xcrun --show-sdk-path)"
fi
"$CLANG" -O2 -Wall -Wextra -Werror -std=c11 \
  -isysroot "$FIFO_SYSROOT" \
  "$HERE/scripts/test-idle-fifo.c" -o "$fixture_dir/test-idle-fifo"
"$fixture_dir/test-idle-fifo" "$fixture_dir/serial.fifo"
pass

# The guest marker vocabulary and three-cycle quiet protocol remain present.
/usr/bin/grep -q 'M3_IDLE_READY token=' "$HERE/scripts/arm64-idle-wakeup.c"
/usr/bin/grep -q 'M3_IDLE_DONE token=' "$HERE/scripts/arm64-idle-wakeup.c"
/usr/bin/grep -q 'M3_IDLE_CPU token=' "$HERE/scripts/arm64-idle-wakeup.c"
/usr/bin/grep -q 'M3_IDLE_PASS nonce=' "$HERE/scripts/arm64-idle-wakeup.c"
/usr/bin/grep -q '#define CYCLES 3' "$HERE/scripts/arm64-idle-wakeup.c"
pass

/bin/bash -n "$HERE/scripts/idle-vm.sh"
/bin/bash -n "$HERE/scripts/test-idle-fixtures.sh"
echo "idle: $tests protocol/accounting fixtures passed; Bash syntax passed; no VM launched"
echo "fixture artifacts: $fixture_dir"

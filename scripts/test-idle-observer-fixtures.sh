#!/bin/bash
# Compile the macOS QEMU CPU observer and exercise its parser/output without
# starting QEMU, opening a VM disk, or requiring a live target process.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
SOURCE="$HERE/scripts/qemu-hvf-cpu-observer.c"
CLANG="${CLANG:-/usr/bin/clang}"
JQ="${JQ:-/usr/bin/jq}"

if [ "$(uname -s)" != Darwin ]; then
    echo "idle observer fixtures skipped: macOS libproc/Mach headers unavailable"
    exit 0
fi
[ -x "$CLANG" ] || { echo "missing compiler: $CLANG" >&2; exit 1; }
[ -x "$JQ" ] || { echo "missing jq: $JQ" >&2; exit 1; }

mkdir -p "$HERE/scratch"
FIXTURE_DIR="$(mktemp -d "$HERE/scratch/idle-observer.XXXXXX")"
trap 'rm -rf -- "$FIXTURE_DIR"' EXIT

"$CLANG" -O2 -Wall -Wextra -Werror -std=c11 \
    "$SOURCE" -o "$FIXTURE_DIR/qemu-hvf-cpu-observer"

# Rename the production entry point and include the source directly so static
# parser/accounting helpers can be tested without a QEMU PID or VM.
printf '%s\n' \
    '#undef main' \
    '#include <stdio.h>' \
    '#include <string.h>' \
    'static int failures;' \
    'static void marker(const char *line, int expected_begin, const char *id, const char *workload)' \
    '{' \
    '    bool begin = false;' \
    '    char got_id[65] = { 0 };' \
    '    char got_workload[16] = { 0 };' \
    '    if (parse_marker(line, &begin, got_id, got_workload) != 0 ||' \
    '        begin != (expected_begin != 0) || strcmp(got_id, id) != 0 ||' \
    '        strcmp(got_workload, workload) != 0) {' \
    '        ++failures;' \
    '    }' \
    '}' \
    'static void rejects(const char *line)' \
    '{' \
    '    bool begin = false;' \
    '    char id[65] = { 0 };' \
    '    char workload[16] = { 0 };' \
    '    if (parse_marker(line, &begin, id, workload) == 0) {' \
    '        ++failures;' \
    '    }' \
    '}' \
    'int main(void)' \
    '{' \
    '    struct snapshot start = { 0 };' \
    '    struct snapshot end = { 0 };' \
    '    target_smp = 2;' \
    '    marker("BENCH_WORK_BEGIN sample_id=legacy workload=integer", 1, "legacy", "integer");' \
    '    marker("BENCH_WORK_END sample_id=legacy workload=integer status=ok", 0, "legacy", "integer");' \
    '    marker("BENCH_WORK_BEGIN sample_id=memory-1 workload=memory", 1, "memory-1", "memory");' \
    '    marker("BENCH_WORK_END sample_id=memory-1 workload=memory status=ok", 0, "memory-1", "memory");' \
    '    marker("BENCH_WORK_BEGIN sample_id=idle-1 workload=idle", 1, "idle-1", "idle");' \
    '    marker("BENCH_WORK_END sample_id=idle-1 workload=idle status=ok", 0, "idle-1", "idle");' \
    '    rejects("BENCH_WORK_BEGIN sample_id=bad workload=spin");' \
    '    rejects("BENCH_WORK_END sample_id=bad workload=idle status=failed");' \
    '    rejects("BENCH_WORK_BEGIN sample_id=bad workload=idle extra");' \
    '    start.vcpu_count = end.vcpu_count = 2;' \
    '    start.vcpus[0].tid = end.vcpus[0].tid = 100;' \
    '    start.vcpus[1].tid = end.vcpus[1].tid = 101;' \
    '    start.monotonic_ns = 10;' \
    '    end.monotonic_ns = 1000000010;' \
    '    if (print_interval("legacy", "integer", &start, &end) != 0 ||' \
    '        print_interval("idle-1", "idle", &start, &end) != 0) {' \
    '        ++failures;' \
    '    }' \
    '    return failures != 0;' \
    '}' | "$CLANG" -O2 -Wall -Wextra -Werror -std=c11 \
    -Dmain=observer_program_main -include "$SOURCE" -x c - \
    -o "$FIXTURE_DIR/parser-fixture"

JSON="$FIXTURE_DIR/output.jsonl"
"$FIXTURE_DIR/parser-fixture" > "$JSON"
"$JQ" -s -e '
  length == 2 and
  (.[0].sample_id == "legacy" and .[0].workload == "integer" and
   .[0].boundary_source == "serial-marker-receipt") and
  (.[1].sample_id == "idle-1" and .[1].workload == "idle" and
   .[1].boundary_source == "observer-handshake") and
  all(.[]; .accounting_status == "ok" and
    .host_wall_seconds == 1.0 and
    .qemu_process_cpu_seconds == 0 and
    .qemu_vcpu_cpu_seconds == 0 and
    .qemu_management_cpu_seconds == 0 and
    .vcpu_thread_count == 2 and
    .vcpu_thread_set_stable == true)
' "$JSON" >/dev/null

echo "idle observer fixtures passed: compiler, legacy/idle markers, rejection paths, and zero-CPU JSON"

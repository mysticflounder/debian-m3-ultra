#!/bin/bash
# Static payload checks and adversarial evidence fixtures; never starts QEMU.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
AWK=/usr/bin/awk
JQ=/usr/bin/jq
mkdir -p "$HERE/scratch"
fixture_dir=$(mktemp -d "$HERE/scratch/psci-fixtures.XXXXXX")
# macOS Bash 3.2 can silently ignore a process-substitution source. Retain
# extracted helpers as a regular fixture artifact before sourcing them.
sed -n '/^normalize_control_cleanup() {/,/^run_cycle() {/p' "$HERE/scripts/psci-vm.sh" | sed '$d' > "$fixture_dir/helpers.sh"
source "$fixture_dir/helpers.sh"
declare -F make_psci_script >/dev/null
for n in 1 8 16 24 32; do
    mkdir "$fixture_dir/$n"
    make_psci_script "$n" > "$fixture_dir/$n/guest.sh"
    /bin/bash -n "$fixture_dir/$n/guest.sh"
    for cycle in 1 2; do
        make_guest_script "$cycle" "$n" fixture-token > "$fixture_dir/$n/boot-$cycle.sh"
        /bin/bash -n "$fixture_dir/$n/boot-$cycle.sh"
    done
    : > "$fixture_dir/$n/console.txt"
    if validate_psci "$n" "$fixture_dir/$n/console.txt" "$fixture_dir/$n"; then
        echo 'empty evidence incorrectly accepted' >&2; exit 1
    fi
    cp "$fixture_dir/$n/expected-transitions.txt" "$fixture_dir/$n/console.txt"
    validate_psci "$n" "$fixture_dir/$n/console.txt" "$fixture_dir/$n"
    sed '$d' "$fixture_dir/$n/expected-transitions.txt" > "$fixture_dir/$n/console.txt"
    if validate_psci "$n" "$fixture_dir/$n/console.txt" "$fixture_dir/$n"; then
        echo 'incomplete evidence incorrectly accepted' >&2; exit 1
    fi
    sed 's/online=1 /online=2 /; s/observed=1$/observed=0/' \
        "$fixture_dir/$n/expected-transitions.txt" > "$fixture_dir/$n/console.txt"
    if validate_psci "$n" "$fixture_dir/$n/console.txt" "$fixture_dir/$n"; then
        echo 'incorrect CPU evidence accepted' >&2; exit 1
    fi
    cp "$fixture_dir/$n/expected-transitions.txt" "$fixture_dir/$n/console.txt"
    printf 'PSCI_TRANSITIONS status=passed count=0\n' >> "$fixture_dir/$n/console.txt"
    if validate_psci "$n" "$fixture_dir/$n/console.txt" "$fixture_dir/$n"; then
        echo 'duplicate evidence incorrectly accepted' >&2; exit 1
    fi
done
for state in skipped cleaned leftover; do
    "$JQ" -n --arg state "$state" '{cycles:[
        {attempted:true,temporary_qemu_pid_file_removed:true},
        {attempted:($state != "skipped"),temporary_qemu_pid_file_removed:($state == "cleaned")}
    ], safety:{}}' > "$fixture_dir/cleanup-$state.json"
    normalize_control_cleanup "$fixture_dir/cleanup-$state.json" > "$fixture_dir/cleanup-$state-observed.json"
    "$JQ" -e --arg state "$state" '
        .safety.temporary_control_staging_removed == ($state != "leftover") and
        (if $state == "skipped" then .cycles[1].temporary_qemu_pid_file_removed == null else true end)
    ' "$fixture_dir/cleanup-$state-observed.json" >/dev/null
done
/bin/bash -n "$HERE/scripts/psci-vm.sh"
printf 'PSCI static and evidence fixtures passed; artifacts: %s\n' "$fixture_dir"

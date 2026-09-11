#!/bin/bash
# Host-only bounded EL0 run plus malformed-result fixtures. No VM launch.
set -euo pipefail
umask 077
HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
mkdir -p "$HERE/scratch"
run="$(mktemp -d "$HERE/scratch/rpres-test.XXXXXX")"
validator="$HERE/scripts/validate-rpres-probe.jq"
for opt in 0 2; do
    /usr/bin/clang -std=c11 -O"$opt" -Wall -Wextra -Werror \
        "$HERE/scripts/arm64-rpres-probe.c" -o "$run/probe-o$opt"
    "$run/probe-o$opt" > "$run/host-o$opt.json"
    /usr/bin/jq -e -f "$validator" "$run/host-o$opt.json" >/dev/null
done
cmp "$run/host-o0.json" "$run/host-o2.json"
tests=3
for mutation in \
    'del(.samples[0])' \
    '.samples[0] = .samples[1]' \
    '.samples[0].fpcr = "0x0000000000000002"' \
    '.samples[0].fpsr = "0x0000000000000001"' \
    '.samples[0].result = "bad"' \
    '.state_restored = false' \
    '.restored_fpcr = "0x0000000000000001"'; do
    /usr/bin/jq "$mutation" "$run/host-o2.json" > "$run/malformed.json"
    if /usr/bin/jq -e -f "$validator" "$run/malformed.json" >/dev/null; then
        echo "accepted mutation: $mutation" >&2
        exit 1
    fi
    tests=$((tests+1))
done
printf '%s checks passed; artifacts: %s\n' "$tests" "$run"

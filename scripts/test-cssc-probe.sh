#!/bin/bash
# Small host child-process tests; no VM launch or CPU setting changes.
set -euo pipefail
umask 077
HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
mkdir -p "$HERE/scratch"
run="$(mktemp -d "$HERE/scratch/cssc-test.XXXXXX")"
validator="$HERE/scripts/validate-cssc-probe.jq"
shasum -a 256 "$HERE/scripts/arm64-cssc-probe.c" "$validator" \
    "$HERE/scripts/compare-cssc-results.sh" "$HERE/scripts/test-cssc-probe.sh" > "$run/source-sha256.txt"
clang --version > "$run/compiler.txt"
sw_vers > "$run/host-os.txt"
date -u '+%Y-%m-%dT%H:%M:%SZ' > "$run/collected-at.txt"
for opt in 0 2; do
    clang -std=c11 -O"$opt" -Wall -Wextra -Werror "$HERE/scripts/arm64-cssc-probe.c" -o "$run/probe-o$opt"
    "$run/probe-o$opt" > "$run/host-o$opt.json"
    jq -e -s 'length==1' "$run/host-o$opt.json" >/dev/null
    jq -e -f "$validator" "$run/host-o$opt.json" >/dev/null
done
cmp "$run/host-o0.json" "$run/host-o2.json"
bash "$HERE/scripts/compare-cssc-results.sh" "$run/host-o0.json" "$run/host-o2.json" > "$run/comparison.json"
jq -e '.all_equal and .exact_count==27' "$run/comparison.json" >/dev/null
tests=4
# A valid executing feature is not rejected merely because this host faults.
jq '.samples |= map(.outcome="result" | .result=.expected_if_executed)' "$run/host-o2.json" > "$run/executing.json"
jq -e -f "$validator" "$run/executing.json" >/dev/null
tests=$((tests+1))
for mutation in \
    'del(.samples[0])' \
    '.samples[0]=.samples[1]' \
    '.samples[0].outcome="SIGILL" | .samples[0].result=null' \
    '.samples[0].expected_if_executed="0x0000000000000000" | .samples[0].result="0x0000000000000000"' \
    '.samples[3].outcome="timeout"' \
    '.samples[3].outcome="SIGILL" | .samples[3].result="0x0000000000000000"' \
    '.core_dumps_disabled=false'; do
    jq "$mutation" "$run/host-o2.json" > "$run/bad.json"
    if jq -e -f "$validator" "$run/bad.json" >/dev/null; then echo "accepted mutation: $mutation" >&2; exit 1; fi
    tests=$((tests+1))
done
jq -c '.,.' "$run/host-o2.json" > "$run/multiple.json"
if bash "$HERE/scripts/compare-cssc-results.sh" "$run/host-o0.json" "$run/multiple.json" >/dev/null 2>&1; then exit 1; fi
tests=$((tests+1))
shasum -a 256 -c "$run/source-sha256.txt" > "$run/source-check.txt"
printf '%s checks passed; artifacts: %s\n' "$tests" "$run"

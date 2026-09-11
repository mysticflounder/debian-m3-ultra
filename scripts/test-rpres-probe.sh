#!/bin/bash
# Host-only bounded EL0 run plus malformed-result fixtures. No VM launch.
set -euo pipefail
umask 077
HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
mkdir -p "$HERE/scratch"
run="$(mktemp -d "$HERE/scratch/rpres-test.XXXXXX")"
validator="$HERE/scripts/validate-rpres-probe.jq"
/usr/bin/shasum -a 256 "$HERE/scripts/arm64-rpres-probe.c" \
    "$HERE/scripts/rpres-reference.c" "$HERE/scripts/rpres-state-fixture.c" \
    "$HERE/scripts/test-rpres-probe.sh" "$HERE/scripts/compare-rpres-results.sh" \
    "$validator" > "$run/source-sha256.txt"
/usr/bin/clang --version > "$run/compiler.txt"
/usr/bin/sw_vers > "$run/host-os.txt"
/bin/date -u '+%Y-%m-%dT%H:%M:%SZ' > "$run/collected-at.txt"
for opt in 0 2; do
    /usr/bin/clang -std=c11 -O"$opt" -Wall -Wextra -Werror \
        "$HERE/scripts/arm64-rpres-probe.c" -o "$run/probe-o$opt"
    "$run/probe-o$opt" > "$run/host-o$opt.json"
    /usr/bin/jq -e -f "$validator" "$run/host-o$opt.json" >/dev/null
done
cmp "$run/host-o0.json" "$run/host-o2.json"
tests=3
/usr/bin/clang -std=c11 -O2 -Wall -Wextra -Werror \
    "$HERE/scripts/rpres-reference.c" -o "$run/reference"
"$run/reference" > "$run/reference.json"
/usr/bin/jq -e --slurpfile reference "$run/reference.json" '
    def results: [.samples[] | {ah_requested,op,input,result}] |
        sort_by([.ah_requested,.op,.input]);
    results == ($reference[0] | results)' "$run/host-o2.json" >/dev/null
tests=$((tests+1))
bash "$HERE/scripts/compare-rpres-results.sh" "$run/host-o0.json" \
    "$run/host-o2.json" > "$run/comparison.json"
/usr/bin/jq -e '.all_equal and .exact_count == 28 and .mismatch_count == 0' \
    "$run/comparison.json" >/dev/null
/usr/bin/jq '.samples[0].result = "0x00000000"' "$run/host-o2.json" > "$run/different.json"
bash "$HERE/scripts/compare-rpres-results.sh" "$run/host-o0.json" \
    "$run/different.json" > "$run/difference.json"
/usr/bin/jq -e '(.all_equal|not) and .exact_count == 27 and .mismatch_count == 1' \
    "$run/difference.json" >/dev/null
tests=$((tests+2))
/usr/bin/jq -c '., .' "$run/host-o2.json" > "$run/duplicate-document.json"
if bash "$HERE/scripts/compare-rpres-results.sh" "$run/host-o0.json" \
    "$run/duplicate-document.json" > "$run/duplicate-comparison.json" 2>/dev/null; then
    echo "accepted multiple JSON documents" >&2
    exit 1
fi
tests=$((tests+1))
for opt in 0 2; do
    /usr/bin/clang -std=c11 -O"$opt" -Wall -Wextra -Werror \
        "$HERE/scripts/rpres-state-fixture.c" -o "$run/state-o$opt"
    "$run/state-o$opt" > "$run/state-o$opt.json"
    /usr/bin/jq -e -f "$validator" "$run/state-o$opt.json" >/dev/null
    /usr/bin/jq -e '.saved_fpcr == "0x0000000000400000" and
        .saved_fpsr == "0x0000000000000011"' "$run/state-o$opt.json" >/dev/null
    tests=$((tests+1))
done
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
/usr/bin/shasum -a 256 -c "$run/source-sha256.txt" > "$run/source-check.txt"
printf '%s checks passed; artifacts: %s\n' "$tests" "$run"

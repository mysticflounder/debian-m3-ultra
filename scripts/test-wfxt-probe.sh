#!/bin/bash
# Build/disassembly and synthetic-validator tests only. Never execute a WFxT probe.
set -euo pipefail
umask 077
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
mkdir -p "$HERE/scratch"
run="$(mktemp -d "$HERE/scratch/wfxt-test.XXXXXX")"
source="$HERE/scripts/arm64-wfxt-probe.c"
validator="$HERE/scripts/validate-wfxt-probe.jq"
compare="$HERE/scripts/compare-wfxt-results.sh"
for file in "$source" "$validator" "$compare" "$HERE/scripts/test-wfxt-probe.sh"; do
    [ -f "$file" ] && [ ! -L "$file" ] || exit 1
done
/usr/bin/shasum -a 256 "$source" "$validator" "$compare" \
    "$HERE/scripts/test-wfxt-probe.sh" > "$run/source-sha256.txt"
/usr/bin/clang --version > "$run/compiler.txt"
/usr/bin/clang -std=c11 -O0 -Wall -Wextra -Werror "$source" -o "$run/probe-o0"
/usr/bin/clang -std=c11 -O2 -Wall -Wextra -Werror "$source" -o "$run/probe-o2"
/usr/bin/otool -tvV "$run/probe-o0" > "$run/disassembly-o0.txt"
/usr/bin/otool -tvV "$run/probe-o2" > "$run/disassembly-o2.txt"
for disassembly in "$run/disassembly-o0.txt" "$run/disassembly-o2.txt"; do
    /usr/bin/grep -Eq '[[:space:]]wfet[[:space:]]+x0' "$disassembly"
    /usr/bin/grep -Eq '[[:space:]]wfit[[:space:]]+x0' "$disassembly"
done
/usr/bin/grep -E '[[:space:]](wfet|wfit)[[:space:]]+x0' \
    "$run/disassembly-o0.txt" | /usr/bin/sed -E 's/^[^[:space:]]+[[:space:]]+//' \
    > "$run/capabilities-o0.txt"
/usr/bin/grep -E '[[:space:]](wfet|wfit)[[:space:]]+x0' \
    "$run/disassembly-o2.txt" | /usr/bin/sed -E 's/^[^[:space:]]+[[:space:]]+//' \
    > "$run/capabilities-o2.txt"
cmp "$run/capabilities-o0.txt" "$run/capabilities-o2.txt"

/usr/bin/jq -n '
  {schema_version:1,core_dumps_disabled:true,observations_valid:true,
   samples:[
    {op:"NOP",input:"0x0000000000000000",outcome:"result",result:"0x000000000000a001",expected_if_executed:"0x000000000000a001"},
    {op:"ADD",input:"0x0000000000000000",outcome:"result",result:"0x0000000000000001",expected_if_executed:"0x0000000000000001"},
    {op:"WFET",input:"0x0000000000000000",outcome:"result",result:"0x000000000000a003",expected_if_executed:"0x000000000000a003"},
    {op:"WFIT",input:"0x0000000000000000",outcome:"result",result:"0x000000000000a004",expected_if_executed:"0x000000000000a004"}
   ]}' > "$run/fixture-results.json"
/usr/bin/jq -e -f "$validator" "$run/fixture-results.json" >/dev/null
/usr/bin/jq '
  .samples |= map(if .op == "WFET" or .op == "WFIT"
                  then .outcome="SIGILL" | .result=null else . end)' \
    "$run/fixture-results.json" > "$run/fixture-sigill.json"
/usr/bin/jq -e -f "$validator" "$run/fixture-sigill.json" >/dev/null
bash "$compare" "$run/fixture-results.json" "$run/fixture-sigill.json" > "$run/comparison.json"
/usr/bin/jq -e '(.all_equal|not) and .exact_count==2 and .mismatch_count==2' \
    "$run/comparison.json" >/dev/null
tests=6
for mutation in \
    'del(.samples[0])' \
    '.samples[0]=.samples[1]' \
    '.samples[0].outcome="SIGILL" | .samples[0].result=null' \
    '.samples[2].outcome="timeout" | .samples[2].result=null' \
    '.samples[2].outcome="SIGILL" | .samples[2].result="0x000000000000a003"' \
    '.samples[2].outcome="SIGILL" | del(.samples[2].result)' \
    '.samples[0].expected_if_executed="0x000000000000a005" | .samples[0].result="0x000000000000a005"' \
    '.samples[0].input="0x0000000000000001"' \
    '.core_dumps_disabled=false'; do
    /usr/bin/jq "$mutation" "$run/fixture-results.json" > "$run/malformed.json"
    if /usr/bin/jq -e -f "$validator" "$run/malformed.json" >/dev/null; then
        echo "accepted mutation: $mutation" >&2
        exit 1
    fi
    tests=$((tests+1))
done
/usr/bin/jq -c '.,.' "$run/fixture-results.json" > "$run/multiple.json"
if bash "$compare" "$run/fixture-results.json" "$run/multiple.json" >/dev/null 2>&1; then
    echo "accepted multiple JSON documents" >&2
    exit 1
fi
tests=$((tests+1))
/usr/bin/shasum -a 256 -c "$run/source-sha256.txt" > "$run/source-check.txt"
printf '%s checks passed; artifacts: %s\n' "$tests" "$run"

#!/bin/bash
# Compare complete controlled observations, never infer a feature from timing.
set -euo pipefail
[ "$#" = 2 ] || { echo "usage: $0 HOST_JSON GUEST_JSON" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
for input in "$@"; do
    /usr/bin/jq -e -s 'length == 1' "$input" >/dev/null
    /usr/bin/jq -e -f "$HERE/scripts/validate-rpres-probe.jq" "$input" >/dev/null
done
/usr/bin/jq -n --arg host_path "$1" --arg guest_path "$2" \
  --slurpfile host "$1" --slurpfile guest "$2" '
  def rows: .samples | sort_by([.ah_requested,.op,.input]);
  ($host[0] | rows) as $h | ($guest[0] | rows) as $g |
  [range(0;28) as $i |
    {ah_requested:$h[$i].ah_requested,op:$h[$i].op,input:$h[$i].input,
     host_result:$h[$i].result,guest_result:$g[$i].result,
     equal:($h[$i].result == $g[$i].result)}] as $comparisons |
  {schema_version:1,scope:"controlled scalar reciprocal estimate observations",
   host_capture:$host_path,guest_capture:$guest_path,
   row_count:28,exact_count:([$comparisons[]|select(.equal)]|length),
   mismatch_count:([$comparisons[]|select(.equal|not)]|length),
   all_equal:all($comparisons[];.equal),comparisons:$comparisons,
   limitation:"Equality covers these inputs and FP states only, not complete CPU passthrough"}'

#!/bin/bash
set -euo pipefail
[ "$#" = 2 ] || exit 2
HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
for input in "$@"; do
    /usr/bin/jq -e -s 'length==1' "$input" >/dev/null
    /usr/bin/jq -e -f "$HERE/scripts/validate-hbc-probe.jq" "$input" >/dev/null
done
/usr/bin/jq -n --arg host_path "$1" --arg guest_path "$2" --slurpfile host "$1" --slurpfile guest "$2" '
  def rows: .samples | sort_by([.op,.input]);
  ($host[0]|rows) as $h | ($guest[0]|rows) as $g |
  [range(0;8) as $i | {op:$h[$i].op,input:$h[$i].input,
    host_outcome:$h[$i].outcome,guest_outcome:$g[$i].outcome,
    host_result:$h[$i].result,guest_result:$g[$i].result,
    equal:([$h[$i].outcome,$h[$i].result]==[$g[$i].outcome,$g[$i].result])}] as $rows |
  {schema_version:1,host_capture:$host_path,guest_capture:$guest_path,
   all_equal:all($rows[];.equal),exact_count:([$rows[]|select(.equal)]|length),
   mismatch_count:([$rows[]|select(.equal|not)]|length),comparisons:$rows,
   limitation:"Only EQ/NE forward +8 branches with two flag conditions; no prediction/performance claim"}'

#!/bin/bash
# Source-only parser for the bounded EL1 trace-control marker stream.
#
# APIs:
#   parse_trace_control_json SMP MARKERS OUTPUT
#   validate_trace_state_json INPUT REQUEST_ID EVENT

JQ="${JQ:-/usr/bin/jq}"

parse_trace_control_json() {
    [ "$#" -eq 3 ] || return 2
    local smp=$1 markers=$2 output=$3 tmp

    [ -n "$markers" ] && [ -n "$output" ] || return 2
    [ "$markers" != "$output" ] || return 2

    case "$smp" in
        ''|*[!0-9]*) return 2 ;;
    esac
    [ "$smp" -gt 0 ] 2>/dev/null || return 2
    [ -r "$markers" ] || return 1

    tmp="${output}.tmp.$$"
    /bin/rm -f -- "$output" "$tmp"

    # The marker stream is deliberately bounded and ordered: two lines per CPU,
    # with no filtering that could hide an unknown, duplicate, or missing row.
    if ! "$JQ" -Rn --argjson requested_smp "$smp" '
      def attempt_re:
        "^EL1_PROBE_TRACE_CONTROL_ATTEMPT cpu=(?<cpu>[0-9]+) name=OSLSR_EL1$";
      def value_re:
        "^EL1_PROBE_TRACE_CONTROL_VALUE cpu=(?<cpu>[0-9]+) name=OSLSR_EL1 status=read value=(?<value>0x[0-9a-f]{16})$";
      def fail($message): error($message);

      [inputs] as $lines |
      if (($requested_smp|type) != "number" or
          ($requested_smp|floor) != $requested_smp or
          $requested_smp < 1) then
        fail("SMP must be a positive integer")
      elif ($lines|length) != (2 * $requested_smp) then
        fail("unexpected trace-control marker line count")
      else
        [range(0; $requested_smp) as $cpu |
         ($cpu * 2) as $line_index |
         $lines[$line_index] as $attempt_line |
         $lines[$line_index + 1] as $value_line |
         if ($attempt_line|test(attempt_re)) and ($value_line|test(value_re)) then
           # test() guards capture(): a failed capture must not silently become
           # an empty object or permit a malformed record through.
           ($attempt_line|capture(attempt_re)) as $attempt |
           ($value_line|capture(value_re)) as $value |
           if (($attempt.cpu|tonumber) != $cpu or
               ($value.cpu|tonumber) != $cpu or
               $attempt.cpu != (($attempt.cpu|tonumber)|tostring) or
               $value.cpu != (($value.cpu|tonumber)|tostring)) then
             fail("trace-control markers are missing, duplicated, or out of order")
           else
             {cpu:$cpu, name:"OSLSR_EL1", status:"read", value:$value.value}
           end
         else
           fail("unknown or malformed trace-control marker")
         end] as $samples |
        {
          schema_version: 1,
          requested_smp: $requested_smp,
          row_count: ($samples|length),
          samples: $samples,
          all_reads_completed: true
        }
      end
    ' "$markers" > "$tmp"; then
        /bin/rm -f -- "$tmp" "$output"
        return 1
    fi
    if ! /bin/mv -f -- "$tmp" "$output"; then
        /bin/rm -f -- "$tmp" "$output"
        return 1
    fi
}

validate_trace_state_json() {
    [ "$#" -eq 3 ] || return 2
    local input=$1 request_id=$2 event=$3
    [ -n "$input" ] && [ -n "$request_id" ] && [ -n "$event" ] || return 2
    [ -r "$input" ] || return 1

    # QMP logs contain greetings and asynchronous events.  Select the requested
    # reply, then require exactly one such reply and the precise enabled state.
    "$JQ" -e -s --arg request_id "$request_id" --arg event "$event" '
      [ .[] | select((.id? // null) == $request_id) ] as $replies |
      if ($replies|length) != 1 then
        error("expected exactly one QMP reply for request ID")
      else
        $replies[0] as $reply |
        if ($reply|has("error")) or (($reply|has("return"))|not) then
          error("QMP trace-state reply has an error or no return")
        elif (($reply.return|type) != "array" or ($reply.return|length) != 1) then
          error("QMP trace-state return must contain exactly one event")
        elif (($reply.return[0].name? == $event) and
              ($reply.return[0].state? == "enabled")) then
          true
        else
          error("trace-state event is not enabled")
        end
      end
    ' "$input" >/dev/null
}

validate_trace_log() {
    [ "$#" -eq 1 ] || return 2
    local input=$1 count
    [ -n "$input" ] && [ -r "$input" ] || return 1

    # The trace stream may contain metadata and sysreg records.  The bounded
    # runner contract needs exactly the pre/post query-status trace records;
    # leave interpretation of the other records to their dedicated parsers.
    count="$(/usr/bin/awk 'index($0, "qmp_enter_query_status ") == 1 { n++ } END { print n + 0 }' "$input")" || return 1
    [ "$count" -eq 2 ] 2>/dev/null
}

# This file intentionally has no main program: sourcing it installs the two
# parser APIs, while direct execution is a harmless no-op.

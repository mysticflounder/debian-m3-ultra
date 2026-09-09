#!/bin/bash
# Source-only parser for the bounded EL1 newer-ID marker stream.
#
# API:
#   parse_new_id_json SMP MARKERS OUTPUT

JQ="${JQ:-/usr/bin/jq}"

parse_new_id_json() {
    [ "$#" -eq 3 ] || return 2
    local smp=$1 markers=$2 output=$3 tmp

    [ -n "$markers" ] && [ -n "$output" ] || return 2
    [ "$markers" != "$output" ] || return 2

    # Remove any stale destination before validating the input path too.
    tmp="${output}.tmp.$$"
    /bin/rm -f -- "$output" "$tmp"

    # Keep the shell-side contract narrow before passing SMP to --argjson.
    case "$smp" in
        ''|*[!0-9]*) return 2 ;;
    esac
    [ "$smp" -gt 0 ] 2>/dev/null || return 2
    [ -r "$markers" ] || return 1

    # Build privately and publish only after jq succeeds.  Remove a stale
    # destination on every failure so failure cannot look like success.
    if ! "$JQ" -Rn --argjson requested_smp "$smp" '
      def attempt_re:
        "^EL1_PROBE_NEW_ID_ATTEMPT cpu=(?<cpu>[0-9]+) name=(?<name>(ID_AA64PFR2_EL1|ID_AA64ISAR2_EL1|ID_AA64MMFR3_EL1|ID_AA64MMFR4_EL1))$";
      def value_re:
        "^EL1_PROBE_NEW_ID_VALUE cpu=(?<cpu>[0-9]+) name=(?<name>(ID_AA64PFR2_EL1|ID_AA64ISAR2_EL1|ID_AA64MMFR3_EL1|ID_AA64MMFR4_EL1)) status=read value=(?<value>0x[0-9a-f]{16})$";
      def register_names:
        ["ID_AA64PFR2_EL1", "ID_AA64ISAR2_EL1",
         "ID_AA64MMFR3_EL1", "ID_AA64MMFR4_EL1"];
      def fail($message): error($message);

      [inputs] as $lines |
      if (($requested_smp|type) != "number" or
          ($requested_smp|floor) != $requested_smp or
          $requested_smp < 1) then
        fail("SMP must be a positive integer")
      elif ($lines|length) != (8 * $requested_smp) then
        fail("unexpected newer-ID marker line count")
      elif any($lines[]; (test(attempt_re) or test(value_re)) | not) then
        fail("unknown or malformed newer-ID marker")
      else
        [range(0; $requested_smp) as $cpu |
         range(0; 4) as $register_index |
         ($cpu * 8 + $register_index * 2) as $line_index |
         (register_names[$register_index]) as $name |
         if (($lines[$line_index] | test(attempt_re)) and
             ($lines[$line_index + 1] | test(value_re))) then
           ($lines[$line_index] | capture(attempt_re)) as $attempt |
           ($lines[$line_index + 1] | capture(value_re)) as $value |
           if (($attempt.cpu|tonumber) != $cpu or
               ($value.cpu|tonumber) != $cpu or
               $attempt.cpu != (($attempt.cpu|tonumber)|tostring) or
               $value.cpu != (($value.cpu|tonumber)|tostring) or
               $attempt.name != $name or $value.name != $name) then
             fail("newer-ID markers are missing, duplicated, or out of order")
           else
             {cpu:$cpu, name:$name, value:$value.value}
           end
         else
           fail("newer-ID markers are missing, duplicated, or out of order")
         end] as $rows |
        if ($rows|length) != (4 * $requested_smp) then
          fail("newer-ID row count contract violated")
        else
          [range(0; $requested_smp) as $cpu |
            {cpu:$cpu,
             registers:(reduce ($rows[] | select(.cpu == $cpu)) as $row
               ({}; .[$row.name] = {status:"read", value:$row.value}))}] as $cpus |
          {
            schema_version: 1,
            requested_smp: $requested_smp,
            row_count: ($rows|length),
            cpus: $cpus,
            all_reads_completed: true,
            register_contract_homogeneous: ([$cpus[].registers] | unique | length == 1)
          }
        end
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

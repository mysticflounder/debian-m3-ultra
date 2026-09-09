#!/bin/bash
# Source-only parser/validator for current-fork EL1 marker streams.
# APIs:
#   parse_probe_json SMP MARKERS OUTPUT
#   validate_probe_json SMP INPUT

JQ="${JQ:-/usr/bin/jq}"

parse_probe_json() {
    local smp=$1 markers=$2 output=$3

    "$JQ" -Rn --argjson requested_smp "$smp" '
      def start_re: "^EL1_PROBE_START schema_version=[0-9]+ online_cpu_count=[0-9]+$";
      def cpu_re: "^EL1_PROBE_CPU cpu=[0-9]+ observed_cpu=[0-9]+ status=(read|not_read)$";
      def reg_re: "^EL1_PROBE_REG cpu=[0-9]+ name=[A-Z0-9_]+ status=(read|not_read) value=0x[0-9a-f]{16}$";
      def selector_re: "^EL1_PROBE_CACHE_SELECTOR cpu=[0-9]+ before=0x[0-9a-f]{16} after=0x[0-9a-f]{16} restored=(yes|no)$";
      def cache_re: "^EL1_PROBE_CACHE cpu=[0-9]+ level=[1-7] ctype=[1-4] cache_type=(data_or_unified|instruction) ind=[01] selector=[0-9]+ status=(read|not_read) value=0x[0-9a-f]{16}$";
      def end_re: "^EL1_PROBE_END sampled_cpu_count=[0-9]+ status=[a-z]+$";
      def valid_marker:
        test(start_re) or test(cpu_re) or test(reg_re) or test(selector_re) or
        test(cache_re) or test(end_re);
      def cpu_row:
        capture("^EL1_PROBE_CPU cpu=(?<cpu>[0-9]+) observed_cpu=(?<observed_cpu>[0-9]+) status=(?<status>read|not_read)$") |
        {cpu:(.cpu|tonumber),observed_cpu:(.observed_cpu|tonumber),status};
      def reg_row:
        capture("^EL1_PROBE_REG cpu=(?<cpu>[0-9]+) name=(?<name>[A-Z0-9_]+) status=(?<status>read|not_read) value=(?<value>0x[0-9a-f]{16})$") |
        {cpu:(.cpu|tonumber),name,status,value:(if .status == "read" then .value else null end)};
      def selector_row:
        capture("^EL1_PROBE_CACHE_SELECTOR cpu=(?<cpu>[0-9]+) before=(?<before>0x[0-9a-f]{16}) after=(?<after>0x[0-9a-f]{16}) restored=(?<restored>yes|no)$") |
        {cpu:(.cpu|tonumber),selector_before:.before,selector_after:.after,selector_restored:(.restored == "yes")};
      def cache_row:
        capture("^EL1_PROBE_CACHE cpu=(?<cpu>[0-9]+) level=(?<level>[1-7]) ctype=(?<ctype>[1-4]) cache_type=(?<cache_type>data_or_unified|instruction) ind=(?<ind>[01]) selector=(?<selector>[0-9]+) status=(?<status>read|not_read) value=(?<value>0x[0-9a-f]{16})$") |
        {cpu:(.cpu|tonumber),level:(.level|tonumber),ctype:(.ctype|tonumber),cache_type,ind:(.ind|tonumber),selector:(.selector|tonumber),status,value:(if .status == "read" then .value else null end)};
      [inputs] as $lines |
      if ($lines|length) == 0 or any($lines[]; (valid_marker|not)) then
        error("unknown or malformed EL1 marker")
      else
        ([$lines[] | select(test(start_re)) | capture("^EL1_PROBE_START schema_version=(?<schema>[0-9]+) online_cpu_count=(?<count>[0-9]+)$") | {schema:(.schema|tonumber),count:(.count|tonumber)}]) as $starts |
        ([$lines[] | select(test(cpu_re)) | cpu_row] | sort_by(.cpu)) as $cpus |
        ([$lines[] | select(test(reg_re)) | reg_row]) as $regs |
        ([$lines[] | select(test(selector_re)) | selector_row]) as $selectors |
        ([$lines[] | select(test(cache_re)) | cache_row]) as $caches |
        ([$lines[] | select(test(end_re)) | capture("^EL1_PROBE_END sampled_cpu_count=(?<count>[0-9]+) status=(?<status>[a-z]+)$") | {count:(.count|tonumber),status}]) as $ends |
        if ($selectors|length) != $requested_smp or
           any($selectors[]; .cpu < 0 or .cpu >= $requested_smp) or
           any($caches[]; .cpu < 0 or .cpu >= $requested_smp) then
          error("cache marker CPU/count contract violated")
        else {
          schema_version:2,
          requested_smp:$requested_smp,
          module_start:$starts,
          module_end:$ends,
          register_row_count:($regs|length),
          cache_row_count:($caches|length),
          cpus:[$cpus[] as $cpu |
            ([$selectors[]|select(.cpu==$cpu.cpu)]) as $sel |
            {cpu:$cpu.cpu,observed_cpu:$cpu.observed_cpu,status:$cpu.status,
             register_row_count:([$regs[]|select(.cpu==$cpu.cpu)]|length),
             registers:(reduce ($regs[]|select(.cpu==$cpu.cpu)) as $r ({}; .[$r.name]={status:$r.status,value:$r.value})),
             cache_registers:(if ($sel|length)==1 then
               {selector_before:$sel[0].selector_before,selector_after:$sel[0].selector_after,selector_restored:$sel[0].selector_restored,
                entries:([$caches[]|select(.cpu==$cpu.cpu)|del(.cpu)]|sort_by(.level,.ind))}
               else null end)}]
        } end
      end
    ' "$markers" > "$output"
}

validate_probe_json() {
    local smp=$1 input=$2
    "$JQ" -e --argjson smp "$smp" '
      def expected_registers: [
        "MPIDR_EL1", "CLIDR_EL1", "CTR_EL0", "DCZID_EL0",
        "ID_AA64PFR0_EL1", "ID_AA64PFR1_EL1", "ID_AA64DFR0_EL1",
        "ID_AA64DFR1_EL1", "ID_AA64ISAR0_EL1", "ID_AA64ISAR1_EL1",
        "ID_AA64MMFR0_EL1", "ID_AA64MMFR1_EL1", "ID_AA64MMFR2_EL1",
        "ID_AA64SMFR0_EL1", "ID_AA64ZFR0_EL1"];
      def hex24:
        .[-6:] | explode |
        reduce .[] as $digit (0;
          . * 16 +
          (if $digit >= 48 and $digit <= 57 then $digit - 48
           elif $digit >= 97 and $digit <= 102 then $digit - 87
           else error("non-hex digit") end));
      def clidr_ctype($value; $level):
        ($value|hex24) as $clidr |
        (($clidr / [1,8,64,512,4096,32768,262144][$level-1])|floor) % 8;
      def cache_group_valid:
        length >= 1 and (map(.ctype)|unique|length) == 1 and .[0].ctype as $ctype |
        if $ctype == 1 then length == 1 and .[0].ind == 1 and .[0].cache_type == "instruction"
        elif $ctype == 2 or $ctype == 4 then length == 1 and .[0].ind == 0 and .[0].cache_type == "data_or_unified"
        elif $ctype == 3 then length == 2 and [.[].ind] == [0,1] and [.[].cache_type] == ["data_or_unified","instruction"]
        else false end;
      def cache_entry_valid:
        (.level|type == "number" and floor == . and . >= 1 and . <= 7) and
        (.ctype|type == "number" and floor == . and . >= 1 and . <= 4) and
        (.ind == 0 or .ind == 1) and .selector == ((.level-1)*2+.ind) and
        (((.ind == 0 and .cache_type == "data_or_unified" and (.ctype == 2 or .ctype == 3 or .ctype == 4)) or
          (.ind == 1 and .cache_type == "instruction" and (.ctype == 1 or .ctype == 3)))) and
        ((.status == "read" and (.value|test("^0x[0-9a-f]{16}$"))) or (.status == "not_read" and .value == null));
      .schema_version == 2 and .requested_smp == $smp and
      .module_start == [{schema:2,count:$smp}] and .module_end == [{count:$smp,status:"ok"}] and
      (.cpus|length) == $smp and .register_row_count == ($smp * (expected_registers|length)) and
      (.cache_row_count|type == "number" and floor == . and . >= 0) and
      .cache_row_count == ([.cpus[].cache_registers.entries[]]|length) and
      [.cpus[].cpu] == [range(0;$smp)] and [.cpus[].observed_cpu] == [range(0;$smp)] and
      ([.cpus[].registers.MPIDR_EL1.value]|unique|length) == $smp and
      ([.cpus[].registers|del(.MPIDR_EL1)]|unique|length) == 1 and
      ([.cpus[].cache_registers.entries]|unique|length) == 1 and
      all(.cpus[];
        . as $cpu |
        .status == "read" and .register_row_count == (expected_registers|length) and
        (.registers|length) == (expected_registers|length) and
        ([expected_registers[] as $name | .registers[$name] != null]|all) and
        all(.registers[];
          (.status == "read" and (.value|test("^0x[0-9a-f]{16}$"))) or
          (.status == "not_read" and .value == null and
            (. == {status:"not_read",value:null}))) and
        (([.registers|to_entries[] | select(.value.status == "not_read") | .key] | sort) == ["ID_AA64SMFR0_EL1","ID_AA64ZFR0_EL1"]) and
        (.cache_registers|type == "object") and .cache_registers.selector_restored == true and
        .cache_registers.selector_after == .cache_registers.selector_before and
        (.cache_registers.selector_before|test("^0x[0-9a-f]{16}$")) and
        (.cache_registers.entries|type == "array") and
        ([.cache_registers.entries[]|[.level,.cache_type]|join(":")]|unique|length) == (.cache_registers.entries|length) and
        all(.cache_registers.entries[]; ((keys|sort) == (["cache_type","ctype","ind","level","selector","status","value"]|sort)) and cache_entry_valid) and
        all(.cache_registers.entries|group_by(.level)[]; cache_group_valid) and
        all(range(1;8); clidr_ctype($cpu.registers.CLIDR_EL1.value; .) <= 4) and
        ([range(1;8) as $level | clidr_ctype($cpu.registers.CLIDR_EL1.value; $level) as $ctype | select($ctype >= 1 and $ctype <= 4) | [$level,$ctype]] ==
         [$cpu.cache_registers.entries|group_by(.level)[]|[.[0].level,.[0].ctype]])
      )
    ' "$input" >/dev/null
}

# This file intentionally has no main program: sourcing it installs the two
# parser APIs, while direct execution is a harmless no-op.

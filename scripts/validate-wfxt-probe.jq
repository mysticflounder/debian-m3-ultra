# Exact four-case validation. Timed cases may return or catch SIGILL; timeout is invalid.
def fixed_input: "0x0000000000000000";
def ops: ["NOP", "ADD", "WFET", "WFIT"];
def expected:
    if .op == "NOP" then "0x000000000000a001"
    elif .op == "ADD" then "0x0000000000000001"
    elif .op == "WFET" then "0x000000000000a003"
    else "0x000000000000a004" end;
def cases: [ops[] as $op | [$op, fixed_input]];

.schema_version == 1 and
.core_dumps_disabled == true and
.observations_valid == true and
(.samples | type) == "array" and
(.samples | length) == 4 and
all(.samples[];
    (type == "object") and
    has("result") and
    (.op | type) == "string" and
    (.input == fixed_input) and
    (.outcome | type) == "string" and
    (.expected_if_executed == expected) and
    (if .outcome == "result" then
         (.result == expected)
     elif .outcome == "SIGILL" then
         ((.op == "WFET" or .op == "WFIT") and .result == null)
     else false end) and
    (if .op == "NOP" or .op == "ADD" then .outcome == "result"
     else (.outcome == "result" or .outcome == "SIGILL") end)) and
([.samples[] | [.op, .input]] | sort) == (cases | sort)

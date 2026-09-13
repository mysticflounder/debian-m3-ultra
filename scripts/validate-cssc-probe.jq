# Validate observations without assuming unadvertised instructions must fault.
def inputs: ["0xfffffffffffffffe","0x0000000000000000","0x0000000000000002"];
def ops: ["ADD_X","SMAX_W","SMIN_W","UMAX_W","UMIN_W","SMAX_X","SMIN_X","UMAX_X","UMIN_X"];
def hex64: type=="string" and test("^0x[0-9a-f]{16}$");
def want:
    .input as $i | .op as $op |
    if $op=="ADD_X" then
        if $i=="0xfffffffffffffffe" then "0xffffffffffffffff"
        elif $i=="0x0000000000000000" then "0x0000000000000001" else "0x0000000000000003" end
    elif ($op|startswith("SMAX")) then
        if $i=="0x0000000000000002" then $i else "0x0000000000000001" end
    elif ($op|startswith("UMAX")) then
        if $i=="0x0000000000000000" then "0x0000000000000001"
        elif $op=="UMAX_W" and $i=="0xfffffffffffffffe" then "0x00000000fffffffe" else $i end
    elif ($op|startswith("SMIN")) then
        if $i=="0x0000000000000002" then "0x0000000000000001"
        elif $op=="SMIN_W" and $i=="0xfffffffffffffffe" then "0x00000000fffffffe" else $i end
    else if $i=="0x0000000000000000" then $i else "0x0000000000000001" end end;
.schema_version==1 and .core_dumps_disabled==true and .observations_valid==true and
(.samples|length)==27 and
([.samples[]|[.op,.input]]|sort)==([ops[] as $op|inputs[]|[$op,.]]|sort) and
all(.samples[];
    (.expected_if_executed|hex64) and .expected_if_executed==want and
    (if .op=="ADD_X" then .outcome=="result" else
        (.outcome=="result" or .outcome=="SIGILL") end) and
    (if .outcome=="result" then (.result|hex64) and .result==.expected_if_executed
     else .result==null end))

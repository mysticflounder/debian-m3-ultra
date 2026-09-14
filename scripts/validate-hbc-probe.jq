# Exact coverage and expected forward-branch results, independent of signals.
def inputs: ["0x0000000000000000","0x0000000000000001"];
def ops: ["B_EQ","B_NE","BC_EQ","BC_NE"];
def want:
    if ((.op|endswith("EQ")) == (.input=="0x0000000000000000"))
    then "0x0000000000000000" else "0x0000000000000001" end;
.schema_version==1 and .core_dumps_disabled==true and .observations_valid==true and
(.samples|length)==8 and
([.samples[]|[.op,.input]]|sort)==([ops[] as $op|inputs[]|[$op,.]]|sort) and
all(.samples[];
    .expected_if_executed==want and
    (if (.op|startswith("B_")) then .outcome=="result"
     else (.outcome=="result" or .outcome=="SIGILL") end) and
    (if .outcome=="result" then .result==want else .result==null end))

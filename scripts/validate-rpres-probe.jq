# Structural/control validation only: this does not classify instruction behavior.
def hex64: type == "string" and test("^0x[0-9a-f]{16}$");
def hex32: type == "string" and test("^0x[0-9a-f]{8}$");
def inputs: ["0x3f800000","0x3fa00000","0x3fc00000","0x3fe00000",
             "0x40000000","0x40400000","0x41200000"];
.schema_version == 1 and .state_restored == true and
(.saved_fpcr | hex64) and (.saved_fpsr | hex64) and
.saved_fpcr == .restored_fpcr and .saved_fpsr == .restored_fpsr and
(.samples | length) == 28 and
([.samples[] | [.ah_requested, .op, .input]] | sort) ==
([range(0;2) as $ah | ["FRECPE","FRSQRTE"][] as $op |
  inputs[] | [$ah,$op,.]] | sort) and
all(.samples[];
    (.result | hex32) and (.fpsr == "0x0000000000000000") and
    .fpcr == (if .ah_requested == 0 then "0x0000000000000000"
              else "0x0000000000000002" end))

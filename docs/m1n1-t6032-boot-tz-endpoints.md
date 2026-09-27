# J575d iBoot: four TZ records and endpoint reads

2026-09-27. Offline continuation of the
[protection-range record trace](m1n1-t6032-boot-range-records.md).
All locations are decoded-file offsets. No extracted firmware was executed,
registers accessed, native dispatch enabled, or boot/storage/VM state changed.

## Evidence

Input: the same pinned 3,200,112-byte J575d iBoot image, SHA-256
`bed91c680ce5471ed1210be017ef9a33542e47c83bb7721f03e0aac209ca1c9e`.
Local artifacts under `scratch/mcc-evidence/`:

| Artifact | SHA-256 |
| --- | --- |
| `verify-boot-tz-endpoints.py` | `602de991f0cf6edcc0a1bfc20f5ba8d7c41f700ae1d9fd0a572ac8961cee88b8` |
| `boot-tz-endpoints.json` | `b9514b2e7d208c921332ee6849ec354938cf353877c969314a4f5403cc8a5a67` |

The verifier pins its field-verifier dependency, validates the complete
zero-address wrapper against the raw image, compares 510 instruction words
in 21 bounded extracts, and checks the four-word group table at `0x292f30`.
The report contains extract ranges/hashes. These checks establish byte
identity, not runtime reachability or hardware behavior. Separate bounded
reviews checked the constructor definitions and endpoint arithmetic.

## Four named TZ slot layouts

The constructor's `0x103–0x106` groups are named `tz0–tz3` by the previously
verified name table. Each has five 24-byte child records:

| Group | Lower limit | Upper limit | Enable | Write-disable | Lock |
| --- | --- | --- | --- | --- | --- |
| `0x103 / tz0` | `0x6d8` | `0x6dc` | `0x6e4` | `0x6e8` | `0x6e0` |
| `0x104 / tz1` | `0x6ec` | `0x6f0` | `0x6f8` | `0x6fc` | `0x6f4` |
| `0x105 / tz2` | `0x700` | `0x704` | `0x70c` | `0x710` | `0x708` |
| `0x106 / tz3` | `0x714` | `0x718` | `0x720` | `0x724` | `0x71c` |

These are record offsets and names, not sampled registers. Lower and upper
records explicitly receive mask `0x0fffffff`. Their value words are not
explicitly assigned by the shown stores; do not infer initialization from
absence of a store. The other three kinds receive mask/value one through
`0x416a0` or `0x413f4`, using w24 set to one at `0x3b820`.

Group headers are at `0x3ba90`, `0x3bb38`, `0x3bbdc` and `0x3bc90`.
Their child construction runs through `0x3bd1c`. Outlined tag helpers
include `0x41868` (w24), `0x41898` (2), `0x41970` (w21), `0x416dc` (3),
`0x417d0` (w28), `0x41964` (w20), and `0x4171c` (4).
Relevant definitions are w24=1 at `0x3b820`, w28=5 at `0x3b890`,
w21=3 at `0x3ba40`, w20=4 at `0x3ba74`, and w22=`0x0fffffff` at `0x3babc`.
Later changes to w21/w20 are why the later groups use constant-tag helpers.

The patched T6032 m1n1 path selects `t6031_tz_regs` in `src/mcc.c`.
Its count four and stride `0x14`, applied to start/end/enable bases
`0x6d8`/`0x6dc`/`0x6e4`, match **all four** corresponding rows—not merely
the first row or literal constants appearing in source. This corroborates
the selected offset table. It does not establish safe access or identical
state across aliases/controllers/planes.

## A separate reader also adds F

Function `0x35774` iterates exactly the group-table entries
`[0x103, 0x104, 0x105, 0x106]`, selects AMCC parent `0x1000`, and looks up
each group. Missing groups are skipped. Pointer bounds, array stride/count
and child counts are checked before the accesses traced here.

For lower/upper records, the aperture-array lookup explicitly selects ordinal
zero (`0x358f4`, `0x3591c`). Helper `0x383a0` returns:

```text
B = u64(table_base + checked_byte_offset)
F = u32(parent + 0x14)
R = u32(child_record + 8)
address = B + zero_extend(u32(F + R))
```

Here the first three expressions denote loads. The caller performs 32-bit
upper/lower reads at `0x35900` and `0x35928`. Thus this software uses the
F-adjusted address for **reads too**. Calling the field "write-only" would
be incorrect. These paths do not add a plane ordinal/stride.

The lock-record path instead reads at `B+R` (`0x358b8–0x358c4`) and
compares the masked result with the record's expected word. There is no F
term on that path. Unlike the range writer's other per-plane checks, this
reader samples only the first aperture; it does not demonstrate agreement
between controllers or between the F-adjusted and per-plane addresses.

## Exact endpoint arithmetic and limits

The statically identified caller at `0x3b5cc` supplies `base=0`, `shift=12`
when its w19 bit zero is clear. Earlier caller setup and its service calls
have not been qualified as an m1n1 handoff contract. The constant 12 here
is a caller argument; it is **not** a demonstrated read of group field `+8`.

The reader initializes lower and upper working values to zero. After scanning
the records it requires nonzero upper and a working flag equal to one
(`0x35944–0x35954`). A successful lock comparison sets that flag; lower/upper
helpers and unhandled record kinds clear it. It is not a universal
"all required records present" flag. In these constructed lists, lock is
the last child. There is no separate lower-record-presence check here.

Let L and U be the unsigned 32-bit lower/upper values. `subs` at `0x3595c`
and `b.ls` at `0x35960` reject **U <= L** using the subtraction flags—not
merely a zero wrapped difference. On the returning paths, arguments passed
to the as-yet-uninterpreted helper `0x31c90` at `0x35974` and `0x35994` are:

```text
t = u32(U - L + 1)
A = base + (zero_extend(L) << (shift & 63))
Z = (base - 0x4000) + ((zero_extend(L) + zero_extend(t)) << (shift & 63))
```

All 64-bit arithmetic wraps architecturally. For shift 12 and values where
the 32-bit increment does not wrap, this simplifies to:

```text
A = base + (L << 12)
Z = base + ((U + 1) << 12) - 0x4000
```

That is consistent with a 4-KiB-unit inclusive upper limit, followed by a
**16-KiB subtraction** for the second argument. Z is neither the exclusive
end nor the start of the final 4-KiB page. Do not copy that subtraction into
m1n1's unmap length or call this a complete interval-validation algorithm.
The reader does not mask its lower/upper loads with the constructor masks
on these paths. Nonzero helper returns branch to failure; the helper's
operation and effects remain outside this trace.

## What this qualifies—and what it does not

The four lower/upper/enable offsets now have corroborating Apple software
evidence. The endpoint code also supports, conditionally, the inclusive-upper
interpretation used by m1n1. It does not qualify m1n1's OR reconstruction
with `ram_base`: this caller passes zero, and the shown arithmetic uses
addition. It does not settle alias equivalence, current protection state,
safe early reads, loader/payload containment, DMA protection or recovery.

No firmware patch changes follow solely from this evidence. A real cache
transition remains a distinct operation; the range writer and this reader
must not be relabeled as cache enable. Native CPU/frequency dispatch remains
disabled, and that gate does not protect the separate early MCC read path.

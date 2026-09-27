# J575d iBoot physical-base producer and copy path

2026-09-27. This continues the [TZ input-conversion trace](m1n1-t6032-boot-tz-inputs.md).
It identifies the object and source-record dependencies behind a candidate
boot-argument physical base. It does **not** establish a live handoff value,
native execution safety, or complete compatibility with m1n1's boot ABI.
Instruction addresses below are decoded-file offsets; global addresses are
zero-address image coordinates, not physical addresses or necessarily
file-backed data. The artifact is the pinned J575d iBoot in the
[firmware inventory](inventory/t6032-boot-firmware-2026-09-26.json).

## Object and field provenance

On the `0x28114` path taking the branch from `0x283d0` to `0x2841c`,
`0x28460–0x28464` constructs x20 = Q = `0x30de78`. The following bounded
operation supplies length `0x488`; stores at `0x28480/0x2848c` initialize
the two leading 16-bit fields. This is not a claim about every loader path.

| Value | Local producer | Later use |
| --- | --- | --- |
| Record P selected by ID `0x18` | `0x28490–0x284a4`, through `0x19ff0c` | P retained in x23 |
| P's first 64-bit word | `0x284ac`, saved at `[sp+0xe8]` by `0x286e0` | Restored at `0x28e08`; supplied as x4 at `0x28f28` |
| Q's `+0x10` field | `0x288c4–0x288d0`: load `[P]`, store through alias `0x30de88` | Physical-base field consumed by `0x2c904` and adjusted by `0x2ce8c` |
| Q's `+0x18` field | `0x288d4–0x288d8`: load `[P+0x10]` | Memory-size field consumed by those same routines |
| Bounded Q argument | `0x28f14`, helper `0x2eab4` at `0x28f24` | x0/x1 = Q, x2 = Q + `0x488` at `0x28f2c` |

The `0x2ce8c` callee retains input x0 as x25, so its field updates target
this Q object on the reviewed path. In particular, x0 is not a diagnostic
label left over from an earlier call: `0x2eab4` explicitly restores it.
The field offsets agree with `virt_base`, `phys_base`, and `mem_size` in
the pinned m1n1 `src/xnuboot.h`. A complete ABI equivalence does not follow
from those offsets alone.

## Exact adjustment, without assuming a fixed RAM base

At `0x2cfac–0x2cfb4`, selector 4 is passed to `0x19ff0c`, then its result
to `0x1a01b0`. For a valid record with nonzero first word and no addition
overflow, that helper returns D = `[record] + [record+0x10]`. A zero first
word returns zero instead; validation and overflow failures do not establish
a usable range.

Let I denote input x4, and V/P/M the object's fields at `+0x08/+0x10/+0x18`
immediately before `0x2cfbc`. The instruction sequence through `0x2cfe0` is:

```text
delta = (D < P, unsigned) ? u64(I - D) : 0
new_virt = u64(V - delta)
new_phys = u64(P - delta)
new_mem  = u64(M + delta)
```

The pointer guard passes for `lower <= pointer < end`; it is not a numeric
constraint on the physical base. Arithmetic here is wrapping 64-bit arithmetic.
The first word of the selected `0x18` record supplies both the earlier
physical-base store and I, through two separate reads. **If those reads
agree and the stored field remains unchanged before this adjustment**,
then I = P and the expression simplifies to `new_phys = min(P, D)`.
That simplification is conditional: the bounded trace is not an exhaustive
side-effect proof for every intervening callee or a captured execution.

Consequently, neither a literal `dram-base` property elsewhere in the image
nor the TZ encoder's fixed 1-TiB origin proves the boot argument's value.
The condition needed by the current m1n1 RAM-base alignment remains:

```text
0x10000000000 <= handoff_phys_base < 0x10100000000
```

## Copy and outgoing value

`0x2ce8c` looks up records under the literal labels `DeviceTree` and
`BootArgs`; the latter result must have size `0x4000`. Its region coordinate
is retained in x26. Helper `0x2c904` converts that coordinate to a copy
address x28 by subtracting Q's physical base and adding the global base
loaded from image coordinate `0x30de70`, after range/nonzero checks.

At `0x2d014–0x2d038`, the ninth, stack-passed copy argument is `0x488`;
`0x2ea9c` supplies destination x28, and x4 supplies source x25 = Q.
Wrapper `0x161d24` passes those values to the memmove-style routine
`0x161890` at `0x161dbc`. Thus the normal validated copy path transfers
`0x488` bytes; the `0x4000` region size is not the copy length. That extent
is not proof that all copied fields match m1n1's structure or revision.

The return at `0x2d058` is x26, the original region coordinate, **not** x28.
The caller retains it at `0x28f30` and writes it through an output pointer
at `0x28f88`. In caller `0xdb8`, that output is the local slot `[sp+0x70]`,
subsequently loaded into x2 at `0xefc` for the call to `0x856b8` at `0xf04`.
This connects the copy to an outgoing argument; final handoff/SVC semantics,
runtime branch selection, and the current machine's actual values remain
unqualified.

## Source-record table and remaining gate

`0x19ff0c` selects records by a 16-bit ID at offset `+0x18`, advancing
in `0x40`-byte steps. Through `0x346f0` and `0x40610`, it obtains the table
at image coordinate `0x2d6f20`, count `0x9a`, extent `0x2680`.

| Selector | Initial record file offset | Initial first word | Initial word at `+0x10` |
| --- | --- | --- | --- |
| `4` | `0x2d8460` | `0xffffffffffffffff` | `0xffffffffffffffff` |
| `0x18` | `0x2d87a0` | `0xffffffffffffffff` | `0xffffffffffffffff` |

These are unresolved initial values, not measured RAM ranges.
Validator `0x1a0020` rejects either all-ones field. Next, trace the writers
that resolve these records and the final handoff contract; do not substitute
their initial bytes, the installed RAM capacity, or a generic T6032 RAM map
for the missing value proof. Early MCC access permissions and cache effects
remain separate gates even if the RAM-base condition is eventually proven.

## Verification

The follow-up [boot-stage boundary trace](m1n1-t6032-boot-stage-boundaries.md)
identifies a common writer for both records, the dynamic source-pointer
load, and the outgoing platform-call argument. It does not establish the
source table's runtime contents or the final payload-entry contract.

The byte verifier under `scratch/mcc-evidence/` checks the complete wrapper
against the pinned raw image, 1,604 words in 18 bounded extracts, two literal
labels, and the two selected initial table records. These are byte-identity
checks, not execution or safety tests.

An independent byte audit reproduced all these checks with no mismatches;
a separate static review agreed with the object identity, copy and outgoing
slot trace. The existing source-extracted carveout preflight sanitizer harness
also passes unchanged at both page granules. No new runtime value was measured.

| Artifact | SHA-256 |
| --- | --- |
| `verify-bootargs-evidence.py` | `ef8539fa71387fd2d530a0b9e75a294cb0e1182cfc9d99b651a375db2f884816` |
| `bootargs-evidence.json` | `ff00da4994620efbf7fa498b4f88fd44f0cabaa0fb944a015e77fe82bcd9a9fc` |

No firmware, decoder, VM, disk layout, or boot policy was changed.

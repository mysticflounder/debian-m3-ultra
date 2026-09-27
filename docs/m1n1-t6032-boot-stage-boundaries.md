# J575d boot-stage table source and outgoing handoff

2026-09-27. This extends the [boot-argument trace](m1n1-t6032-boot-arguments.md)
in both directions: where the memory records can acquire their values,
and where the copied BootArgs region is passed next. These are conditional
static paths in the [pinned iBoot image](inventory/t6032-boot-firmware-2026-09-26.json),
not observations of execution on this Mac. No firmware or hardware-access
code was executed. Instruction locations are decoded-file offsets; literals
used as addresses must not be mistaken for offsets into that file.

## A concrete writer for the unresolved memory records

Function `0x33c7c` obtains the `0x2d6f20` destination table through
`0x40610`. Its loop computes destination x23 as `table + index*0x40` and
reads the record ID at `+0x18`. Thus indices 85 and 98 address the previously
identified selector-4 and selector-`0x18` records. Reaching either index and
passing the filters are not established runtime facts.

Before the loop, `0x33ce4/0x33ce8` call `0x154868(1)` and `0x154bdc`.
The returned source-list pointer is retained in x21. `0x1557e8`, called
at `0x33d90`, searches that list for the destination's ID. Its source-list
layout is distinct from the fixed destination table:

| Source-list field | Role in the search |
| --- | --- |
| `+0x0c`, u32 | Entry count |
| `+0x10`, u32 | Entry stride |
| `+0x14`, u32 | Entry-array offset relative to the list pointer |
| Entry `+0x18`, u16 | ID compared with the requested ID |

Outlined helper `0x158948` performs the offset/stride calculation;
`0x34bb4` retains the selected entry and bounds as x24/x25/x26. The
subsequent paths `0x33e6c–0x33e78` and `0x33e84–0x33e94` copy its first
`0x20` bytes to the destination. The latter also clears destination
`+0x1e`; `0x33e98` sets `+0x08` separately. Both paths therefore write
the start and size fields needed by the boot-argument calculation.

These are conditional merges, not unconditional overwrites. The loop has
type/flag filters, source validation and a size comparison. In addition,
`0x1915a8` reads bit 0 at image coordinate `0x31989`. **Only when this flag
is set and the source's first word shifted right by 40 is nonzero** does
`0x33e10–0x33e24` require the source end to be at least `0x10064000000`.
`0x33df4` bypasses that test when the flag is zero. This is not an upper
bound and cannot prove the needed first-4-GiB RAM-base window.

## The source pointer depends on a fixed-address load

The cold path in `0x154868` obtains a source object through `0x154a64`,
validates it, copies the length read from its `+0x08` field, and publishes
a bounded pointer at image coordinate `0x390df0` (`0x15499c–0x1549a8`).
`0x154bdc` subsequently validates that cached object and returns its base
plus the nonzero u32 offset at `+0x20` as the source-list pointer.

`0x154a64` obtains the initial source address by calling `0x35ab0`:

```text
address of 32-bit load = 0x2a02c0024
source_address = 0x10000000000 + (zero_extend(loaded_u32) << 14)
```

The complete address comes from three MOV/MOVK instructions at
`0x35ab0–0x35ab8`; the load is at `0x35abc`, followed by the base and
shifted addition at `0x35ac0/0x35ac4`. **This describes iBoot's instructions,
not an access we performed or propose performing.** The register/block
identity, access prerequisites and actual value are unqualified.

When the flag from `0x1915a8` is zero, `0x154a64` uses the address directly
as its candidate object pointer. When set, a nonnull output pointer is also
required at `0x154aa0`; the normal path passes the address through
`0x35a3c`. That routine obtains selector `0x252`, writes the address to its
first word and `0x4000` to its size field, then calls `0x34480`. The caller
uses `0x1550d4` on the returned record before validating the source object;
the full mapping/extension semantics are not established here.

This identifies the next provenance boundary: the fixed-address value and
the table it locates. The arithmetic alone allows offsets much larger than
4 GiB and says nothing about the selected entries' contents. It cannot
replace a proof of the actual boot-argument physical-base window. Further
offline work should examine the preceding boot stage's table construction
and address publication; do not turn this discovery into an MMIO probe.

Follow-up: the [LLB publication trace](m1n1-t6032-llb-table-publication.md)
now identifies the preceding-stage writer and selector-1 input, including
its initial image value. Runtime table contents and the BootArgs RAM-base
window remain unproved.

## The outgoing BootArgs coordinate reaches a platform call

On normal continuation from `0xdb8`, function `0x856b8` preserves the two
loader outputs and supplies them as x0/x1 to `0x85864`. The second is the
BootArgs region coordinate established by the previous trace. This wrapper
sets x3 to 1 and issues `SVC #3` at `0x85874`.

Under the [previously traced SVC dispatch](m1n1-t6032-boot-tz-translation.md)
and its context/permission guards, table slot 3 at `0x199cd0` has signed
displacement `0x264` relative to `0x196398`, selecting `0x1965fc`.
That handler restores the four input arguments, normalizes the fourth to
a boolean, and calls `0x19a090`.

`0x19a090` has additional context and mode checks and cleanup loops. It
retains the first two arguments at `[sp+0x20]` (`0x19a17c`), reloads them
at `0x19a518`, and calls `0x855bc`. This is a conditional dataflow result,
not proof that the checks pass, the cleanup terminates or all runtime
callee effects are known.

On the normal nonzero-TPIDRRO getter path, `0x855bc` checks
`TPIDRRO_EL0 == -1` and another flag before proceeding. The zero-TPIDRRO
diagnostic fallback is not qualified. Callback getter `0x19fae0` branches
to `0x35cb4`, which constructs these literals:

```text
x0 = x1 = 0x10064000000
x2      = 0x10064004000
```

The caller signs the x0 callback pointer, retains it in x24, and eventually
issues `BLRAAZ x24` at `0x8567c`. Immediately before this call, x0 is the
first loader output and **x1 is the original BootArgs region coordinate**.
It is not the temporary copy address used to fill that region.

The code residing at this target, its provenance, the final payload entry,
and its argument/exception-level contract are still unverified. In
particular, this target is not a file offset into the decoded iBoot image.
This trace does not establish an m1n1 or Linux entry with MMU/cache settings
appropriate for this machine.

## Checks and limits

The two verifiers in `scratch/mcc-evidence/` compare the complete wrapper
with pinned raw iBoot, then check 1,126 instruction words in 25 extracts
and the SVC3 dispatch-table slot. An independent byte audit reproduced these
checks with zero mismatches. Byte checks do not prove semantics or live
execution. Static reviews independently checked the merge and handoff
paths; the flag-controlled bypass and zero-TPIDRRO boundary remain explicit.

| Artifact | SHA-256 |
| --- | --- |
| `verify-record-merge-evidence.py` | `671ccc6eae79bf965e88dff44ed6641050331c42cd6817d766cd53865a28ab1d` |
| `record-merge-evidence.json` | `3c2192d39864dc02d0a2d5acc54dd5d5bc14249ec43fb77a12641b60fb5fcc6f` |
| `verify-handoff-evidence.py` | `e34dd992504b37bc2fc4170d3bcda376ffb1f63c817a03cd7363ef816a25dbac` |
| `handoff-evidence.json` | `d3d9367c10813688dfbed1f021663172aa95bdd8ff884d402378dea10cba435f` |

Native MCC permissions, cache transitions, DMA containment and recovery
remain separate unresolved gates. No decoder, firmware, disk, VM or boot
policy was changed.

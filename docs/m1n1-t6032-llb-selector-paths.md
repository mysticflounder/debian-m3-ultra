# J575d LLB memory-record selector paths

2026-09-27. Offline follow-up to the
[memory-list exporter](m1n1-t6032-llb-memory-export.md). Locations are
decoded-file offsets in the pinned J575d LLB, not addresses to probe.
The missing fact remains the runtime initialization of selectors 4 and
`0x18`, whose image-default address and size fields are all ones.

## Three dynamic call sites narrowed

| Call to common writer `0x11cbb0` | Selector source | Bounded result |
| --- | --- | --- |
| `0x9b68` | u32 at image `0x2c15c0` | Initial value 2; runtime mutation not excluded |
| `0x113968` | Incoming x1 of `0x1137ec`, retained in x20 on this path | Observed direct caller chains supply zero (bypasses this write) or `0x10a` |
| `0x11dc2c` | Incoming x5 of `0x11dba8`, retained in x28 | Observed direct callers supply initial table values `0x4d/0x4e`, or literal `0x4f` |

These are candidate reductions, **not proof that no writer initializes 4
or `0x18`**. Indirect entry, aliasing, runtime mutation and other setter
paths are not exhaustively excluded.

### Global-selected call

At `0x9b44/0x9b48`, x8 becomes image coordinate `0x2c15c0`;
`0x9b4c` loads w0 from it. Subsequent stores use offsets `+0x100`,
`+0x104`, and `+0x108`, not the selector word. The call at `0x9b68`
therefore uses that loaded selector. Its initial raw u32 is 2.
This does not establish that the initial value persists until execution.

### Allocation path

Function `0x1137ec` saves x1 in x20 at `0x113828`. Zero w1 branches
away at `0x113838`. For a nonzero selected record that fails the validity
test, `0x113868` branches to `0x113924`; that path preserves x20 and
passes it as x0 to the writer at `0x113968`.

The four observed direct calls to `0x1137ec` are:

- `0x74cd8`: w1 is zero.
- `0x113a68`: wrapper `0x113a48`; its observed direct caller
  `0x74d90` supplies zero w1.
- `0x113a9c`: wrapper `0x113a78`; its observed direct caller
  `0x16d04c` supplies zero w1.
- `0x113b48`: wrapper `0x113ab8` retains incoming x5 in x24, with
  a separate branch that clears w24. Its observed direct caller
  `0x74d54` supplies w5=`0x10a`.

Outlined helper `0x114034` clears x2 through x5, not x1. The x20
redefinitions on the allocation-without-record path do not reach
`0x113968`. Thus these direct chains do not bind this writer to either
missing selector. The earlier w4=`0x12` at `0x11389c` is an argument to
a different call, not this selector.

### Two-entry input table

Function `0x11dba8` saves x5 at `0x11dbcc` and passes it to the writer
at `0x11dc24/0x11dc2c`. Its observed direct callers are:

- `0x11e1c8`, with literal w5=`0x4f`.
- `0x11df3c`, with w5 loaded from `[x27+0x14]`. The enclosing loop
  starts x27 at image `0x2f87a8`, stops after two iterations, and advances
  by `0x38` at `0x11dfd8`. Initial u32 selector fields at `0x2f87bc`
  and `0x2f87f4` are `0x4d` and `0x4e`.

The initial table bytes narrow this candidate; they are not a runtime
capture or a proof that these mutable fields cannot change.

## Evidence and next boundary

`scratch/mcc-evidence/verify-llb-selector-paths.py` checks the complete
zero-address wrapper against the pinned raw LLB, 13 bounded extracts
containing 258 instruction words, and the three initial u32 fields.
It does not execute firmware or prove instruction semantics/reachability.

- Verifier SHA-256: `3b9e765aff946acd303e82928fec39859fa9655e9c8e5470cff2ee61ff925487`
- Report SHA-256: `50471cfbb89e62c768ce374a2f892a78cd90bd8cd5c0f52b5246d8f39462baf7`

Remaining routes include lookup-derived keys, callback arguments and
caller-owned object fields. Check direct record writes outside the common
setter before expanding those dynamic producer chains. None of this
establishes the BootArgs physical-base window, early MCC permissions,
cache scope, or DMA safety. Native dispatch remains disabled; its switch
does not guard the earlier initial-MMU MCC reads.

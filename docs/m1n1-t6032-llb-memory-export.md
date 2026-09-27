# J575d LLB memory-list export

2026-09-27. This follows the
[LLB table-address publication](m1n1-t6032-llb-table-publication.md) upstream
to the list assembled for handoff. It is a conditional static trace of the
same pinned LLB, not a captured handoff or a native test. All instruction
locations below are decoded-file offsets.

## The fixed table is repacked, not exported verbatim

Function `0x119830` uses the bounded parent-buffer descriptor at image
coordinate `0x373d10`. It checks global state and the descriptor; an existing
nonzero parent `+0x20` offset takes a separate validation/return path.
On the construction path, helper `0x11c2e4`, called at `0x1198c0`, tail-calls
`0x31590` with outputs in the caller's stack. This supplies the previously
identified fixed table: base `0x2c4650`, 146 records, stride `0x40`.

The new list pointer x21 is the parent-buffer base plus its u32 `+0x08`
length rounded up to eight bytes (`0x1198ec–0x1198f4`, helper `0x11c47c`).
The writer sets magic `0x686f6d6d` and version 2 at list `+0/+4`.
The combined 64-bit store at `0x119904` sets u32 stride `0x20` at list
`+0x10` and u32 entry-array offset `0x18` at list `+0x14`.

Two passes use predicate `0x119ad0`: the first counts eligible fixed
records; the second increments list `+0x0c` and writes their entries.
The final count must equal the first pass's count (`0x1199ec–0x1199f4`).
**This export loop does not itself initialize list `+0x0c` to zero.** The
initializer below provides a concrete earlier clearing path. Reaching it
before export, preserving the unused buffer space, and keeping the inputs
stable between passes remain preconditions rather than runtime observations.

For each eligible record, `0x1199b4–0x1199c0` copies the first `0x20`
bytes, then applies these changes:

| Exported entry field | Relation to the internal record |
| --- | --- |
| `+0x00`, u64 | First/address field copied unchanged |
| `+0x08`, u64 | Cleared at `0x1199d8` |
| `+0x10`, u64 | Size field copied unchanged |
| `+0x18`, u16 | Selector copied unchanged |
| `+0x1a`, u16 | Translated by `0x119b6c`; stored at `0x1199d4` |
| `+0x1c`, u16 | Copied unchanged |
| `+0x1e`, u16 | Cleared at `0x1199dc` |

The translator checks the original `+0x1a` against `0x13` and bitmap
`0xfdb6d`, then loads a u16 mapping from image table `0x262ad4`.
This is a metadata translation, not a conversion of the first/address or
size fields.

On normal continuation, `0x1199fc` sets list length to `count*0x20 + 0x18`.
`0x119a18` stores `list_pointer - parent_pointer` as the parent's u32
`+0x20` offset. Additional parent-length/capacity checks and validation
follow. These fields match the separately traced
[iBoot source-list lookup](m1n1-t6032-boot-stage-boundaries.md): it locates
the list through parent `+0x20`, then uses list count/stride/entry offset
at `+0x0c/+0x10/+0x14` and selector at entry `+0x18`.

## Eligibility matters to the missing memory ranges

The predicate at `0x119ad0` rejects a record when its `+0x1c` bit 0 is set,
when selector-policy helper `0x25bfc` returns bit 0 set, or when
`0x15e87c` rejects it. The policy helper branches to `0x14ea04` and has
further dependencies; no constant policy result is assumed.

`0x15e87c` uses `0x15e838` to reject `UINT64_MAX` in either the first or
size field, then rejects zero in either field. After those checks pass,
the final tail target `0x15e448` returns 1. Pointer checks guard the
record accesses throughout this path.

Consequently, **if selectors 4 and `0x18` still contain their image-default
sentinels when checked, they are not exported by this path**. Their
presence in the fixed table alone cannot establish their presence in the
handoff list. A successful export of either requires initialized fields
and passing the other filters. The exporter preserves those fields; it
does not supply their initial values or establish the first-4-GiB
BootArgs physical-base window.

## Parent-buffer initialization supplies the clearing operation

Function `0x118da8` first rejects an already populated descriptor or set
state byte at image coordinate `0x373ce8`. It selects record 1 through
`0x15e6dc`, validates it through `0x15e87c`, and reads its size field into
x20 at `0x118df4`; call this size `N`.

It obtains a context through `0x186760(0)` and passes that context, 1 and
`N` to `0x18670c` (`0x118e00–0x118e08`). The latter branches to
`0x1864b0`, which invokes `0x185cd0` through an outlined argument helper.
The returned pointer `P`, rather than record 1's first/address field,
becomes the parent-buffer pointer. This identifies the allocation call
boundary, not the buffer's physical address or the allocator's complete
safety contract.

At `0x118e18/0x118e24`, LLB stores the descriptor with pointer/lower bound
`P`, end `P+N`, and type at image coordinate `0x1ad8c0`, at `0x373d10`.
It then calls `0x125990` at `0x118e34` with fill value zero and length `N`.
The descriptor stores occur **before** the fill call, not atomically with
successful initialization.

The fill wrapper retains the pointer in x23, length in x22 and fill value
in x24. After range/type checks, `0x1259fc` calls `0x125510` with those
three values. Its byte-replication and store loops implement the zero
fill; the global-selected fast path and fallback use the same zero value.
The wrapper skips writing for zero length. On normal return with valid
writable, non-wrapping bounds, the requested `N`-byte buffer is cleared.
No such code was executed by this analysis.

The constructor subsequently installs these parent-header fields:

| Field | Value written | Instruction |
| --- | --- | --- |
| `+0x00`, u32 | Magic `0x484f6666` | `0x118e54` |
| `+0x04`, u32 | Version 1 | `0x118e70` |
| `+0x08`, u32 | Initial used length `0x90` | `0x118e8c` |
| `+0x0c`, u32 | Low 32 bits of the re-read record-1 size | `0x118eac` |

Its local validator `0x118efc` requires that magic, nonzero version,
used length at least `0x90`, and used length no greater than capacity.
Thus a successful constructor clears the unused space that can later
hold the exported list. It does not alone prove that the same buffer
reaches the exporter unmodified or that the actual memory-range records
have been initialized. Nor does allocating this temporary buffer establish
the final BootArgs physical-base window.

## Evidence and next boundary

`scratch/mcc-evidence/verify-llb-export.py` pins the LLB raw hash and complete
zero-address wrapper text, then checks 14 extracts containing 351
instruction words against the raw bytes. This is byte verification, not
execution or proof of hardware semantics.

- Verifier SHA-256: `6def33f69114fdc29a3a91299c58d3e52722f9228af963dc35889e6419d2b447`
- Report: `scratch/mcc-evidence/llb-export-evidence.json`
- Report SHA-256: `e69ba7ab70393975f8069612d8c602b491a88a7e15449b906e50139972864906`

The initializer follow-up, `scratch/mcc-evidence/verify-llb-buffer-init.py`,
checks another 10 extracts/306 instruction words with the same raw-image
and wrapper checks. Independent review separately checked the fill path.

- Initializer verifier SHA-256: `7654a3cb09afd17b9e58518c363864cbcc266982db6f99792b3b7759599b9245`
- Initializer report: `scratch/mcc-evidence/llb-buffer-init-evidence.json`
- Initializer report SHA-256: `10968c61e36ebacc9366e9c8f999d3aa96f4635c6f21df8de987554c8b68795c`

The fixed-table-to-list transformation and parent-buffer clearing path are
now identified. A [selector-path follow-up](m1n1-t6032-llb-selector-paths.md)
narrows three dynamic setter call sites without identifying the missing
ranges. Next trace the selector-4/selector-`0x18` writers and the
initialization-to-export call sequence; do not substitute these routines'
existence for runtime values or execution order.
The publication destination's mapped alias and the final platform
callback contract also remain separate requirements. MCC/cache safety,
CPU/frequency dispatch and native-boot authorization are unchanged.

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
**This slice does not itself initialize list `+0x0c` to zero.** The
parent-buffer allocation/clearing and stable inputs between passes remain
preconditions, not observations established by this loop.

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

## Evidence and next boundary

`scratch/mcc-evidence/verify-llb-export.py` pins the LLB raw hash and complete
zero-address wrapper text, then checks 14 extracts containing 351
instruction words against the raw bytes. This is byte verification, not
execution or proof of hardware semantics.

- Verifier SHA-256: `6def33f69114fdc29a3a91299c58d3e52722f9228af963dc35889e6419d2b447`
- Report: `scratch/mcc-evidence/llb-export-evidence.json`
- Report SHA-256: `e69ba7ab70393975f8069612d8c602b491a88a7e15449b906e50139972864906`

The fixed-table-to-list transformation is now identified. Next trace the
selector-4/selector-`0x18` writers and the parent-buffer initialization;
do not substitute the exporter's existence for their runtime values.
The publication destination's mapped alias and the final platform
callback contract also remain separate requirements. MCC/cache safety,
CPU/frequency dispatch and native-boot authorization are unchanged.

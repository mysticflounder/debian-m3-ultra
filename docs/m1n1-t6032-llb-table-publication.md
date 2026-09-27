# J575d LLB memory-table address publication

2026-09-27. Offline continuation of the
[iBoot source-table trace](m1n1-t6032-boot-stage-boundaries.md).
This uses the pinned `mBoot-20457.1.29` J575d LLB from the
[restore-artifact inventory](inventory/t6032-boot-firmware-2026-09-26.json).
Instruction locations are decoded-file offsets, not live addresses. No
firmware was executed and no physical address was accessed.

## The preceding-stage writer is present

LLB function `0x288cc`, reached through branch thunk `0x15e378`, tests its
x0 input. For a nonzero input `A`, the bounded instruction sequence is:

```text
t = u64(A + 0x3f0000000000)
encoded = u32(t >> 14)
store_u32(0x2a02c0024, encoded)   // instruction 0x288e8
store_u32(0x292880004, encoded)   // instruction 0x288f8
```

These stores describe Apple's code, not a procedure to run on this Mac.
The zero-input branch goes to `0x28900`, which calls diagnostic helpers;
it does not enter the two stores above. The diagnostic's ultimate behavior
has not been established. No alignment or range check occurs on the
writer's nonzero path.

LLB's reader starts at **`0x28984`**, loads the first slot at `0x28990`, and
returns `B + (zero_extend(encoded) << 14)`, where `B = 0x10000000000`
(1 TiB). This matches the separately traced iBoot reader at `0x35ab0`.
`0x28980` belongs to the preceding function's error path, not this getter.
The block identity, access permissions, ordering requirements and actual
contents of both slots remain unqualified.

## Input provenance and the initial records

On normal continuation through `0x1195bc`, after global-state gates,
`0x1195fc/0x119600` request selector 1 through `0x15e6dc`. Its returned
object is retained in x19. Further validation, mapping/copy-related calls
and size checks intervene. At `0x1196dc`, the first 64-bit word of that
object becomes x0; `0x1196e0` calls the publication thunk. Thus the
immediate publication source is selector 1's first field, not the object
pointer itself. This does not prove that the selected object is unchanged
through all intervening calls or that this path executes on our machine.

`0x15e6dc` calls `0x15e8d8`, whose cold path obtains the table through
`0x31590`. That descriptor names table `0x2c4650`, extent `0x2480`, and
count `0x92` (146). The lookup compares the u16 selector at `+0x18` and
advances by `0x40`. Raw initial bytes give:

| Selector | Index | LLB image offset | First field | Size at `+0x10` |
| --- | ---: | --- | --- | --- |
| `1` | 108 | `0x2c6150` | `0x10000000000` | `0x4000` |
| `4` | 85 | `0x2c5b90` | `UINT64_MAX` | `UINT64_MAX` |
| `0x18` | 97 | `0x2c5e90` | `UINT64_MAX` | `UINT64_MAX` |

All three initial `+0x08` fields are zero. These are **image defaults,
not captured live ranges**. In particular, selector 1's default would
encode as zero and decode to `B` if retained; a zero encoded value is not
the writer's rejected zero input. Selector-4 and selector-`0x18` defaults
cannot supply the runtime ranges needed by the boot-argument proof.
LLB's table and iBoot's 154-entry table also have different indices;
do not transfer indices between images.

## Arithmetic establishes an encoding, not the RAM-base window

For any nonzero u64 input, the reconstructed value is:

```text
decoded = B + align_down((A - B) mod 2^46, 0x4000)
```

The 64-bit addition's wrap does not change this equivalence: it is
discarded again by the shift and low-32-bit store. Exact roundtrip requires
a 16-KiB-aligned input in `[B, B + 2^46)`. Unaligned inputs lose their low
14 bits; addresses separated by `2^46` alias. This says nothing about
which of these addresses are backed by RAM or accessible.

Eight synthetic arithmetic checks cover the origin, one-page offset,
unaligned input, first-4-GiB boundary, last representable page, period
alias, below-origin input and u64 wrap. Notably `A = B + 4 GiB` roundtrips
unchanged. **The encoding therefore does not impose the required
`B <= BootArgs.phys_base < B + 4 GiB` window.** The published table's
address is also distinct from the memory-range fields it contains.

## Evidence and remaining gate

`scratch/mcc-evidence/verify-llb-publication.py` checked eight bounded
extracts containing 236 instruction words against the pinned raw image,
the zero-address wrapper's complete text bytes, the three initial records,
and the eight synthetic arithmetic cases. Independent bounded review
confirmed the writer/caller flow and corrected the reader's entry offset.
Byte identity is not a semantic proof or a hardware test.

- Verifier SHA-256: `d1d0998af1959cf4d0d3faf7365bd0cb5c6009cf05dea178cb98de7a26fc3b14`
- Report: `scratch/mcc-evidence/llb-publication-evidence.json`
- Report SHA-256: `3f01f1ec078b6dd0fa3a8d96ff8b803285702034071f0c2a4bfe13c25b94bd05`

The address-publication producer is now located. Remaining work is to
trace the table's construction and runtime selector-4/selector-`0x18`
contents, plus the final platform callback's code/mapping contract.
Finding another literal callback getter is not evidence that its target
code has been initialized or that its calling convention is known.

This does not qualify early MCC/cache access, per-die effects or DMA
safety, and does not enable native CPU/frequency dispatch. Initial-MMU
MCC reads remain a separate gate; leaving dispatch disabled does not
make those reads safe.

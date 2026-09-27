# J575d iBoot: AMCC write-address field

2026-09-27. Offline continuation of the [boot consumer trace](m1n1-t6032-boot-consumers.md).
This resolves a software use of parent field `+0x14`; it does not establish
hardware broadcast scope or safe early m1n1 access. No firmware was executed,
registers accessed, or VM, disk, boot policy or native dispatch changed.
All code locations below are decoded-image file offsets, not observed PCs.

## Evidence and reproducibility

The input remains the exact iBoot image pinned in the
[firmware inventory](inventory/t6032-boot-firmware-2026-09-26.json):
3,200,112 bytes, SHA-256
`bed91c680ce5471ed1210be017ef9a33542e47c83bb7721f03e0aac209ca1c9e`.

Local evidence artifacts (not committed firmware):

| Artifact under `scratch/mcc-evidence/` | SHA-256 |
| --- | --- |
| `verify-boot-field-evidence.py` | `dc804a2a92b6302f9dbc0c9ef2872075f2df6f5b0f1405412a7fe8861bc04c4c` |
| `boot-field-evidence.json` | `9b61fefb4084b8fe0e65df8f9d8452490b2efc84abf32fe153dcefaa9f87a9e4` |

The report records 19 end-exclusive extraction ranges, their hashes and 422
raw instruction words. The verifier checks the pinned image size/hash,
byte equality of the complete zero-address Mach-O `__text` wrapper, absence
of text relocations, and each extracted word against the raw image. It does
not verify semantic interpretation, runtime reachability or hardware effects.
Reproduce with the script's `--emit --output <new-report>` and repeatable
`--range START:END` options using the report's ranges; the first six are
already defaults. Existing reports are not overwritten.

## Descriptor identity and aperture bases

The shim at `0x1a0dec` forwards its incoming `w4` as the parent lookup key.
Call sites `0xb4dc` and `0x4097c` supply `0x1000`, the previously identified
AMCC tag; this is not an assertion that all callers select AMCC.
The main function calls constructor `0x3b6a4`, then lookup `0x1563fc`.
That lookup compares each 64-byte record's first word with the key
(`0x156450`, with the load in `0x15872c`). A matching pointer is returned;
the caller rejects null and assigns it to `x24` at `0x1a0ebc`.
The local trace retains that descriptor register through the field load.
This bounded identity argument is not a proof of every intervening callee.

For the AMCC constructor record, `+0xc` is the plane count, `+0x10` the
stride `S = 0x40000`, and `+0x14` the field `F = 0x1c0000` (store at
`0x3b81c`). The aperture-array descriptor at `0x3bd28–0x3bd30` has:

| Record field | Meaning in this code |
| --- | --- |
| `+0x34` | Total controller count: product at `0x3b704`, saved at `0x3b7b4` |
| `+0x38` | Array element stride: 8 bytes |
| `+0x3c` | Relative array offset: `0x4a8` |

The nested constructor loop stores numeric bases at `0x3bdcc`:

```text
B(d,c) = 0x220000000 + d * 0x2000000000 + c * 0x2000000
```

The two strides are advanced at `0x3bdd4` and `0x3bdec`. These are stores
into the constructed table, not writes to those hardware addresses.
Two dies/eight controllers per die remain conditional on the count-helper
initialization described in the earlier trace, not observed execution here.

## Write arithmetic versus per-plane reads

At `0x1a1348–0x1a1358`, the code loads F and sets the local write-loop count
to one when F is nonzero; for F zero it retains the prior count.
`cbnz` at `0x1a135c` skips both optional setup paths when F is nonzero.
For F zero, input flag bit 30 selects a direct store versus a call to
`0x15f48`; that callee is not interpreted here. F and that flag are distinct.

The aperture lookup helper `0x1a2614` passes array stride/count/offset to
`0x1a2320`, which returns a checked **byte offset**. Thus
`ldr x8,[x21,w0,uxtw]` loads B from `x21 + zero_extend(w0)`, not `x21+8*w0`.

Helper `0x1a2680` loads B, then **both** words with
`ldp w10,w9,[x24,#0x10]`: S into w10 and F into w9. It computes
`x8 = B + u32(S*p)`, where p is w25, leaving F in w9.
At `0x1a15c0–0x1a15cc`, the caller loads record offset R from `record+8`,
adds R to F in a 32-bit register, and stores a 32-bit payload at:

```text
write address = B + u32(S*p) + u32(F+R)
```

The store at `0x1a15ec` uses the same calculation for another record.
Here `u32` means reduction modulo 2^32 followed by zero extension;
64-bit additions follow architectural wraparound. These are guarded paths,
not evidence that every invocation performs these stores or uses one formula.

By contrast, read/compare helper `0x1a2640` accesses:

```text
read address = B + u32(S*p) + R
```

It loads a word, masks it with `record+0xc`, and compares with `record+0x10`.
F is absent. The later loop initializes p to zero at `0x1a194c`, compares
with the descriptor's full plane count at `0x1a1950`, and increments/backedges
at `0x1a1c34–0x1a1c38`. The direct read helper is called at `0x1a1984`
under additional guards. The earlier skip-mask provider `0x19fb80` returns
constant zero in this image; later conditions/errors can still bypass reads.

## Consequence and next gate

The software has a nonzero-F, one-iteration write path and a separate
full-plane verification loop. Adding `F=0x1c0000` to a record offset is
therefore supported by actual address-consuming instructions, not just by
adjacent constants or exported metadata. Interpreting F as a write alias
is consistent with this code; its hardware scope remains unverified.
The later [TZ endpoint reader](m1n1-t6032-boot-tz-endpoints.md) also reads
through an F-adjusted address. F must not be described as write-only;
the per-plane helper above is one particular read path, not every read path.

Do not yet substitute `R=0x1c00` and claim this proves the cache-enable
operation. The representative stores' selected records/payloads must be
traced to their selecting caller. The subsequent
[record-identity trace](m1n1-t6032-boot-range-records.md) identifies these
representative stores as lower/upper protection-range writes, not cache enable.
The earlier `0xc1` pointer's stack
slot is cleared at `0x1a1008`; its identity cannot be carried across that
store. Next: find a distinct cache-specific operation, permissions and ordering,
and compare with the [macOS cache contract](m1n1-t6032-cache-contract.md).
Early MCC carveout reads, TZ protection, loader/DMA containment and recovery
remain separate gates. CPU/frequency dispatch being off does not guard those
early MCC reads. No native-enablement recommendation follows from this trace.

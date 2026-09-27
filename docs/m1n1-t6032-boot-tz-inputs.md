# J575d iBoot TZ limit production

2026-09-27. This continues the [endpoint/RAM reconstruction trace](m1n1-t6032-boot-tz-translation.md).
The new evidence identifies an explicit input conversion, not merely a
constant resembling an address unit. Instruction locations are decoded-file
offsets in the pinned J575d iBoot image. Global addresses use the zero-address
inspection view; they are not claimed to be live physical or file-backed
addresses. No firmware or MMIO was executed, and no
native dispatch, boot-policy, disk or VM state changed.

## Evidence

Input SHA-256:
`bed91c680ce5471ed1210be017ef9a33542e47c83bb7721f03e0aac209ca1c9e`.
Local artifacts under `scratch/mcc-evidence/`:

| Artifact | SHA-256 |
| --- | --- |
| `verify-boot-tz-inputs.py` | `268b5e019e1a79063132161866d6589555cc2fc0f07ed09d0d23d7940eb16671` |
| `boot-tz-inputs.json` | `d09d230db738b13d464f1c035448aac11cfa22b25003f1ff380ece412364a06d` |

The pinned-helper verifier checks the entire zero-address wrapper against
the raw image, 308 raw words in ten disassembly extracts, and the `tz`
label's bytes. Byte equality does not establish execution or hardware effects.
An independent byte audit reproduced these checks; a separate static
review checked the caller, stack-spilled output pointer and conversion.

## Exact conversion

At `0x348b8`, the input is a bounded pointer to a range descriptor.
Outlined helper `0x34bc4` loads x4/x5 from its first two 64-bit words and
saves the pointer/bounds to the caller's stack. The caller then supplies:

| Input to `0x1a03c0` | Value | Evidence |
| --- | --- | --- |
| x4/x5 | Original start S and exclusive end E | `0x34bc4` |
| x6 | 12, controlling the alignment/page decrement | `0x348f4` |
| x7 | `0x10000000000` (1 TiB), subtracted before encoding | `0x348f8` |
| Stack shift argument | 12 | `0x348d8–0x348dc` |
| Diagnostic label | `tz` | Pointer construction at `0x348e0–0x348ec`, bytes at `0x2c3d49` |

The conversion checks pointer bounds, a non-null output pointer, unsigned
`E > S`, and alignment of both endpoints to `1 << x6`. It sets
`last_page_start = E - 0x1000`, stores S and that last-page address in the
descriptor's first two words, and checks their ordering/alignment. The
second pair of stores, at `0x1a0440`, writes **32-bit** encoded fields at
descriptor offsets `+0x10/+0x14`:

```text
B = 0x10000000000
lower_word = u32(u64(S - B) >> 12)
upper_word = u32(u64(E - 0x1000 - B) >> 12)
```

The explicit `u64` denotes wrapping subtraction; the shown helper does not
separately prove `S >= B` or confinement to a particular RAM window. The
input descriptor is modified in place, including a flag byte at `+0x1b`.
This is an inclusive last-page encoding of the originally exclusive end.
It is distinct from the reader's later 16-KiB endpoint-query subtraction.

The [range-writing consumer](m1n1-t6032-boot-range-records.md) loads the
two encoded words at `0x1a11b4`, masks them with the selected lower/upper
record masks, and checks unsigned ordering before retaining write payloads.
For the named TZ groups the masks are `0x0fffffff`. Masking after encoding
discards information; do not infer an unrestricted inverse from this formula.

## Connection to the TZ0 write input

The caller constructs global descriptor `0x3974d0` at `0x4076c–0x4077c`:
its start comes from a selected source record's first word, while its end
comes from helper `0x1a01b0`. The exact upstream allocation/handoff provenance
is not qualified here. At `0x40790`, this descriptor is passed to the
conversion above with bounds `[0x3974d0, 0x3974f0)`.

At `0x409a0–0x409b8`, the same global pointer is passed to the range writer
with AMCC parent `0x1000`, TZ0 group `0x103`, and flags `0xf`. Wrapper
`0x1a0dec` remaps the selector arguments and supplies `-1` as its last
argument; it does not change the input pointer. `0x1a0ed4` retains the
pointer at `[sp+0x40]`, from which `0x1a1174` retrieves it for the encoded
word loads. Flags `0xf` satisfy the nonzero `flags & 0x41` payload gate.

Thus this is a named TZ0 input-conversion/write path, not a detached
constant match. The local caller contains no explicit intervening write
to that descriptor's encoded fields; no live execution or exhaustive
side-effect proof for all intervening callees is claimed.

## Conditional decoder agreement

For a range inside the 1-TiB window beginning at B, with `E < 2*B`, the
28-bit page-index encoding can be inverted by adding B. OR with B agrees
because the reconstructed offsets have bit 40 clear. This statement needs
the range/window assumptions; it is not a conclusion from affine-length
checks alone. The exclusive endpoint at `E == 2*B` needs separate handling
because `(upper_word + 1) << 12` then sets bit 40 itself.

The actual source-extracted m1n1 decoder now has a synthetic round-trip test
for `[B+0x1000000, B+0x1008000)`, at both 4-KiB and 16-KiB granules.
The [host-only harness](../tests/m1n1-carveout-preflight.c) and
[sanitizer runner](../scripts/test-m1n1-carveout-preflight.py) pass.
This checks the decoder given `ram_base == B`; it does not establish that
the boot arguments produce that base. Since m1n1 rounds `phys_base` down
to 4 GiB, the needed condition is `B <= phys_base < B + 0x100000000`, not
necessarily `phys_base == B`. The earlier OR-versus-addition counterexamples
remain useful for other possible aligned bases.

Independent public source agrees with this RAM-map origin: the
[T6032 U-Boot change](https://github.com/AsahiLinux/u-boot/commit/5654e6e9f2b4dc7af138600bf9beb983c92097ef)
sets the initial `t6032_mem_map` RAM virtual/physical address to
`0x10000000000`. Its initial mapping size is not a measurement of this
machine's installed memory, and the map is not a captured m1n1 boot argument.

## Remaining boundaries

This identifies a concrete encoding used by the target firmware image.
It does not establish live branch selection, actual limit values, equality
between F-adjusted and per-plane register contents, or early MCC access
permission. A decoder change is not justified solely by replacing the
boot-argument-derived base with this constant. Native testing still requires
the independently reviewed access plan, recovery readiness and authorization.

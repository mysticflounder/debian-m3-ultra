# J575d iBoot MCC consumers: offline trace

2026-09-26. This continues the [boot address-model investigation](m1n1-t6032-boot-address-model.md)
using its exact decoded iBoot image. Code locations are decoded-file offsets;
constant-derived access addresses are not observed runtime translations.
No extracted firmware was executed. A separate read-only IORegistry query
compared published metadata; no register access or firmware change was performed.
The [evidence inventory](inventory/t6032-boot-consumers-2026-09-26.json)
pins the verifier, 26 bounded extracts (897 raw words), name tables,
allowlisted collector and capture. Wrapper bytes were compared with the
original image; byte equality does not prove runtime behavior.

## AMCC diagnostic geometry and access path

The routine beginning at `0x64e8c` contains the previously identified
`AMCC %d/%d/%d error` format reference. Its address construction now provides
an independent static comparison with the [MCC geometry evidence](m1n1-t6032-mcc-layout.md):

| Quantity | Static evidence | Limit |
| --- | --- | --- |
| Die count | `0x3a66c` returns a cached nonzero count, otherwise calls `0x19fa54`, compares the result with `0x6032` through `0x41a00`, and caches two for equality, one otherwise | The cached value and selected path were not observed |
| Controller count per die | `0x65a98` selects eight for returned IDs `0x6031`/`0x6032`, six for `0x6034`, and stores the count at image-relative `0x35b70c`; `0x65b08` loads it | Requires the initializer to have run successfully |
| Plane count | The same initializer writes one to byte `0x35b708`; `0x65b14` returns four when that byte is nonzero, zero otherwise | Global state is not a captured runtime value |
| Plane stride | `0x64f98` shifts the plane ordinal left 18 bits | `0x40000` |
| Controller stride | `0x6515c–0x65168` advances the relevant bases by `0x2000000` | Per-die loop, not the die stride |
| Die stride | `0x65178–0x65188` advances saved die bases by `0x2000000000` | Separate outer loop |

The ID getter is also not a pure constant: `0x19fa54` branches to
`0x46d88`, whose instructions form address `0x2a02c822c`, load a word,
and return its low sixteen bits on the accepted-ID path. We inspected
those instructions, not that register. A direct call to the count initializer
at `0x3a998` follows several guards; this does not establish the entire
boot path or inherited state at a future m1n1 entry.

For loop indices die `d`, controller `c`, plane `p`, the shown diagnostic
path forms these numeric access addresses:

| Access | Address expression | Instructions |
| --- | --- | --- |
| Three words, `k = 0,1,2` | `0x220021004 + d*0x2000000000 + c*0x2000000 + p*0x40000 + k*8` | Base at `0x64eb8–0x64ec0`; plane addition `0x64f98–0x64fa4`; post-index loads `0x64fb4` |
| Three detail words on the selected error path, `k = 0,1,2` | `0x22000074c + d*0x2000000000 + c*0x2000000 + p*0x40000 + k*4` | Base `0x64f0c–0x64f14`; plane addition `0x64fa0`; post-index loads `0x65000` |

Thus, **if** the count state is established by the shown T6032 initializer
and the die-count cache follows the shown T6032 path, the loops describe
two dies, eight controllers each, four planes each. This corroborates the
16-controller/four-plane layout; it does not prove successful execution,
access permission, or cache-mode scope.

### The diagnostic is not a read-only probe

After a selected error's detail and table-mask checks, the routine can
write back to the x21 address sequence: `0x65104` loads a table word
at `+8`, and `0x65108` performs `str w10,[x21],#8`. The table is at file
offset `0x2a7378`, with three twelve-byte records. Hardware meanings such
as write-one-to-clear are **not** established by this instruction pattern.

There is also a conditional direct call to the diagnostic at `0x64a7c`,
after a different store/read/test sequence. This is not claimed to be its
only caller. Neither the diagnostic nor its ID getter is suitable for a
new host-side read-only probe simply because this investigation itself is
read-only.

## Cache record names and published metadata

A different constructor consumer begins at `0x1a1dfc`, calls `0x3b6a4`
at `0x1a1e28`, and uses the literal `chosen/lock-regs` at `0x1a1e64`.
It walks 64-byte descriptors, resolves their names through `0x15650c`,
and passes field slices to the same generic routine `0x150340` used by
the inclusive-TZ path. The subrecord exporter at `0x1a2398` resolves
names through `0x156594`, constructs `%s-%s` keys, and supplies four-byte
field slices for `reg-offset`, `reg-mask`, and `reg-value`.

The name tables give a more precise interpretation of the constructor:

| Tag | Table entry | Name bytes, decoded-file offset |
| --- | --- | --- |
| `0x1000` | `0x288990` | `amcc`, `0x3099e8` |
| `0xc0` | `0x288c50` | `broadcast`, `0x309aab` |
| `0xc1` | `0x288c70` | `cache-status`, `0x309ab5` |
| `0xc2` | `0x288c90` | `master-lock`, `0x309ac2` |

For these entries, subtracting the independently established preferred
image base from the raw pointer words gives the exact name spans, including
their NUL terminators. The `0xc0–0xc2` lookup uses 32-byte records at
`0x156574–0x15658c`; `0x158680` returns their four words. This is a static
pointer-table interpretation, not observation of live firmware pointers.

The live comparison on J575d/chip `0x6032`, macOS 27.0 build 26A428,
found the following selected fields under `chosen/lock-regs/amcc`:

| Published field | Value | Corresponding constructor / exporter evidence |
| --- | --- | --- |
| `aperture-count` | 16 | Exporter takes descriptor `+0x34`; calls `0x150340` at `0x1a1fbc` |
| `aperture-size` | `0x200000` | Constructor descriptor `+8`; exporter call `0x1a1ff8` |
| `plane-count` | 4 | Constructor descriptor `+0xc`, from `0x65b14`; exporter call `0x1a206c` |
| `plane-stride` | `0x40000` | Constructor descriptor `+0x10`; exporter call `0x1a20a4` |
| `cache-status-reg-offset` | `0x1c00` | Subrecord tag `0xc1`, field `+8`; exporter call `0x1a24a4` |
| `cache-status-reg-mask` | 1 | Same subrecord, field `+0xc`; exporter call `0x1a2530` |
| `cache-status-reg-value` | 0 | Same subrecord, field `+0x10`; exporter call `0x1a25b0` |

These are **published metadata values, not register contents**. In
particular, `cache-status-reg-value = 0` does not show that a hardware
register currently reads zero, or establish a safe cache-transition sequence.
Matching the OS build and metadata does not prove that this exact downloaded
iBoot binary was the one executed by the installed boot chain.
The 2-MiB `aperture-size` field is not the 32-MiB controller window length
used by the MCC `reg` geometry; these must not be substituted for one another.
The three allowlisted `broadcast-reg-offset/mask/value` keys were absent
from this node. That is not evidence that the hardware lacks broadcast access.

The parent descriptor's `+0x14 = 0x1c0000` remains unresolved. At
`0x1a2074`, forming `descriptor+0x14` supplies the end bound of the
four-byte `plane-stride` slice beginning at `+0x10`; it does **not** read
the word at `+0x14`. This export path therefore does not justify adding
`0x1c0000` to the cache-status offset or labeling that field a broadcast base.

## Inclusive-TZ argument packaging

The bit-4-guarded call at `0x133974` reaches `0x150340`. Before the call,
x4/x5 point to the `inclusive-tz-range` string, x6 is that pointer plus
19, and x7 is copied from x28 by `0x13410c`. The callee:

- saves incoming x0/x1/x2 in x10/x9/x8 through `0x151304`;
- copies caller-stack arguments and x4–x7 into a temporary stack record;
- calls `0x1512ac`, which loads the global cell at image-relative
  `0x2c9b48`, constructs a `+0x50` bound and restores the saved arguments
  into x4/x5/x6;
- calls `0x15002c`, then restores its frame and returns.

This establishes argument/record packaging. It does not, by itself,
identify a TZ register write or exclude hardware effects in downstream
callees. The bounded `0x14fda8` callee walks a table with count at `+0x40`
and 80-byte records, calls a comparator, and returns a selected record
through an output pointer. That supports a generic in-memory lookup path;
it does not identify a hardware protection operation. Ordinary loads/stores
can access MMIO without any special system-register instruction; the
absence of `mrs`/`msr` is not an MMIO safety test. The global's raw file
contents are not treated as an observed live pointer.

## Remaining cache/TZ gates

The diagnostic accesses are not the cache-enable operation at logical
offset `0x1c1c00` found in the macOS driver. They cannot settle that
operation's broadcast scope or early-boot accessibility. Record names and
several field meanings are now corroborated, but the `0x1c0000` field's
hardware role, actual cache-transition consumer, inclusive-TZ protection
contract, loader/DMA containment and recovery remain separate questions.

# J575d TZ endpoint translation and RAM reconstruction

2026-09-27. Offline continuation of the
[four-slot endpoint trace](m1n1-t6032-boot-tz-endpoints.md).
All instruction locations below are decoded-file offsets, not live PCs.
No firmware, MMIO or native boot code was executed. Native CPU/frequency
dispatch remains disabled; it does not guard the separate early MCC reads.

## Pinned evidence

The input is the same 3,200,112-byte J575d iBoot image, SHA-256
`bed91c680ce5471ed1210be017ef9a33542e47c83bb7721f03e0aac209ca1c9e`.
Local artifacts under `scratch/mcc-evidence/`:

| Artifact | SHA-256 |
| --- | --- |
| `verify-boot-tz-translation.py` | `b16ef68a6558df8d09584744db4bc1e25b1ef6625908d43d933a179fa8bc3009` |
| `boot-tz-translation.json` | `513d6fc14bfd086d25d98183d4078b94d8b45b9949e5b89075b5379ed74a14a3` |

The verifier pins its byte-checking dependency, validates the entire wrapper
against the raw image, compares 325 raw instruction words in 15 extracts,
and checks one signed jump-table entry. These are byte/provenance checks,
not a proof of instruction semantics, runtime reachability or hardware safety.
An independent byte audit reproduced the wrapper, extract and table checks;
a separate static review checked the context/result dataflow below.

## What the endpoint helper actually does

The two calls to `0x31c90` at `0x35974` and `0x35994` are not loads from
the candidate endpoints. The direct branch reaches `0x31a68`, which executes
`AT S1E1R`, `ISB`, and reads `PAR_EL1`. It tests bit zero and returns:

```text
PAR_EL1 bit 0 set:   0
PAR_EL1 bit 0 clear: (PAR_EL1 & 0x0000fffffffff000) | (input & 0xfff)
```

This is a stage-1 translation query with read permissions, not a cache-enable
operation or proof that physical memory is safe to access. Arm documents AT
as a query whose result or translation-fault information is returned in PAR;
the translation regime depends on architectural execution state.
See [Arm's AT S1E1R register reference, page 140](https://documentation-service.arm.com/static/60df1943677cf7536a55ddef)
and [Memory management, section 9](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/Learn%20the%20Architecture/LearnTheArchitecture-MemoryManagement-101811_0100_00_en.pdf).

The caller rejects a nonzero return after either query. A zero return is
**not an unambiguous assertion that the address is unmapped**: the helper
also returns zero for a successful zero-valued reconstructed address.
It discards the fault details. Two endpoint queries cannot establish the
translation/protection of every address in the interval, and stage-1 results
cannot establish MCC register permission or the state of physical TZ locks.

## Direct versus SVC dispatch

`0x18b7e8` reads `TPIDRRO_EL0`; its ordinary nonzero return preserves that
value. `0x18b81c` tests whether it equals minus one. That sentinel selects
the direct tail branch at `0x31ccc`; another nonzero value selects
`SVC #0x32` at `0x31cd4`. The zero case enters a separate error path whose
normal return is not established. No live selector value was captured.

The image also contains this guarded SVC route:

| Step | Static evidence |
| --- | --- |
| Exception classification | `0x18c43c–0x18c448`: read ESR_EL1, compare bits 31:26 with `0x15`, branch to `0x18c820` |
| Selector and original argument | `0x18c854`: w7 receives ESR low 16 bits; `0x1962cc` saves selector and `0x1962e8` saves incoming x0 in x23 |
| Preconditions | Context/pointer bounds, helper `0x191ec8` bit-zero result, and global byte `0x3b8b0c` are checked before the jump table |
| SVC32 table entry | Table `0x199cc4`, slot `0x199d8c`: signed `0x480` relative to `0x196398` selects `0x196818` |
| Same translation helper | `0x196818` restores x0 from x23; `0x19681c` calls `0x31a68` |
| Result packaging | `0x197738` saves result in x4; `0x198164` restores the saved context pointer; `0x196504` calls `0x18ccfc`, which bounds-checks and stores x4 at context offset zero |
| Normal return | `0x18c8e0` selects the TPIDR_EL1 context as SP; the normal path restores x0 from `[sp]` at `0x18c980` and reaches `ERET` at `0x18ca0c` |

The context getter `0x195a38` calls `0x18cce4`, which obtains the pointer
from `TPIDR_EL1` and constructs bounds `[pointer, pointer+0x5b0)`.
The dispatcher saves that pointer at `[sp+0xd0]`, explaining the result
store/restore correspondence on the normal path with that context retained.
The alternate return path selected by context halfword `+0x138` is not
qualified here. Runtime vector registration, context initialization,
permission-helper result and mapping state remain unobserved. This is a
conditional static route, not evidence that this exception path executed.

## What this leaves unresolved in m1n1

In the pinned eleven-patch source, `memory.c:mmu_add_default_mappings()` sets
`ram_base = ALIGN_DOWN(cur_boot_args.phys_base, BIT(32))`. The T6032 decoder
in `mcc.c` reconstructs limits as:

```text
start = ((u64)first << 12) | ram_base
end   = (((u64)last + 1) << 12) | ram_base
```

The aligned base is derived from boot arguments, not from the TZ registers.
The `/chosen` DRAM value used separately for FDT reporting is not this
assignment. iBoot's identified caller instead supplies base zero to an
addition-based endpoint calculation. Neither that caller nor the published
carveout metadata proves m1n1's OR reconstruction.

For example, the **synthetic**, 4-KiB-granule decoder inputs
`ram_base=0x100000000`, `first=0x100000`, `last=0x100001` and sufficient RAM
extent preserve the two-page interval under OR and pass the decoder checks.
OR produces `[0x100000000, 0x100002000)`; addition instead produces
`[0x200000000, 0x200002000)`. This demonstrates a limitation of the software
checks, not a bug in the hardware encoding or a reason to replace OR.

The [host harness](../tests/m1n1-carveout-preflight.c) now checks this case
and a second synthetic base `0x13f00000000` using the actual source-extracted
affine helper and decoder. Its [runner](../scripts/test-m1n1-carveout-preflight.py)
passes with AddressSanitizer/UndefinedBehaviorSanitizer; MMIO and mapping
operations are mocks. Neither input is claimed to have occurred on hardware.

The constructor's 28-bit mask would allow shifted fields in bits 12–39,
overlapping bits 32–39 of a merely 4-GiB-aligned base. m1n1 currently accepts
full 32-bit fields, whose shifted values can also occupy bits 40–43.
Whether these bits are absolute address bits, relative offsets, reserved,
or supplied by the base needs target-specific evidence. Endpoint increment
carry must be considered separately from the width of the stored field.

Next: trace the producer of the lower/upper descriptor values and the source
of the handoff physical base, looking for an explicit coordinate conversion.
A future comparison with actual boot arguments and raw limits must identify
the same boot and pass the separate native-access/recovery authorization
gates. Do not substitute current metadata addresses or perform speculative
register reads. Alias equivalence, cache transition effects and early access
permissions remain separate open obligations.

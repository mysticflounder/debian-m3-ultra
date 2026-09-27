# T6032 runtime stage-1 mapping guard

2026-09-26 local time. Offline source changes and host tests only; no native
firmware, MMIO, boot-policy, storage or VM changes.

[`0010`](../patches/m1n1/0010-guard-t6032-runtime-mappings.patch) follows
[initial carveout preflight](m1n1-t6032-carveouts.md). Initial removal alone
was insufficient: framebuffer setup can create new mappings afterward.

## Coverage and lifecycle

All in-tree stage-1 mapping creation reaches `mmu_add_mapping()`. The lower
`mmu_map()` is also globally visible. The patch checks both:

- Raw mapping requests are validated before descriptor attributes are added.
- Valid descriptor targets are checked again in `mmu_map()` before its first
  page-table operation. The check extracts the physical target, so changing
  the virtual alias cannot avoid a protected physical interval.
- `mmu_map_framebuffer()` checks before `dc_civac_range()`, not just before
  mapping. Direct `fb_init()` and `fb_clear_direct()` mapping calls pass
  through the shared guard as well.
- Invalid descriptors used by `mmu_rm_mapping()` remain permitted. This is
  an exclusion guard on mapping creation, not a ban on removing mappings.

For nonzero T6032 mappings, the raw helper checks runtime 4K/16K alignment,
low-48-bit virtual table indices and 42-bit physical bounds. These limits
match the pinned `mmu_configure()` TCR settings, including `TCR_IPS_4TB`;
the wider `PTE_TARGET_MASK` is not evidence that this configuration accepts
50-bit physical addresses. Subtraction-based bounds checks reject overflow
before any mapping effect. Zero-size requests retain existing mapper
behavior. Non-T6032 calls bypass the new checks.

A separate private ready flag distinguishes a published empty carveout map
from incomplete setup. After successful initial removal, the flag activates
physical half-open interval checks against the published ranges. Oversized
counts and zero, misaligned or wrapping published ranges fail closed. A
repeated preflight cannot silently clear active protection: it rejects until
a new setup phase is explicitly started.

`P_MMU_SHUTDOWN` followed by `P_MMU_INIT` is an existing rebuild path.
`mmu_init()` starts a new carveout setup phase only after its MMU-enabled
early return, before allocating the new tables. Default mappings are built
while protection is unpublished; final preflight removes carveouts and
republishes protection before MMU enable. `mmu_disable()` and
`mmu_restore()` do not clear this state. Secondary setup reuses the tables
and does not begin a new phase.

## Offline verification

[`test-m1n1-mapping-guard.py`](../scripts/test-m1n1-mapping-guard.py) verifies
the source archive hash, applies all ten patches and extracts the actual MCC
preflight/publication functions, mapper, mapping wrappers and constants.
The host harness passes with AddressSanitizer and fail-fast UBSan. Page-table
helpers, cache maintenance, hardware reads and heap effects are mocked;
unexpected fatal calls abort rather than returning into the tested code.

Coverage includes successful/empty/failed publication, repeat-call rejection,
state reset, alias clipping, all four virtual aliases at both granules,
physical overlap with descriptor attributes, exact VA/PA boundary acceptance,
overflow/width/alignment rejection, invalid-PTE unmapping, zero-size mapping,
framebuffer rejection before cache effects and legacy T6031 behavior. Source
checks tie limits to the actual TCR configuration and confirm reset ordering.
Removing only the new T6032 guards leaves the original mapper and both
wrappers byte-for-byte unchanged. Full MMU initialization, page-table
allocation and native cache/TLB effects are not executed by this harness.

All thirteen previous suites also pass (71 Python unit tests and seven
host/source harnesses). Those suites apply their relevant patch subsets;
the new harness applies all ten. The [ten-patch default firmware build](inventory/m1n1-mapping-build-2026-09-26.json)
passes for all four artifacts, with the same two baseline warning categories.
All ten patch and four artifact hashes match the build record. Artifacts
remain uninstalled and unexecuted.

```sh
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 scripts/test-m1n1-mapping-guard.py
bash scripts/build-m1n1-cpu-offline.sh patched
```

## Limits that remain native gates

This is not a security boundary against privileged proxy calls, arbitrary
memory/register writes or deliberate mutation of global state. It does not
guard DMA or stage-2 page tables. In particular, display reconfiguration
performs DART operations before calling the framebuffer mapping helper;
rejecting a stage-1 mapping does not undo those operations. Framebuffer
caller state changes/logging before the shared mapping call are not rolled
back either.

The rebuild check observes the calling CPU's MMU state; it does not establish
that other CPUs are quiescent. Concurrent mapping changes, SMP rebuild
coordination and native cache/TLB behavior are not validated by this patch.

The initial setup phase intentionally has no published carveout filter;
it relies on final preflight and fatal failure propagation before MMU enable.
TZ register interpretation, controller/die equivalence, cache-mode semantics,
complete loader payload containment, Linux memory handoff and native
boot/recovery remain unvalidated. T6032 CPU dispatch remains disabled.

# T6032 mask contract: mode selection and write-path evidence

2026-09-26 local time. Offline analysis and allowlisted host metadata only;
no native payload, register write, driver installation or boot-policy change.

## Mode 1, not mode 2

The [schema-3 capture](inventory/t6032-pmgr-mode-2026-09-26.json) records
`acc-harvesting=1`. A separate filtered `kern.bootargs` check found no
`acc-harvesting` override; raw boot arguments were neither displayed nor
saved. This corrects the earlier investigation's focus on mode 2: mode 2
was useful corroboration, but is not selected by this captured property.
This is static path selection from inputs, not a live read of the driver's
private object or a trace of CPU release.

The mode selector at `this+0x238c` is feature-table entry `0x42`'s value:
`0x1d50 + 0x42*0x18 + 0xc`. The constructor template's name pointer at
`0xfffffe0008294470` resolves to `acc-harvesting`. The generic feature
loader at `0xfffffe0009b74690` obtains the property and stores the value at
record `+0xc`; it can subsequently apply a same-name boot-argument override.
Thus a zero in the constructor template was not the final selector value.

## Applicable mask computation

The non-2 branch of `ApplePMGR::configMiscCores` starts at
`0xfffffe0009b95884`. It selects a per-die slice of the requested CPU mask,
then consumes `clusters` as four-byte records: low 16 bits are the cluster's
CPU count; high 16 bits are the output shift. The translation loop is
`0xfffffe0009b958e0`–`0xfffffe0009b9592c`. A zero shift falls back to
a runtime multiplier times cluster index; for our cluster 0 this is zero
regardless of that multiplier. The model rejects zero shifts on nonzero
clusters rather than guessing the runtime multiplier's value.

The captured pairs are `(4,0), (6,4), (6,10)`. The loop takes each cluster's
low input bits, shifts them by the recorded offset, ORs the results, and
passes the result to group offset `+4` at `0xfffffe0009b95960`. Its subsequent
loop passes the unshifted cluster slices to `+8+4*cluster`, including zero
slices, at `0xfffffe0009b959c4`.

The host model now independently evaluates this mode-1 computation and
compares it with all 32 `acc-cores` byte-5 masks. They agree for every CPU:
bit ranges 0–3, 4–9, 10–15 per die. The legacy `4*cluster+core` formula
differs for 12 CPUs and aliases two pairs per die. This is a concrete
layout mismatch for the proposed T6032 port, **not a claim of an existing
T6032 runtime regression**: m1n1's T6032 dispatch is still disabled.

## Virtual calls resolved through real fixup chains

The [fixup manifest](inventory/t6032-pmgr-fixups-2026-09-26.json) proves each
listed pointer's membership in its page chain, format 8, cache level 0 and
file-backed target, for the previously matched collection hash
`a24fefccc060854cecc996b40983499e1319008e4f16c0717a5fef6c4d4828dc`.
The local SDK's `mach-o/fixup-chains.h` defines this format. Pointer
authentication is **not** performed; this is unslid offline resolution.

| Link | Resolved target |
| --- | --- |
| Subclass vptr slot `0xa88` | `ApplePMGR::enableCPUCores`, `0xfffffe0009b95c7c` |
| Slot `0xd20` | `ApplePMGR::configMiscCores`, `0xfffffe0009b95554` |
| Slot `0x1060` | `AppleT6031PMGR::writeReg32`, `0xfffffe0009f601e4` |
| Subclass superclass-vtable import | `ApplePMGR` vtable at `0xfffffe0008292c58` |
| Superclass vtable `+0x1070` | `ApplePMGR::writeReg32`, `0xfffffe0009b98580` |

Map 0 bypasses the subclass's special cases for maps 2/6 and reaches the
superclass write. That implementation obtains the selected map/die and
stores the supplied 32-bit value at mapped base plus offset
(`0xfffffe0009b98654`–`0xfffffe0009b9865c`). This closes the previously
unresolved virtual-call link, not all register side-effect/ordering questions.

## Separate topology-field question resolved

The matching collection's kernel entry—not a guessed public header—reads
the `cluster-core-id` string at `0xfffffe0007063cfc`, calls its integer
DT-property helper at `0xfffffe000be75e58`, and stores the result into CPU
record `+0x7c` at `0xfffffe000be75e5c`. The helper at
`0xfffffe000be76cfc` reads the property or uses the physical-ID low byte as
default. The sibling `die-cluster-id` lookup populates `+0x78`. The CPU
record construction uses the same `0x88` stride seen by ApplePMGR.

This establishes the field consumed by the mode-2 per-cluster path without
using an ABI-mismatched public XNU struct. It is useful corroboration, not
a reason to switch the observed board to mode 2.

## Implementation boundary and reproduction

Local patch [0005](../patches/m1n1/0005-t6032-cpu-start-masks.patch) adds a
**T6032-scoped**, fail-closed mask-selection helper to secondary startup.
It accepts only the captured `acc-harvesting=1` and twelve-byte `clusters`
table with pairs `(4,0), (6,4), (6,10)`, and die/cluster/core coordinates
within that two-die layout. Bytewise little-endian decoding avoids alignment
assumptions. Both outputs are assigned only after the entire table and the
requested coordinates pass validation. Failure precedes RVBAR access,
allocation, stack publication, cache operations and release writes.
This is a per-secondary preflight, not an all-CPU transaction or a
whole-boot abort/status interface. Before enabling dispatch, the boot CPU's
separate RVBAR path and caller-failure handling must also be reviewed.
[Patch 0006](m1n1-t6032-inventory-preflight.md) now adds whole-inventory
metadata validation before that path, without enabling CPU release.

Other SoCs keep the original two mask expressions, without reading these
properties. A `T6032` identity constant is added, **not** a dispatch case or
supported build target. The helper does not consume macOS boot arguments;
it qualifies only this captured ADT contract, not arbitrary runtime modes.
The [full offline build](inventory/m1n1-cpu-mask-build-2026-09-26.json)
passes with all five patches and no new compiler warnings. The firmware
artifacts have not been installed or executed.

The source-extracted startup harness passes four variants under ASan/UBSan:
baseline, pre-release guards, fatal timeout, and T6032 masks. The new variant
checks all 32 masks and per-die uniqueness, all 29 existing SoC constants
with no new ADT dependency, 24 malformed metadata/coordinate cases with no
startup side effects, and unchanged output masks on helper rejection.
The separate 63 Python regression tests and bounds, synthetic handoff and
four exact-board handoff cases also pass. Full ADT CPU enumeration remains
mocked in the startup harness; this is not native hardware validation.

Do not enable T6032 CPU release merely because this offline contract is clearer:
native entry/reset sequencing, CPU feature state and recovery readiness
remain separate gates. Apple's runtime sequence also writes zero masks to
other clusters; equivalence of an early-boot sequence remains untested.

```sh
python3 scripts/inspect-kernelcache-fixup.py \
  scratch/kernelcache-mac15j-offline.macho 0xfffffe00083666e0
python3 scripts/model-t6032-cpu-masks.py \
  docs/inventory/t6032-pmgr-mode-2026-09-26.json \
  docs/inventory/t6032-cpus-2026-09-26.json > scratch/t6032-cpu-mode1-model.json
```

The fixup tool rejects unsupported formats/cache levels, multi-start pages,
out-of-bounds chains and non-members. Seven synthetic chain tests and real
collection queries pass. The mask model has eleven tests, including all
32 mode-1/mode-2 comparisons and rejected inconsistent tables/selectors.
Use `PYTHONDONTWRITEBYTECODE=1` for local Python tests to avoid worktree caches.

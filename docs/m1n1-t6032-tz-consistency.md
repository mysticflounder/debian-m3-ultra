# T6032 cross-controller TZ consistency preflight

2026-09-27. Offline implementation and host testing only. No register
reads, firmware execution, installation, disk or VM changes on the target.

## Removed assumption

[Patch 0013](../patches/m1n1/0013-check-t6032-tz-plane-consistency.patch)
replaces the assumption that controller 0, plane 0 represents every TZ
configuration with a comparison of all sixteen controllers and four planes.
It retains the [fixed-origin decoder](m1n1-t6032-tz-origin.md).

Before the first register read, the preflight validates all sixteen cached
descriptors: the expected TZ table, four planes and stride `0x40000`.
Existing chip/count/initialization, RAM, image and heap checks remain.
The earlier metadata initializer still supplies and validates the aperture
bases; these new checks do not establish accessibility.

For each of the four slots:

1. Read start, inclusive end and enable at controller 0, plane 0.
2. Read the same three words at each of the remaining 63 contexts.
3. Reject a different enable state. For enabled slots, also reject any
   different start/end word. Disabled slots may have different unused limits.
4. Decode the common enabled range and stage the existing alias/heap checks.

The loop bounds are fixed at sixteen controllers and four planes. The
existing nonzero-to-boolean interpretation of enable is unchanged; distinct
nonzero words compare as enabled. This does **not** prove bit-level enable
semantics. Enabled limit words retain the decoder's 28-bit rejection.

No heap-limit update, mapping removal or successful publication occurs
until all slots pass. A late mismatch returns failure with unpublished
carveouts. An already published map is still protected by the existing
repeat-preflight rejection. The implementation rejects differences rather
than unioning them into a buffer designed for four ranges. Legitimate
nonuniform controller layouts, if discovered, would require a separately
qualified policy; they are not claimed to be supported by this check.

## Access expansion is not authorization

The maximum is now **768 32-bit reads**, not 12:
`16 controllers * 4 planes * 4 slots * 3 words`. Earlier failures may stop
sooner. Even disabled slots have their limit words read, preserving the
start/end/enable order for each sampled context. Legacy SoCs retain their
original single-context behavior.

The [Apple firmware trace](m1n1-t6032-boot-write-addresses.md) independently
contains direct per-plane verification, but its controller/plane and mode
guards do not qualify unrestricted access from m1n1. This patch requires
the access contract to cover every sampled aperture. Presence in ADT alone
is not evidence that an access is powered, permitted or fault-safe.

Sequential agreement is not an atomic snapshot or proof that another boot
agent cannot change registers afterward. A read-count bound cannot contain
a stalled or faulting MMIO access. There is no fault recovery or rollback
claim. F-adjusted versus direct-aperture equivalence, live encoding,
controller scope, cache state and DMA remain unqualified.

**Do not boot these experimental artifacts on the strength of these tests.**
Native execution still needs an independently reviewed access plan, recovery
readiness and explicit authorization. Disabled CPU/frequency dispatch does
not guard the initial-MMU MCC reads, including the additional reads here.

## Offline validation

Both source-extracted host suites apply all thirteen patches and pass with
ASan/UBSan and sanitizer recovery disabled:

- `scripts/test-m1n1-carveout-preflight.py`
- `scripts/test-m1n1-mapping-guard.py`

The mocked read log checks every controller/plane/slot/field exactly once
for successful 4K and 16K scans (768 reads). This checks coverage, not an
atomic snapshot or hardware access ordering. Tests also cover last-context
start/end/enable disagreement, disabled-slot payload variation, malformed
descriptors rejected before reads, and unchanged legacy single-context reads.
Late-failure cases include an earlier valid staged range and require no
heap-limit update, unmapping or successful publication.

A scratch-only mutation replaces just the mismatch predicate with false,
retaining descriptor validation and the full scan. With valid non-overlapping
slot-0 and slot-3 ranges, it fails the late enable-mismatch assertion as
expected (exit 1). The unmodified suite passes; this is evidence that the
assertion detects the removed guard, not a hardware test. Actual rerun output
is retained in `scratch/mcc-evidence/tz-consistency-mutant.log`.

The adjacent MCC-layout suite also passes against its existing eight-patch
subset; that result is not claimed as thirteen-patch integration coverage.

The full thirteen-patch default firmware cross-build passes in
`scratch/m1n1-firmware-patched.CyvlHP/`. No resulting firmware was executed.
Its binary SHA-256 is
`ea5878a14ea47747cbe31defec9d92e00423a516830a4bea981c1255068b81b5`.
The [build and test record](inventory/m1n1-tz-consistency-build-2026-09-27.json)
pins the patch, test sources, artifacts and rerun logs.

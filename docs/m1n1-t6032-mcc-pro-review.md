# T6032 MCC Pro-consult review

2026-09-26 local time. Consult `01M3GGV110Y8CN0VT6W9875J5N` returned;
the response was treated as external research, not execution authority.
The three primary-source findings below were independently checked. Other
consult claims are not promoted merely because they appeared in the response.

## What the sources establish

- The [T8122 MCC commit](https://github.com/AsahiLinux/m1n1/commit/fddbddf83150108d5ce1a125511413c6bc3701aa)
  reports macOS 14.8.3 using offset `0x1c1c00` to enable all planes and
  reports that the T6031-style per-plane approach also works on T8122.
  This gives the all-plane hypothesis independent family-level provenance.
  It does **not** establish T6032 decoding, side effects or sequence equivalence.
- The [historical kboot change](https://github.com/AsahiLinux/m1n1/commit/24a3a0d962e1248c6920fb8b372558073bf888d1)
  deliberately moves MCC cache enablement out of earlier initialization and
  into kernel boot. The author also reports earlier stage-1 installations
  had not been executing that enable path. This supports investigating
  deferred enablement; it does not prove a suitable inherited state on J575d.
- The [T6032 U-Boot change](https://github.com/AsahiLinux/u-boot/commit/5654e6e9f2b4dc7af138600bf9beb983c92097ef)
  adds an explicit memory map and compatible selection in `board.c`.
  It is real Ultra-specific work, but contains no MCC initialization or
  target/firmware-matched validation of the accesses we are investigating.

None closes the two requested gaps: exact T6032 register effects, and safe
access or inherited-state retention at the intended early-boot stage.
No new native dispatch, register probe, install or boot-policy change follows
from this review. Public source reading is not an upstream submission.

## Reconciliation with our existing work

The consult examined the upstream pin, not our local patch series. Its
unchecked `mcc_enable_cache()` return observation is already addressed for
T6032 by [patch 0008](../patches/m1n1/0008-validate-t6032-mcc-layout.patch):
`kboot_boot()` rejects a negative result. That guard does not roll back writes,
make each transaction safe, or establish immediate cessation of later plane
accesses after a timeout. Do not duplicate the existing caller fix or promote
it to a hardware-safety guarantee.

Likewise, absence of a literal T6032 name in upstream MCC code is not proof
that no path can execute: the captured board shares `mcc,t6031` compatibility.
Our exact geometry correction and the still-disabled CPU/frequency dispatch
must be considered separately from that upstream spelling.

## Remaining evidence needed

The [handoff/access ledger](m1n1-t6032-mcc-handoff-ledger.md) now records
our source-level accesses and independent guards. The remaining trace must
separate macOS runtime operations from the matching boot firmware. For enable,
status and carveout accesses, record the accessor, guards, aperture selection,
translation, width and ordering, and label what is observed versus inferred.
Identify the matching firmware binary/version/hash before attributing any
pre-handoff operation to it. A matching kernelcache alone cannot do that.

Retaining inherited state remains a research option, not an implementation
decision. Suppressing cache-enable writes alone does not resolve remaining
carveout reads, memory protection, loader containment or DMA requirements.

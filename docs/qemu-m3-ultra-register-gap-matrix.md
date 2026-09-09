# M3 Ultra register-exposure audit

## Result — 2026-09-08

Follow-up: the [current-fork register matrix](qemu-m3-ultra-register-results.md)
has now passed at 1/8/16/24/32 vCPUs, closing the provenance gap identified
below for the existing register set. The audit and its completed follow-up
are distinguished below; proposed steps 1–2 are complete.

No new **wrong / qemu-gap** row is demonstrated by the available evidence.
Do not add speculative cache or feature-register overrides. The current-fork
capture is complete; the remaining measurement gap concerns newer ID
registers and supported access paths, not another performance benchmark.

The initial audit queried an HVF configuration object and inspected local
QEMU/SDK sources without creating a VM. The follow-up used disposable VMs;
neither stage changed the persistent VM, firmware, boot policy, or
physical-device configuration.

## Evidence and its limits

- Completed current-fork captures: `out/el1-fork.hYTSJR/manifest.json` (one
  vCPU) and `out/el1-fork.1MDU6Z/manifest.json` (8/16/24/32), matched against
  `out/el1-fork-host.wLfqPk/host.json`. Full provenance and results are in the
  linked register-results document. These corroborate the historical values
  below with actual current-fork guest observations.

- Fresh host configuration: `out/register-audit.fqx4Ky/host.json`, macOS
  26.6.2 (25G83), SDK 26.5. All 14 feature-register queries and both cache
  arrays succeeded and exactly equal `out/cpu-matrix/host.json`. The recorded
  brand is the sandbox fallback `arm64`; this artifact alone does not identify
  the physical chip. Its QEMU 11.1.50 version string is metadata, not evidence
  that a guest ran with that binary.
- Matched historical raw guest comparison:
  `out/el1-probe-smp32.LgYQkT/host-comparison.json` and `evidence.json`.
  This used stock QEMU 11.1.1: 480 register rows and 96 cache rows across
  32 vCPUs, with consistency checks passing. The historical 1/8/16/24/32
  matrix has the same register result.
- Historical userspace comparison: `out/cpu-matrix/gap-report.json`.
  Linux EL0 observations are a separate ABI layer, not raw HVF values.
- Later fork behavioral tests do not replace a full current-fork raw-register
  matrix. In particular, `scripts/qemu-hvf-cpu-observer.c` measures thread CPU
  time; it does **not** observe effective vCPU architectural registers.

Fresh host values agreeing with old host values does not make an archived
guest capture a current-fork test.

## Gap matrix

Here, **passed-through** means measured equality, not proof of which component
services the register access. Classifications apply to the stated evidence,
not to untested configurations or M5 Max.

| Surface | Classification | Evidence-backed disposition |
| --- | --- | --- |
| Raw EL1 PFR0/1, DFR1, ISAR0/1, MMFR0/1/2 | passed-through (measured equality only) | Eight exact matches, now confirmed on the current fork. Current source mixes raw synchronization with manual PFR0/ISAR0/MMFR0 writes, including a possible MMFR0 IPA clamp. |
| CTR, CLIDR, DCZID | passed-through | Three further exact matches: `0x9444c004`, `0x81000023`, `0x4`. No measured cache-description defect. |
| CCSIDR | passed-through | L1 data `0x700fe03a`, L1 instruction `0x203fe01a`, L2 unified `0x70ffe07b`; all 96 SMP32 rows match. Exact values do not establish the servicing path. |
| DFR0 with kernel irqchip enabled | virtualized | Host `0x10305006`, guest `0x10305106`: QEMU explicitly sets PMUVer to 1. This is not host event-counter passthrough. |
| EL0 PFR0/1, DFR0, ISAR0/1, MMFR0/1/2 | masked (Linux ABI layer) | Eight historical differences classified `linux-el0-sanitized`; do not attribute them to QEMU register loss. |
| EL0 CLIDR | unavailable (access layer) | No comparable EL0 observation; use the raw EL1 capture. |
| ZFR0 / SMFR0 and SVE / SME | unavailable for guest behavioral validation | Fresh HVF values are zero; historical EL1 probes mark these `not_read`, not zero. TPIDR2's five skips do not test TPIDR2 semantics or establish physical hardware absence. |
| PFR2, ISAR2, MMFR3, MMFR4 | host API gap; measured guest zero, servicing layer unresolved | SDK 26.5 has no named queries; the experimental getter rejected all four with `HV_BAD_ARGUMENT`. The [one-vCPU EL1 follow-up](qemu-m3-ultra-new-id-registers.md) successfully read zero for each. Its trace was empty without a positive control: neither QEMU fallback servicing nor physical feature absence is established. |
| MIDR / MPIDR | virtualized (source-derived) | QEMU supplies Apple MIDR and guest affinity. Physical per-core identity passthrough is not established or required by the homogeneous model. |

The historical EL0 report also has five exact observations: DFR1, CTR,
DCZID, SMFR0 and ZFR0. EL0 equality for the latter two does not turn their
missing raw EL1 reads into measurements.

## Source trace

References below are to the checked-out sources; they explain behavior but
are not a claim that every path was exercised in the historical binary.

- `qemu/target/arm/hvf/hvf.c:1142` imports the older ID register set;
  `:1181` conditionally queries SME/SVE IDs. Comments identify missing newer
  API registers. `:1195` constructs MIDR and `:1223` sets the kernel-irqchip
  PMU version. `:1122` clamps the physical address range to the VM IPA size.
- `qemu/target/arm/hvf/sysreg.c.inc:95` lists synchronized ID registers.
  `hvf.c:1425` builds the synchronization list, excluding EL2 state when
  nested virtualization is disabled; `:1472` handles several IDs manually.
  The guards at `sysreg.c.inc:83` exclude manually handled IDs from raw
  synchronization in this tree.
  An imported configuration value is therefore not, by itself, the final
  guest-visible value.
- `hvf.c:1693` supplies a zero fallback for trapped, otherwise unhandled
  architectural ID-space reads. This describes the fallback only: it is not
  proof that a particular register trapped or that hardware lacks a feature.
- `qemu/target/arm/cpu.c:2175` clears disabled EL3/EL2/PMU fields during CPU
  realization. The masking at `:2299` is TCG-only and must not be applied to
  the HVF audit.
- SDK headers beneath
  `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/Hypervisor.framework/Headers/`:
  `hv_vcpu_config.h:29` enumerates the 14 named feature queries; `:55` and
  `:65` declare configuration and cache queries. `hv_vcpu_types.h:326`
  likewise lacks named newer IDs. This establishes the named API boundary,
  not that every raw-encoding experiment is impossible or supported.

Cache equality remains an empirical result. Current source has no HVF
cache-register synchronization or emulation path for CTR, CLIDR, DCZID or
CCSIDR (CSSELR is synchronized). A trapped, unhandled cache read reaches the
undefined-exception path at `hvf.c:1875`, not generic QEMU cache helpers.
This strongly suggests native/HVF handling if current-fork reads succeed,
but historical equality does not prove the current fork's runtime servicing
path. Observe that boundary before proposing an import patch.

## Bounded work and status

1. **Complete:** use the disposable EL1 probe with the current fork, `-cpu host`
   and `kernel-irqchip=on`, initially one vCPU. Record binary hash, source
   revision/worktree state, guest kernel, launch options and a fresh host
   capture together. Keep networking off and backing images unchanged.
2. **Complete:** compare all register and cache rows with that matched host capture using
   the existing strict comparator. If the single-vCPU gate passes, repeat
   across 8/16/24/32 vCPUs to check homogeneity.
3. If servicing-path ambiguity matters to a proposed fix, design a separately
   reviewed diagnostic that observes effective vCPU state. Do not repurpose
   the timing observer or equate a configuration query with a vCPU read.
4. Patch only a demonstrated incorrect transformation or omission with a
   supported, safe replacement. Keep newer-API investigation and irqchip-off
   PMU questions separate from the default irqchip-on contract.

The phase-4 classification gate is satisfied for the historical comparable
rows and now corroborated by the linked current-fork matrix. Successful
current-fork cache reads support native/HVF servicing given the source trace,
but do not constitute direct per-access instrumentation. Newer-register API
coverage and broader reset/migration and absent-feature validation are not
closed by these raw-register tests.

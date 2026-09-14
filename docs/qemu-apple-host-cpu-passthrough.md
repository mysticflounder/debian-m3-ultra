# QEMU Apple Host-CPU Passthrough Plan

## Project priority order

The project now prioritizes a usable persistent test environment over further
CPU-model expansion:

- **P0 (complete):** bring up the
  [persistent headless test VM](persistent-test-vm.md) with a standalone
  writable root disk, bridged NFS access, loopback-only management SSH, and
  state that survives a clean reboot.
- **P1:** continue M3 Ultra QEMU/HVF CPU correctness and stability from the
  completed evidence below. Focused QEMU or component fixes may be merged into
  the project fork before upstream acceptance.
- **P2:** inventory and validate M5 Max independently. M5 results are not a
  prerequisite for the P0 VM and must not be projected onto M3 Ultra.
- **Deferred:** retain m1n1/T6032 as the separate bare-metal roadmap; do not
  attach firmware, NVRAM, boot-policy state, or physical devices while pursuing
  the VM milestones.

Upstream QEMU coordination remains useful, but sending or landing an upstream
series is not on the critical path to the persistent VM. The numbered CPU work
below records technical dependencies, not current execution priority.

## Objective

Make QEMU's AArch64 `-cpu host` path on Apple Silicon expose every
architecturally safe CPU capability available through the public
Hypervisor.framework API to an arm64 Debian guest, with machine-checkable
evidence that every advertised feature is usable.

This is a QEMU CPU-model project. HVF remains the execution backend, but merely
enabling hardware acceleration is not the goal. Apple device emulation,
bare-metal boot, and installation on the internal SSD are not part of this
workstream.

The primary CPU target is the M3 Ultra host. M5 Max is later P2 work and must
be inventoried and validated independently. The existing
[`m1n1-t6032-bringup.md`](m1n1-t6032-bringup.md) remains a deferred bare-metal
roadmap and is not the implementation plan for this project.

## Success contract

For this project, host-CPU passthrough means:

- every system-wide-safe architectural feature that the public HVF API exposes
  is represented correctly in the guest CPU model;
- guest ID registers, Linux HWCAP/HWCAP2, and instruction behavior agree;
- QEMU does not advertise an instruction or state component that HVF cannot
  execute and preserve;
- intentional virtualization changes such as MPIDR, IPA/PARange, PMU, GIC,
  and cache-topology policy are explicit and tested;
- every vCPU exposes one coherent feature contract even when macOS schedules
  its backing thread across heterogeneous physical cores; and
- CPU-only workloads meet the project's performance target of no more than a
  few percent loss where a controlled host/guest comparison is meaningful.

Performance is an acceptance criterion, not the passthrough mechanism.

Literal physical-core identity is not currently promised. Apple's public vCPU
configuration API exposes a common feature model but no physical P/E-core
selector or divergent per-core MIDR. QEMU therefore hardcodes the Apple MIDR
`0x610f0000` and gives all vCPUs a homogeneous identity. If exact physical
MIDR or P/E identity is required, that part is blocked on new Apple API rather
than a QEMU-only patch.

## Current baseline

The repository already provides:

- a bootable Debian `linux-asahi` kernel, initramfs, and root filesystem;
- QEMU 11.1.1 launchers using `-M virt`, `-accel hvf`, and `-cpu host`;
- successful Debian boots and a complete Debian kernel package build inside
  the guest; and
- a matched host/guest integer and memory microbenchmark.

The current guest reports Apple TSO, showing that some host feature state is
already visible. It also reports MIDR `0x610f0000` for every vCPU, matching
QEMU's deliberate synthetic Apple identity. There is no source-controlled
evidence bundle containing the complete host/guest feature fingerprints, QEMU
version manifest, or benchmark suite yet. Machine-local manifests under ignored
`out/` paths now include the complete advertised-feature behavior runs and the
initial matched integer/memory benchmark matrix.

Upstream QEMU's HVF host model currently queries:

- `ID_AA64PFR0_EL1` and `ID_AA64PFR1_EL1`;
- `ID_AA64DFR0_EL1` and `ID_AA64DFR1_EL1`;
- `ID_AA64ISAR0_EL1` and `ID_AA64ISAR1_EL1`;
- `ID_AA64MMFR0_EL1`, `ID_AA64MMFR1_EL1`, and
  `ID_AA64MMFR2_EL1`; and
- `ID_AA64SMFR0_EL1` and `ID_AA64ZFR0_EL1` when the macOS/HVF runtime
  supports SME2.

The public vCPU-configuration API also exposes `CTR_EL0`, `CLIDR_EL1`,
`DCZID_EL0`, and per-cache `CCSIDR_EL1` values. Current QEMU host probing does
not consume those APIs in its explicit host-feature snapshot. Schema-2 raw
EL1 evidence now establishes that instantiated HVF vCPUs nevertheless expose
the same CTR, CLIDR, DCZID, and all three CLIDR-described CCSIDR values. Do not
infer a runtime passthrough gap from the host-snapshot code alone. Newer SDK
system-register enums include additional architectural ID registers, but enum
availability alone does not prove that the feature-configuration API or a
particular runtime can supply them.

The first complete 1, 8, 16, 24, and 32-vCPU matrix completed on 2026-08-31.
Every vCPU and configured count exposed the same Linux-visible register,
HWCAP, and sysfs identification contract. The guest exposed 19 of the 20
EL0-probed registers and reported `CLIDR_EL1` unavailable. Across the 14
registers also returned by the host HVF collector, five values matched and
eight differed. Field decoding shows that all eight differences are in fields
Linux deliberately sanitizes from its EL0 CPU-feature ABI; the current matrix
therefore demonstrates no QEMU feature-loss gap. See the
[M3 Ultra Phase 3 results](qemu-m3-ultra-phase3-results.md).

A disposable QEMU/HVF EL1 collector subsequently observed the kernel's raw
system registers directly. In the completed 1-, 8-, 16-, 24-, and 32-vCPU
evidence set, eleven raw register values matched the host HVF configuration
exactly, including `CLIDR_EL1 = 0x0000000081000023`. `MPIDR_EL1` values were unique and
topology-encoded across vCPUs. The one comparable mismatch was
`ID_AA64DFR0_EL1`: host configuration `0x0000000010305006`, instantiated
guest vCPU `0x0000000010305106`. This is attributed to the distinct HVF
configuration-versus-instantiated-vCPU API views and QEMU's minimal virtual
PMU; it is not a patch target until PMU behavior establishes a demonstrated
QEMU gap. SVE/SME registers were recorded as `not_read` because those features
are absent, never inferred as zero. These are verified QEMU-guest results,
not bare-metal observations.

The schema-2 cache follow-up sampled and restored `CSSELR_EL1` on every vCPU.
At 1 and 32 vCPUs, guest `CCSIDR_EL1` matched the host configuration exactly
for L1 data/unified (`0x700fe03a`), L1 instruction (`0x203fe01a`), and L2
unified (`0x70ffe07b`). All 96 cache rows in the 32-vCPU run were homogeneous.
Those values describe HVF's one safe homogeneous cache contract, not the
different physical P- and E-core cache geometries reported by macOS.
Specifically, macOS reports 24 performance cores with 192 KiB L1I, 128 KiB
L1D, and 16 MiB L2 groups, plus 8 efficiency cores with 128 KiB L1I, 64 KiB
L1D, and 4 MiB L2 groups. HVF's homogeneous CCSIDR sizes numerically match the
efficiency-core group. This is an API-supplied conservative contract, not
evidence that a vCPU is pinned to an efficiency core.

## Verified behavior slices (M3 Ultra)

### PMU behavior

The guest-only PMU collector is `scripts/pmu-probe-vm.sh`, using
`scripts/arm64-pmu-behavior.c`. Its runs use an explicit disposable overlay,
read-only source, no network, no firmware, and no host devices. In
`out/pmu-probe-smp1-irqchipon.JqyF1W/evidence.json`, `armv8_pmuv3` is
registered in sysfs, but cycles and all eight other hardware events are
unavailable because `perf_event_open` returns `ENOENT`; the positive-cycles
gate is false. In
`out/pmu-probe-smp1-irqchipoff.FbyweY/evidence.json`, no `armv8_pmuv3` sysfs
device is present, the kernel log reports a failed PMU probe, all nine events
return `ENOENT`, and the gate is false.

QEMU v11.1.1 `hvf.c` shows that `kernel-irqchip=on` selects Apple-OS
cycles-only PMU emulation with PMUVer 1. `off` intentionally reports PMUVer 0,
despite an inaccurate Windows-oriented userspace cycle counter; PMCEID0/1 are
zero in that userspace path. The raw DFR0/PMU distinction is consequently
classified conservatively as `unavailable`, with reason `hvf-gap` in the
runtime vPMU. This does not demonstrate a QEMU host-passthrough
patch. A focused direct EL1 PMU-register diagnostic and upstream report remain
appropriate.

### Advertised-feature behavior

The complete probe uses `scripts/feature-probe-vm.sh`,
`scripts/arm64-feature-behavior.c`, `scripts/arm64-feature-tests.S`,
`scripts/arm64-feature-crypto-tests.S`, and
`scripts/arm64-feature-advanced-tests.S`. Its 35 advertised ABI rows per CPU
split into 26 semantic checks and 9 execution-only checks. `evtstrm_wfe` and
`bti` verify instruction execution, not event-stream configuration or BTI
enforcement semantics.

All 35 rows passed at 1 vCPU in
`out/feature-probe-smp1.k7ifKG/evidence.json`. All 1,120 rows (35 per vCPU)
passed at 32 vCPUs in `out/feature-probe-smp32.85xa8v/evidence.json`; the
results are homogeneous across vCPUs. Each manifest records before/after
hashes for all eight protected inputs.

## Safety and ABI rules

- Host inventory tools require neither root nor a VM disk write. Guest-side
  collectors may make persistent writes only to their disposable overlay and
  project evidence; transient diagnostic register state must be restored and
  verified before return. They must never open a host physical device or
  system volume.
- Run guest probes with an explicit disposable overlay and read-only source
  drives. Never pass firmware, NVRAM, boot policy, or raw physical storage.
- Never infer an absent register as zero; record `unavailable`, the API error,
  and the probe method.
- Never expose a feature merely because the host compiler accepts its
  instruction mnemonic.
- Treat the complete guest-visible CPU feature set as an ABI. A new feature
  can affect migration, save/restore, kernel alternatives, and userspace
  dispatch.
- Do not bind guest identity to the physical core on which a QEMU vCPU thread
  happens to be running. macOS can schedule that thread elsewhere.
- Prefer a safe common feature value over per-vCPU asymmetry. If no safe value
  can be proven, fail `-cpu host` rather than advertise an unsafe model.
- Preserve QEMU's required virtualization clamps, including IPA/PARange and
  configuration-dependent PMU/GIC fields.

## Deliverables

1. A read-only macOS HVF feature and cache-register collector.
2. A guest-local Linux arm64 ID/cache-register and HWCAP collector that
   restores transient selector state before returning.
3. A deterministic JSON schema and comparison tool that classifies every
   difference as passed through, virtualized, masked, unavailable, or wrong.
4. Positive and negative instruction tests for every guest-visible optional
   feature relevant to the two hosts.
5. Reproducible M3 Ultra and M5 Max evidence bundles.
6. A small QEMU patch series covering only demonstrated gaps.
7. QEMU documentation for HVF `-cpu host` semantics and migration limits.
8. Performance and stability results across the target vCPU-count matrix.

## Work plan

### 0. Coordinate with upstream before changing the CPU ABI

- Send a short design note to `qemu-devel@nongnu.org` and the Apple Silicon
  HVF maintainer describing the measured gap, proposed feature contract, and
  test format.
- Ask whether cache-register passthrough, newer ID-register probing, or a
  versioned HVF host model is already being developed.
- Agree on whether host-specific fingerprints are explicitly non-migratable or
  need destination preflight checks.

Exit gate: the proposed first patch boundary and CPU-model policy have no known
duplicate or immediate maintainer objection.

### 1. Freeze a reproducible baseline

- Record the macOS build, Command Line Tools/SDK version, machine model, SoC,
  QEMU binary path, QEMU version, QEMU source revision, command line, kernel,
  initramfs, rootfs, and probe hashes.
- Keep QEMU 11.1.1 as the known-good local baseline and build a clean current
  upstream QEMU for comparison.
- Use a versioned `virt` machine where migration compatibility is being tested;
  record that unversioned `virt` and `-cpu max` can change across QEMU releases.
- Capture results for `-cpu host`; under HVF, QEMU documents `-cpu max` as the
  same host model, so it is not an independent passthrough implementation.

Exit gate: another developer can reproduce both baseline boots and identify
every binary involved.

### 2. Capture the host feature contract

The macOS collector must:

- create only an `hv_vcpu_config_t`, never a VM or vCPU;
- query the complete explicit `hv_feature_reg_t` table from the pinned build
  SDK and review that table whenever the SDK changes;
- query instruction, data, and unified `CCSIDR_EL1` arrays where supported;
- distinguish compile-time absence, runtime unavailability, and API failure;
- emit fixed-width hexadecimal values and deterministic JSON; and
- include schema, tool, SDK, OS, and QEMU metadata in the surrounding run
  manifest.

Exit gate: the collector runs without privilege or state changes, emits valid
JSON, and repeats identically on an idle host.

### 3. Capture the guest-visible CPU contract

The Debian collector must:

- record `AT_HWCAP`, `AT_HWCAP2`, and whether `HWCAP_CPUID` is present;
- attempt all relevant `MIDR`, cache, PFR, DFR, ISAR, MMFR, SVE, and SME
  register reads through Linux's userspace MRS-emulation ABI;
- turn an unsupported or restricted read into an explicit unavailable result
  rather than crashing on `SIGILL`;
- capture each vCPU's identification files under
  `/sys/devices/system/cpu/cpu*/regs/identification/`;
- capture `/proc/cpuinfo`, CPU online/present/possible masks, kernel feature
  messages, and the final QEMU command; and
- produce deterministic JSON without requiring root.

Exit gate: the existing Debian image produces a complete feature fingerprint
for all configured vCPUs.

### 3a. Observe the raw EL1 contract (verified on M3 Ultra)

- Build and load the small EL1 collector only inside a disposable QEMU/HVF
  guest; no bare-metal or firmware path is permitted for this gate.
- Capture `MPIDR_EL1`, `CLIDR_EL1`, and the ID registers sanitized by the EL0
  ABI, with explicit `not_read` status for absent SVE/SME support.
- Capture each CLIDR-described `CCSIDR_EL1` value, with interrupts disabled
  around the per-PE `CSSELR_EL1` selection and verified selector restoration.
- Require unique topology-encoded MPIDRs and a homogeneous non-MPIDR register
  contract across the selected vCPU counts.
- Compare the raw values with the host HVF configuration view. Record the
  observed `CLIDR_EL1` value (`0x81000023`) and keep the DFR0 PMU difference
  (`0x...5006` host versus `0x...5106` guest) as a virtualization/API
  investigation, not a patch request.

Exit gate: the full schema-1 1/8/16/24/32 matrix passed the original raw-EL1
consistency, safety, and host-comparison checks; schema-2 cache evidence passed
at 1 and 32 vCPUs with exact values and a homogeneous 96-row maximum-vCPU
contract; PMU behavior is classified above; and the complete 35-row
advertised-feature behavior gate passed for the recorded 1- and 32-vCPU runs.

### 4. Build the host/guest gap matrix

Classify every field with the five-value deliverable vocabulary:

1. `passed-through`: host and guest values agree exactly;
2. `virtualized`: QEMU applies a documented safe architectural transformation;
3. `masked`: QEMU intentionally removes a feature and the guest cannot use it;
4. `unavailable`: the SDK or runtime does not expose enough information, or no
   safe homogeneous value can be justified; or
5. `wrong`: the public HVF API supplies a safe value that QEMU omits or changes
   incorrectly.

Record `qemu-gap`, `hvf-gap`, or `unsafe` as a separate reason rather than as a
second classification vocabulary.

Current dispositions and remaining questions include:

- instantiated HVF vCPUs already expose HVF's `CTR_EL0`, `CLIDR_EL1`,
  `DCZID_EL0`, and `CCSIDR_EL1` values exactly; trace and document why before
  changing QEMU's separate host-feature snapshot;
- whether newer PFR2, ISAR2, MMFR3, and MMFR4 values are available through a
  usable pre-vCPU feature API on either target;
- whether PMU, SVE, and SME state survives reset and migration consistently;
  and
- whether all vCPUs see the same safe feature set at every configured count.

The irqchip-off compatibility PMU also had an independent
`PMINTENCLR_EL1` write-one-to-clear defect: QEMU 11.1.1 set cycle-interrupt bit
31 when the guest wrote that bit to the clear alias. The bounded EL1 probe in
`scripts/pmintenclr-probe-vm.sh` reproduced the transition from `0` to
`0x80000000`. The reviewable patch in
`patches/qemu/0001-hvf-arm-fix-pmintenclr-semantics.patch` passed the same
probe on QEMU 11.1.50, leaving the bit clear. Keep this fix separate from host
CPU-feature passthrough; it corrects existing virtual PMU semantics and does
not expose host PMU events.

The [2026-09-08 register-exposure audit](qemu-m3-ultra-register-gap-matrix.md)
records the source trace and evidence-backed classifications. A fresh HVF
configuration capture matches the historical host values. The subsequent
[current-fork raw EL1 matrix](qemu-m3-ultra-register-results.md) passed at
1/8/16/24/32 vCPUs: 81 CPU samples, 1,215 register records (including 162
explicit `not_read` records), and 243 exact cache comparisons. Protected
inputs were unchanged and all disposable VMs were cleaned up. No new
incorrect passthrough row or cache override is justified. Successful cache
reads support native/HVF servicing given the source trace, without directly
instrumenting each access.

The [newer-ID API investigation](qemu-m3-ultra-new-id-registers.md) then
confirmed that SDK 26.5 lacks named queries for PFR2/ISAR2/MMFR3/MMFR4. An
explicit experiment passing their architectural encodings to the vCPU getter
on macOS 26.6.2 returned `HV_BAD_ARGUMENT` for all four; seven named controls
succeeded. A subsequent one-vCPU guest EL1 capture measured successful zero
reads for all four IDs, with the existing register/cache controls passing
and all 24 protected inputs unchanged. The enabled QEMU read trace was empty
and had no positive control, so the servicing layer remains unresolved;
neither physical feature absence nor a QEMU fallback hit is established.
The [calibrated follow-up](qemu-m3-ultra-trace-calibration.md) then recorded
the OSLSR control through QEMU's sysreg handler and two QMP trace controls,
with both events enabled before/after. None of the four newer-ID reads
produced a sysreg trace; all again returned zero. This supports those reads
bypassing QEMU's userspace handler/fallback in this configuration, not proof
of physical feature absence. All 25 protected inputs remained unchanged.
The [public-control and host-feature audit](qemu-m3-ultra-public-hvf-controls.md)
found no documented named override in SDK 26.5, but identified a specific
advertisement mismatch: macOS reports RPRES while guest ISAR2.RPRES is zero.
The [matched scalar reciprocal-estimate probe](qemu-m3-ultra-rpres-behavior.md)
then matched all 28 host/guest results with controlled, restored FP state and
a QEMU-derived reference. This is an advertisement gap with no behavior
mismatch observed on the tested inputs, not proof of complete passthrough.
The [remaining-ID reconciliation](qemu-m3-ultra-remaining-id-disposition.md)
finds no additional positive mismatch in the available public flags; PFR2
and MMFR3/MMFR4 remain incomplete host evidence, not proven physical zeros.
The [CSSC scalar follow-up](qemu-m3-ultra-cssc-behavior.md) now agrees on
24 caught illegal-instruction outcomes and three successful integer controls
across host/guest. The [HBC conditional-branch follow-up](qemu-m3-ultra-hbc-behavior.md)
also matches: four caught HBC faults and four correct ordinary branch controls.
No mismatch is demonstrated for those encodings. WFxT remains untested;
the [timeout/trap review](qemu-m3-ultra-wfxt-review.md) selects an isolated
expired-deadline probe next, with future-deadline tests still deferred.
Keep CPU features unchanged; no speculative override is justified.

Exit gate: every observed mismatch has exactly one classification and an
evidence-backed disposition.

### 5. Add architectural instruction tests

For each advertised feature, execute a minimal positive test. Cover at least:

- CRC32, AES, SHA, and polynomial multiply;
- LSE atomics and RCpc where advertised;
- pointer authentication and BTI;
- DIT and Apple TSO behavior where testable;
- SVE and SME instructions and vector-length state when advertised;
- counter/timer and PMU behavior; and
- cache-maintenance and DC ZVA semantics derived from CTR/DCZID.

For each unadvertised feature with a safe test encoding, first establish its
feature-specific expected behavior. Lack of advertisement alone does not
imply an instruction must trap: RPRES changes the precision of existing
instructions, and our unadvertised guest observations match the host.
Compare host and guest under matched controls; classify faults, baseline
semantics, and enhanced semantics separately. Require a fault only when the
applicable instruction contract warrants it. Kernel selftests and existing
QEMU tests should be reused before adding project-only versions.

Exit gate: every guest-advertised optional feature has a passing behavioral
test, and unadvertised cases have an evidence-backed, feature-specific
disposition. Do not label unexpected execution a regression without checking
its results and applicable architectural contract.

### 6. Implement QEMU fixes in reviewable slices

Expected areas are `target/arm/hvf/hvf.c`,
`target/arm/hvf/sysreg.c.inc`, `target/arm/cpu64.c`, shared ARM CPU
finalization, tests, and documentation.

Proposed patch sequence:

1. add host-gated feature-probe and normalization tests;
2. refactor the HVF host snapshot only as needed to represent missing public
   data;
3. pass through cache or instruction-semantics fields only if the gap matrix
   demonstrates a runtime mismatch; the current M3 Ultra cache rows are exact;
4. add runtime-gated newer ID registers only when Apple exposes a usable API;
5. add consistency checks and fail-closed diagnostics; and
6. document the homogeneous host model and migration restrictions.

Do not add an `M3` or `M5` named CPU model merely to encode an unavailable
physical MIDR. Do not combine unrelated HVF execution, device, or performance
changes with CPU-model patches.

Exit gate: each patch fixes a reproduced mismatch, includes a regression test,
and preserves existing guests unless an intentional ABI change is approved.

### 7. Validate M3 Ultra correctness, stability, and performance

Test 1, 8, 16, 24, and 32 vCPUs. For each count:

- compare the host and guest feature fingerprints;
- boot and reboot, exercise guest PSCI CPU on/off for pre-created vCPUs, test
  same-configuration save/restore, and run bounded SMP and memory stress;
- exercise idle/WFI long enough to catch host-spin regressions;
- run the instruction suite and Linux CPU-feature selftests; and
- run a broader matched CPU-only workload suite during release qualification,
  after architectural correctness and stability are established.

The advertised-feature portion is complete across the full count matrix:
35/35 rows at 1 vCPU, 280/280 at 8, 560/560 at 16, 840/840 at 24, and
1,120/1,120 at 32 (2,835/2,835 total). All 35 advertised rows, including DC
ZVA, DC CVAP, and DC CVADP, passed on every tested vCPU. The remaining Phase 7
work is Linux-selftest coverage listed above, plus release qualification.

The bounded same-process, same-configuration save/restore gate also passes
at 1/8/16/24/32 vCPUs. All five runs restored RAM and disk after deliberate
mutation, retained guest and QEMU process identities, and passed 81 total
post-restore per-CPU workload checks plus timer functionality checks. See
[save/restore results](qemu-m3-ultra-save-restore-results.md) for evidence,
the corrected serial-reader race, and scope limits: Asahi builder kernel,
one snapshot cycle per count, and no claim about already-armed timers or
cross-process/cross-host resume.

The bounded idle/timer-wakeup gate also passes at 1/8/16/24/32 vCPUs:
243 verified wakeups, positive Linux idle counters on every CPU, and stable
host thread CPU accounting. At 32 vCPUs, vCPU threads consumed 0.272845
CPU-seconds over a 31.002195-second window (0.008801 host cores on average).
See [idle results](qemu-m3-ultra-idle-results.md) for scope and evidence.
This is timed guest-idle behavior with HVF's kernel interrupt controller,
not direct WFI-instruction counting or physical power-state validation.

The bounded SMP/memory gate also passes at 1/8/16/24/32 vCPUs: 648 worker
passes and 6,480,000 checked atomic increments, with up to 512 MiB of test
memory. See [stress results](qemu-m3-ultra-stress-results.md) for the
barrier-separated cross-CPU checks, evidence, and bounded Asahi-builder scope.
No new QEMU patch was needed. The Linux HWCAP selftest matrix also passes
at 1/8/16/24/32 vCPUs: 7,938 checks passed, 10,530 skipped, zero failed.
All 81 per-CPU TAP streams are identical. See
[selftest results](qemu-m3-ultra-selftest-results.md) for the build fixes,
evidence, and limits. Broader arm64 ABI tests remain next; skips are not
feature-support evidence, and this does not close the full Linux-selftest gate.
The one-vCPU unprivileged `ptrace` ABI smoke now passes all 11 TLS/debug
register-set checks with no skips. See [ABI results](qemu-m3-ultra-abi-results.md).
The matching one-vCPU `syscall-abi` test also passes both baseline
`getpid()`/`sched_yield()` GPR/FPSIMD checks with no skips or failures.
The combined ABI matrix now passes at 1/8/16/24/32 vCPUs: all 1,053 checks
across 81 guest-CPU placements pass without skips or failures. This is
sequential per-CPU affinity coverage, not concurrent stress or complete
CPU-state passthrough. The separate static/nolibc `tpidr2` build now succeeds;
all five checks skip because the guest SME sysctl is absent. This is not
TPIDR2 support evidence. Register-exposure comparison remains next.

Guest PSCI CPU off/on is now validated on the patched fork: all 76 secondary
cycles passed across 8/16/24/32 vCPUs, plus a 1-vCPU control. This work
reproduced and fixed an Arm HVF CPU power-state defect. See
[PSCI results](qemu-m3-ultra-psci-results.md) for the patch, failed controls,
passing matrix, and Asahi builder-kernel scope.

The clean shutdown/relaunch gate is also complete. Two separate QEMU processes
used the same disposable overlay at each of 1/8/16/24/32 vCPUs; all 10 launches
reported the exact online CPU count, both launches shut down cleanly, and the
second launch verified a sentinel written by the first. The 1-vCPU smoke
manifest is `out/lifecycle-matrix.l6bzHl/manifest.json`, and the remaining
matrix is `out/lifecycle-matrix.VfycDn/manifest.json`. This is deliberately
classified as a relaunch test, not as proof of in-process reboot/reset.

The in-process guest-reboot gate is complete as a separate test. At every
1/8/16/24/32-vCPU count, one QEMU process survived a guest PSCI system reset;
the recorded PID, process start time, command, UID, and private QMP socket
identity were unchanged. Each run observed exactly one post-boundary QMP
`RESET` event with `guest=true` and `reason=guest-reset`, retained QMP
responsiveness, changed Linux boot ID, preserved the sentinel, and reported the
exact CPU count on both boots. The 1-vCPU smoke manifest is
`out/reboot-matrix.cCLHOE/manifest.json`, and the remaining matrix is
`out/reboot-matrix.g39ZKt/manifest.json`.

QMP vCPU device hotplug is not a valid Arm `virt` gate in this QEMU baseline:
the machine does not advertise hotpluggable CPUs, so
`query-hotpluggable-cpus` and CPU `device_add` are unsupported. Guest PSCI
CPU on/off remains testable because all configured vCPUs are created at
startup. HVF also supplies the reset and pre-load synchronization hooks needed
to test reboot/reset and same-configuration save/restore. Cross-host migration
of `-cpu host` is not a portability goal.

Report performance distributions, not a single best run. Separate instruction
throughput from scheduler placement, guest OS overhead, virtio I/O, and thermal
effects. Disk and network results do not determine CPU-passthrough success.
When a concrete anomaly has already been identified, use only the smallest
reproduction and control needed to isolate it; do not expand the generic suite
in place of diagnosis.

For scheduler diagnosis, compare the fixed integer work against summed CPU
time over the same workload boundaries, not wall time alone. Native runs record
worker and process CPU seconds. Guest runs additionally snapshot the same-user
QEMU process and its stable `CPU N/HVF` thread set at each boundary, separating
vCPU CPU seconds from QEMU management-thread CPU seconds. Report wall
throughput, work per CPU-second, and scheduler residency together. These
measurements can distinguish descheduling from execution efficiency, but a
CPU-second does not normalize Apple performance/efficiency core placement or
frequency.

Clock reads and serial marker receipt are sequential rather than atomic. Treat
summed worker/vCPU time as the primary execution measure, retain process time
as the management-overhead cross-check, and record endpoint sampling
uncertainty instead of claiming identical nanosecond boundaries.

The first schema-2 24-thread diagnostic used one measured interval to validate
the method, not to establish a performance distribution. Native worker
residency was 98.73%; host-side QEMU vCPU occupancy was 99.00%, with a stable
24-thread HVF set and no counter-skew clamp. QEMU delivered 99.01% of native
integer work per CPU-second and 99.33% of native wall throughput in that
interval. This rules out host descheduling as the cause of that sample, while
leaving episodic scheduler placement as a hypothesis to test only when the
slow behavior recurs.

Exit gate: all advertised features are correct, all vCPU counts are stable,
and controlled CPU-only workloads meet the agreed performance threshold or
have an understood, actionable exception.

### 8. P2: repeat independently on M5 Max

- Run the read-only M5 inventory before making chip-specific claims.
- Capture the same host and guest JSON schema, instruction tests, vCPU-count
  matrix, stability tests, and performance suite.
- Compare M3 and M5 fingerprints to identify shared infrastructure versus
  runtime-gated feature additions.
- Keep any necessary M5-only behavior in a separate, justified patch.

Exit gate: M5 Max passes the same contract without M3 register or topology
assumptions.

### 9. Coordinate upstream without blocking fork delivery

- Develop against current QEMU master and follow `qemu-devel` email submission
  rules, DCO, `scripts/checkpatch.pl`, and `scripts/get_maintainer.pl`.
- Include host/guest fingerprints, exact macOS and QEMU versions, and test
  results in each cover letter without publishing device identifiers.
- Track regressions across QEMU and macOS updates, especially SME/SVE state,
  PMU behavior, save/restore, and idle/WFI.
- Keep the local harness able to test released QEMU and the patched development
  build with the same evidence format.

Exit gate for this coordination lane: reviewable fixes and evidence have been
sent upstream, and maintainer feedback is reflected in this plan. Neither
upstream acceptance nor this gate blocks use of validated fork-local fixes in
the persistent VM.

## Evidence bundle

Each run ID contains:

- host model/SoC class with serial numbers and device identifiers removed;
- macOS, SDK, QEMU, kernel, initramfs, and rootfs versions and hashes;
- exact QEMU command line and environment;
- raw host and guest probe JSON;
- normalized comparison and classification output;
- instruction-test commands, status, and relevant logs;
- benchmark commands, repetitions, distributions, and thermal/load notes; and
- a one-paragraph gate result.

## Definition of done

The M3 Ultra CPU-passthrough lane is complete when:

- every system-wide-safe architectural feature available through public HVF is
  correctly represented in the Debian guest;
- every advertised optional instruction or state component has a passing
  behavioral test;
- unavailable Apple APIs and intentional QEMU normalization are documented;
- M3 Ultra exposes an internally consistent homogeneous vCPU model;
- the supported vCPU-count matrix survives repeated boot, stress, hotplug,
  idle, and state-management tests;
- controlled CPU-only workloads meet the agreed performance target; and
- any required fork-local QEMU changes have regression tests and pass the M3
  validation contract.

M5 Max has its own later P2 completion gate. Upstream acceptance is a release
and maintenance goal, not a prerequisite for either the P0 persistent VM or
the fork-local M3 milestone.

Completion does not require Apple-device emulation, a real Apple MIDR, physical
P/E-core identity, m1n1, or a bare-metal Debian installation.

## Current P0 sprint: persistent headless VM

- [x] Implement `scripts/test-vm.sh init|run|info` around a standalone
  `out/testvm-root.qcow2`.
- [x] Attach `scripts/test-vm-provision.sh` read-only and provision DHCP/DNS,
  SSH, and the NFSv4 client without exposing a writable host directory.
- [x] Keep management SSH on user-mode networking bound only at
  `127.0.0.1:22022`, and add a second virtio NIC bridged to `en0` for LAN/NFS.
- [x] Pass and record the two-boot writable-root, identity, DNS/HTTPS, and
  host-to-guest SSH acceptance gates. Provisioner idempotence also passed.
- [x] Mount, read, hash, and cleanly unmount `10.0.0.229:/tank/nfs` over
  NFSv4.0 through the bridged NIC, preserving the secure reserved source port.
- [x] Verify the exact launch remains headless and attaches no firmware,
  NVRAM, Apple boot-policy state, raw physical disk, system volume, or host
  device.

The 2026-09-02 run completed two clean boots with the fork's QEMU 11.1.50,
8 vCPUs, 8 GiB RAM, direct kernel/initrd boot, HVF `-cpu host`, a read/write
ext4 root on `/dev/vda`, slirp IPv4/IPv6, loopback SSH port 22022, and the
read-only scripts disk. The root sentinel, machine ID, and SSH host key all
persisted; DHCP/DNS/HTTPS, SSH, and provisioner idempotence passed.

On 2026-09-03 the stock-kernel profile added the bridged NIC, received
`10.0.0.98/24`, and passed `scripts/test-vm-nfs.sh` end to end. The bridge is
created through a short `sudo` window; QEMU then runs as the invoking user.

See [`persistent-test-vm.md`](persistent-test-vm.md) for the launcher contract
and the complete persistence, bridge, and NFS acceptance evidence.

## Completed and queued CPU work

- [x] Add and validate the read-only macOS HVF feature collector.
- [x] Add and statically validate the read-only Linux arm64 register collector.
- [x] Add and validate the disposable QEMU/HVF raw EL1 kernel collector.
- [x] Add a QEMU probe mode that runs the guest collectors with an explicit
  disposable overlay and read-only source drives.
- [x] Run and validate the guest collector after the active builder VM releases
  `vmroot.ext4`.
- [x] Capture QEMU 11.1.1 M3 Ultra fingerprints at 1, 8, 16, 24, and 32
  vCPUs.
- [x] Run the initial matched integer/memory microbenchmark at 1, 8, 16, 24,
  and 32 vCPUs and retain seven-sample distributions plus a normalized
  descriptive comparison.
- [x] Re-run the variable 24-vCPU case with bounded controls; the original
  severe drop did not reproduce consistently and variability also appeared at
  32 vCPUs. This supports an environment-sensitive classification and does not
  establish a stable CPU-model defect.
- [x] Add only the targeted scheduler/load telemetry needed to isolate future
  performance anomalies; first add workload-boundary native and host-side QEMU
  CPU-time accounting, then retain the broader suite for release qualification.
- [x] Capture and compare raw CCSIDR values at 1 and 32 vCPUs; all three cache
  entries match public HVF exactly and the 32-vCPU contract is homogeneous.
- [x] Produce the first classified host/guest gap matrix.
- [x] Run and classify the guest-only PMU behavior slice; record the raw
  DFR0/PMU distinction as `unavailable` (`hvf-gap`, runtime vPMU) with no
  demonstrated host-passthrough patch.
- [x] Reproduce the irqchip-off `PMINTENCLR_EL1` clear-semantics defect on
  QEMU 11.1.1 and validate the focused fix on a patched QEMU 11.1.50 build.
- [x] Run the complete advertised-feature behavior gate across 1/8/16/24/32
  vCPUs: 2,835/2,835 per-vCPU rows passed homogeneously; 26 rows are semantic
  and 9 are execution-only checks.
- [x] Run two clean QEMU launches against one disposable overlay at each of
  1/8/16/24/32 vCPUs; all 10 launches reported the exact CPU count, preserved
  the sentinel across relaunch, and passed the protected-input safety gates.
- [x] Run a guest-requested in-process reboot at each of 1/8/16/24/32 vCPUs;
  the same verified QEMU process survived, QMP reported one guest reset, Linux
  boot IDs changed, sentinels persisted, and CPU counts remained exact.
- [x] Cover AES/SHA and the remaining advertised features in the complete
  behavior gate.
- [ ] Send the measured baseline and proposed first patch boundary to the QEMU
  Apple Silicon HVF maintainer and `qemu-devel`. This is a non-blocking P1
  coordination task; fork-local VM work proceeds independently.

## Primary references

- [QEMU Arm `virt` CPU types](https://gitlab.com/qemu-project/qemu/-/raw/master/docs/system/arm/virt.rst)
- [QEMU Apple Silicon HVF CPU implementation](https://gitlab.com/qemu-project/qemu/-/raw/master/target/arm/hvf/hvf.c)
- [QEMU HVF system-register allowlist](https://gitlab.com/qemu-project/qemu/-/raw/master/target/arm/hvf/sysreg.c.inc)
- [Apple Hypervisor.framework vCPU management](https://developer.apple.com/documentation/hypervisor/vcpu-management)
- [Linux arm64 CPU feature-register userspace ABI](https://docs.kernel.org/arch/arm64/cpu-feature-registers.html)
- [QEMU patch submission guide](https://www.qemu.org/docs/master/devel/submitting-a-patch.html)

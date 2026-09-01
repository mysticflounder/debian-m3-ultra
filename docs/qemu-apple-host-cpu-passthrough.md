# QEMU Apple Host-CPU Passthrough Plan

## Objective

Make QEMU's AArch64 `-cpu host` path on Apple Silicon expose every
architecturally safe CPU capability available through the public
Hypervisor.framework API to an arm64 Debian guest, with machine-checkable
evidence that every advertised feature is usable.

This is a QEMU CPU-model project. HVF remains the execution backend, but merely
enabling hardware acceleration is not the goal. Apple device emulation,
bare-metal boot, and installation on the internal SSD are not part of this
workstream.

The primary target is the M3 Ultra host. M5 Max is the secondary target and
must be inventoried and validated independently. The existing
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
not consume those APIs. Newer SDK system-register enums include additional
architectural ID registers, but enum availability alone does not prove that
the feature-configuration API or a particular runtime can supply them.

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
  collectors may write only their disposable overlay and project evidence;
  they must never open a host physical device or system volume.
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
2. A read-only Linux arm64 ID-register and HWCAP collector.
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
- Require unique topology-encoded MPIDRs and a homogeneous non-MPIDR register
  contract across the selected vCPU counts.
- Compare the raw values with the host HVF configuration view. Record the
  observed `CLIDR_EL1` value (`0x81000023`) and keep the DFR0 PMU difference
  (`0x...5006` host versus `0x...5106` guest) as a virtualization/API
  investigation, not a patch request.

Exit gate: the full 1/8/16/24/32 matrix passed the raw-EL1 consistency, safety,
and host-comparison checks; PMU behavior is classified above; and the complete
35-row advertised-feature behavior gate passed for the recorded 1- and
32-vCPU runs.

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

Initial questions include:

- whether QEMU should use HVF's `CTR_EL0`, `CLIDR_EL1`, `DCZID_EL0`, and
  `CCSIDR_EL1` data, and how those values interact with virtual topology;
- whether newer PFR2, ISAR2, MMFR3, and MMFR4 values are available through a
  usable pre-vCPU feature API on either target;
- whether PMU, SVE, and SME state survives reset and migration consistently;
  and
- whether all vCPUs see the same safe feature set at every configured count.

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

For every absent feature with a safe test encoding, verify that execution is
rejected rather than silently misexecuted. Kernel selftests and existing QEMU
tests should be reused before adding project-only versions.

Exit gate: every guest-advertised optional feature has a passing behavioral
test, and negative cases fail in the expected way.

### 6. Implement QEMU fixes in reviewable slices

Expected areas are `target/arm/hvf/hvf.c`,
`target/arm/hvf/sysreg.c.inc`, `target/arm/cpu64.c`, shared ARM CPU
finalization, tests, and documentation.

Proposed patch sequence:

1. add host-gated feature-probe and normalization tests;
2. refactor the HVF host snapshot only as needed to represent missing public
   data;
3. pass through safe cache/instruction-semantics fields demonstrated by the gap
   matrix;
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
- boot, reboot, hotplug permitted CPUs, save/restore if supported, and run
  bounded SMP and memory stress;
- exercise idle/WFI long enough to catch host-spin regressions;
- run the instruction suite and Linux CPU-feature selftests; and
- run matched CPU-only integer, floating-point, vector, crypto, compression,
  atomic, memory, syscall, and kernel-build workloads.

Report performance distributions, not a single best run. Separate instruction
throughput from scheduler placement, guest OS overhead, virtio I/O, and thermal
effects. Disk and network results do not determine CPU-passthrough success.

Exit gate: all advertised features are correct, all vCPU counts are stable,
and controlled CPU-only workloads meet the agreed performance threshold or
have an understood, actionable exception.

### 8. Repeat independently on M5 Max

- Run the read-only M5 inventory before making chip-specific claims.
- Capture the same host and guest JSON schema, instruction tests, vCPU-count
  matrix, stability tests, and performance suite.
- Compare M3 and M5 fingerprints to identify shared infrastructure versus
  runtime-gated feature additions.
- Keep any necessary M5-only behavior in a separate, justified patch.

Exit gate: M5 Max passes the same contract without M3 register or topology
assumptions.

### 9. Submit and maintain upstream

- Develop against current QEMU master and follow `qemu-devel` email submission
  rules, DCO, `scripts/checkpatch.pl`, and `scripts/get_maintainer.pl`.
- Include host/guest fingerprints, exact macOS and QEMU versions, and test
  results in each cover letter without publishing device identifiers.
- Track regressions across QEMU and macOS updates, especially SME/SVE state,
  PMU behavior, save/restore, and idle/WFI.
- Keep the local harness able to test released QEMU and the patched development
  build with the same evidence format.

Exit gate: the fixes and tests are accepted upstream or maintainers have given
a concrete alternative direction reflected in this plan.

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

The active CPU-passthrough milestone is complete when:

- every system-wide-safe architectural feature available through public HVF is
  correctly represented in the Debian guest;
- every advertised optional instruction or state component has a passing
  behavioral test;
- unavailable Apple APIs and intentional QEMU normalization are documented;
- M3 Ultra and M5 Max expose internally consistent homogeneous vCPU models;
- the supported vCPU-count matrix survives repeated boot, stress, hotplug,
  idle, and state-management tests;
- controlled CPU-only workloads meet the agreed performance target; and
- the required QEMU changes and regression tests have been accepted upstream.

Completion does not require Apple-device emulation, a real Apple MIDR, physical
P/E-core identity, m1n1, or a bare-metal Debian installation.

## Immediate first sprint

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
- [ ] Complete the broader controlled performance suite, resolve the variable
  24-vCPU result, and establish the numerical performance gate.
- [x] Produce the first classified host/guest gap matrix.
- [x] Run and classify the guest-only PMU behavior slice; record the raw
  DFR0/PMU distinction as `unavailable` (`hvf-gap`, runtime vPMU) with no
  demonstrated host-passthrough patch.
- [x] Run the complete advertised-feature behavior gate: 35/35 rows at 1 vCPU
  and 1,120/1,120 rows at 32 vCPUs, homogeneous; 26 rows are semantic and 9
  are execution-only checks.
- [x] Cover AES/SHA and the remaining advertised features in the complete
  behavior gate.
- [ ] Send the measured baseline and proposed first patch boundary to the QEMU
  Apple Silicon HVF maintainer and `qemu-devel`.

## Primary references

- [QEMU Arm `virt` CPU types](https://gitlab.com/qemu-project/qemu/-/raw/master/docs/system/arm/virt.rst)
- [QEMU Apple Silicon HVF CPU implementation](https://gitlab.com/qemu-project/qemu/-/raw/master/target/arm/hvf/hvf.c)
- [QEMU HVF system-register allowlist](https://gitlab.com/qemu-project/qemu/-/raw/master/target/arm/hvf/sysreg.c.inc)
- [Apple Hypervisor.framework vCPU management](https://developer.apple.com/documentation/hypervisor/vcpu-management)
- [Linux arm64 CPU feature-register userspace ABI](https://docs.kernel.org/arch/arm64/cpu-feature-registers.html)
- [QEMU patch submission guide](https://www.qemu.org/docs/master/devel/submitting-a-patch.html)

# M3 Ultra QEMU Host-CPU Phase 3 Results

## Scope

This report records the first complete M3 Ultra CPU-contract matrix for QEMU
11.1.1 with `-M virt`, `-accel hvf`, and `-cpu host`. It compares the
Hypervisor.framework vCPU-configuration view with Linux's guest-visible EL0
CPU-feature ABI. It does not claim to observe the guest kernel's raw EL1
register state.

All Phase 3 guest runs used QEMU `-snapshot`, a read-only vvfat source drive,
and no host privilege. Their writes were confined to project output files and
QEMU's disposable snapshot state. No firmware, NVRAM, boot policy, raw
physical disk, or host system volume was passed through or intentionally
modified.

## Evidence matrix

The matrix covered 1, 8, 16, 24, and 32 vCPUs. Every run passed these gates:

- the configured CPU count equaled the online and collected CPU count;
- the collector pinned to and observed every requested vCPU exactly once;
- the online CPU mask remained stable throughout collection;
- every vCPU exposed the same register contract except for the separately
  observed `MPIDR_EL1` value;
- the sysfs identification contract was homogeneous;
- HWCAP/HWCAP2, CPU-0 registers, and sysfs identification were identical
  across all five configured CPU counts; and
- the canonical manifests contained no machine ID, boot ID, or serial number.

The guest exposed 19 of the 20 EL0-probed registers on every vCPU.
`CLIDR_EL1` raised `SIGILL`. The sysfs identity was homogeneous:

| File | Value |
|---|---|
| `aidr_el1` | `0x000000016a695797` |
| `midr_el1` | `0x00000000610f0000` |
| `revidr_el1` | `0x0000000000000000` |

Linux returned the documented safe `MPIDR_EL1` value `0x80000000` on every
pinned vCPU. That value is an EL0 ABI result, not the vCPU's actual EL1 MPIDR.

## Classified host/guest comparison

Five complete register values matched the HVF configuration view exactly at
Linux EL0:

- `ID_AA64DFR1_EL1`;
- `CTR_EL0`;
- `DCZID_EL0`;
- `ID_AA64SMFR0_EL1`; and
- `ID_AA64ZFR0_EL1`.

The report classifies these as `exact-el0-observation`, not as proof of raw
EL1 passthrough. In particular, Linux implements `ID_AA64DFR1_EL1` as
read-as-zero for this userspace ABI, so its exact zero match is inconclusive
without the planned EL1-side observation.

The raw comparison found eight different registers and one EL0-unavailable
register. The comparison report records the eight differences as
`linux-el0-sanitized`, records `CLIDR_EL1` as `observation-unavailable`, and
leaves no register `pending`. Field-level decoding gives these dispositions:

| Register | Changed or unavailable fields | Classification | Reason |
|---|---|---|---|
| `ID_AA64PFR0_EL1` | `CSV3`, `CSV2`, `RAS` | Linux EL0 sanitized | Linux hides these fields from its EL0 CPU-feature ABI. Visible `SVE`, `DIT`, AdvSIMD, and FP fields did not differ. |
| `ID_AA64PFR1_EL1` | `CSV2_FRAC` | Linux EL0 sanitized | Visible PFR1 fields did not differ. |
| `ID_AA64DFR0_EL1` | `CTX_CMPS`, `WRPS`, `BRPS` | Linux EL0 sanitized | Linux exposes no DFR0 fields through this ABI. |
| `ID_AA64ISAR0_EL1` | `TLB` | Linux EL0 sanitized | Visible ISAR0 fields did not differ. |
| `ID_AA64ISAR1_EL1` | `SPECRES` | Linux EL0 sanitized | Visible ISAR1 fields did not differ. |
| `ID_AA64MMFR0_EL1` | `EXS`, `TGRAN4_2`, `TGRAN64_2`, `TGRAN16_2`, `TGRAN4`, `TGRAN16`, `PARANGE` | Linux EL0 sanitized | Linux hides these fields. QEMU also deliberately clamps `PARANGE` to the virtual IPA size, so an EL1 observation is required to distinguish the two transformations. |
| `ID_AA64MMFR1_EL1` | `XNX`, `SpecSEI`, `PAN`, `LO`, `HPDS` | Linux EL0 sanitized | Visible `AFP` did not differ. |
| `ID_AA64MMFR2_EL1` | `E0PD`, `TTL`, `IDS`, `NV`, `IESB`, `UAO`, `CNP` | Linux EL0 sanitized | Visible `AT` did not differ. |
| `CLIDR_EL1` | whole register | observation unavailable | Its encoding is outside Linux's EL0 CPU-feature emulation range; `SIGILL` does not establish a QEMU or HVF gap. |

Here, `sanitized` or `observation unavailable` means the current method cannot
determine the guest's raw EL1 field or value. It does not mean the feature is
absent.

## MPIDR and CLIDR ABI limits

Linux's `HWCAP_CPUID` ABI emulates a defined subset of EL0 `MRS` operations and
returns sanitized, system-wide feature values. It deliberately returns
`SYS_MPIDR_SAFE_VAL`, bit 31 only, for `MPIDR_EL1`. `CLIDR_EL1` uses `Op1=1`
and is outside the accepted feature-register encoding range, so EL0 receives
`SIGILL` even when the guest kernel can read a valid virtual CLIDR.

Consequently:

- homogeneous `MPIDR_EL1=0x80000000` does not indicate broken QEMU topology;
- EL0 `CLIDR_EL1` failure does not indicate missing QEMU cache state; and
- neither value can select a QEMU patch without an EL1-side observation.

## Conclusion and next patch gate

The Phase 3 matrix demonstrates a stable, homogeneous Linux-visible CPU
contract from 1 through 32 vCPUs. It shows no evidence of a QEMU feature-loss
gap in fields Linux exposes through the EL0 CPU-feature ABI. The follow-up raw
EL1 observation is now recorded below; do not patch QEMU from the earlier EL0
differences. Only a difference surviving the raw-register comparison and
behavioral tests becomes a QEMU patch candidate.

## Raw EL1 follow-up (verified)

The EL0 limitations above were resolved for the registers that require a
kernel-side observation. `scripts/el1-probe-vm.sh` builds and loads
`scripts/arm64-el1-probe.c` only inside a disposable Debian guest running in
QEMU/HVF. It is not a bare-metal probe and makes no firmware or boot-policy
changes. The completed 1-, 8-, 16-, 24-, and 32-vCPU evidence set is retained
under `out/el1-probe-*/evidence.json`.

The raw EL1 collector reported a complete, homogeneous contract for every
vCPU in those runs. Eleven raw register values matched the host HVF
configuration exactly, including `CLIDR_EL1 = 0x0000000081000023`. Each
`MPIDR_EL1` was unique; its topology encoding is not required to be a simple
sequence. The collector therefore checks uniqueness and observed-vCPU
correspondence rather than assuming sequential MPIDRs.

The only comparable raw mismatch was `ID_AA64DFR0_EL1`: the host HVF
configuration reported `0x0000000010305006`, while the instantiated guest
vCPU reported `0x0000000010305106`. This is currently attributed to the
distinct HVF configuration-versus-instantiated-vCPU API views and the
minimal virtual PMU exposed by QEMU. It is not a patch target yet: the result
does not demonstrate that QEMU is dropping a safe public-HVF value, and PMU
behavior is an intentional virtualization boundary that needs independent
behavioral tests.

`ID_AA64ZFR0_EL1` and `ID_AA64SMFR0_EL1` were explicitly recorded as
`not_read`, not as zero, because the guest contract reports no SVE or SME
support. This is an absence/unavailability result, not evidence of a missing
QEMU passthrough field.

A schema-2 follow-up also sampled `CCSIDR_EL1` through transient, per-vCPU
`CSSELR_EL1` selections. The selector was restored and read back before the
module re-enabled interrupts. At both 1 and 32 vCPUs, every guest cache sample
matched the public-HVF configuration exactly:

- L1 data/unified: `0x00000000700fe03a` (64 KiB, 8-way, 64-byte line);
- L1 instruction: `0x00000000203fe01a` (128 KiB, 4-way, 64-byte line); and
- L2 unified: `0x0000000070ffe07b` (4 MiB, 16-way, 128-byte line).

The 32-vCPU evidence contains 96 cache rows and reports a homogeneous cache
contract. Its comparison classifies all three architectural cache entries as
exact, with no mismatch or unavailable row. Evidence is retained at
`out/el1-probe-smp1.DbP3LL/` and `out/el1-probe-smp32.LgYQkT/`.

This closes the apparent cache-observation gap. QEMU's HVF host-feature
construction does not explicitly copy the public configuration's CTR, CLIDR,
DCZID, or CCSIDR fields into its host snapshot, but instantiated HVF vCPUs
already expose the same values at runtime. A cache-import patch is therefore
not justified by current evidence; first trace and document which values HVF
provides natively versus which QEMU virtualizes.

These EL1 runs make host/storage writes only to project evidence and a
disposable qcow2 overlay. The cache probe transiently changes only the guest
vCPU's `CSSELR_EL1`, with interrupts excluded, then restores and verifies the
original selector before returning. The root backing image is opened through
the overlay; the build disk and source share are read-only. No firmware,
NVRAM, boot policy, raw physical disk, or host system volume is passed through
or intentionally modified.

## PMU behavior (verified)

The guest-only PMU behavior collector is `scripts/pmu-probe-vm.sh`, using
`scripts/arm64-pmu-behavior.c`. It collects only guest perf behavior. Each run
uses an explicit disposable overlay and read-only source, with networking
disabled and no firmware or host devices attached.

With `kernel-irqchip=on`,
`out/pmu-probe-smp1-irqchipon.JqyF1W/evidence.json` records a registered
`armv8_pmuv3` sysfs device. Cycles and all eight other hardware events are
unavailable: every `perf_event_open` returns `ENOENT`, and the positive-cycles
gate is false. With `kernel-irqchip=off`,
`out/pmu-probe-smp1-irqchipoff.FbyweY/evidence.json` records no
`armv8_pmuv3` sysfs device; the kernel log says that probing the PMU failed,
all nine events return `ENOENT`, and the positive-cycles gate is false.

The QEMU v11.1.1 `hvf.c` source explains the distinction: `on` selects
Apple-OS cycles-only PMU emulation with PMUVer 1, while `off` intentionally
reports PMUVer 0 despite an inaccurate Windows-oriented userspace cycle
counter. PMCEID0/1 are zero in that userspace path. Classify the raw DFR0/PMU
distinction conservatively as `unavailable`, reason `hvf-gap` in the runtime
vPMU. This is not a demonstrated QEMU host-passthrough patch.

A separate direct-EL1 regression did identify a defect in the irqchip-off
compatibility implementation. In
`out/pmintenclr-probe.92g8zm/evidence.json`, QEMU 11.1.1 reports PMUVer 0 and
starts with `PMINTENCLR_EL1` bit 31 clear, but a write to the clear alias sets
the bit (`0x0000000080000000`). Source inspection found the corresponding
`|= val` operation in `target/arm/hvf/hvf.c`. The focused patch at
`patches/qemu/0001-hvf-arm-fix-pmintenclr-semantics.patch` replaces it with a
masked clear and virtual interrupt-line update. QEMU fork commit
`bcc559e53b6af4a989a7cb6b103e4f9faf3f2bd6`, based on upstream master
`a925240509d1b4b656cc480f1cc79ba4d7c8bc08`, leaves the bit clear in
`out/pmintenclr-probe.tJWBJx/evidence.json` and reports `pass` with guest PMU
state restored. Both runs used one vCPU, no
network, firmware, monitor, or host devices, immutable inputs, and a removed
disposable root overlay. This result fixes PMINTENCLR semantics only; it does
not change the broader PMU availability classification.

## Advertised-feature behavior (verified)

The probe uses `scripts/feature-probe-vm.sh` with the driver, base instruction,
crypto instruction, and advanced instruction sources. It validates 35
advertised ABI rows per CPU: 26 semantic checks and 9 execution-only checks.
`evtstrm_wfe` and `bti` remain execution-only checks: they verify instruction
execution, not event-stream configuration or BTI enforcement semantics.

The complete 1/8/16/24/32-vCPU matrix passed all 2,835 per-vCPU rows:

| vCPUs | Passing rows | Evidence |
|---:|---:|---|
| 1 | 35/35 | `out/feature-probe-smp1.k7ifKG/evidence.json` |
| 8 | 280/280 | `out/feature-probe-smp8.7jUjXx/evidence.json` |
| 16 | 560/560 | `out/feature-probe-smp16.eW1qJw/evidence.json` |
| 24 | 840/840 | `out/feature-probe-smp24.4nQfHV/evidence.json` |
| 32 | 1,120/1,120 | `out/feature-probe-smp32.85xa8v/evidence.json` |

The results were homogeneous across vCPUs at every count. In particular,
`dc_zva`, `dc_cvap`, and `dc_cvadp` executed successfully on every tested
vCPU. Each evidence manifest records the eight protected input artifacts and
their before/after hashes; all protected inputs were unchanged and every
disposable overlay and source-staging directory was removed after shutdown.

## Clean relaunch lifecycle (verified)

`scripts/lifecycle-vm.sh` performed two separate QEMU launches against the
same disposable qcow2 overlay at each of 1, 8, 16, 24, and 32 vCPUs. The first
launch wrote and verified a per-run sentinel, requested a clean shutdown, and
exited QEMU. The second launch observed the exact configured online CPU count,
verified that the sentinel survived, and also shut down cleanly.

All 10 launches passed. The 1-vCPU smoke result is in
`out/lifecycle-matrix.l6bzHl/manifest.json`; the 8/16/24/32-vCPU matrix is in
`out/lifecycle-matrix.VfycDn/manifest.json`. Both manifests report that all
protected hashes and filesystem identities remained stable and that every
disposable overlay was removed. The QEMU command lines disabled networking,
monitor/QMP, display, firmware/pflash, build drives, and host devices.

This gate proves clean shutdown and process relaunch with persisted overlay
state. It does not claim an in-process guest reboot/reset, PSCI CPU on/off, or
QEMU state save/restore; those remain separate lifecycle gates.

## In-process guest reboot/reset (verified)

`scripts/reboot-vm.sh` exercised a guest-requested PSCI system reset at 1, 8,
16, 24, and 32 vCPUs. Each count used one QEMU process and one disposable
overlay. The host armed the reset only after recording a QMP-log boundary,
then required exactly one subsequent QMP `RESET` event with `guest=true` and
`reason=guest-reset`.

All five counts passed. The QEMU PID, process start time, command, UID, and
private QMP socket identity were unchanged across each reset; QMP remained
responsive after the event. The second boot reported the exact configured CPU
count, a new Linux boot ID, and the sentinel written before reset. It then
requested a clean shutdown. The 1-vCPU smoke manifest is
`out/reboot-matrix.cCLHOE/manifest.json`; the 8/16/24/32-vCPU matrix is
`out/reboot-matrix.g39ZKt/manifest.json`.

The private QMP socket existed only inside a mode-0700 run directory and was
removed after use. Networking, display, firmware/pflash, build drives, raw
host disks, and host devices were not exposed. All protected input hashes and
filesystem identities remained stable, and every disposable overlay and
runtime control was removed.

## Matched integer/memory benchmark (verified, descriptive)

The host runner retained seven measured samples at 1, 8, 16, 24, and 32
threads in `out/benchmark-host.Do9Ue6/evidence.json`. Disposable guest runs
retained the single-thread and full-utilization rows at each vCPU count:

- `out/benchmark-guest-smp1.b9bWkx/evidence.json`;
- `out/benchmark-guest-smp8.DFCWSU/evidence.json`;
- `out/benchmark-guest-smp16.iX7pbC/evidence.json`;
- `out/benchmark-guest-smp24.FNLcLN/evidence.json`; and
- `out/benchmark-guest-smp32.FlatJT/evidence.json`.

The normalized comparison is
`out/benchmark-comparison.LCB9zl/evidence.json`. Full-utilization median guest
deltas relative to the matched host thread count were +6.15%, +0.55%, -0.60%,
-28.15%, and +19.67% for integer throughput, and +9.70%, +7.41%, +6.83%,
-13.21%, and +17.86% for single-thread memory bandwidth. The 24-thread integer
samples were highly variable on both host and guest.

The result is `descriptive_only`: host GCC 16.1 and guest GCC 16.2 differ; CPU
affinity and thermal state were not controlled; host load during guest runs was
not captured; memory remains a single-thread workload; and this slice covers
only integer and memory behavior. Every guest used a disposable overlay,
read-only source, no network, no firmware, and no host devices.

### Targeted 24-vCPU diagnosis

The original severe 24-vCPU result did not reproduce at the same magnitude.
In `out/benchmark-guest-smp24.Zk03NU/evidence.json`, the 24-thread integer
median was 31.22 Gops with a tight 30.30--32.21 Gops range, versus the original
25.70 Gops median and 24.62--34.21 Gops range. A 16-thread control in that same
24-vCPU guest had a 23.65 Gops median.

The topology discriminator in
`out/benchmark-guest-smp32.8GUd6z/evidence.json` then ran 24 and 32 active
threads inside one 32-vCPU guest. Its medians were 27.60 and 31.64 Gops, both
substantially more variable and slower than the retained original 32-thread
median of 41.02 Gops. The variability therefore moved across vCPU counts and
launches; current evidence does not establish a stable defect specific to the
24-vCPU CPU model.

### Schema-2 CPU accounting: first matched 24-thread interval

Schema 2 records host CPU-seconds observations for every warmup and measured
integer/memory interval. The observer uses non-privileged macOS process and
thread counters, requires a same-user QEMU PID/start identity, and accepts a
vCPU only when its `CPU N/HVF` thread name and stable TID are verified. The
first matched 24-thread fixed-work interval is retained in
`out/benchmark-host.uaie26/evidence.json` and
`out/benchmark-guest-smp24.Yg7LS7/evidence.json`:

| Measurement | Host | Guest |
|---|---:|---:|
| Fixed integer work | 38.4 Gops | 38.4 Gops |
| Wall time | 1.037573 s | 1.044559542 s |
| Worker CPU time | 24.584667 s | 24.837596487 s |
| Scheduler residency | 0.987266559 | 0.990752381 |
| Gops per CPU-second | 1.561949161 | 1.546043315 |

The guest wall-throughput ratio is `0.9933115`; QEMU vCPU efficiency relative
to native worker CPU is `0.9901199`. In the guest's QEMU window
(1.044986146 s), the observer measured 24 stable vCPU threads using
24.829989 s of vCPU CPU time (occupancy `0.990044585`) and
0.024641667 s of management CPU time. Sampling uncertainty was
`0.000038396 s`; no counter-skew clamp was needed.

This single sample diagnoses this interval and shows no host stolen-cycle
anomaly, but it cannot rule out episodic scheduler effects. The measurement
requires no privileged or device access. Its classification remains
`descriptive_only`, not a performance gate.

These runs support focusing further diagnosis on host/guest scheduling,
placement, load, or frequency/thermal conditions. macOS does not expose usable
non-root thermal telemetry here (`pmset -g therm` is unavailable and
`powermetrics` requires root), so the present evidence cannot choose among
those causes. Do not expand the generic benchmark suite for this issue. Any
further performance work must be a minimal discriminating experiment with host
scheduler/load telemetry.

## Remaining work

Guest PSCI off/on now passes on the patched fork: 76 secondary CPU cycles
across 8/16/24/32 vCPUs and a 1-vCPU control. The tests exposed an Arm HVF
power-state defect; the fix and evidence are recorded in
[PSCI results](qemu-m3-ultra-psci-results.md).

The EL1, cache, PMU, and complete 35-row advertised-feature results close their
respective observation/classification slices; they do not justify a QEMU
feature or cache patch. Remaining work is to trace the native-HVF versus
QEMU-emulated register boundary, complete Linux-selftest stability
coverage, classify any demonstrated mismatch, validate M5 Max independently,
and coordinate the resulting model semantics upstream. The clean
shutdown/relaunch and in-process guest-reboot gates are complete. QMP vCPU
device hotplug is excluded because Arm `virt` does not advertise hotpluggable
CPUs in this QEMU baseline. Performance diagnosis is now a separate
scheduler/environment lane, not a prerequisite for constructing the faithful
architectural CPU contract. The m1n1/T6032 bare-metal roadmap remains deferred
and is outside this QEMU workstream.

The bounded same-process save/restore gate now passes across 1/8/16/24/32
vCPUs, including RAM/disk rollback, unchanged process identity, 81 per-CPU
workload checks, post-load timer functionality, and clean shutdown. See
[save/restore results](qemu-m3-ultra-save-restore-results.md) for evidence and
limits; this does not establish already-armed timer preservation, exhaustive
architectural state restoration, or migration portability.

The bounded idle/timer-wakeup gate also passes across 1/8/16/24/32 vCPUs
with 243 verified wakeups and low measured host CPU consumption. The largest
guest used 0.272845 vCPU-thread CPU-seconds during a 31.002195-second observed
window. See [idle results](qemu-m3-ultra-idle-results.md) for exact accounting,
the Asahi-builder/kernel-interrupt-controller scope, and the distinction
between guest idle behavior and direct WFI or physical sleep-state evidence.

The bounded SMP/memory stress gate passes across 1/8/16/24/32 vCPUs:
648 worker passes and 6,480,000 checked atomic increments, with up to 512 MiB
of test memory. All disposable guests shut down cleanly, overlays were
removed, and protected input hashes stayed unchanged. See
[stress results](qemu-m3-ultra-stress-results.md) for evidence and scope;
this is not long-duration qualification or a stock-kernel result.

The Linux HWCAP selftest matrix also passes across 1/8/16/24/32 vCPUs:
7,938 checks passed, 10,530 skipped, zero failed, with all 81 per-CPU TAP
streams identical. See [selftest results](qemu-m3-ultra-selftest-results.md)
for the matching Asahi-builder source, unchanged input hashes, and the two
corrected build-header integration issues. Broader arm64 ABI selftests remain
open; skips are not feature-support evidence.
The one-vCPU unprivileged `ptrace` ABI smoke subsequently passed all 11
TLS/debug register-set checks without skips or failures. See
[ABI results](qemu-m3-ultra-abi-results.md) for source pins and bounded scope;
the matching one-vCPU `syscall-abi` smoke also passed both baseline
GPR/FPSIMD checks without skips or failures. The combined ABI matrix then
passed at 1/8/16/24/32 vCPUs: 1,053 checks across 81 guest-CPU placements,
zero skips/failures, with all protected inputs unchanged. This validates
sequential per-CPU affinity coverage only; the separate `tpidr2` build and
broader architectural coverage remain open.

## Primary sources

- [QEMU 11.1.1 HVF Arm host construction](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.1/target/arm/hvf/hvf.c)
- [QEMU AArch64 feature-field definitions](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.1/target/arm/cpu-features.h)
- [QEMU AArch64 CPU finalization](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.1/target/arm/cpu64.c)
- [Linux arm64 CPU-feature-register ABI](https://www.kernel.org/doc/html/latest/arch/arm64/cpu-feature-registers.html)
- [Linux arm64 CPU-feature emulation](https://github.com/torvalds/linux/blob/master/arch/arm64/kernel/cpufeature.c)
- [Linux armv8 PMUv3 implementation](https://github.com/torvalds/linux/blob/v6.12/drivers/perf/arm_pmuv3.c)
- [Linux CPU identification sysfs ABI](https://github.com/torvalds/linux/blob/master/Documentation/ABI/testing/sysfs-devices-system-cpu)

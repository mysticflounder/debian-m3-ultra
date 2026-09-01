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

These EL1 runs write only project evidence and a disposable qcow2 overlay.
The root backing image is opened through that overlay; the build disk and
source share are read-only. No firmware, NVRAM, boot policy, raw physical
disk, or host system volume is passed through or intentionally modified.

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
vPMU. This is not a demonstrated QEMU host-passthrough patch; a focused direct EL1
PMU-register diagnostic and upstream report remain appropriate.

## Advertised-feature behavior first slice (verified, incomplete)

The first slice uses `scripts/feature-probe-vm.sh`,
`scripts/arm64-feature-behavior.c`, and `scripts/arm64-feature-tests.S`. It
covers 14 advertised checks. The seven semantic checks are `fp_asimd`,
`crc32`, `pmull`, `lse_atomic`, `flagm_cfinv`, `dit`, and `dc_zva`. The seven
execution-only checks are `lrcpc_ldapr`, `ilrcpc_ldapur`, `sb`,
`paca_roundtrip`, `pacg`, `dc_cvap`, and `dc_cvadp`.

At 1 vCPU, all 14 checks passed in
`out/feature-probe-smp1.xCza5u/evidence.json`. At 32 vCPUs, all 448 checks
(14 per vCPU) passed in `out/feature-probe-smp32.jhdO3F/evidence.json`; the
results were homogeneous across vCPUs.

**This is a first slice only and does not close the full
every-advertised-feature gate. AES/SHA and other advertised features remain.**

## Remaining work

The verified EL1 and PMU results close their observation/classification slice;
they do not by themselves justify a QEMU patch. Future work is to complete the
advertised instruction/state suite, including AES/SHA and the remaining
features, and classify any mismatch that survives those tests. M5 Max remains
the secondary target and must repeat the same inventory and evidence process
independently. The m1n1/T6032 bare-metal roadmap remains deferred and is
outside this QEMU workstream.

## Primary sources

- [QEMU 11.1.1 HVF Arm host construction](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.1/target/arm/hvf/hvf.c)
- [QEMU AArch64 feature-field definitions](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.1/target/arm/cpu-features.h)
- [QEMU AArch64 CPU finalization](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.1/target/arm/cpu64.c)
- [Linux arm64 CPU-feature-register ABI](https://www.kernel.org/doc/html/latest/arch/arm64/cpu-feature-registers.html)
- [Linux arm64 CPU-feature emulation](https://github.com/torvalds/linux/blob/master/arch/arm64/kernel/cpufeature.c)
- [Linux armv8 PMUv3 implementation](https://github.com/torvalds/linux/blob/v6.12/drivers/perf/arm_pmuv3.c)
- [Linux CPU identification sysfs ABI](https://github.com/torvalds/linux/blob/master/Documentation/ABI/testing/sysfs-devices-system-cpu)

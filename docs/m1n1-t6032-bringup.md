# m1n1 T6032 / J575d Bring-up Plan

Status: planning baseline, 2026-08-29

Target hardware: Mac Studio (M3 Ultra), Apple model `Mac15,14`, board
`J575dAP`, SoC `T6032`, 32 CPUs (8 efficiency and 24 performance cores),
two dies.

## Objective

Add the minimum upstream-quality T6032 support needed for m1n1 to start and
release all CPUs, perform required early SoC initialization, preserve the
firmware-derived hardware description, and hand a bootable payload to U-Boot
and Linux.

The first milestone is a diagnostic, RAM-only Linux boot with all 32 CPUs. It
is not a Debian installer and does not include speculative kernel drivers.
m1n1 provides the boot and hardware-enablement layer; Linux drivers remain a
separate workstream.

## Baselines

Record and pin all three inputs before implementation, then refresh them before
submitting anything upstream:

| Component | Planning baseline | Purpose |
| --- | --- | --- |
| m1n1 | `a735ea29aed4843c301d8d9665949b30a84d25df` | Source to modify |
| Linux Apple SoC device tree | `396331cc6447` in `apple-soc/dt-7.3` | T6032 topology and address cross-check |
| Asahi installer | `f0469cea0899f3efed8efead604174c7a53c4451` | Installation dependency only; not an initial target |

The accepted initial Linux series already describes T6032's 32 CPUs, two dies,
AIC, power-state controllers, UART, pinctrl, I2C, watchdog, and boot
framebuffer. The m1n1 work should consume that knowledge, not invent a second
board description.

## Safety invariants

This machine currently has no second recovery Mac available. Until either a
known-good recovery host is on hand or a maintainer runs the payload on a
separate T6032 test machine:

- do not create or alter an Apple boot-policy entry;
- do not install or replace m1n1 stage 1;
- do not resize APFS or write an internal EFI System Partition;
- do not hand-build an unsupported Asahi installer profile;
- do not run code that writes NVMe, SMC, power-management, or unknown MMIO
  registers on the target.

Apple firmware revive/restore requires another supported Mac and a USB-C cable
that carries data. Acquiring or borrowing that recovery setup is a hard gate
for persistent native-machine testing, not a paperwork item to waive.

The first target execution after that gate must be a tethered or maintainer-run
diagnostic payload. Linux, its DTB, and the initramfs stay in RAM; the initramfs
contains no storage assembly or filesystem-writing services.

## What is known and what must be measured

| Area | Established from current sources | Hypothesis requiring ADT or hardware evidence |
| --- | --- | --- |
| SoC ID | `src/soc.h` defines T6030, T6031, and T6034, but not T6032 | T6032 can share the T6031/T6034 early-UART path |
| CPU capacity | `src/smp.h` caps m1n1 at 24 CPUs, and `src/smp.c` drops ADT CPUs whose ID exceeds the bound; T6032 exposes 32 | Raising the bound has no hidden 32-bit bitmap or layout limit; the separate four-CPU EL3 limit remains valid |
| CPU start | `src/smp.c` has a T6031/T6034 start-register case and already applies a per-die PMGR offset | T6032 uses the same `0x88000` start offset on both dies |
| CPU clusters | `src/cpufreq.c` lacks T6032; T6031 has three clusters and existing Ultra tables demonstrate explicit six-cluster/two-die layouts | T6032 uses T6031 p-state semantics at the six expected die-relative register blocks |
| Memory controller | `src/mcc.c` selects `mcc,t6031` by ADT compatibility and has generic multi-die handling | T6032 firmware advertises a compatible layout needing no new code |
| PCIe | `src/pcie.c` selects `apcie,t6031` by ADT compatibility | T6032 firmware advertises the same compatible and register contract |
| CPU workarounds | `src/chickens.c` selects core workarounds from CPU identity and has existing T6030/T6031 M3 core initialization | T6032 uses identical Everest/Sawtooth MIDRs and feature behavior |
| Device tree | Linux T6032 DTS has both dies and all CPU nodes | The final runtime FDT retains correct OPP, capacity, performance-domain, interrupt, and NUMA/topology data for die 1 |

Candidate CPU frequency register blocks, to be checked against a real ADT
before coding, are:

| Cluster | Candidate base |
| --- | --- |
| die 0 ECPU | `0x0210e00000` |
| die 0 PCPU 0 | `0x0211e00000` |
| die 0 PCPU 1 | `0x0212e00000` |
| die 1 ECPU | `0x2210e00000` |
| die 1 PCPU 0 | `0x2211e00000` |
| die 1 PCPU 1 | `0x2212e00000` |

These addresses are a review aid derived from the existing T6031 and other
dual-die tables. They are not permission to touch those registers until the
ADT and a maintainer familiar with T603x confirm them.

## Deliverables

1. A small, reviewable m1n1 patch series adding T6032 support without unrelated
   refactoring.
2. A reproducible build manifest recording compiler, m1n1 revision, config,
   payload hashes, Linux revision, DTB, and initramfs.
3. A read-only diagnostic payload and serial/proxy capture procedure.
4. Evidence for every reused compatibility or register layout.
5. A hardware validation report covering all 32 CPUs, both dies, repeated
   boots, and clean handoff to Linux.
6. Upstream pull requests, revised from maintainer feedback.

Not in the initial scope:

- enabling the public Asahi installer for `J575dAP`;
- internal-NVMe installation or an unattended Debian installer;
- GPU, Thunderbolt, HDMI, Wi-Fi, Bluetooth, 10 GbE, or NVMe drivers;
- inventing an Apple-specific Linux cpuidle ABI;
- changing kernel drivers merely because QEMU reports them absent.

## Work plan

### 0. Coordinate before duplicating private bring-up work

- Open a short design discussion with m1n1/Asahi maintainers describing the
  exact board, recovery limitation, and proposed minimal patch split.
- Ask whether unpublished T6032 m1n1 changes, ADT dumps, or a maintainer-owned
  test machine already exist.
- Ask for confirmation of the CPU start offset, early UART, and CPU-frequency
  register map. Keep all unconfirmed values marked as hypotheses.
- Decide who can execute the first hardware test. Prefer a maintainer with a
  disposable/recoverable T6032 environment until this machine has a recovery
  host.

Exit gate: no known duplicate series, and a named safe path exists for the
first hardware run.

### 1. Make the source and build inputs reproducible

- Work from a dedicated m1n1 fork based on the pinned revision.
- Record the upstream remote and exact commit rather than copying loose source
  files into this repository.
- Build the normal universal image and a T6032-targeted debug image. The latter
  is for early UART and assertions; it must not become a permanent fork of the
  universal image.
- Enable warnings-as-errors where supported and retain the map file, ELF,
  stripped binary, symbols, and checksums.
- Add a CI/static check that enumerates every `MAX_CPUS` consumer and every
  T603x `switch` so a new SoC cannot be partly supported unnoticed.

Exit gate: both configurations build reproducibly from a clean checkout and
the artifact manifest is sufficient for another developer to reproduce them.

### 2. Add the minimal target definition and 32-CPU capacity

Expected source areas:

- `src/soc.h`: define `T6032` and, after confirmation, place it in the correct
  early-UART mapping.
- `src/uart.c`: verify that runtime selection finds the real T6032 ADT
  `uart6/debug-console` or `uart0` node and uses its `reg`, independent of the
  compile-time debug base.
- `src/smp.h`: raise `MAX_CPUS` from 24 to at least 32.
- every use of `MAX_CPUS`: audit arrays, loops, CPU-ID validation, stack
  allocation, spin tables, printf formats, and masks.

Do not assume that increasing the array bound is sufficient. Prove that no
CPU-set representation uses a 32-bit value in a way that loses CPU 31, that
logical IDs are dense or correctly mapped, and that the larger secondary-stack
allocation fits the m1n1 layout. `MAX_EL3_CPUS`, currently four, is a separate
constraint for the EL3 path; document why normal EL2 bring-up does or does not
touch it instead of raising it mechanically.

Hardware-free tests:

- compile-time assertions for array lengths and CPU-mask widths;
- a fixture or host-side test containing all 32 T6032 CPU nodes;
- boundary tests for CPU IDs 0, 23, 24, and 31;
- inspection of the link map for overlap or unexpected image growth.

Exit gate: the image represents all 32 CPUs without truncation, overflow, or
layout overlap.

### 3. Bring up secondary CPUs on both dies

- Add T6032 to the CPU-start path in `src/smp.c` only after confirming the PMGR
  start-register offset from ADT or maintainer hardware evidence.
- Preserve the existing per-die offset logic; avoid copying a second complete
  bring-up routine for die 1.
- Instrument enumeration and release with logical CPU ID, affinity/MPIDR,
  die, cluster, core, computed start-register address, and bounded timeout.
- Verify every ADT CPU tuple against the current decoder: core in bits 0-7,
  cluster in bits 8-10, and die in bits 11-14 of the ADT `reg` value. Treat an
  out-of-range or duplicate tuple as a fatal description error.
- Make failure non-destructive: a secondary that does not acknowledge must
  time out, identify itself, and return to the proxy or diagnostic shell rather
  than continuing into Linux with silent topology corruption.
- Confirm whether firmware has already initialized die-to-die transport and
  power domains. Do not add D2D register writes without evidence.

First hardware success criteria:

- m1n1 retains console or proxy control;
- exactly 32 unique CPU identities are enumerated;
- all 31 secondaries acknowledge startup on both dies;
- no duplicate MPIDRs, stuck release loops, SError, watchdog reset, or
  unexplained MMIO access occurs.

Abort immediately on an unknown SoC/board identity, a computed address outside
the confirmed PMGR windows, loss of console, repeated watchdog reset, or any
sign that firmware state differs from the captured ADT.

### 4. Initialize the six CPU clusters conservatively

- Add a T6032 cluster table in `src/cpufreq.c` after validating the six bases.
- Start from T6031 p-state limits and feature flags only where register-level
  evidence shows they are identical.
- Extend all relevant read, write, initialization, and feature-selection cases;
  do not add a table that only fixes one call path.
- Log the current p-state and programmed safe boot p-state per cluster.
- During the first run, prefer read-only inspection. Enable writes one cluster
  class at a time, then one die at a time, with thermal and timeout monitoring.
- Keep Linux DVFS testing separate from m1n1's early safe-state setup.

Exit gate: all six clusters initialize once, report plausible values, and boot
Linux without unexplained frequency, thermal, or stability asymmetry between
dies.

### 5. Audit compatibility-driven subsystems

For `src/mcc.c`, `src/pcie.c`, `src/chickens.c`, SPMI, and any early serial or
DebugUSB path:

1. capture the relevant ADT compatibles, register ranges, revisions, and CPU
   MIDRs;
2. compare them field-by-field with the existing T6031/T6034 path;
3. run read-only probes where possible;
4. add code only when the existing compatibility dispatch does not select a
   valid implementation.

Absence of a literal `T6032` case is not itself a bug when dispatch is based on
an ADT compatible or MIDR. Conversely, adding T6032 to a broad numeric range is
not proof that the hardware block exists. For example, ISP support is not a
bring-up requirement when the board DTS deliberately removes the block.

Exit gate: each reused subsystem has recorded evidence, and each new special
case is tied to a demonstrated mismatch.

### 6. Validate the device-tree handoff

- Capture both the firmware ADT view used by m1n1 and the final FDT received by
  Linux.
- Compare CPU count, `reg`/MPIDR values, enable method, cache hierarchy,
  interrupt topology, die affinity, reserved memory, MMIO ranges, and board
  compatibles.
- Specifically inspect die-1 CPU nodes for OPP references,
  `capacity-dmips-mhz`, and performance-domain bindings. The current source DTS
  warrants checking, but the runtime FDT is authoritative because the loader
  can amend it.
- Validate that the selected DTB is T6032/J575d and fail closed on a board
  mismatch. Require the genuine J575 board compatible together with
  `apple,t6032` and `apple,arm-platform`; never relabel a T6031 payload DT.
- Exercise m1n1's payload target-type rejection explicitly. Confirm that the
  kboot handoff neither prunes CPUs 24-31 nor emits a duplicate or missing
  `cpu-release-addr` for any surviving CPU node.
- Check U-Boot's generic Apple target before proposing board-specific U-Boot
  code; the intended difference should remain in m1n1 and DT data.

Exit gate: the kernel sees an internally consistent 32-CPU, two-die topology
and no DT validation warnings relevant to the enabled nodes.

### 7. Boot a diagnostic Linux payload from RAM

Use a tiny initramfs first, not the Debian root filesystem. It should:

- mount only `proc`, `sysfs`, and `debugfs` as needed;
- leave internal NVMe unbound or explicitly read-only;
- capture `dmesg`, `/proc/cpuinfo`, CPU present/possible/online masks,
  per-CPU topology, interrupts, clocks, OPPs, and thermal sensors;
- provide serial and m1n1-proxy recovery paths;
- boot with cpuidle and deep sleep disabled until the separate PSCI path is
  ready;
- shut down or return control without installing anything.

Test in this order:

1. boot with one boot CPU and console;
2. release a single secondary on die 0;
3. release all die-0 CPUs;
4. release one secondary on die 1;
5. release all 32 CPUs;
6. boot Linux with `maxcpus=1`, then 8, 16, 24, and 32;
7. online/offline non-boot CPUs where Linux permits;
8. run bounded CPU, memory, interrupt, and scheduler stress;
9. repeat cold boots and warm reboots while retaining full logs.

The QEMU/HVF Debian harness in this repository may verify the initramfs,
logging scripts, and user-space payload. It cannot validate these m1n1 changes:
QEMU exposes a generic virtual board, not Apple PMGR, MCC, AIC, or dual-die CPU
hardware.

Exit gate: Linux consistently reports 32 present and online CPUs, both dies
make scheduler progress, bounded stress completes, and repeated boots show no
new m1n1 or kernel errors.

### 8. Keep PSCI/cpuidle as a follow-on project

Basic secondary startup and a 32-CPU Linux boot use the current m1n1 mechanism.
Deep idle and upstream Linux cpuidle are a separate interface project. Current
Asahi direction is to expose PSCI through m1n1 using UEFI Runtime Services so
Linux can use the standard arm64 PSCI path.

Do not upstream a new Apple-only cpuidle driver as part of the T6032 enablement
series. Once basic bring-up is stable, test the shared PSCI implementation on
T6032 and contribute only T6032-specific fixes backed by traces.

### 9. Upstream in reviewable slices

Proposed patch sequence:

1. `m1n1: add T6032 SoC identity and early-console support`
2. `m1n1: support 32 CPUs and validate T6032 topology`
3. `m1n1: add T6032 secondary CPU startup`
4. `m1n1: initialize T6032 CPU clusters`
5. optional compatibility or DT-handoff fixes, one subsystem per patch and
   only when hardware evidence requires them

Each commit should state the evidence for reused T6031 behavior, name the
tested board, describe the test payload, and include no installer enablement.
Send a draft pull request early if maintainers want the changes squashed or
ordered differently. Keep diagnostic instrumentation until reviewers and the
hardware log agree; then remove noise or place it behind existing debug
controls.

Installer work begins only after the m1n1 series is accepted, the boot chain is
repeatable, Linux reaches a safe recovery shell, and a full restore path has
been exercised. `J575dAP` device metadata and T6032 firmware-version policy
must then be reviewed as their own project.

## Evidence bundle for every hardware run

Store these together under a run ID, with secrets and device identifiers
redacted before publication:

- source commits and dirty-tree patches;
- compiler version and full build configuration;
- SHA-256 hashes of m1n1, DTB, U-Boot, kernel, and initramfs;
- firmware/macOS version and hardware model/board/SoC IDs;
- captured ADT nodes used to justify register choices;
- complete m1n1 serial/proxy log from reset through handoff;
- complete kernel log and runtime FDT;
- CPU present/possible/online masks and per-CPU topology;
- test commands, exit status, duration, temperatures, and observed resets;
- a short result stating which gate passed or why the run was aborted.

Never publish serial numbers, ECIDs, recovery keys, personalization tickets, or
other device-bound secrets.

## Definition of done

The m1n1 milestone is complete when:

- upstream m1n1 recognizes T6032/J575d without an unsafe fallback;
- all 32 CPUs on both dies start deterministically;
- all six CPU clusters enter a confirmed safe boot state;
- compatibility-driven subsystems are either proven reusable or separately
  fixed;
- a correct runtime FDT reaches Linux;
- a RAM-only Linux payload repeatedly boots with 32 CPUs and survives bounded
  stress;
- the implementation and evidence are reviewed upstream; and
- recovery and rollback procedures are documented and exercised before any
  installer or internal-storage work.

## Immediate first sprint

- [ ] Ask maintainers about unpublished T6032 m1n1 work and test hardware.
- [ ] Obtain a redacted T6032 ADT dump through a safe existing environment.
- [ ] Confirm UART, CPU-start, PMGR die-offset, and six cluster bases.
- [ ] Audit every `MAX_CPUS` use and CPU-mask width.
- [ ] Prepare the first two hardware-free patches: SoC definition and 32-CPU
  capacity.
- [ ] Add synthetic 32-CPU topology tests and inspect the link map.
- [ ] Build the read-only initramfs and validate it under QEMU.
- [ ] Arrange a second recovery Mac or a maintainer-run first boot.
- [ ] Review the proposed SMP and cpufreq patches before any target execution.

## Audit of this plan (2026-08-29)

This section records a review of the plan above against the real sources. It
does not change the plan text. Corrections are listed in A for a follow-up
edit.

Sources checked:

- m1n1 at the pinned commit `a735ea29aed4843c301d8d9665949b30a84d25df`
  (equal to `main` on 2026-08-29);
- `t6032.dtsi` from mainline `master`, `AsahiLinux/linux` `asahi-wip-7.2`,
  and the Debian `linux-asahi 7.1.10-1-1` source;
- the live ADT of this Mac Studio, read with `ioreg -p IODeviceTree`
  (read-only; only the keys named below were printed; no device secrets);
- every link under "Primary references" (all resolve).

The `scratch/` checkouts in this repository are empty directories and
zero-byte JSON files. They were not used.

### A. Corrections to the plan text

| Where | Problem | Correct statement |
| --- | --- | --- |
| Baselines, Linux row | `396331cc6447` is the `AsahiLinux/linux` copy of the patch. It is not on `apple-soc/dt-7.3`. | Mainline `master` and `apple-soc/dt-7.3` carry `67d9574cf8ed` ("arm64: dts: apple: Initial T603[124] (M3 Max and Ultra) device trees", committed 2026-08-01). It is not in tag `v7.2`; it is in the 7.3 merge window. The Asahi `t6032.dtsi` differs from mainline: it adds `t6031-nvme.dtsi` on die 1 and deletes the ISP nodes. State which tree is the cross-check. |
| §6, "the loader can amend it" | m1n1 does not amend CPU nodes except `cpu-release-addr` and pruning. Only GPU OPPs are touched (`kboot_gpu.c:634`). | Whatever is missing from the source DTS reaches Linux unchanged. See E. |
| §5, ISP example | The board DTS does not remove the ISP. | Mainline `t6031-die0.dtsi:381` leaves `isp` with `status = "disabled"`. Only the Asahi `t6032.dtsi` (lines 357-360) deletes `isp` and its DARTs. The ADT of this machine has no `isp` node, so `isp_init` returns 0 early (`isp.c:67-68`). The `case T6031 ... T6034` range in `isp.c:97` includes 0x6032 but is not reached here. |
| Immediate first sprint, "Obtain a redacted T6032 ADT dump" | The ADT is available now on this machine. | macOS exposes the full ADT read-only through `ioreg -p IODeviceTree`. See B. |
| §2, "the larger secondary-stack allocation fits the m1n1 layout" | Secondary stacks are not static. | `smp.c:138` allocates each stack with `memalign` when the CPU starts. Eight more CPUs cost 8 × 64 KiB of heap. |

### B. ADT evidence read from macOS

All values below come from `ioreg -p IODeviceTree` on this machine. Nothing
was written to hardware.

| ADT item | Value | Consequence |
| --- | --- | --- |
| `/target-type` | `J575d` | `payload.c:293-301` derives `apple,j575d`, which is the root compatible of `t6032-j575d.dts`. DTB selection works without change. |
| `/chosen/chip-id` | `0x6032` | `smp_start_secondaries` hits `default` and returns (`smp.c:303-305`): no secondary CPU starts today. `cpufreq_get_clusters` returns NULL (`cpufreq.c:415-417`). |
| `/chosen/board-id` | `0x44` | — |
| `/cpus` | 32 nodes, `cpu0`..`cpu31` | Matches the 32-node mainline DTS. |
| `cpu16` `reg` | `0x800` | Bit 11 set = die 1. `cpu31` `reg` = `0xa05` decodes to die 1, cluster 2, core 5 and matches its own `die-id = 1`, `cluster-id = 10`. The decoder in `smp.c:23-25` is correct for T6032. |
| `cpu-impl-reg` | die 0: `0x210050000`; die 1: `0x2210050000` | Die 1 = die 0 + `0x2000000000` = `PMGR_DIE_OFFSET` (`pmgr.h:8`). |
| `cpu4` `state` | `running` | macOS boots on cpu4. m1n1 finds the boot CPU by this field. |
| `/arm-io` compatible, `ranges` | `arm-io,t6031`; child `0x0` maps to `0x200000000` | — |
| `/arm-io/uart0` `reg` | `0x191200000`, absolute `0x391200000` | Equals `EARLY_UART_BASE` for T6031/T6034 (`soc.h:54-55`) and `serial0@391200000` in `t6031-die0.dtsi:532`. |
| `/arm-io/pmgr` compatible | `pmgr1,t6031` | — |
| `/arm-io/mcc` compatible | `mcc,t6031` | Dispatch selects `mcc_init_m3` → `mcc_init_t6031`. See C. |
| `/arm-io/apcie0`, `apcie1` compatible | `apcie,t6031` | `pcie.c:303` selects the T6031 path. |
| `/arm-io/isp` | absent | See A. |
| die-1 node names | `die1-nub-spmi0`..`die1-nub-spmi4` | Die-1 SPMI nodes carry a `die1-` prefix. There is no `die1-pmgr` or `die1-mcc`; MCC lists both dies in one `reg`. |

### C. New finding: `mcc_init_m3` miscounts the T6032 MCC instances

`/arm-io/mcc` `reg` has 20 entries of 16 bytes:

| Index | Base | Size | Meaning |
| --- | --- | --- | --- |
| 0 | `0x903c0000` | `0x20000` | header |
| 1 | `0x904d0000` | `0x149c` | header |
| 2 | `0x92818000` | `0x4000` | header, die 0 |
| 3 | `0x2092818000` | `0x4000` | header, die 1 |
| 4–11 | `0x20000000` .. `0x2e000000` | `0x2000000` | 8 MCC instances, die 0 |
| 12–19 | `0x2020000000` .. `0x202e000000` | `0x2000000` | 8 MCC instances, die 1 |

`mcc_init_m3` sets `reg_offset = 3` and computes
`mcc_count = reg_len / 16 - reg_offset` (`mcc.c:406-421`). On this ADT that
is 17, clamped to `MAX_MCC_INSTANCES = 16`. The result:

- entry 3, a 16 KiB block, is treated as an MCC instance; its plane, global,
  and DCS offsets (`+0x100000`, `+0x400000`) fall outside the block;
- entry 19, a real die-1 instance, is dropped.

`mcc_enable_cache()` runs at kernel handoff (`kboot.c:2909`) and writes
`PLANE_CACHE_ENABLE` to every instance (`mcc.c:183`). This is an unknown MMIO
write and violates the safety invariants. The hypothesis in the row "Memory
controller" is false. The fix belongs in the patch series (§9) before any
hardware run.

The assumption that a T6031 ADT has 3 header entries was not checked against a
T6031 ADT; it is inferred from `reg_offset = 3` working on M3 Max.
{{NEEDS_PROOF}}

### D. New finding: `kboot` cannot hand off the mainline DTS today

`dt_set_cpus` counts `cpu@` nodes in FDT order and bails when
`cpu > MAX_CPUS` (`kboot.c:561-562`). The mainline `t6032.dtsi` has 32 nodes,
so the loop bails at the 26th. A "24 CPUs first" boot is not possible. Raising
`MAX_CPUS` is a prerequisite for any boot, not only for the 32-CPU milestone.
The comparison is `>` where `>=` is meant; it is harmless today because
`smp_is_alive` is bounds-checked (`smp.c:502-504`).

### E. New finding: die-1 CPU nodes in the merged DTS are incomplete

`t6032.dtsi:90-265` (die-1 CPUs `cpu_e10`..`cpu_p35`) have no
`operating-points-v2`, no `capacity-dmips-mhz`, and no `performance-domains`.
Die-0 CPUs have all three (`t6031-base.dtsi:86-88`). T6022's die-1 CPUs have
all three (`t6022.dtsi:91-93`). The `cpufreq_e_die1`, `cpufreq_p0_die1`, and
`cpufreq_p1_die1` nodes exist in the FDT (from `t6031-dieX.dtsi` under
`&die1`) but nothing references them. This part of the file is identical in
mainline, `asahi-wip-7.2`, and Debian 7.1.10.

Consequences in Linux:

- `arch_topology.c:311,356`: capacity data is discarded for all CPUs when one
  CPU lacks it. All 32 CPUs get capacity 1024, so the scheduler sees E-cores
  and P-cores as equal.
- `apple-soc-cpufreq.c:216` reads `performance-domains` in policy init. The
  die-1 clusters get no cpufreq policy and stay at the p-state m1n1 leaves.

The merged series was written without T6032 hardware; its commit message
infers the design "judging by the advertised memory bandwidth". A DTS
follow-up that copies the T6022 pattern is a candidate hardware-free
contribution. Whether maintainers accept it untested is unknown.
{{UNVALIDATED}}

### F. Hypothesis status

Update of the table "What is known and what must be measured":

| Row | Status |
| --- | --- |
| SoC ID / early UART | Confirmed by ADT `uart0` `reg`. |
| CPU capacity | Confirmed necessary; see D. Stack allocation is heap; see A. |
| CPU start | Die offset confirmed by `cpu-impl-reg`. The `0x88000` start offset is not in the ADT. {{NEEDS_PROOF}} |
| CPU clusters | Bases are not in the ADT; m1n1 hardcodes them. The DTS corroborates them: `cpufreq@210e20000`, `@211e20000`, `@212e20000` = base + `0x20000` (`t6031-dieX.dtsi:9-22`), and die 1 `ranges` map `0x2_00000000` to `0x22_00000000` (`t6032.dtsi:303-313`). {{NEEDS_PROOF}} |
| Memory controller | False. See C. |
| PCIe | Confirmed by ADT compatible `apcie,t6031`. |
| CPU workarounds | MIDR is not in the ADT. The ADT CPU compatibles are `apple,sawtooth` and `apple,everest`. Precedent: T6002 and T6022 have no entries of their own in `chickens.c:136-147` and run on the T6001/T6021 MIDRs. {{NEEDS_PROOF}} |
| Device tree | Both dies and all 32 CPUs are present. Die-1 CPU nodes are incomplete; see E. |

### G. Plan claims verified as written

| Claim | Evidence |
| --- | --- |
| m1n1 and installer pins | Both equal the current `main` heads on 2026-08-29. |
| `soc.h` lacks T6032 | `soc.h:31-37` (also defines T6040, T6041, T6050, T6051). |
| `MAX_CPUS` 24, `MAX_EL3_CPUS` 4, IDs ≥ bound dropped | `smp.h:9-10`, `smp.c:316-318`. |
| T6031/T6034 start case, `0x88000`, per-die offset | `smp.c:21`, `smp.c:295-301`, `smp.c:157`. |
| T6031 three clusters, Ultra tables six | `cpufreq.c:352-373`. |
| `MAX_EL3_CPUS` is a separate EL3-only constraint | `smp.c:121` applies it only when `has_el3()`. M3 has no EL3. |
| `reg` bit layout core 0-7, cluster 8-10, die 11-14 | `smp.c:23-25`; the ADT values decode correctly. |
| `uart.c` runtime selection | `uart.c:22-34` tries `/arm-io/uart6/debug-console`, then `/arm-io/uart0`, and reads `reg`. |
| Payload target-type check | `payload.c:293-301` builds `apple,` + lowercase `target-type`; `payload.c:352` errors when no DTB matches. |
| PSCI via UEFI Runtime Services | Stated in the Asahi 7.2 progress report. |
| SPMI and DebugUSB paths exist | `spmi.c`, `dockchannel_uart.c`, `usb.c`. |
| Per-SoC debug image | `config.h:22` (`//#define TARGET T8103`) selects `EARLY_UART_BASE` in `soc.h:39-80`. T6032 needs a line in the `T6034 || T6031` branch. |

### H. Housekeeping

- `scratch/`, `scratch-upstream.json`, `m1n1-tree.json`, and
  `t6032-history.json` are empty placeholders. They are untracked and not in
  `.gitignore`.
- kisd runs on a device that itself runs Asahi Linux (kisd README). It is one
  more hardware dependency for the proxy path.
- `lore.kernel.org` sits behind a JavaScript challenge for plain HTTP clients;
  patchew serves the same series.

### I. Not verified

- The MIDR part numbers of this chip.
- The T6031 ADT MCC header count (see C).
- The `0x88000` CPU start offset and the six cluster bases on T6032.

## Primary references

- [m1n1 source](https://github.com/AsahiLinux/m1n1/tree/a735ea29aed4843c301d8d9665949b30a84d25df)
- [Initial T603x Linux device-tree series](https://patchew.org/linux/20260724-apple-t603x-initial-devices-v3-0-bbeba0420603@jannau.net/)
- [Asahi M3 feature-support matrix](https://asahilinux.org/docs/platform/feature-support/m3/)
- [Asahi Linux 7.1 progress report](https://asahilinux.org/2026/06/progress-report-7-1/)
- [Asahi Linux 7.2 progress report](https://asahilinux.org/2026/08/progress-report-7-2/)
- [kisd debug-interface notes](https://github.com/AsahiLinux/kisd/blob/main/README.md)
- [Apple firmware revive/restore procedure](https://support.apple.com/en-us/108900)

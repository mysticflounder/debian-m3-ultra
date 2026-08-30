# m1n1 T6032 / J575d Bring-up Plan

Status: planning baseline, 2026-08-29

Primary target: Mac Studio (M3 Ultra), Apple model `Mac15,14`, board
`J575dAP`, SoC `T6032`, 32 CPUs (8 efficiency and 24 performance cores),
two dies.

Secondary target: M5 Max. Its exact model, board target, SoC ID, CPU topology,
ADT layout, and recovery/test hardware are not yet recorded. Nothing in this
plan assumes that a T6032 register address or compatibility is valid on M5 Max.

## Objective

Add the minimum upstream-quality T6032 support needed for m1n1 to start and
release all CPUs, perform required early SoC initialization, preserve the
firmware-derived hardware description, and hand a bootable payload to U-Boot
and Linux.

The first milestone is a diagnostic, RAM-only Linux boot with all 32 CPUs. It
is not a Debian installer and does not include speculative kernel drivers.
m1n1 provides the boot and hardware-enablement layer; Linux drivers remain a
separate workstream.

## Target strategy

Build reusable mechanisms where the firmware evidence supports them, then keep
small target-specific data and quirks:

- shared work: CPU-count bounds, topology validation, ADT parsing helpers,
  payload identity checks, safe timeouts, evidence capture, and test tooling;
- T6032/J575d work: CPU-start selection, six-cluster initialization, the MCC
  register-list correction, and T6032 device-tree completion;
- M5 Max work: first capture its real ADT and identifiers, then add only the
  target data or code proven necessary by that evidence.

Passing a test on either target does not validate the other. Every hardware log
and upstream commit must name the exact model, board target, and SoC ID.

## Baselines

Record and pin all inputs before implementation, then refresh them before
submitting anything upstream:

| Component | Planning baseline | Purpose |
| --- | --- | --- |
| m1n1 | `a735ea29aed4843c301d8d9665949b30a84d25df` | Source to modify |
| Mainline Linux Apple SoC device tree | `67d9574cf8ed1c81c472b932a9d9819f47fb5286` | Initial T603x topology in the Linux 7.3 merge window; no M3 cpufreq integration |
| Asahi downstream Linux | `bdb78c2fe5e6e47332c7e0a3df470a0cc352995d` (`asahi-wip-7.2`) | Downstream M3 cpufreq and OPP reference; T6032 die 1 is incomplete |
| Asahi installer | `f0469cea0899f3efed8efead604174c7a53c4451` | Installation dependency only; not an initial target |

The mainline initial series describes T6032's 32 CPUs, two dies, AIC,
power-state controllers, UART, pinctrl, I2C, watchdog, and boot framebuffer.
It does not contain the downstream M3 CPU OPP/cpufreq integration. Mainline,
Asahi downstream, and Debian source observations must therefore be labeled by
tree and revision instead of being combined into one "merged DTS" claim.

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

On T6032, no native Linux handoff through `kboot_boot()` is allowed until the
MCC register-list bug described below is fixed or cache enablement is safely
disabled. A RAM-only root filesystem prevents storage writes; it does not make
incorrect MMIO writes safe.

## What is known and what must be measured

| Area | Established from current sources | Hypothesis requiring ADT or hardware evidence |
| --- | --- | --- |
| SoC identity and UART | `src/soc.h` lacks T6032. The live ADT reports target `J575d`, chip `0x6032`, and `uart0` absolute address `0x391200000`, matching the T6031/T6034 early-UART base | The compile-time target definition and runtime ADT path both work after adding T6032 |
| CPU capacity | `src/smp.h` caps m1n1 at 24 CPUs; `src/smp.c` drops larger IDs; `kboot.c` cannot process a 32-node FDT. Secondary stacks are heap allocations | Raising the bound has no hidden mask or heap limit; the separate four-CPU EL3 limit remains unchanged |
| CPU start | The live ADT confirms 32 dense CPU IDs, the current `reg` decoder, and the `0x2000000000` per-die PMGR offset | T6032 uses the T6031 `0x88000` CPU-start offset; this value is not exposed by the ADT |
| CPU clusters | `src/cpufreq.c` lacks T6032. Downstream DTS addresses corroborate six die-relative blocks | T6032 uses T6031 p-state semantics and the six candidate bases below |
| Memory controller | The live ADT advertises `mcc,t6031` but contains four header/register blocks followed by 16 MCC instances. Current `mcc_init_m3()` starts at entry 3, selects the wrong block, and drops the last real instance | Whether the preferred fix is a T6032 offset of 4 or structural register-list parsing; a T6031 ADT is needed to preserve that path |
| PCIe | The live ADT advertises `apcie,t6031`, so m1n1 selects `regs_t6031` | T6032 has the same register contract, hard-coded offsets, tunables, and PHY behavior; dispatch alone does not prove this |
| CPU workarounds | ADT CPUs report `apple,sawtooth` and `apple,everest`; m1n1 selects workarounds from runtime CPU identity | T6032 MIDRs and feature behavior match the existing T6031 path |
| Device tree | Mainline has all 32 CPUs but no M3 cpufreq integration. Asahi/Debian downstream add die-0 OPP/capacity/performance domains but omit them on die 1 | Verified T6032 OPP values and a schema-valid downstream die-1 completion; upstream mainline needs the broader M3 DVFS series, not a die-1-only patch |
| M5 Max | Selected as the secondary project target | All hardware identity, topology, register, compatibility, recovery, and enablement claims await its own evidence capture |

Candidate CPU frequency register blocks, to be corroborated from source and
validated safely on hardware before any write, are:

| Cluster | Candidate base |
| --- | --- |
| die 0 ECPU | `0x0210e00000` |
| die 0 PCPU 0 | `0x0211e00000` |
| die 0 PCPU 1 | `0x0212e00000` |
| die 1 ECPU | `0x2210e00000` |
| die 1 PCPU 0 | `0x2211e00000` |
| die 1 PCPU 1 | `0x2212e00000` |

These addresses are a review aid derived from the existing T6031 and other
dual-die tables. The T6032 ADT does not expose them directly. They are not
permission to touch those registers until maintainers confirm the derivation
and read-only hardware evidence validates it.

## Deliverables

1. A small, reviewable m1n1 patch series adding T6032 support without unrelated
   refactoring.
2. Shared, synthetic ADT/FDT fixtures that exercise 32 CPUs, multiple dies,
   register-list parsing, target identity, and boundary failures without
   hardware.
3. A sanitized, reproducible ADT inventory tool and evidence snapshot for each
   target. Raw dumps containing device identifiers are not deliverables.
4. A reproducible build manifest recording compiler, m1n1 revision, config,
   payload hashes, Linux revision, DTB, and initramfs.
5. A purpose-built, read-only diagnostic initramfs and serial/proxy capture
   procedure. This supplements rather than replaces Claude's completed,
   bootable QEMU/HVF Debian image.
6. A mandatory T6032 MCC correction and a separately scoped Linux DTS/binding
   contribution for downstream die-1 CPU performance data.
7. Hardware validation reports covering the exact target identity, every CPU
   and die, repeated boots, and clean handoff to Linux.
8. Upstream pull requests, revised from maintainer feedback.

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
- Share the sanitized live T6032 ADT evidence and ask for confirmation of the
  CPU start offset, CPU-frequency register map, and MCC fix design. Request a
  T6031 ADT register list so the existing path is not broken.
- Decide who can execute the first hardware test. Prefer a maintainer with a
  disposable/recoverable T6032 environment until this machine has a recovery
  host.
- Collect the M5 Max inventory with the
  [read-only local-agent prompt](m5-max-inventory-agent-prompt.md). Keep its
  source baselines, hypotheses, patches, and hardware logs distinct from T6032
  until shared behavior is proven.

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
- Record dependency repository snapshots, package versions, container/toolchain
  image digests, and exact commands. The existing floating `apt`-based QEMU
  harness is useful for exploration but does not satisfy this reproducibility
  gate.
- Add a CI/static check that enumerates every `MAX_CPUS` consumer and every
  T603x `switch` so a new SoC cannot be partly supported unnoticed.

Exit gate: both configurations build reproducibly from a clean checkout and
the artifact manifest is sufficient for another developer to reproduce them.

### 2. Add the minimal target definition and 32-CPU capacity

Expected source areas:

- `src/soc.h`: define `T6032` and use the ADT-confirmed T6031/T6034 early-UART
  base.
- `src/uart.c`: verify that runtime selection finds the real T6032 ADT
  `uart6/debug-console` or `uart0` node and uses its `reg`, independent of the
  compile-time debug base.
- `src/smp.h`: raise `MAX_CPUS` from 24 to at least 32.
- `src/kboot.c`: change the CPU-node limit check from `>` to `>=` and prove a
  32-node FDT completes without pruning or aborting merely because of the old
  bound.
- every use of `MAX_CPUS`: audit arrays, loops, CPU-ID validation, stack
  allocation, spin tables, printf formats, and masks.

Do not assume that increasing the array bound is sufficient. Prove that no
CPU-set representation uses a 32-bit value in a way that loses CPU 31, that
logical IDs are dense or correctly mapped, and that the larger secondary-stack
heap demand is available. Secondary stacks are allocated with `memalign`; eight
additional CPUs require 512 KiB, not a larger static image section.
`MAX_EL3_CPUS`, currently four, is a separate constraint for the EL3 path;
document why normal EL2 bring-up does or does not touch it instead of raising it
mechanically.

Hardware-free tests:

- compile-time assertions for array lengths and CPU-mask widths;
- a fixture or host-side test containing all 32 T6032 CPU nodes;
- boundary tests for CPU IDs 0, 23, 24, and 31;
- tests that reject a 33rd node before indexing any fixed-size storage;
- a kboot test proving all 31 non-boot CPU nodes receive valid, unique release
  addresses while the boot CPU is preserved without requiring one; and
- heap-budget and allocation-failure tests for secondary stacks.

Exit gate: the image and kboot FDT path represent all 32 CPUs without
truncation, overflow, accidental pruning, or heap failure.

### 3. Bring up secondary CPUs on both dies

- Add T6032 to the CPU-start path in `src/smp.c` only after confirming the
  `0x88000` start-register offset from maintainer source or hardware evidence;
  the ADT confirms the per-die offset but not this register offset.
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

An SMP-only diagnostic may return to the m1n1 shell, but no Phase 3 test image
may expose a path to native kboot until the mandatory Phase 4 MCC gate passes.

First hardware success criteria:

- m1n1 retains console or proxy control;
- exactly 32 unique CPU identities are enumerated;
- all 31 secondaries acknowledge startup on both dies;
- no duplicate MPIDRs, stuck release loops, SError, watchdog reset, or
  unexplained MMIO access occurs.

Abort immediately on an unknown SoC/board identity, a computed address outside
the confirmed PMGR windows, loss of console, repeated watchdog reset, or any
sign that firmware state differs from the captured ADT.

### 4. Correct T6032 MCC enumeration before kernel handoff

The live T6032 ADT `/arm-io/mcc` node has 20 register entries: four
non-instance blocks at indices 0-3, eight 32 MiB MCC instances for die 0 at
4-11, and eight for die 1 at 12-19. It reports `mcc,t6031`, four planes per
MCC, and four DCS channels per MCC.

Current `mcc_init_m3()` uses `reg_offset = 3`, computes 17 instances, clamps
the result to 16, treats the 16 KiB entry 3 as an MCC, and omits the real entry
19. `mcc_enable_cache()` later writes the cache-enable register for every
selected plane during `kboot_boot()`.

For the misclassified entry, the first plane-0 write at `base + 0x1c00` is
inside its 16 KiB range but targets an unproven register. Plane 1-3 addresses
using the `0x40000` stride, and the `0x100000` global and `0x400000` DCS
offsets, are outside that range. This is a mandatory safety fix, not an optional
compatibility cleanup.

Implementation requirements:

- preserve a T6031 fixture or ADT capture before changing its working offset;
- choose with maintainers between an explicit T6032 offset of 4 and structural
  parsing that selects only register windows large enough for the declared
  plane/global/DCS layout;
- require exactly the expected number of instances and reject, rather than
  clamp, an unexpected layout;
- retain each ADT register size and bounds-check every derived MMIO range;
- add a host-side 20-entry T6032 fixture proving entries 4-19 are selected in
  order and no MMIO operation is performed by the parser; and
- make MCC initialization or kboot fail closed when validation fails.

Exit gate: the synthetic fixture selects all 16 real instances, T6031 behavior
is preserved, and no T6032 native kernel handoff can reach cache enablement
with an unvalidated register list.

### 5. Initialize the six CPU clusters conservatively

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

### 6. Audit compatibility-driven subsystems

For `src/pcie.c`, `src/chickens.c`, SPMI, and any early serial or DebugUSB
path not already covered by the mandatory MCC work:

1. capture the relevant ADT compatibles, register ranges, revisions, and CPU
   MIDRs;
2. compare them field-by-field with the existing T6031/T6034 path;
3. run read-only probes where possible;
4. add code only when the existing compatibility dispatch does not select a
   valid implementation.

Absence of a literal `T6032` case is not itself a bug when dispatch is based on
an ADT compatible or MIDR. Conversely, selecting the T6031 PCIe implementation
from `apcie,t6031` confirms dispatch only; register geometry, hard-coded
offsets, tunables, and PHY behavior remain unverified until checked
field-by-field. The live T6032 ADT has no ISP node, so do not add an ISP case or
infer its presence from a numeric SoC range.

Repeat this audit independently for M5 Max. A shared compatible is evidence to
investigate reuse, not permission to inherit a T6032 conclusion.

Exit gate: each reused subsystem has recorded evidence, and each new special
case is tied to a demonstrated mismatch.

### 7. Complete and validate the device-tree handoff

m1n1 updates `cpu-release-addr` and prunes dead CPUs and their topology/AIC
references. It does not synthesize missing CPU OPP, capacity, or performance
domain properties. Keep the two Linux baselines separate:

- mainline commit `67d9574cf8ed` has the initial T603x topology but no M3 CPU
  OPP/cpufreq integration on either die;
- Asahi downstream and Debian `linux-asahi 7.1.10-1-1` add the M3 performance
  data and cluster controllers for die 0, while T6032's die-1 CPU nodes omit
  `operating-points-v2`, `capacity-dmips-mhz`, and `performance-domains`.

In the downstream tree, partial capacity data makes arm64 topology fall back to
capacity 1024 for every CPU. Missing `performance-domains` prevents Linux from
managing the die-1 clusters through `apple-soc-cpufreq`; measure their runtime
p-state instead of assuming it remains exactly at the m1n1 handoff value.

Required work:

- capture the ADT view used by m1n1 and the final FDT received by Linux;
- compare CPU count, `reg`/MPIDR, enable method, cache hierarchy, interrupt
  topology, die affinity, reserved memory, MMIO ranges, and compatibles;
- prepare a downstream patch adding the die-1 CPU performance references only
  after validating T6032 OPP values and phandle mapping;
- update or reconcile the Apple cluster-cpufreq binding, which does not
  currently admit the downstream `apple,t6031-cluster-cpufreq` compatible;
- compile all affected DTBs and run the relevant `dtbs_check` schemas;
- coordinate mainline work with the broader M3 DVFS series rather than sending
  a die-1-only patch that references nodes absent from mainline;
- require the genuine J575 board compatible with `apple,t6032` and
  `apple,arm-platform`; never relabel a T6031 payload DT;
- exercise m1n1's payload target-type rejection and prove kboot neither prunes
  CPUs 24-31 nor emits duplicate or missing secondary release addresses; and
- check U-Boot's generic Apple target before proposing board-specific U-Boot
  code.

Exit gate: the selected tree builds without relevant schema warnings, and the
runtime FDT gives Linux a consistent 32-CPU/two-die topology with validated
capacity and performance-domain relationships.

### 8. Boot a diagnostic Linux payload from RAM

Claude's existing image already boots Debian successfully under QEMU/HVF. Keep
that completed emulation milestone as the build, packaging, init-system, and
user-space regression harness. It cannot validate m1n1 or Apple hardware.

For the first native handoff, build a separate tiny initramfs instead of using
the emulated system's writable ext4 root. It should:

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

The QEMU/HVF harness should boot this additional initramfs and verify its
logging and shutdown paths before target use. QEMU still exposes a generic
virtual board, not Apple PMGR, MCC, AIC, or dual-die CPU hardware.

Exit gate: Linux consistently reports 32 present and online CPUs, both dies
make scheduler progress, bounded stress completes, and repeated boots show no
new m1n1 or kernel errors.

### 9. Keep PSCI/cpuidle as a follow-on project

Basic secondary startup and a 32-CPU Linux boot use the current m1n1 mechanism.
Deep idle and upstream Linux cpuidle are a separate interface project. Current
Asahi direction is to expose PSCI through m1n1 using UEFI Runtime Services so
Linux can use the standard arm64 PSCI path.

Do not upstream a new Apple-only cpuidle driver as part of the T6032 enablement
series. Once basic bring-up is stable, test the shared PSCI implementation on
T6032 and contribute only T6032-specific fixes backed by traces.

### 10. Upstream in reviewable slices

Proposed patch sequence:

1. `m1n1: add T6032 SoC identity and early-console support`
2. `m1n1: support 32 CPUs and fix the kboot CPU-node bound`
3. `m1n1: correct T6032 MCC register enumeration`
4. `m1n1: add T6032 secondary CPU startup`
5. `m1n1: initialize T6032 CPU clusters`
6. optional compatibility fixes, one subsystem per patch and
   only when hardware evidence requires them

Each commit should state the evidence for reused T6031 behavior, name the
tested board, describe the test payload, and include no installer enablement.
Send a draft pull request early if maintainers want the changes squashed or
ordered differently. Keep diagnostic instrumentation until reviewers and the
hardware log agree; then remove noise or place it behind existing debug
controls.

Keep Linux work in a separate series and name the target tree explicitly. A
planned Asahi/Debian downstream patch must complete T6032 die-1 performance
relationships and the corresponding binding validation. Mainline M3 DVFS
enablement is a broader series and must not be presented as the same patch.

M5 Max starts with an inventory and gap analysis, not a copy of this patch
list. Once its identifiers and layouts are known, split its work into shared
infrastructure commits and independently reviewable target support.

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
- the sanitized collection command/tool version, raw byte widths, decoded
  values, redaction check, and a hash of every published evidence artifact;
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
- kboot processes all 32 CPU nodes with a correct upper-bound check;
- MCC enumeration selects the 16 real instance windows, rejects unexpected
  layouts, and cannot enable cache through an unvalidated address;
- all 32 CPUs on both dies start deterministically;
- all six CPU clusters enter a confirmed safe boot state;
- compatibility-driven subsystems are either proven reusable or separately
  fixed;
- a topology-consistent runtime FDT reaches Linux without m1n1 pruning or
  corrupting CPU nodes;
- a RAM-only Linux payload repeatedly boots with 32 CPUs and survives bounded
  stress;
- the implementation and evidence are reviewed upstream; and
- recovery and rollback procedures are documented and exercised before any
  installer or internal-storage work.

The M5 Max milestone is separate. Its first completion gate is a sanitized,
reviewed hardware inventory and source-gap report; T6032 completion neither
depends on nor implies M5 Max support.

The separate T6032 Linux CPU-performance milestone is complete when the
downstream DTS and binding pass compilation/schema checks, the runtime FDT has
validated die-1 OPP/capacity/performance-domain relationships, and Linux
demonstrates correct scheduler capacity and cpufreq control on both dies.

## Immediate first sprint

- [ ] Ask maintainers about unpublished T6032 m1n1 work and test hardware.
- [ ] Add a reproducible, whitelisted T6032 ADT collector and commit its
  sanitized evidence; the live ADT is already readable from macOS.
- [ ] Run the M5 Max read-only inventory prompt and review its sanitized output.
- [ ] Confirm the CPU-start offset and six cluster bases; UART and the PMGR die
  offset are already corroborated by the T6032 ADT.
- [ ] Audit every `MAX_CPUS` use and CPU-mask width.
- [ ] Prepare the SoC identity, 32-CPU/kboot-bound, and mandatory MCC patches.
- [ ] Add synthetic 32-CPU topology and 20-entry MCC fixtures.
- [ ] Preserve Claude's bootable QEMU/HVF Debian image as the emulation
  baseline, then build and boot the separate read-only diagnostic initramfs
  under the same emulator.
- [ ] Draft the tree-scoped downstream die-1 DTS/binding patch and run DT
  compilation plus `dtbs_check` without claiming unvalidated OPP values.
- [ ] Arrange a second recovery Mac or a maintainer-run first boot.
- [ ] Review the proposed SMP and cpufreq patches before any target execution.

## Primary references

- [m1n1 source](https://github.com/AsahiLinux/m1n1/tree/a735ea29aed4843c301d8d9665949b30a84d25df)
- [Mainline initial T603x DTS commit](https://github.com/torvalds/linux/commit/67d9574cf8ed1c81c472b932a9d9819f47fb5286)
- [Pinned Asahi downstream comparison tree](https://github.com/AsahiLinux/linux/tree/bdb78c2fe5e6e47332c7e0a3df470a0cc352995d)
- [Apple cluster-cpufreq binding in the comparison tree](https://github.com/AsahiLinux/linux/blob/bdb78c2fe5e6e47332c7e0a3df470a0cc352995d/Documentation/devicetree/bindings/cpufreq/apple%2Ccluster-cpufreq.yaml)
- [Initial T603x Linux device-tree series](https://patchew.org/linux/20260724-apple-t603x-initial-devices-v3-0-bbeba0420603@jannau.net/)
- [Asahi M3 feature-support matrix](https://asahilinux.org/docs/platform/feature-support/m3/)
- [Asahi Linux 7.1 progress report](https://asahilinux.org/2026/06/progress-report-7-1/)
- [Asahi Linux 7.2 progress report](https://asahilinux.org/2026/08/progress-report-7-2/)
- [kisd debug-interface notes](https://github.com/AsahiLinux/kisd/blob/main/README.md)
- [Apple firmware revive/restore procedure](https://support.apple.com/en-us/108900)

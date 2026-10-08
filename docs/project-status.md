# Project status — 2026-10-08 UTC

Updated at task completion. Source/offline validation is not native-hardware
validation. External PR, VM and MacBook states below are last recorded states,
not a fresh remote or live-machine check.

Scope: this is functional Debian/M3 Ultra SoC bring-up, not security work.
Report and record security findings, distinguishing verified issues from
suspicions, and advise Adam whether an issue should be opened. Security fixes
and additional hardening are outside this project's implementation scope and
are not boot-completion gates. Do not file issues or disclosures without approval.

Current handoff: the SMP shared-memory fix (`d484a58`) and SMP index guards
(`f51c869`) were pushed before this follow-up. Patch 0018 adds MMU/HV direct
and proxy index validation, preserving canonical exit/unpin sentinels; it is
committed locally as `14605bf`, not pushed. The twenty-one-patch cross-build
and linked-layout checks pass; prior sanitizer and mutation results remain
recorded for the unchanged guards. The subsequent
[CPU callback trace](m1n1-t6032-startup.md#captured-runtime-callback-path--2026-09-30)
identifies `function-enable_core`, its stored receiver and base-class forwarding
path; 2,273 instruction words match the captured collection. A subsequent
allowlisted capture resolves all 32 callback records to PMGR's parent identifier,
the `Core` selector and `1<<cpu-id` masks. The specialized callback's static
factory/initializer/vtable chain now reaches `enableCPUCores`; a separate
1,478-word/twelve-fixup check passes. This is not a live callback trace or native
boot validation. PMGR offset and conditional mask evidence are no longer
classified as wholly unknown.
The [group-8 guard producer](m1n1-t6032-mask-contract.md#register-descriptor-guard--2026-09-30)
is also traced: it marks a software register descriptor available, not hardware
ready. Its private PMGR field need not be reproduced in m1n1; mapped-register
availability and native release/reset sequencing still need qualification.
The same mode-1 CPU-mask offsets fail the shared writer's `isPsReg` predicate,
so its conditional readback wait is not a CPU-start acknowledgement for this
path. That question is closed statically; native entry/reset is not.
The [DVFS producer follow-up](m1n1-t6032-dvfs-contract.md#die-count-producer-and-provider-ancestry--2026-09-30)
locates the multiplier writer in `ApplePMGR::start`: default 1, overridden by
an ancestor's `die-count` property. A same-snapshot allowlisted capture reports
`die-count=2` and 13 performance-domain descriptors. Another 1,083 instruction
words and two base-class fixups match the pinned collection. Initialization-time
execution remains unobserved; the conditional allocation scan reaches beyond
the captured property, so its backing contract and exact capacity are not
claimed. Reproducing this private macOS allocator is not an m1n1 prerequisite;
safe raw APSC/default indices, feature ordering and failure handling remain open.
The [runtime state-producer trace](m1n1-t6032-dvfs-states.md#runtime-request-producer--2026-09-30)
finds caller-controlled state and an equal-state pending loop, not a safe
boot-state constant. A separate driver-body host harness now characterizes
the current frequency-init rejection, sequencing and failure behavior.
Entry-address, release-order and initialization prerequisites remain unresolved;
native testing is not authorized.

The [AIC metadata follow-up](m3-ultra-soc-status-2026-09-26.md#aic-metadata-follow-up--2026-09-30)
adds patch 0019: exact-length scalar reads, capability-offset rejection before
MMIO, and complete external-interrupt table preflight before writes. AIC1/2
defaults remain covered by the source-extracted host harness. The nineteen-patch
cross-build and shared-layout audit pass. An allowlisted live capture confirms
that macOS supplies both capability offsets and `aic-iack-offset`; the missing
offset defect is not an observed failure on this Studio. No physical register
was accessed. Patch 0020 now fixes the shared ADT copy helper's
copy-before-length-check defect. Its real-Rust ABI harness passes, with
deterministic original-source and guard-removal negative controls. The
[full20 follow-up](m3-ultra-soc-status-2026-09-26.md#shared-adt-copy-contract--2026-09-30)
also verifies static reset-entry placement, without qualifying reset-time
hardware behavior. The safe early-DVFS contract remains open; actual
CPU cold-entry observations need recovery readiness and native approval.
ADT parser bounds were a separate follow-up, completed for the handoff-declared
extent below. AIC aperture/stride arithmetic and whole-boot failure propagation
remain open hardening items.

The [early-DVFS follow-up](m1n1-t6032-dvfs-states.md#initial-backing-record-and-early-firmware-metadata--2026-09-30)
identifies the runtime record's initial zero fill and separately checks six
iBoot frequency-property exports. Neither establishes a safe raw APSC/default
index or the first state consumed on a cold boot. The
[inherited-state boundary](m1n1-t6032-cpufreq-status.md#inherited-state-boundary--2026-09-30)
also distinguishes m1n1's software rejection from a hardware requirement for
frequency writes. No bypass or native dispatch was added.

The [frequency-record follow-up](m1n1-t6032-dvfs-states.md#typed-frequency-record-consumer--2026-09-30)
resolves operation `0x1500` to a unique inline constant `24,000,000` in the
pinned iBoot registry. The static successful path supplies this same scalar
to all six frequency metadata selectors; it is not a per-cluster state table.
The metadata lead is closed, while safe early-DVFS policy remains unresolved.
Patch 0021 now fixes the ADT property-view metadata defect using the full
payload length with the template flag masked; traversal and getter/copy
lengths share that normalization. The host view tests and C-copy ABI regression pass,
including deterministic original/mutation controls. See the
[ADT view follow-up](m3-ultra-soc-status-2026-09-26.md#adt-property-view-length--2026-10-06).
The actual Rust parser also traverses the captured restore template's 771
nodes and 9,999 properties, including 69 template-marked properties, offline.
The declared-span follow-up below adds ADT buffer bounds; physical mapping and
Rust lifetime/aliasing remain separate requirements.

The [October 6 upstream review](m1n1-upstream-review-2026-10-06.md) found
44 commits since our pinned baseline, including T6032/M3 Ultra support and
overlapping SMP startup/shared-state changes. Our ADT fixes remain needed.
The [patch reconciliation](m1n1-upstream-reconciliation-2026-10-06.md) now
classifies all 21: CPU cleanup and the shared-memory backport are redundant;
capacity/stack patches must be split to retain bounds and RVBAR protection.
The remaining protections are not supplied by upstream. Separate unmodified
and three-input-guard builds pass, as do the current-source AIC/ADT host suites.
The startup/index guards are now adapted to cached CPU records and static
stacks. Comparison-only 0022 also contains T6032 normal-stop timeout and
reset-entry indexed-state hazards. The twelve-patch comparison build and
eight-object/static-stack linked layout pass. New source-extracted SMP and
MMU/HV host fixtures pass with ASan/UBSan and designated safe mutation
controls; SMP raw proxy-index checks remain structural, not a newly executed
ingress matrix. Deep-sleep and first-registration identity remain unqualified.
The mapping/readiness and MCC guards are also now adapted. The nineteen-patch
comparison build, linked layout, five current-source MCC/MMU fixtures,
bounded inherited-MMU mutation and source-scoped caller checks pass.
Cpufreq failure propagation (0011) and T6032-only first-cluster failure
containment (0023) are now adapted, and the full 21-patch comparison build
and linked layout pass. The 48-case driver/payload mock fixture, three safe
mutation controls, five full-stack MCC/MMU fixtures and independent rerun
pass. All 215 canonical C/Rust source files match the cross-build tree.
Hardware MMIO/cache/TZ/reset and early-DVFS contracts remain
unqualified. ADT declared-span checks (0024) and early handoff relocation checks
(0025) now pass the 23-patch cross-build and linked-layout audit, with the same
six upstream C warnings and no additional warnings. Exact/truncated fixtures,
all C offset wrappers, bounded paths, twelve payload-size/flag copy/view/set
regressions and the captured J575d tree pass. Three Rust guard-removal controls
fail at designated assertions without panic; fourteen C relocation cases and
four controls pass under ASan/UBSan. An independent final rerun passes. The
complete 23-patch source also passes the 48-case DVFS mock suite, its three
controls and five MCC/MMU fixtures. All 215 canonical C/Rust files agree across
the build, primary host, reviewer and adjacent-regression trees. The
[declared-span inventory](inventory/m1n1-upstream-adt-bounds-2026-10-07.json)
records evidence and remaining contracts. This validates the handoff-declared
extent and arithmetic, not the physical allocation/mapping, Rust static
aliasing, caller-owned C buffers or raw C property macro.

The [upstream refresh](m1n1-upstream-review-2026-10-06.md#freshness-follow-up--2026-10-07-utc)
finds no newer m1n1 default-branch changes; all three QEMU fixes remain absent
from the official checked source. Official Linux 7.3-rc6/master contains
T6032/J575d DTS/bindings, to be used during kernel/board integration; this is
not native boot evidence. AIC aperture/stride validation is now complete for
the declared register window, with the hardware qualifications below. AIC
startup failure propagation is implemented in the comparison stack; local
HV trace guards are now complete offline in the follow-up below. The
default source pin and disabled native dispatch are unchanged. Upstream
comparison artifacts contain its native T6032 dispatch and are not
boot-approved or fully hardware-qualified. The full original guard adaptation
is accounted for, but the remaining input and runtime gates are not complete.
Those implementation tasks take priority over further private-firmware tracing.

The [AIC aperture follow-up](m1n1-upstream-reconciliation-2026-10-06.md#aic-aperturestride-follow-up--2026-10-07-utc)
adds comparison-only 0026: bounded capability/IACK reads, indexed bank/stride
preflight and software-IRQ/raw-write ingress, preserving AIC1/2/3 layouts and
the HV event-hook size. The 24-patch cross-build/layout audit, seven AIC fixture
groups, four exact-diagnostic sanitized mutation controls and independent rerun
pass. ADT/relocation, 48-case DVFS/payload and five MCC/MMU regressions also pass
on that complete source. The
[evidence inventory](inventory/m1n1-upstream-aic-aperture-2026-10-07.json)
records the declared-span scope and unchanged hardware/recovery gates.
At that 24-patch checkpoint startup still ignores AIC failure before SMP.
Comparison-only 0027 now exposes initializer status and makes every normal
AIC1/2/3 startup stop before SMP on failure, preserving valid initialization
and the explicit `BRINGUP` bypass. The 25-patch cross-build/layout and adjacent
ADT/relocation, DVFS and MCC/MMU suites pass; all 215 canonical C/Rust files
match the build and adjacent trees. See the
[startup cutoff contract](m1n1-upstream-reconciliation-2026-10-06.md#aic-startup-failure-cutoff--2026-10-07-utc).
The final caller suite and independent rerun pass normal/`BRINGUP` startup,
status and stale-state checks, the retained aperture baseline and four
designated ASan/UBSan mutation controls. Their 215 canonical source files also
match the build. The
[startup cutoff inventory](inventory/m1n1-upstream-aic-boot-cutoff-2026-10-07.json)
records distinct build/host patch orders and retained evidence. HV trace-index
guards and other startup contracts remain separate at that checkpoint. No native
execution or MMIO.

Comparison-only 0028 now validates optional HV IRQ-trace geometry before
division or bitmap access, partitions global IRQs by initialized `max_irq`,
rejects cross-die ranges, bounds event fields and handles hook failure before
bitmap mutation. Python rejects a failed proxy request before changing its
local maps, without relying on `assert`. Valid zero-count requests, flag
semantics and the existing event-hook extent/lifecycle are preserved. The
26-patch cross-build and linked-layout audit pass with the same six known C
warnings. Final host tests and an independent rerun pass the C baseline and
three exact exit-1 mutation controls under ASan/UBSan, plus four Python
map-stability checks in each optimization mode (0 and 1). See the
[HV trace inventory](inventory/m1n1-upstream-hv-aic-trace-2026-10-07.json).
Of the 215 canonical C/Rust files, only `src/hv/hv_aic.c` differs
from the qualified 25-patch source; the other 214 are byte-identical. This is
optional HV work, not a native Linux boot prerequisite. The next native-boot
implementation priorities remain early-DVFS contracts and kernel/board
integration, followed by qualified console/interrupt/DMA bring-up.

The second read-only upstream check finds unchanged m1n1/Linux heads and the
HV trace defects still upstream. Exact follow-up responses resolve QEMU's
initial GitLab/GitHub discrepancy: both now report `f9587d4045c67cd0d8d8bdcd5d0bb5b6b395b63c`.
Its checked HVF source still lacks our three candidates. The pin remains unchanged.
See the [freshness correction](m1n1-upstream-review-2026-10-06.md#second-freshness-check--2026-10-07-utc).

Comparison-only 0029 now drains an inherited T6032 BUSY state before sampling
or changing a p-state request, rereads the completed state and preserves the
post-write wait. The 27-patch build/layout checks, 90-case source-extracted
ASan/UBSan suite and two exact mutation controls pass, including an independent
frozen rerun. Existing cluster fail-fast and payload cutoff are preserved.
See the [BUSY follow-up](m1n1-upstream-reconciliation-2026-10-06.md#inherited-dvfs-busy-drain--2026-10-07-utc)
and [inventory](inventory/m1n1-upstream-cpufreq-busy-2026-10-07.json).
This is not atomic hardware exclusion or qualification of raw indices,
routing, feature/restore or DVC policy. Default native dispatch remains off.
The additional 08:54 UTC upstream ref check finds all four API bodies identical
to the preceding captures; no newer default-branch commit needs reconciliation.
Next: exact official kernel/J575d source and configuration integration, without
inventing OPP data or bypassing unresolved early-initialization gates.

The [official J575d integration follow-up](m1n1-upstream-reconciliation-2026-10-06.md#official-j575d-kernelboard-handoff--2026-10-07-utc)
now locks and compiles the exact 14-file mainline closure. Current m1n1 handoff
tests pass four sanitized scenarios and two exact controls independently.
Comparison-only 0030 corrects the earlier mistaken omission of normal pruning
list cleanup; upstream's static-stack reservation scheme is preserved. Full28
build/layout and the old board baseline/90-case BUSY regressions pass. The
[kernel fragment](../configs/linux-j575d-ram-serial.fragment) was still a candidate
at that checkpoint; the follow-up below supplies the resolved config and Image.
Mainline lacks M3 OPP/cpufreq data. The cached downstream DART array's primary
`apple,t6031-dart` ID is absent, but its `apple,t8110-dart` fallback matches the
official driver; the earlier binding-gap claim was incorrect. The official DTB
has no DART nodes and does not exercise that fallback. Native register-layout,
power/clocks/console transport, CPU entry, interrupts and DMA remain unqualified.

The requested 09:37:04 UTC upstream refresh finds the same m1n1/Linux/QEMU
default-branch revisions. The fresh source check still lacks comparison
patches 0029/0030 and all three QEMU candidates; no pins or forks were changed.

The [pinned diagnostic-artifact milestone](m1n1-upstream-reconciliation-2026-10-06.md#pinned-diagnostic-kernel-and-initramfs--2026-10-07-utc)
now completes real Kconfig, full-tree dtschema and Linux **7.3.0-rc6** Image/DTB
builds. Native-target 16 KiB pages are explicit; a separate configuration run
matches byte-for-byte. The actual Kbuild DTB passes schema checks without
diagnostics and four sanitized m1n1 handoff scenarios. Two static AArch64
diagnostic initramfs builds are identical and satisfy the ELF/alignment/archive
checks, including a dynamic-ELF rejection control. The official DT lacks
DART/IOMMU, M3 frequency/OPP and intended storage/network descriptions. This
build milestone does not qualify physical SoC behavior or approve native boot.
The [inventory](inventory/m1n1-j575d-kernel-build-2026-10-07.json) records exact
inputs, artifacts and scope. The persistent Debian VM remains unchanged.
The exact kernel/initramfs additionally pass a disposable QEMU 11.1.1/HVF
RAM-only boot: four CPUs online, 16 KiB runtime pages and diagnostic PID1 alive.
The passing recipe uses QEMU's launch-time virt DTB and PL011 earlycon; the
earlier no-serial external-DTB run is retained. No physical J575d DTB or
m1n1 runs in this guest, so this is artifact validation, not native validation.

The [native-loader audit and destination guard](m1n1-native-loader.md) now pass
a full29 comparison build/layout, real gzip/XZ tests (10 helper and 16 wrapper
cases, four exact controls) and current-source BUSY/board regressions. The
[loader inventory](inventory/m1n1-native-loader-2026-10-07.json) binds 232 inputs
and artifacts. The fresh 11:09 UTC upstream refresh is again unchanged.
The subsequent [coordinated reservation fix](m1n1-topdown-reservations.md)
passes full30 build/layout, fifteen real-allocator/helper cases and two exact
overlap controls, plus decoder/BUSY/board regressions. Patch 0032 preserves
placement and the single guard page, checks arithmetic/collisions before
top-down metadata changes, and retains live reservations despite clearing or
widening a requested limit. The separate
[inventory](inventory/m1n1-topdown-reservations-2026-10-07.json) binds the final
inputs. The fresh 11:47:47 UTC upstream check remains unchanged.
Full31's [compressed-input guards](m1n1-native-loader.md#compressed-source-bounds-and-consumption)
now pass build/layout and real-codec fixtures: 16 input-helper cases, 10 output
helper cases, 25 wrapper scenarios and six exact controls. Patch 0033 uses a
checked finite declared handoff bound, rejects compressed source/output overlap
before decoding and corrects XZ's nonzero-capacity consumption result. Explicit
gzip prefix APIs preserve strict existing APIs while supporting a payload tail.
At the full31 checkpoint, XZ seek-wrap arithmetic remained separate work. The
allocator/BUSY/board regressions remain green; the separate
[inventory](inventory/m1n1-compressed-input-2026-10-07.json) binds final evidence.
The fresh 12:28:21 UTC official-API check still finds unchanged heads. No pins,
external forks or submissions changed.
No native boot or new VM was attempted. Exact producer-backed input extent,
complete parser bounds/failure handling, initrd placement, physical backing
and entry remain separate open work; requested
MCC/proxy limits are not made immutable by the reservation ceiling.

Full32's [checked XZ seeks](m1n1-native-loader.md#checked-xz-seeks-and-range-decoder-failures)
now separate forward seeks from checked rewinds, propagate failed position
queries/skips, reject failed range refills without breaking buffered endpoint
decoding, and preserve the legal compressed-chunk count of 65,536. The offline
cross-build/layout and actual-code sanitized fixtures pass, including four exact
negative controls, real compressed/raw streams, a size-only 65,536 metadata
packet and range-state boundary probes. Payload, allocator, BUSY and board
regressions remain green. The new [inventory](inventory/m1n1-xz-seek-2026-10-07.json)
binds final source/build/test evidence separately from earlier checkpoints.

The 13:24:05 UTC upstream refresh found unchanged official m1n1, Linux and both
QEMU mirror heads; no new commits were available to reconcile. No source pins,
external forks, submissions or native configuration changed.

The cached DART/NVMe/SART/mailbox/PMGR compatible arrays already select official
fallback implementations. Resolved kernel outputs have PMGR built in and
DART/NVMe/mailbox/SART as modules. This is source/build availability, not T6032
hardware qualification. The candidate DT was rebuilt byte-identically and its
sorted decompilation matches. DTC reported six warnings; offline full schema
validation emitted 431 diagnostic lines despite returning zero, so this is
not a clean schema pass. DART/mailbox/SART/NVMe compatible declarations and
NVMe's three-domain binding need schema reconciliation. The selected drivers were
unbuilt at that earlier checkpoint; the follow-up
below now records their separate, pinned module package and module-capable
diagnostic initramfs. An alias copying older hardware data would add no
evidence.
The candidate NVMe node uses SART/mailbox/power/reset and has no `iommus`
property, so DART is not assumed to be every storage node's dependency.

The [driver-module integration milestone](m1n1-upstream-reconciliation-2026-10-06.md#j575d-driver-modules-and-ram-only-module-initramfs--2026-10-07-utc)
completed on 2026-10-07. The producer compiled the exact six Kbuild goals
together against pinned Linux `602042bf29f6efde39cfb5fdd9289bf4854bc0c5`,
the retained `scratch/linux-j575d-kernel.HdzQNm` build, and the unchanged
Image/config hashes. The retained package is
`scratch/j575d-driver-modules.WpGKk3/package`, release `7.3.0-rc6`, with
actual modinfo/vermagic, `modules.dep`/`modules.alias` and empty depmod
stderr; the [module inventory](inventory/m1n1-j575d-driver-modules-2026-10-07.json)
records the package inputs and outputs. The module initramfs is
`scratch/j575d-initramfs.lQ4Gr7/`; the baseline remains
`scratch/j575d-initramfs.LdEBjk/`. Both disposable QEMU/HVF RAM-only runs
pass: `scratch/j575d-artifact-vm-2026-10-07/run-s11woxm1` is the module run
and `run-1qm_6azy` is the baseline; the module run loads all six modules and
reports them in `/proc/modules`, while both runs keep four CPUs, 16 KiB pages
and PID1 alive, with no disk, network or firmware and clean post-cleanup exit.
The retained serial/error records contain no module errors; QEMU stderr is the
expected 81-byte termination receipt and cleanup exits are zero. This is
functional artifact integration, not physical Apple probe/binding or native
validation.

The candidate fallback compatible tables remain usable for the selected
drivers. NVMe uses SART/mailbox/RTKit/reset and three direct PMGR domains
(seven domains in the full dependency closure); it has no `iommus`, so DART remains separate.
`CONFIG_APPLE_PMGR_PWRSTATE=y`. The actual `apple_nvme_attach_genpd` loop
accepts all domains: the binding's maximum-two restriction is schema-only, not
a runtime bug or reason for a driver patch. Candidate DTC's six warnings and
full-schema validation's 431 diagnostic lines remain unresolved. No alias or
copied-ops patch is warranted. Native work still requires a current verified
backup (last reported status: none), recovery readiness and separate approval.

The 2026-10-07T23:13:45Z official refresh returned HTTP 200 from all four
endpoints. Linux advanced to `7b63ef2d55f24519e7e9e5f4d15dbea03f126e40`;
the retained comparison is 16 commits across nine paths confined to
`drivers/md` and `fs/btrfs`, with no relevant M3 driver changes. m1n1
`2460b604c6f016956ead711823605eea840c602e` and QEMU
`f9587d4045c67cd0d8d8bdcd5d0bb5b6b395b63c` remain unchanged. No source pins,
forks or submissions changed.

The [inline-package milestone](m1n1-upstream-reconciliation-2026-10-06.md#assembled-inline-imagedtbinitramfs-packages--2026-10-07-utc)
assembled actual candidate and official Image/DTB/initramfs packets from the
hash-pinned full32 raw loader. Candidate and official retained outputs are
`scratch/j575d-inline-package.zv0ik1p4` and
`scratch/j575d-inline-package.z0up7d3d`; each is explicitly unqualified and
contains no installer. The contiguous packet uses default bootargs
`earlycon console=ttySAC0 rdinit=/init`, gzip Image, exact DTB, 14-byte
`m1n1_initramfs` wrapper plus length, and a 64-byte zero trailer. Actual
payload/tinf/libfdt host tests pass for both DTBs with zero mismatches; the
separate handoff fixture at
`scratch/m1n1-linux-package-handoff.mlaq_etg` passes the four fixup functions
against the actual packaged official/candidate DTBs and module initrd using a
synthetic 16 GiB memory/ADT/CPU state (the input DT placeholder is 8 GiB).
These are host tests:
post-fixup DTBs are test-only, no native CPU matrix or physical placement,
allocation, firmware or kernel-entry claim is made. The
[inventory](inventory/m1n1-j575d-inline-package-2026-10-07.json) records scope.

The [I/O module milestone](m1n1-upstream-reconciliation-2026-10-06.md#j575d-io-module-closure--2026-10-08-utc)
adds a cloned-build closure for PCIe, I2C, Apple tunable/ATC, Type-C and
Aquantia networking. Only four resolved symbols change:
`APPLE_TUNABLE=m`, `AQTION=m`, `PHY_APPLE_ATC=m` and
`NET_VENDOR_AQUANTIA=y`; the original config and old Image/vmlinux.o/System.map/
vmlinux.symvers hashes remain unchanged. The retained 17-module package is
`scratch/j575d-io-modules.RBhuUf/package`, and its module initrd is
`scratch/j575d-initramfs.g1ScGZ/output/initramfs.cpio.gz`, SHA-256
`0923b9e2ca20deaf63dab4d01b1ae037cce19ce36ba9eaa1d2ba612434d3096d`.
The final RAM-only HVF run `scratch/j575d-artifact-vm-2026-10-07/run-_c1kxiz_`
loads all 17 modules, reports 17 `/proc/modules` members and every marker,
with no network/disks/persistent VM/native hardware; legacy-six and extended-17
manifest checks pass in `scratch/j575d-module-manifest-checks.c32siftq`.
The [I/O module inventory](inventory/m1n1-j575d-io-modules-2026-10-08.json)
records the exact inputs and scope.

Read-only host I/O identifies AQC113 `1d6a04c0`, Apple subsystem `106b0223`,
bound port 2/BDF `2:0:0`; in the cached candidate before the separate profile,
port 02/DART2 is disabled and cached m1n1 does not enable a Linux DT node
(`pcie_init` is hardware initialization only). USB remains open: `t8103` compatibility, missing die-1 ATC aliases,
restore ADT tunables and absent Type-C graph are unresolved. Do not label USB
hardware complete. The 00:12 UTC official refresh leaves Linux
`7b63ef2d55f24519e7e9e5f4d15dbea03f126e40`, m1n1 and QEMU unchanged; its
responses are retained in `scratch/upstream-refresh-usb-network-2026-10-08`.

The [PCIe profile milestone](m1n1-upstream-reconciliation-2026-10-06.md#j575d-pcie-four-port-dt-profile--2026-10-08-utc)
now produces `scratch/j575d-pcie-dt.z4iac0rm/manifest.json`: the original DTB
hash is preserved, the profile hash is
`ed4623024f6d06bd816fc483735027e53798ad7f3de489775b77c5c2f5ea54a6`, exactly
six status changes enable ports/DARTs 1–3, and all 41 command receipts exit
zero. Six DTC warnings remain; both dtschema receipts retain 431 stderr lines.
This host-only profile does not prove physical PCIe, DART, link, DMA, IRQ or
driver binding.

The [USB live/backport inventory](inventory/j575d-usb-live-contract-2026-10-08.json)
now binds a filtered, unprivileged macOS collection: six ATC PHYs, six USB DRDs,
six ACE3 HPM controllers, two relevant SPMI banks and fourteen named tunable
payloads per PHY. The restore template contains only two generic tunables.
ACE3 needs SPMI transaction/IRQ support and a TIPD common/SPMI split; the old
17-module package is not sufficient. Primary source supplies a complete M3
PHY implementation through the intentional T6031/T8122 fallback, not a bare
compatible alias. The SPMI series applies in scratch with an include
prerequisite; TIPD needs a semantic port preserving newer pinned-core behavior.
Those source gaps are now addressed by the subsequent
[functional USB driver inventory](inventory/j575d-usb-drivers-2026-10-08.json):
three complete backports apply without fuzz, the six-symbol module overlay
builds a twenty-module closure, and the original Image/built-in ABI remain
byte-identical. The TIPD port preserves all four existing variant data tables,
packed status layouts, newer power-status callbacks and TPS66993 matches.
The new RAM-only HVF run loads all twenty modules and passes thirty markers;
there are no unresolved-symbol/load diagnostics. This is ABI/registration
evidence, not physical Apple driver operation. An inherited SPMI ACT/RSP
FIFO-recovery discrepancy is recorded as an unverified reliability item;
no speculative register fix or issue filing was made. The subsequent routing
evidence below resolves the second bank's physical placement; the runtime
power-domain join, fourth ACE3 IRQ, all six connector graphs and final per-port
tunable handoff remain open. The separate m1n1 comparison lane awaits Adam's
decision on its local no-AI instruction; no alternate copy or policy override
was used. No firmware, disk or persistent-VM state was changed.

The [USB physical-routing inventory](inventory/j575d-usb-routing-2026-10-08.json)
now binds an additional filtered read-only observation and eleven passing
collector fixtures. Explicit USB-to-PHY and USB-to-mapper-to-DART joins show
the J575d layout is four die-0 ports plus two die-1 ports. The generic candidate
is three-plus-three: die-0 port 4's DWC3/ATCPHY/two-DART set is missing, while
its third die-1 pair is not witnessed by the six live providers. The missing
DART resources and IRQ 1450 are directly captured, rather than inferred from
the USB provider's separate IRQ 858. Two wrong-die data controls fail as expected.
SPMI a2's translated resources resolve to die 0 (`0x2a11a8000`), with common
AIC controller `0x170` and IRQ 767; its source-sized register window is covered,
but the PMGR runtime join and hardware operation remain unqualified.
The companion SPMI/ACE3 binding patch applies without fuzz and passes offline
schema-document/reference validation; it does not change the frozen driver
build or establish full board-DTB schema validity. The offline profile below
now corrects the provider layout; connector graphs and per-port calibration
remain open. No pinned board source, boot-entry, firmware, disk or persistent-VM change was made;
no confirmed security finding was identified.

The [USB layout profile inventory](inventory/j575d-usb-layout-2026-10-08.json)
records a separately compiled Linux fragment adding the missing die-0 DWC3,
ATCPHY and two DARTs and disabling the unwitnessed die-1 quartet. Its combined
PCIe/USB DTB contains six active DWC3/PHY pairs and twelve USB DARTs. The
unchanged nineteen-file baseline still produces its pinned DTB hash; the PCIe
fragment still changes only six statuses. Resolved-reference comparison limits
the USB changes to four added nodes, four added symbols and four disabled
statuses, despite dtc phandle renumbering. Designated wrong-resource/IRQ/link,
unwitnessed-port and unrelated-change controls are rejected. DTC diagnostics
remain visible; this is not full schema or hardware validation. No connector,
calibration, alias handoff, default loader or native-dispatch change is included.
The separate [disabled ACE3 candidate](m1n1-native-loader.md#disabled-ace3type-c-graph-candidate--2026-10-08-utc)
adds a disabled die-0 a2 bank and six disabled ACE3 children with 36 endpoints
and 18 reciprocal connector/DWC3/ATCPHY links. Two independent builds match;
eleven regression tests and eight builder controls pass on each. Exact
endpoint ownership and existing provider references/resources are checked.
The public collector confirms six actual `AppleHPMARMSPMI` services and 426
valid retained byte tuples, but still supplies only three interrupts per HPM.
Candidate select IRQs are explicitly sibling-source inference, not J575d
witnesses. Six existing DTC warnings remain byte-identical; full schema and
native operation are unqualified. Default profiles and the frozen twenty-module
package are unchanged. See the [candidate inventory](inventory/j575d-ace3-candidate-2026-10-08.json).
Next: faithful per-port calibration and independent select-IRQ evidence;
the candidate stays disabled pending physical qualification.

The initial [native PHY normalization follow-up](m1n1-native-loader.md#native-phy-record-normalization--2026-10-08-utc)
identifies the retained `AppleT6032TypeCPhy` driver and joins all 252 six-port
register tuples to its 42-by-8 table. Two identical offline decoder outputs
preserve 852 records from twelve named groups; ten independent-reference tests
pass. Physical containment is 312 AXI2AF, 150 core and 390 unassigned fabric
records. At that checkpoint, the fabric bank was outside the five Linux
resources and native caller ownership was still open. Common/lane grouping
and the separate USB2 consumer were not qualified; the original decoder
emits no calibration properties and its frozen inputs remain unchanged.
See the [normalization inventory](inventory/j575d-phy-calibration-2026-10-08.json).

The [generic PHY integration follow-up](m1n1-native-loader.md#generic-phy-calibration-integration--2026-10-08-utc)
now resolves native init part B to the generic helper and its AXI2AF → Fabric
→ LN0/LN1 RX-clock sequence; the flag tests select logging, not a calibration
gate. A new opt-in Linux Fabric resource/property preserves the legacy
five-window path, rejects unsupported generations and applies after AXI2AF
before common-b. A fresh isolated twenty-module build and six source tests
pass. The separate candidate contains 750 generic records (312 AXI2AF, 390
Fabric, 48 RX-clock), keeps all six PHY and ACE3 nodes disabled and preserves
legacy windows, graphs, other properties, boot CPU and reservations. Four
independent DT tests and DTC round-trip compilation pass. No package/profile
is installed or booted. The cached dt-schema 2026.9 validator is available
offline, without a dependency download. Its checks caught two redundant
resource bounds and an inferred one-row Fabric limit. The corrected binding
inherits the shared nonempty matrix type without restricting row count;
binding-document validation, the fresh twenty-module build and all twenty
source/DT/decoder tests pass. Full processed-schema validation adds no
diagnostics and reports no ATCPHY errors. The whole board still has 80
existing validation errors and 86 unmatched compatibles; essential
PMGR/DART/NVMe/SPMI/USB descriptions need functional triage. Negative controls
also document dt-schema's disabled-node conditional-coverage limitation;
driver and exact-property builder checks independently enforce the Fabric pair.
The next opt-in T6031 USB-common channel assigns the 72 USB-helper records
in their proven core-resource order, after generic calibration and only for
USB3/USB3-DP before existing lane programming. It preserves absent-property
legacy paths, rejects other generations and does not require Fabric presence.
The fresh twenty-module package builds without installation/boot; six source
tests exercise the complete apply function in 56 mode/presence/orientation
cases and a compiling mode-gate mutation with exact exit 1. Eight independent
DT tests check all 822 raw-to-compiled records, 42 bounded property changes,
disabled PHY/ACE3 nodes and DTC round-trip/reservations. Full-schema validation
of the actual candidate adds no diagnostics relative to the frozen 750-record
baseline; 80 existing errors and 86 unmatched compatibles remain. Seven
copy-only controls accept valid/absent optional USB matrices and reject
malformed, empty and isolated other-generation usage, including disabled nodes.
This targeted qualification is not a clean whole-board or physical boot claim.
The 30 CIO80 defaults and 12 USB2 records remain
unassigned. Board triage distinguishes existing fallback matches from physical
compatibility. The 16 PMGR errors narrow to eight MCA-domain external-clock
booleans, with no identified Linux consumer and unresolved hardware meaning;
those properties are left unchanged. See the
[USB-common inventory](inventory/j575d-phy-usb-common-integration-2026-10-08.json).
The [remaining Type-C contract audit](inventory/j575d-native-typec-contract-gaps-2026-10-08.json)
records fresh three-entry public HPM IRQ arrays and a bounded native
registration trace, neither of which supplies the fourth select hwirq.
The captured native SPMI implementation polls register 0 instead of requiring
that IRQ. Its busy/ready loop is traced. Linux's whole-callback regmap mutex
and synchronous SPMI command completion are now source-qualified, but native
provider equivalence and stale-ready behavior still need qualification before
a Linux polling change. Native busy-loop exhaustion
falls through without a distinct timeout error; no such Linux policy is added.
Valid missing-name lookup returns `-ENODATA`, not the initially proposed
`-ENXIO`; malformed metadata, deferred IRQ domains and IRQ-zero mapping failure
cannot activate polling. The cached Apple binding's four-IRQ default remains.
The native adapter reaches named register-zero-write/read APIs and command
kinds 7/6, but `sendCommand`'s `controller+0xe0` receiver/slot `+0x1e8` and
controller slot `+0x980` remain unresolved. Corrected original-address views
supersede rebased call-site evidence; 520 instruction-byte lines and 27
same-line anchors pass the main verifier, without claiming wire equivalence.
CIO mode 2 has a traced native producer but no proven Linux protocol crosswalk;
USB2's captured HOST/DEV values have opposite polarity to Linux, with native
consumer/base/timing unresolved. The bounded controller trace stops at those
two receiver implementations; independent source-backed help is needed before
a qualified polling implementation and for CIO80/USB2. No new Pro
consult is launched. The disabled candidate and driver patches are unchanged;
no hardware claim is made.
The latest Linux API check at 04:16 UTC still returns `7b63ef2d`;
the retained source pin is not changed. See the [integration inventory](inventory/j575d-phy-fabric-integration-2026-10-08.json).

At the earlier 14:04:34 UTC checkpoint, the official-API refresh returned HTTP
200 for all four endpoints;
m1n1 `2460b604`, Linux `602042bf`, and QEMU `f9587d40` remain unchanged from
13:24:05 UTC. No upstream updates were applied.

Here, **native validation means bare-metal execution**, outside macOS, not
the QEMU/HVF VM. HVF runs guest CPU instructions on the host CPU but exposes
virtual hardware; it cannot validate the Studio's physical SoC initialization.

| Workstream | Status | Next action / gate |
| --- | --- | --- |
| M3 persistent Debian VM | Previously validated; unchanged | Preserve working configuration; regression-test before promoting replacement QEMU |
| QEMU fork PRs 1–3 | Awaiting Adam's review | Review PMINTENCLR, PSCI and SDK27 changes; no merge or upstream submission assumed |
| QEMU regression / promotion | Pending qualification | Complete required SMP/PSCI, reboot and save/restore checks on the replacement binary; retain rollback |
| QEMU CPU feature coverage | Partial; separate from basic VM operation | Continue bounded feature probes where useful; do not treat optional gaps as bare-metal or VM blockers |
| QEMU upstream submission | Not sent | After approval, refresh/check patches and submit separate qemu-devel email series |
| M5 Max durable VM | Setup requested; completion unconfirmed | Confirm MacBook setup and capture persistence, SSH, console, networking and restart acceptance evidence |
| M3 m1n1 capacity / handoff / loader | Full32 comparison builds, inline candidate/official packet assembly, payload tests and handoff fixtures pass; no native boot | Qualify physical placement/source backing and Linux entry; security findings are report-only, not bring-up gates |
| Exact T6032/J575d board DT | Disabled candidate integrates 822 records (750 generic plus 72 USB-only); eight independent DT tests/round-trip and targeted USB schema controls pass with no new diagnostics | Triage 80 existing errors/86 unmatched compatibles; CIO80, USB2 and select IRQ remain open; no boot approval |
| T6032 SoC identity / CPU startup | Cached 32-CPU preflight, packed masks, caller and readiness guards adapted; source-extracted host suites pass | Preserve full comparison regressions; qualify cold reset, release sequencing and RVBAR only after safety gates |
| Secondary-start failure handling | RVBAR/start-timeout/status/index and stop/reset containment pass offline checks; current readiness placement checked structurally | Raw SMP proxy matrix remains structural; native reset/deep-sleep/first-registration identity unqualified; no degraded-SMP recovery claim |
| MCC/cache initialization | MCC/carveout/mapping/readiness guards adapted; 25-patch build, five current-source fixtures and linked layout pass | All 64 controller/plane contexts, register access, cache effects and DMA still need hardware qualification |
| Six-cluster frequency / DVFS | 0011/0023 failure containment preserved; 0029 prewait/reread, full27 build/layout and 90-case sanitized suite plus two controls pass independently | Safe raw APSC/default indices, physical busy/routing and feature/restore/voltage contracts remain open; default native dispatch disabled |
| Native console / interrupts / DMA | UART/AIC/PMGR descriptions checked; USB-extended 20-module closure builds/loads in RAM-only HVF; all four PCIe/DART status entries are enabled only in the host profile | Package/profile handoff, then qualify physical PCIe/DART layout, power/clocks, IRQ, DMA and driver binding on native hardware |
| RAM-only Linux diagnostic boot | Final USB-extended initramfs HVF run loads all 20 modules, passes 30 markers and records 20 `/proc/modules` members; no native boot or hardware claim | Qualify physical backing/placement, bootargs, initrd window and kernel entry; verified backup/recovery and separate approval are required |
| NVMe / USB / Ethernet | Fresh twenty-module USB-common package builds; six source/eight DT tests pass, including 56 complete-source mode cases; native polling and Linux locking/IRQ contracts traced offline | Package not installed or booted; independent help needed for two native controller receivers/completion and stale-ready policy before qualified polling; CIO80 protocol, USB2 consumer/base/role and select IRQ mapping remain open; essential binding/PMGR clock contracts and physical power/clock/IRQ/DMA qualification remain |
| Recovery / boot-entry setup | Adam confirms no current backup; MacBook inventory requested in 18031, Finder procedure clarified in 18043 | Complete and verify backup; confirm data cable and host readiness. Native actions need separate approval; local MMU guard is not recovery evidence |
| Linux storage / partitioning | Researched only; not authorized | Verify backup, refresh disk identifiers/limits, choose layout and obtain approval; no USB/internal-disk changes |
| MacBook project migration | Planned, not performed | Agree on transfer/verification plan; no deletion of Studio project data |
| NFS follow-up | Deferred by Adam | Resume only when requested; historical VM NFS evidence is not native-driver validation |

Details: [CPU work](m1n1-t6032-cpus.md),
[MCC layout and remaining gates](m1n1-t6032-mcc-layout.md),
[MCC Pro-consult source review](m1n1-t6032-mcc-pro-review.md),
[MCC handoff/access ledger](m1n1-t6032-mcc-handoff-ledger.md),
[J575d boot-firmware artifacts](m1n1-t6032-boot-firmware.md),
[boot-image address model and code references](m1n1-t6032-boot-address-model.md),
[boot consumers and published lock-reg metadata](m1n1-t6032-boot-consumers.md),
[AMCC write-address field and per-plane reads](m1n1-t6032-boot-write-addresses.md),
[protection-range record identities and TZ0](m1n1-t6032-boot-range-records.md),
[four TZ slots and endpoint arithmetic](m1n1-t6032-boot-tz-endpoints.md),
[endpoint translation and RAM reconstruction](m1n1-t6032-boot-tz-translation.md),
[TZ0 limit production and conditional inverse](m1n1-t6032-boot-tz-inputs.md),
[fixed-origin T6032 decoder and mapped-RAM containment](m1n1-t6032-tz-origin.md),
[all-controller/plane TZ consistency preflight](m1n1-t6032-tz-consistency.md),
[MMU entry lifecycle and recovery prerequisites](m1n1-t6032-mmu-entry.md),
[SMP shared-memory backport, runtime guards and tests](m1n1-smp-shared.md),
[CPU/DVFS Pro review and remaining contracts](m1n1-t6032-cpu-dvfs-research.md),
[boot-argument physical-base producer and copy path](m1n1-t6032-boot-arguments.md),
[source-table merge and boot-stage boundaries](m1n1-t6032-boot-stage-boundaries.md),
[LLB memory-table address publication](m1n1-t6032-llb-table-publication.md),
[LLB memory-list export and eligibility](m1n1-t6032-llb-memory-export.md),
[LLB dynamic selector paths and bounded exclusions](m1n1-t6032-llb-selector-paths.md),
[cache-control contract trace](m1n1-t6032-cache-contract.md),
[carveout metadata and safety gaps](m1n1-t6032-carveouts.md),
[runtime mapping guards](m1n1-t6032-mapping-guard.md),
[startup contract](m1n1-t6032-startup.md),
[PMGR metadata](m1n1-t6032-pmgr.md),
[DVFS register contract](m1n1-t6032-dvfs-contract.md),
[DVFS live inputs and feature consumers](m1n1-t6032-dvfs-inputs.md),
[DVFS state selection and conversion](m1n1-t6032-dvfs-states.md),
[ACC restore write and die routing](m1n1-t6032-acc-restore.md),
[frequency-init failure propagation](m1n1-t6032-cpufreq-status.md),
[local PMGR binary evidence](m1n1-t6032-pmgr-binary.md),
[32-CPU mask comparison](m1n1-t6032-cpu-masks.md),
[mask contract and mode selection](m1n1-t6032-mask-contract.md),
[whole-inventory preflight](m1n1-t6032-inventory-preflight.md),
[caller failure propagation](m1n1-t6032-start-status.md),
[offline build and handoff](m1n1-cpu-offline-build.md),
[SoC gaps](m3-ultra-soc-status-2026-09-26.md),
[persistent VM](persistent-test-vm.md),
[QEMU CPU plan](qemu-apple-host-cpu-passthrough.md).

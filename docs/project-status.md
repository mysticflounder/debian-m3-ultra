# Project status — 2026-10-22

M5 VM checkpoint: the MacBook's retained Debian disk was copied and its qcow2
reference counts repaired on the copy. Generic-kernel HVF boots, key-only SSH,
DNS/HTTPS, persistent identity/data, serial access, in-process reboot and clean
stop/start passed. The working VM is running; use `scripts/m5-vm.sh`. See the
[M5 acceptance results](persistent-test-vm.md#m5-max-working-vm-2026-10-22).

M3 boot documentation reconciliation: the last physical evidence is from
2026-10-14. No later paired-Recovery entry or native boot has been reported;
no disk, boot-setting or hardware checks were performed for this update.

Latest boot transition: Adam reported successful interactive authorization.
Read-only `bless --getBoot` confirms the verified Debian Boot System volume
`disk7s2` is selected. The target-only `SystemVersion.plist` rename for paired
Recovery is complete; `.IAPhysicalMedia` remains intact. No stage-two script,
`bputil -nc`, `kmutil`, shutdown or native boot has been executed here. Next:
operator-controlled shutdown/Startup Options into Debian Boot, stopping at the
Recovery/installer screen before custom boot authorization. See the updated
[handoff instructions](m1n1-native-loader.md#boot-stub-provisioning-checkpoint--2026-10-13).
The [authorization/handoff inventory](inventory/j575d-boot-handoff-2026-10-14.json)
records the evidence and remaining boundary without changing the older staging receipt.
The staging checkpoint below records the earlier state, before authorization.

Latest storage checkpoint: the portable Debian UEFI disk passes two HVF cold
boots, and the staged `complete-candidate-YFOQRXya` passed its disposable
8 GB APFS, read-only reopen and byte-integrity checks before physical staging.
The user then created the physical 8 GB APFS target; scoped provisioning added
its System/Data/Preboot/Recovery roles. 139 staged records plus three admin records passed
read-only remount audits for hashes, UUID substitution, ownership, modes,
Recovery compression and required paths. At the 2026-10-13 staging checkpoint,
the target used 1,468,968,960 bytes with 6,531,031,040 bytes free, and all four
volumes were unmounted. These are not post-authorization measurements or
current mount-state claims. Full personalization and paired-Recovery/native
bootability remain unqualified.
Offline follow-up stages four FUD inputs/aliases, inert installer templates,
four installer-data exports and the unchanged unqualified diagnostic loader.
The current twenty-module RAM-only diagnostic needs no additional Linux vendor firmware;
firmware collection is an optional later-profile manifest, not a first-RAM
gate. The modern host Bootability caller's Preboot framework/trust-cache paths
are traced, and static eligibility comparator result 3 accepts the actual host
`love` value; successful paired-Recovery entry, Recovery approval and full
personalization remain unqualified despite the verified startup selection.
No physical Linux root/ESP partitions or native boot have been performed.
Full personalization has not been independently established. Backup and data
cable are confirmed; DFU recovery is not
exercised. See the
[current provisioning checkpoint](m1n1-native-loader.md#boot-stub-provisioning-checkpoint--2026-10-13).
The current bounded stub/FUD/adapter checkpoint has 43 passing tests. See the
[physical staging inventory](inventory/j575d-physical-boot-stub-2026-10-13.json)
for the target identifiers and receipts.

Earlier package checkpoint: the pushed m1n1 fork (`b91ede42`) is now integrated with the
updated diagnostic initramfs in explicit offline packages. Official and disabled
event-DT packages both pass the actual combined-input host parser fixture with
zero mismatches; five builder tests and two synthetic DT handoff checks pass.
Historical defaults are unchanged. This is not a VM/native boot or hardware
qualification. See [the package inventory](inventory/m1n1-fork-inline-package-2026-10-11.json).
The local fork source-policy hold is resolved; backup, recovery and native-test
approval gates remain. Older checkpoints below retain their historical scope.

Updated at task completion. Source/offline validation is not native-hardware
validation. External PR, VM and MacBook states below are last recorded states,
not a fresh remote or live-machine check.

Current physical boundary: the user-created target is `disk0s5`, store UUID
`9D38BA18-6581-413B-815C-17D69DE44BDF`, in APFS container
`F6577F6B-0EB5-4E21-9761-3EE18E4A2C29` (`disk7`, 8 GB decimal). Data/VGID is
`DAD29544-6687-4B2C-B0E0-87A1D6A700B5` (`disk7s1`); System, Preboot and
Recovery are `F78D7027-7D09-4A12-8165-9B6374513A13` (`disk7s2`),
`68A1164D-90DE-473B-A9D6-AA6658C60021` (`disk7s3`), and
`846EEAE0-79F7-482D-B8D3-885EE745845C` (`disk7s4`). Physical staging and readonly
remount audits passed; admin metadata staging also passed. Interactive `bless`
success was subsequently reported and startup selection verified on October 14;
the reversible paired-Recovery handoff rename also completed. Full
personalization and paired-Recovery/native boot remain unqualified. The legacy
`schg` workaround was not applied; `bputil -nc` and `kmutil configure-boot` were
not run. Next is operator-controlled entry into Debian Boot's paired Recovery,
stopping before policy/custom-boot changes; native execution requires separate
approval. Device identifiers above are historical and must be re-resolved
before any later disk action. The old
`diskutil addPartition` command was already run by the user and is historical;
do not rerun it.

Scope: this is functional Debian/M3 Ultra SoC bring-up, not security work.
Report and record security findings, distinguishing verified issues from
suspicions, and advise Adam whether an issue should be opened. Security fixes
and additional hardening are outside this project's implementation scope and
are not boot-completion gates. Do not file issues or disclosures without approval.

Earlier loader checkpoint: the SMP shared-memory fix (`d484a58`) and SMP index guards
(`f51c869`) were pushed before this follow-up. Patch 0018 adds MMU/HV direct
and proxy index validation, preserving canonical exit/unpin sentinels; it is
committed as `14605bf` (not yet pushed at that checkpoint). The twenty-one-patch cross-build
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
evidence, not physical Apple driver operation. The inherited SPMI ACT/RSP
FIFO-recovery discrepancy is now corrected by local patch 0007, changing the
flush target from `SPMI_RSP_REG` (`+0x8`) to `SPMI_ACT_REG` (`+0xa4`). It is
referenced against the published upstream v10 FIFO series
([source](https://lists.openwall.net/linux-kernel/2026/10/01/2633)); this is a
published-series reference, not a claim that the correction is mainline.
The actual-source offline build at
`scratch/j575d-select-polling-offline.dfzHSr` completes the 20-module closure
and packages the three TIPD modules plus the corrected SPMI controller module.
The parent review fixture at
`scratch/j575d-spmi-fifo-recovery-2026-10-10/parent-review/fifo-recovery-un32vx1j`
passes `normal=1 timeout-retry=1`; its designated wrong-target mutation exits
exactly 1. That fixture checks the ACT flush before the retry command and
recovery counts, but does not prove ACK/reinitialization ordering or hardware
behavior. Separate captured Gen3 mapping evidence verifies provider resource 0
and descriptor offsets status `+0`, command `+4`, response `+8`, with the
response-empty mask at `BIT(24)`; captured physical resources are a0
`0x2a1188000` and a2 `0x2a11a8000`. No runtime virtual address or native
enablement is claimed. Response decoding, selector freshness, CIO80 and USB2
remain unresolved. The subsequent routing evidence below resolves the second
bank's physical placement; the runtime power-domain join, fourth ACE3 IRQ, all
six connector graphs and final per-port tunable handoff remain open. The
separate m1n1 comparison lane awaits Adam's decision on its local no-AI
instruction; no alternate copy or policy override was used. No firmware, disk
or persistent-VM state was changed.

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
enabling polling on hardware. Native busy-loop exhaustion
falls through without a distinct timeout error; no such Linux policy is added.
Valid missing-name lookup returns `-ENODATA`, not the initially proposed
`-ENXIO`; malformed metadata, deferred IRQ domains and IRQ-zero mapping failure
cannot activate polling. The cached Apple binding's four-IRQ default remains.
The native adapter reaches named register-zero-write/read APIs and command
kinds 7/6. The October 10 [dispatch trace](j575d-spmi-native-dispatch.md)
resolves the retained base command-gate slot `+0x1e8` to `runAction` and
controller slot `+0x980` to `executeLoggedCommand`, using the constructor's
`__ZTV + 0x10` address point. The concrete `AppleSPMIController` exists in
both retained symbols and the HPM providers' registry hierarchy. Its corrected
nested slot `+0x958` resolves to `executeCommand`. Helper tracing reaches
`waitForResponse` and `queuePop`; an actual-source Linux host fixture passes
2,560 packing cases. Native/Linux intermediate selector words differ, but
that does not establish a wire mismatch or driver bug. The captured Gen3
handler/provider mapping is now statically closed; response decoding, the
shifted controller field and selector freshness remain under investigation.
The bounded response follow-up establishes native masks `0x0fe0`/`0x0f80`
for kinds 6/7, post-comparison bit-16/bit-15 checks, and the one-byte FIFO
copy. The corrected Linux source passes a queue-driven 1,024-case read
matrix, two write-ACK cases and FIFO/timeout cases with two semantic mutation
controls. It accepts a mismatched response header in the tested case, unlike
the native masked-comparison path. This is not yet a demonstrated hardware
bug or justification for a driver change. Native controller `+0x194` is
loaded from configuration word 0 by `setConfig`. The configuration producer
now traces from the device's `reg` property through its 24-byte setter/getter
and `updateConfig` into `setConfig`. The concrete secondary interface's
validator returns one; its first entry resolves the device-to-controller
`sendCommand` join. Captured HPM first words are 12, 10, 8, 6, 12 and 10,
but this is initialization-input evidence, not sampled live controller state
or wire/USID equivalence. Gated enqueue refreshes before execution; an explicit
lock refreshes before enabling same-device reuse. The interrupts-disabled
direct path does not refresh in `sendCommand`, so refresh on every command
is not claimed. The mismatch
call resolves to `spmiPanic` and then kernel `_panic`. Its start-path opt-out
is the integer parameter `req-resp-mismatch-no-panic`: successful nonzero
lookup selects the error-return branch. This is static policy evidence, not
a runtime flag observation or a policy to copy into Linux.
Corrected original-address
views supersede rebased call-site evidence; 520 instruction-byte lines and 27
same-line anchors pass the main verifier, without claiming wire equivalence.
CIO mode 2 has a traced native producer but no proven Linux protocol crosswalk;
USB2's captured HOST/DEV values have opposite polarity to Linux. The native
hardcoded initialization consumer and descriptor wrapper are now traced;
captured resource-index equivalence is now traced as described below, while
role semantics, timing and physical operation remain unresolved.
The additional
[timeout/retry fixture](j575d-select-polling-prototype.md#timeoutretry-ambiguity--2026-10-10)
passes against actual extracted polling/read code: the first full read times
out with no payload, then the unchanged driver accepts a same-register
busy/ready sequence attributed externally to the older request and transfers
one byte. ASan/UBSan runs and the designated ready-only mutation control pass.
This demonstrates modeled ambiguity, not a hardware stale-response defect.
Native ready-first acceptance and local command-gate serialization do not
resolve it. Further host-only freshness qualification is parked pending a
device invalidation/completion/recovery contract or qualified select IRQ;
the prototype remains default-off. Next offline work targets the CIO80/USB2
contracts. Static configuration provenance, dispatch and software wait loops
do not establish hardware completion or wire equivalence.

USB2 follow-up (2026-10-10): the pinned native `initUSB2(unsigned)` wrapper
at `0xfffffe000a2096b4` computes its first boolean as
`(descriptor & 0x60000) == 0x20000`, and its second as descriptor bit 19.
It branches to `eusb2phy_init(bool,bool)` at `0xfffffe000a1cfb90`. That
consumer reads the pointer at `this+0x210` and separately updates bits
`0x4000`, `0x2000` and `0x1000` at pointer offset eight: first boolean true
clears them, false sets them. This does not assign host/device meaning.
The caller's bit-19-clear branch skips its masked comparison; bit 19 is
not a mandatory prerequisite. Other state/power checks still govern dispatch.

The `start()` mapping loop stores its index-zero map's virtual-method
`+0x138` result at `this+0x210`; entries have a `0x20` stride. Its receiver
is the original `start` provider: `x1` is saved in `x26`, temporarily spilled
at `sp+0x38`, and restored at `0xfffffe000a1cca70` before the loop. The
intermediate `x25` to `x26` copy followed by a PAC discriminator is **not**
the map-owner provenance. Numeric physical base/aperture and equivalence
to Linux's named `usb2phy` resource are not established by this trace.

Linux source review confirms named-resource lookup and HOST-set/DEVICE-clear
behavior for offset eight, mask `0x7000`. The current generic candidate's
six inventoried physical USB2 bases and DWC3 USB2 links agree; its seventh
ATCPHY declaration is inherited, disabled and lacks a connector witness.
The audited candidate is byte-identical to the integration inventory's
candidate, not a stale alternative. Native opcode/fixup and Linux source/DT
verifiers pass in `scratch/j575d-usb2-consumer-2026-10-10/verify.py` (SHA-256
`fc871987fa6d622793801b98846c69a0997313c6718ec87b59604264e50966e1`,
including the address-point correction below) and
`scratch/j575d-usb2-linux-contract-2026-10-10/verify.py` (SHA-256
`c52cc62b902a5a391abf87d1b504aea05d829edfe86f35d9b78f5b5fce21d232`). These are static
checks, not execution or electrical validation. Next trace the native
descriptor producer and original provider's resource-zero mapping; do not
invert Linux polarity, emit USB2 tunables or enable hardware from these facts.

The subsequent provider follow-up closes the **captured resource-index**
comparison, not hardware qualification. In the retained IOService registry,
each of the six `atc-phy0..5@2A90000` nodes is an `AppleARMIODevice` with
a direct `AppleT6032TypeCPhy@0..5` child. Its own `IODeviceMemory[0]` has
length `0x4000` and base respectively `0x702a90000`, `0xb02a90000`,
`0xf02a90000`, `0x1302a90000`, `0x2702a90000`, `0x2b02a90000`.
All six match the raw registry's first `reg` tuple and Linux's named USB2
resource. Original-image symbols and chained fixups resolve the provider's
slots `0x710`/`0x708` to `IOService::mapDeviceMemoryWithIndex` and
`getDeviceMemoryWithIndex`; the latter retrieves `IODeviceMemory` and passes
the supplied index to `OSArray::getObject`. The generic `IOMemoryMap` slot
`0x138` resolves to `getVirtualAddress`. This connects the known mapping loop
to captured resource metadata; it does not observe a running map object,
live virtual address, power state or successful register access.

The same six parent nodes expose **two** USB2 setting families. Generic
`tunable-host`/`tunable-device` encode `(resource=0, offset=8, mask=0x7000)`
with values `0x7000`/`0`, agreeing with Linux. The separately named
`tunable_USB2PHY_HOST`/`DEV` encode values `0`/`0x7000` instead. The property
names alone do not tell us which is consumed by the hardcoded initialization
path, nor justify changing Linux. Descriptor role production and sequencing
remain the next investigation. The provider receipt is
`scratch/j575d-usb2-provider-2026-10-10/report.md`; generic API checks are in
`scratch/j575d-usb2-map-api-2026-10-10/verify.py` (SHA-256
`0f7e32c5e6925831cd530e0040b376857ae4c4a9bcfcf969613d985aa6086cd3`).
The provider verifier (SHA-256
`ce26544bdec086e6c9a8d01eae2b97eba0b6859bd4fcd6d4f76a28fff4dc0380`)
passes against the pinned service registry
`cf4f681047520d666fea5f9ddfbb4b4b87875240740ecde3cc147e29c524ebad`.
It checks same-node property ownership and direct child identity, with an
accepted baseline and four designated parser rejects. The final parent rerun
is `scratch/j575d-usb2-provider-2026-10-10/parent-review.txt`. No driver, DT
enablement or hardware state was changed.

USB2 dispatch correction: the earlier scratch report confused offsets from
the vtable symbol with offsets from the object's vtable address point.
The constructor explicitly installs symbol `0xfffffe00083bac50 + 0x10`.
Therefore `initUSB2` is runtime slot `0x9d8` (symbol offset `0x9e8`), called
at `0xfffffe000a1c1768`; runtime slot `0x9e8` instead selects `sleepUSB2`.
The earlier power-level-1/sleep call is not an initialization witness.
The corrected verifier checks the constructor, actual init call and both
distinct fixup targets. The hardcoded init's bit behavior is unchanged.

The upstream caller edge within the retained binary is now identified:
`AppleTypeCPhy::open(interface, power, unsigned, unsigned)` saves its
incoming `x2`/`x3` in `w20`/`w21`, captures them at stack offsets
`0x80`/`0x84` in the block beginning at `sp+0x50`, and its block reloads
those words at block `+0x30` as `w1`/`w2`. The call at
`0xfffffe000a1bd924` uses runtime slot `0x920`, resolving to
`configureUSB2`. Thus the descriptor comes from the first unsigned argument
to `open`; the role encoding of that caller argument is still unresolved.
The full base-class disassembly is retained at
`scratch/j575d-usb2-consumer-2026-10-10/base-full.disasm`.
Separately, the initial `init.disasm` was a 662-line excerpt ending at
`0xfffffe000a1d05cc`, not the whole initialization body through
`0xfffffe000a1d1d18`. Absence of later writes or argument uses cannot be
inferred from that excerpt. Full init/shutdown views have now been generated
for the pending power-sequence review; no timing fix is yet justified.

The follow-up caller review corrects an ABI interpretation in the scratch
open-role report. `createTypeCPhyUSB2Interface` supplies zero in `w3` to
static `withTypeCPhy`; the latter saves it in `x20` and passes it as `x4`
to the instance initializer. The USB-interface initializer's `+0x178`
vtable slot and its base-initializer dispatch both resolve in the original
collection. The base initializer stores that zero at interface `+0x40`.
Thus this factory path does not depend on an unknown incoming factory `x4`.
The reviewed 149 instructions match the original collection bytes; the
checked receipt is
`scratch/j575d-usb2-client-role-2026-10-10/virtual-callers/verify.py`
(SHA-256 `b82f9448604f8ba494d3ef58e212410ec36489d0f7be7471a4046b88396152ac`).
Five XHCI slot-`0x880` calls are also byte-anchored, but their presence does
not identify the J575d runtime controller or exclude subclass overrides.
Later writes to `+0x40` are not qualified by this receipt. No role meaning,
timing change, or Linux patch follows from the zero initializer alone.

The next receiver trace now joins the captured client class to a concrete
startup call. The retained Studio registry has six `AppleT8122USBXHCI`
controller headers and three nonempty PHY USB2 client records naming that
class (three other records are empty). The earlier `AppleUSBXHCIARM` view
did not contain this class; its code is in the full collection's
`AppleSynopsysUSB40XHCI` view. T8122 `start` stores the USB2 factory result
at controller `+0xfb8` (`0xfffffe000b5382a4`), reloads it at `...b53837c`,
and calls interface slot `+0x138` at `...b5383b8` with power argument two,
flags `0x40000`, and final argument `0x1f4`. Both USB2 and USB3 interface
pointers must be nonnull on this path. The concrete T6032 factory and
allocated USB-interface open vtable slots resolve to the reviewed methods.
All 84 instructions from the PHY-result check through the open-return check
match the original collection. The checked receipt is
`scratch/j575d-usb2-client-role-2026-10-10/open-receiver/verify.py`
(SHA-256 `e1a0c0a8355532472e5b0451676483d867fd526b8d586cfdaddef545c1b6e4b2`).

With interface `+0x40` retaining its initialized zero, the reviewed open
bridge gives descriptor `0x40000`. Its bit19 is clear and its masked
`0x60000` value is not `0x20000`, producing `eusb2phy_init(false, false)`.
That branch sets the offset-eight `0x7000` family, matching Linux's
`PHY_MODE_USB_HOST` operation. This narrows the host-startup polarity question;
it is not a universal role-enum definition, a device-mode trace, or proof of
physical behavior. No polarity patch follows from this evidence. Timing,
argument-dependent signal changes, reserved-bit handling, and other power
transitions remain open. The T8160 comparison call at `...b57e0cc` belongs
to `setPowerStateGated`, not `start`; it is not used as the Studio-class join.

The full-body power review now identifies a use of **both** initialization
booleans near the final write (`0xfffffe000a1d1b8c..0xfffffe000a1d1ba4`).
The native code preserves the base register's upper bits, replacing only
bits 0–2 with zero when both booleans are true, or two otherwise. Linux's
retained `atcphy_usb2_power_on()` instead writes the whole base word as two.
The known descriptor gate excludes the false/true pair before this caller's
initialization dispatch; the helper's truth table is not proof that every
input pair is reachable. The later host-startup join supports the narrowly
scoped upper-bit-preservation patch described below; it does not justify
changing Linux's mode value or claim a physically observed failure.

Native init also clears control bits `0x8`, `0x1`, `0x2` at resource-zero
offset four, sets bit `0x4`, then clears clock-gate bits `0x20000000` and
`0x40000000` at offset `0x1c`. The corresponding Linux fields/order overlap,
but neither that overlap nor the final register values prove equivalent
sequencing: native calls include `IOSleep(10)`, `IODelay(10)`,
`IODelay(30)` and `IOSleep(5)`, with intervening resource-one operations.
Apple's kernel API documents
[IOSleep in milliseconds](https://developer.apple.com/documentation/kernel/1575320-iosleep)
and [IODelay in microseconds](https://developer.apple.com/documentation/kernel/1575328-iodelay).
Linux's retained path uses `udelay(10)` calls. These observed software delays
do not establish the hardware's minimum timing requirements. No timing or
role-mode change is being copied into Linux without the remaining contracts.
Full views and the original-image/source byte checker
are retained under `scratch/j575d-usb2-power-order-2026-10-10/`.

The subsequent signal CFG audit corrects the earlier scratch power report's
description of bits `0x4/0x8` as "status-conditional". The first initialization
boolean selects two separate paths: true clears role bits `0x7000` and ORs
signal bits `0x1`, `0x2`, `0x4`, `0x8`; false sets role bits `0x7000` and ORs
only `0x1`, `0x2`, preserving bits `0xc`. Diagnostic branches after those
writes select logging, not additional signal writes. The false path bypasses
the OR4/OR8 blocks and rejoins at `0xfffffe000a1d0d28`. The later resource-one
offset-`0x20` read does not control this earlier sequence. The checked receipt
`scratch/j575d-usb2-signal-status-2026-10-10/verify.py`
(SHA-256 `cda4fc9f1c8baa2c1953c777e4cffbbfb1e87971bff29f4c2b19d0851ab057a0`)
compares all 1,111 consecutive CFG instructions with the original collection,
plus 40 selected anchors and pinned helper hashes. This supersedes the old
power verifier's printed "conditional/preserved" interpretation; byte checks
alone did not prove that interpretation. For the traced host-startup path,
native ORs `0x3` where Linux ORs `0xf`. No signal patch is included yet:
role-transition behavior and the appropriate Linux lifecycle location remain
to be checked. This is a static operation difference, not an observed physical
failure or hardware qualification.

The event operation supplies a narrower mapping correction candidate.
Native init reads mapped resource one (`this+0x230`) at offset zero,
ORs the value with `0x9`, then writes it back. Its diagnostic field names
are `AUSBC_CORE_EVT_BLK_C0_USB2_CTL.LOAD_CNT` and `EVT_EN`.
Linux's event operation also sets those two bits with a read-modify-write,
but uses its named `core` bank. The local T6031 descriptor selects the
T8122 generation and therefore reaches that operation. The captured native
event window for the first PHY is `0x702800000`, whereas the candidate's
core window is `0x703000000`; these are not the same physical address.
This is evidence for a separate event mapping, not hardware proof that the
two windows cannot alias or that the entire USB2 sequence is qualified.

The original-image and same-node capture check passes for all six ports;
the candidate core addresses below include the second die's parent-range
translation. Each captured event window is `0x4000` bytes and lies
`0x800000` below that port's candidate core window.

| PHY | Captured event base | Candidate core base |
|---|---|---|
| `atcphy0` | `0x702800000` | `0x703000000` |
| `atcphy1` | `0xb02800000` | `0xb03000000` |
| `atcphy2` | `0xf02800000` | `0xf03000000` |
| `atcphy3` | `0x1302800000` | `0x1303000000` |
| `atcphy0_die1` | `0x2702800000` | `0x2703000000` |
| `atcphy1_die1` | `0x2b02800000` | `0x2b03000000` |

The checked verifier is
`scratch/j575d-usb2-resource1-2026-10-10/verify.py` (SHA-256
`04eb822d95cf6f7e0b104956c465ec2ac240c8c70c56c3ac495b091bd356c26a`).
Its negative controls mutate the actual captured bank, swap two real port
headers, and move a valid parent memory property into a descendant; each
fails its designated check.

Follow-up patch `0008-apple-atcphy-m3-usb2-event-resource.patch` introduces
a T6031-only `usb2-event` resource. It leaves legacy chips on the core bank
and preserves the existing event bits, operation order and delays. Missing
or undersized M3 event resources and mapping errors fail probe before
`atcphy_probe_finalize()`; there is no M3 fallback to the old core address.
The follow-up DT builder appends the named window to those six calibrated
nodes, preserving all other properties and the seventh, unwitnessed disabled
PHY. Parent-range translation, DTC tree roundtrip and reservations are checked.
The delta is 12 properties relative to the USB-common candidate, and remains
42 distinct properties relative to the earlier pre-calibration baseline.
Host tests compile the patched resource mapper, power-on function, hardware
descriptors and register helpers from the real source with ASan/UBSan.
Seven tests pass, including M3 mapping failures, mapped-resource-to-power-on
execution, register-bit preservation, T8103/T8122 behavior, and an exact
T8122 write/delay comparison against the independently extracted unpatched
function. Wrong-core targeting, missing-resource fallback and a disabled M3
descriptor flag each fail their designated runtime check. Probe error cutoff
is checked at source level, not by executing the complete probe in this fixture.
Five DT tests pass. The combined patch builds all 20 modules in
`scratch/j575d-phy-usb2-event.afKoek/`; dependency checks are clean and the
original kernel image and built-in ABI artifacts remain unchanged. All 109
build/package checksum entries were verified. Final targeted binding validation
passes 16 cases (seven accepted, nine rejected), with each negative requiring
the intended node, schema and constraint in the same diagnostic. Enabled
event-only and Fabric-plus-event forms pass; enabled M3 forms missing the
event bank fail, including absent status. The existing binding already rejects
a sole `apple,t8122-atcphy` compatible, so that control is not a regression or
a new promise of legacy DT support. T8122 driver behavior is tested separately.
The standalone binding-doc check still reports an unresolved USB-switch
reference; the merged full-schema fixture resolves it. Disabled-node acceptance
alone does not establish validation of every constraint, and this targeted run
does not replace the outstanding whole-board schema work. See the
[event integration inventory](inventory/j575d-usb2-event-integration-2026-10-10.json).
No modules were installed and no native boot is approved by this mapping change.

Follow-up `0009-apple-atcphy-m3-usbctl-preserve.patch` replaces only the M3
USBCTL whole-word write with `mask32(USB_MODE, RUN)`: `(old & ~7) | 2`.
A dedicated `preserve_usbctl_upper` descriptor flag is true only for T6031;
it is independent of the event-resource mapping flag. T8103 and ordinary
T8122 retain the whole-word write. Mode two, signal writes, delays, role
selection and power-off behavior are unchanged. This follows the retained
native register operation, not a claim that the upper bits' hardware meanings
or physical USB operation are qualified.

Five source-extracted ASan/UBSan host tests pass in both main and independent
runs. They cover zero/nonzero M3 USBCTL values, legacy write behavior,
M3 write/delay interleaving against the exact after-0008 source, an exact-exit-1
whole-write mutation witness, and source equality for role-setting, power-off,
mapping and helpers. A fresh combined 20-module build in
`scratch/j575d-usbctl.w3QGd5/` passes with empty dependency diagnostics;
all 111 build/package checksum entries verify. The driver matches the host
fixture's source hash; the binding, original kernel image and built-in ABI
artifacts are unchanged. No fresh DT/schema qualification is claimed, since
this patch changes neither the DT nor binding. See the
[USBCTL inventory](inventory/j575d-usbctl-preserve-2026-10-10.json).
No package was installed, no VM changed and no native boot performed.

The next lifecycle audit joins `apple,sn201202x` to `tipd_sn201202x_data`
and the CD321x status worker, not generic TPS6598x or TCPM attach handling.
That worker can switch an active role to NONE before updating the mux and
launching the new role; its update-mode call need not invoke the mux callback
when the lane configuration is unchanged. Consequently, a role transition
cannot be assumed to rerun `atcphy_usb2_power_on()`. The Apple DWC3 callback
sets the USB2 role before reset deassert/core initialization; with the ATC
reset provider, its preceding active-role teardown asserts reset and calls
`atcphy_usb2_power_off()`. The retained source audit is
`scratch/j575d-usb2-signal-lifecycle-2026-10-10/report.md`.
This is source ordering, not proof of physical power state or timing.

The subsequent retained-binary device trace closes the T8122 XDCI start
dispatch to `AppleUSBXDCIARM::start`, the Type-C PHY USB2 factory, its
`self+0x2680` interface field, and the conditional interface-open call in
`powerOn`. That call supplies flags `0x20000`, compared with `0x40000` in
the previously checked XHCI host startup. The strengthened device verifier
checks the base-start chained pointer, exact metaclass symbol address, and
all 70 consecutive instructions from `0xb41cad4` through `0xb41cbe8`
against the original collection. Its SHA-256 is
`0b6155b172125eb2502a8b38da768f4608340e196bf8dfb9bbcf65d8a8dab978`;
see `scratch/j575d-usb2-device-role-2026-10-10/verify.py`.
The main rerun passes, as do the existing factory, host receiver, descriptor
bridge and SIG control-flow receipts.

Combining those bounded traces, **if the interface descriptor field retains
its factory-initialized zero**, OR-ing the device open flags yields native
init booleans `(true, false)`; the host flags yield `(false, false)`.
This is not a proof that no intervening writer changes that field or that
every open path uses these flags. The native false branch preserves SIG
bits `0xc`, rather than clearing them. A proposed common `OR 3` plus device
role `OR 0xc` therefore commutes at the register-value level; callback order
alone does not require stored role state. Linux power-off contains no explicit
SIG write, but that does not establish retention across hardware reset.
No SIG patch or hardware qualification follows from this checkpoint alone;
descriptor lifetime and physical reset/timing behavior remain distinct gates.

The follow-up bounded lifetime audit verifies the factory, argument forwarding,
initializer and open-read spans against original bytes. Its direct-immediate
store scan finds only the initializer at `0xa1cad38`; this is not a proof
against computed, pair/vector or external alias writes. Based on the reviewed
caller paths, experimental optional patch `0010` now implements T6031-only
SIG handling: power-on ORs `3`, device mode additionally ORs `0xc` after the
existing HOST-bit clear, and host mode preserves `0xc`. A dedicated descriptor
flag leaves T8103/T8122 unchanged. It adds no stored role or callback and
changes no delays, reset handling, power-off, USBCTL or binding. Device mode
does gain one register read-modify-write; native timing is not reproduced.

Nine source-extracted ASan/UBSan tests pass in implementer and main runs.
They exercise both actual power-on/set-mode callback orders, host/device
transitions without power-on, all 16 initial low-nibble values with upper-bit
seeds, invalid-mode rejection, exact legacy traces and the M3 power-on trace
outside its first SIG value. Three designated mutations fail with exact
exit 1. A fresh combined 20-module build in
`scratch/j575d-usb2-role-signals.C3wVyi/` passes; dependency diagnostics are
empty and all 113 manifest entries verify. The host fixture and build use
byte-identical patched drivers, and the original kernel image and built-in
ABI remain unchanged. See the
[role-signal inventory](inventory/j575d-usb2-role-signals-2026-10-10.json).
This is an offline software checkpoint, not complete USB2 initialization or
physical role-switch qualification. The candidate providers remain disabled;
no installation, VM change or native boot occurred. Reset/timing behavior,
CIO80 and the remaining Type-C selection/IRQ contracts are still outstanding.

The 0010 package now has a separate build-only diagnostic initramfs at
`scratch/j575d-initramfs.AxUPO0/output/initramfs.cpio.gz`, SHA-256
`807b823e87a53304106e5f49e48ed5fc918040f21570cbc77e87df26df5613ee`.
The isolated network-disabled build returned zero, all 11 build receipt
checksums pass, and `/init` is byte-identical to the earlier VM-tested
diagnostic executable. This archive has **not** been booted; the existing
inline loader package was not rebuilt or promoted. The experimental PHY
patch and disabled-provider qualification boundaries are unchanged.
Independent gzip/newc extraction confirms that all 35 package files,
including the 20 modules and their metadata, match byte-for-byte and that
all 20 `modules.load` paths exist in the archive.

The next bounded comparison finds no additional CTL, MISCTUNE or USBCTL
operation/order mismatch in the reviewed host/device startup paths. Both
reviewed descriptors have bit 19 clear and select native RUN `2`; the native
low-`0` branch needs the separate masked descriptor form `0xa0000`, not either
reviewed startup descriptor. Shutdown remains different: native sets port
reset before OR-ing USBCTL with `4`, whereas Linux first replaces the USBCTL
mode field with `4`, then sets SIDDQ and port reset. Linux also clears
APB_RESET_N with no counterpart among the six reviewed native shutdown
writes. These differences do not establish interchangeable controller
lifecycles or justify a shutdown patch. Native delay units are known;
hardware minima and reset effects are not. See
`scratch/j575d-usb2-sequence-gap-2026-10-10/report.md`.

The retained service snapshot now joins all six `atc-phy` nodes' `acio-phy-cpu`
properties (`0x7f`, `0x81`, `0x83`, `0x85`, `0x87`, `0x89`) to matching
RTBuddy ACIOPHY0–5 route keys. It explicitly witnesses CIO80 MBI endpoint
services for ACIOPHY0, 2 and 3; it does not establish absence of the others.
A new receipt checks all 133 MBI-start instructions against the original
collection, pins its inputs, and checks the captured ATC/route associations;
the main rerun passes. Verifier SHA-256:
`18bbe7b8600512e733fe2172df9a101d7b411959385fffde0580963f6b3d16b4`, at
`scratch/j575d-cio80-gap-2026-10-10/verify.py`.
The older `followup/verify-cio80-edge.py` checks text patterns and reports
hashes; it does **not** itself validate original bytes or chained pointers.
The new receipt strengthens the MBI-start span only, not every prior CIO
dispatch assertion. Linux resource ownership and mode/lifecycle equivalence
remain open; the next check is the captured ATCPHY memory-window crosswalk,
not aliasing CIO80 to USB4 based on its name.

The subsequent original-byte audit corrects an older CIO dispatch claim:
the T6032 constructor installs the vtable address point at symbol `+0x10`.
Using the symbol itself shifts every runtime slot by two entries. The
reviewed CIO-client tail at `0xfffffe000a209654` uses runtime slot `0xa08`,
which resolves to `shutdownACIOS2RtoOff`, **not** `initACIO`; its argument
`2` therefore does not prove the previously claimed initialization edge.
Independently, `initACIO` calls runtime `0xbc0` (`aciophy_phy_init`), and
that wrapper calls runtime `0xbb0` (Part B). The generic tunable dispatcher's
mode-2 branch calls CIO (`0xbf0`) then tail-calls CIO80 (`0xbf8`), so that
helper evidence remains valid. The actual client initialization branch is
still being traced; the rejected shutdown edge does not prove absence of
an initialization path.

Main reran `scratch/j575d-cio80-apply-selector-2026-10-10/verify.py`:
**1,618 contiguous instructions match the original collection**, and eight
address-point-relative targets pass chained-pointer membership/target checks.
The receipt pins both fixup helpers and the original/disassembly inputs;
its SHA-256 is
`617ffefea617e9f0c2b050278e8426e9484f6117e43e7b15468468c6c72a4756`.
Its spans cover the constructor address-point setup, complete reviewed
CIO-client function, `initACIO`, physical-init wrapper, generic dispatcher,
CIO80 helper, and the selected `applyTunables` resource-access prefix.
This is static byte/control-flow evidence, not execution, PAC validation,
resource-initializer proof or Linux lifecycle equivalence. The USB-common
0005 patch does not rely on the rejected client edge: its separately
reviewed USB-helper evidence and constrained Linux mode mapping remain,
without gaining CIO80 or hardware qualification from this correction.

The static CIO80 resource crosswalk now checks all 42 captured `reg` and
`IODeviceMemory` tuples for each of the six controllers. It also decodes
30 original-binary `_sRegisters` cells: selectors 3, 16, 18, 25 and 27
select addresses at core offsets `0x400`, `0x9000`, `0xb000`, `0x19000`
and `0x1b000`, respectively, each with length `0x4000`. Adding the five
helper-local offsets reproduces the retained decoder's core-relative
targets (`0x41c`, `0x935c`, `0xb008`, `0x1935c`, `0x1b008`). Main reran
the crosswalk successfully; verifier
`scratch/j575d-cio80-resource-crosswalk-2026-10-10/verify.py` has SHA-256
`b9ff3308995f901d657fdcda6601b7e009fc2b2795d21b7270348326805d2b77`.

A separate main receipt checks all **1,007 instructions of `start()`**
against the original collection, including the table-to-descriptor copy:
`scratch/j575d-cio80-apply-selector-2026-10-10/verify-initializer.py`, SHA-256
`a1f89d130136fee3ddd43b5e9f9c80a4e5ee70c965da131bc20b8455fe8749a6`.
Descriptors are at `self+0x208`, stride 32. Their `+0x10/+0x18` fields
receive the static address/length pair; `+0x8` receives
`table_address + slot_0x138_result - getPhysicalAddress_result`, not a
second independent physical base. The initializer enumerates provider
mappings and tests containment, so overlapping host windows do not justify
equating the descriptor selector with the provider mapping index. Concrete
provider-method identity, runtime mapping, Linux mode/lifecycle correspondence
and physical operation remain unqualified. These checks establish intended
static addresses, not permission to apply CIO80 settings or enable a PHY.

Controller-node coverage is distinct from PHY readiness. The retained event
candidate has seven DWC3 nodes: six have no `status` property and one is
explicitly disabled; all seven referenced ATCPHY providers remain disabled.
Direct reads of the candidate DTB confirm that each of the six witnessed
controllers uses the same ATCPHY phandle for its reset and both PHY arguments
(`3` for USB2, `4` for USB3), and that each reset provider has zero reset cells.
Each controller's compatible pair includes `apple,t8103-dwc3`, which matches
the retained driver's OF table. The first string, `apple,t6031-dwc3`, is absent
from the retained binding enum, so the schema gap does not demonstrate a
missing runtime driver match. Existing `modules.builtin` DWC3 entries are
built-in metadata, not packaged loadable modules or proof of physical probe.
The controller graph still requires qualification of its IRQ, DART, power,
reset, PHY and Type-C endpoints before enabling the providers. The seventh
unwitnessed port remains disabled. No controller-driver extension or compatible
substitution is justified by the schema omission alone. See
`scratch/j575d-usb2-controller-closure-2026-10-10/report.md`.

Hardware-qualified polling and CIO80/USB2 still require the
remaining contracts. Pro consult
`01M4EWE11E4FR4ZNSBYPZBFKYQ` has since completed (channel message 18760),
and its Linux source references were checked. It supports developing an
[optional offline polling prototype](j575d-select-polling-prototype.md)
at the logical SPMI API boundary. The prototype requires observed matching
busy then ready on every selection; this rejects ready-only traces but does
not establish a hardware command epoch. The sanitized actual-source host
suite and exact-exit-1 mutation control pass, as do two valid/seven invalid
binding fixtures and the ARM64 20-module dependency build. The three TIPD
modules and corrected SPMI controller module are packaged offline.
Empty-interrupt schema validation is limited by
a cached dtschema decoder crash; runtime zero-entry rejection is tested.
The normal build recipes include the FIFO correction but do not enable
experimental polling; the 822-record disabled candidate remains unchanged.
The earlier October 8 Linux API checkpoint at 04:16 UTC returned `7b63ef2d`;
this is historical evidence, not a current-head claim. The retained source
pin is unchanged. See the [integration inventory](inventory/j575d-phy-fabric-integration-2026-10-08.json).

At the earlier 14:04:34 UTC checkpoint, the official-API refresh returned HTTP
200 for all four endpoints;
m1n1 `2460b604`, Linux `602042bf`, and QEMU `f9587d40` remain unchanged from
13:24:05 UTC. No upstream updates were applied.

Here, **native validation means bare-metal execution**, outside macOS, not
the QEMU/HVF VM. HVF runs guest CPU instructions on the host CPU but exposes
virtual hardware; it cannot validate the Studio's physical SoC initialization.

Bring-up priority is distinct from completing every SoC capability. The first
serial/PID1 RAM-only boot does not require CIO80/USB4 or storage/network DMA;
its outstanding gates are native loader/entry, physical memory placement,
CPU/interrupt/console/power contracts and recovery readiness. Internal NVMe
uses the separately documented SART/mailbox/RTKit/reset/PMGR path; do not add
PCIe/DART as a prerequisite merely because it is NVMe. Built-in AQC113
Ethernet does require its PCIe/DART/power/IRQ/DMA path. CIO80 and the missing
USB4 pipehandler remain in the full SoC scope, but are not prerequisites for
those three milestones. Prioritize the remaining first-boot contracts before
further optional Type-C capability tracing; native testing still requires a
verified backup, recovery readiness and separate approval.

The first-boot audit on October 10 found no retained authoritative physical
handoff ledger to replace the synthetic placement fixtures. Native RAM and
reservation addresses, entry state and usable console transport remain
unobserved. Repeating those fixtures cannot close that gap. Ask Adam for
backup/recovery readiness and direction before native evidence collection;
separately resolve the existing m1n1 source-policy hold before resuming
source-based loader work. Building the new module initramfs above resolves
an offline integration gap, not either of these prerequisites.

Later on October 10, Adam explicitly authorized AI-assisted changes in our
own m1n1 fork and created `https://github.com/flound1129/m1n1`. The local
m1n1 source-policy hold is therefore lifted; older hold references above
are historical. No patches are to be submitted to upstream m1n1 while its
policy remains unchanged. Adam authorized direct pushes to the fork without
PRs. Backup/recovery readiness and separate approval for native execution,
firmware, boot-policy or disk changes remain required.

The fork's `main` now contains all 32 patches from the tested
`xz-seek-guards` series as individual commits, plus the fork-specific agent
policy commit, pushed directly and confirmed through GitHub at
`b91ede42c1eabe5feaebe575df0016191f003ac5`. No PR or upstream submission was
created. Its starting revision `7f208771` adds only two upstream Rust/build
changes to our tested `2460b604` baseline. Imported C/Rust sources and the
changed Python helper match the retained full32 tree byte-for-byte (excluding
patch-tool backup files). A fresh offline build passed at
`scratch/m1n1-fork-build.fHiV6m`, with all four artifact checksums verified.
This is not native boot qualification. The dedicated checkout is
`scratch/m1n1-fork.xd2NO8`; existing project build pins are unchanged.

| Workstream | Status | Next action / gate |
| --- | --- | --- |
| M3 persistent Debian VM | Previously validated; unchanged | Preserve working configuration; regression-test before promoting replacement QEMU |
| QEMU fork PRs 1–3 | Awaiting Adam's review | Review PMINTENCLR, PSCI and SDK27 changes; no merge or upstream submission assumed |
| QEMU regression / promotion | Pending qualification | Complete required SMP/PSCI, reboot and save/restore checks on the replacement binary; retain rollback |
| QEMU CPU feature coverage | Partial; separate from basic VM operation | Continue bounded feature probes where useful; do not treat optional gaps as bare-metal or VM blockers |
| QEMU upstream submission | Not sent | After approval, refresh/check patches and submit separate qemu-devel email series |
| M5 Max durable VM | Validated 2026-10-22; working copy running | `scripts/m5-vm.sh` controls the VM; persistence, key-only SSH, serial, DNS/HTTPS, reboot and clean stop/start pass; bridged LAN/NFS and CPU-feature qualification remain separate |
| M3 m1n1 capacity / handoff / loader | Full32 comparison builds, inline candidate/official packet assembly, payload tests and handoff fixtures pass; no native boot | Qualify physical placement/source backing and Linux entry; security findings are report-only, not bring-up gates |
| Exact T6032/J575d board DT | Disabled USB-common candidate integrates 822 records (750 generic plus 72 USB-only); follow-up adds six separate USB2 event windows and passes five DT tests/round-trip and 16 targeted binding cases | Triage 80 existing errors/86 unmatched compatibles (historical whole-board results); CIO80, USB2 and select IRQ remain open; no boot approval |
| T6032 SoC identity / CPU startup | Cached 32-CPU preflight, packed masks, caller and readiness guards adapted; source-extracted host suites pass | Preserve full comparison regressions; qualify cold reset, release sequencing and RVBAR only after safety gates |
| Secondary-start failure handling | RVBAR/start-timeout/status/index and stop/reset containment pass offline checks; current readiness placement checked structurally | Raw SMP proxy matrix remains structural; native reset/deep-sleep/first-registration identity unqualified; no degraded-SMP recovery claim |
| MCC/cache initialization | MCC/carveout/mapping/readiness guards adapted; 25-patch build, five current-source fixtures and linked layout pass | All 64 controller/plane contexts, register access, cache effects and DMA still need hardware qualification |
| Six-cluster frequency / DVFS | 0011/0023 failure containment preserved; 0029 prewait/reread, full27 build/layout and 90-case sanitized suite plus two controls pass independently | Safe raw APSC/default indices, physical busy/routing and feature/restore/voltage contracts remain open; default native dispatch disabled |
| Native console / interrupts / DMA | UART/AIC/PMGR descriptions checked; USB-extended 20-module closure builds/loads in RAM-only HVF; all four PCIe/DART status entries are enabled only in the host profile | Package/profile handoff, then qualify physical PCIe/DART layout, power/clocks, IRQ, DMA and driver binding on native hardware |
| RAM-only Linux diagnostic boot | Final USB-extended initramfs HVF run loads all 20 modules, passes 30 markers and records 20 `/proc/modules` members; no native boot or hardware claim | Qualify physical backing/placement, bootargs, initrd window and kernel entry; verified backup/recovery and separate approval are required |
| NVMe / USB / Ethernet | 0008 event mapping passes seven host tests, five DT tests and 16 targeted binding cases; 0009 USBCTL preservation passes five tests; experimental 0010 M3 role signals pass nine sanitizer tests and a fresh combined 20-module build, with 113 build/package checksums verified | No package installed or booted; PHY providers remain disabled and select-polling default-off. Hardware response decoding, selector freshness/cursor-reset/controller equivalence and IRQ mapping remain unqualified; FIFO fixture does not prove ACK/reinitialization ordering. CIO80 protocol and USB2 reset/sequencing/timing remain open; bounded descriptor mapping and register-value tests are not physical validation. Physical power/clock/IRQ/DMA and PMGR clock contracts still need qualification |
| Recovery / boot-entry setup | October 14: successful interactive `bless` reported, Debian Boot System UUID selected by read-only check, reversible Recovery handoff rename complete; backup and USB-C data cable previously confirmed; DFU not exercised | Operator-controlled Startup Options into Debian Boot; stop at Recovery/installer screen before policy/custom-boot confirmation; native actions remain separately approved |
| Portable Debian UEFI disk | Two HVF cold boots, SSH/network and persistence checks passed | Preserve image; VM success does not qualify Apple physical boot |
| Minimal Apple boot stub | October 13 staging/admin audits passed for 142 records; October 14 authorization/startup selection and handoff recorded in the [handoff inventory](inventory/j575d-boot-handoff-2026-10-14.json); old space/mount measurements are historical | Full personalization, paired Recovery, custom-boot policy and native boot remain unqualified; legacy `schg` relevance remains unqualified; do not call the target complete or bootable |
| Offline stub extras / firmware inputs | Adapter outputs, extras and admin metadata staged; last recorded `stub_info.json` is `complete: false`; authorization/handoff completed later, but full personalization is not established | Paired-Recovery entry, then separately reviewed policy/custom-boot work; Linux runtime firmware remains later-profile work; no native install or boot approval |
| Linux storage / partitioning | User-created APFS container `F6577F6B-0EB5-4E21-9761-3EE18E4A2C29` on `disk7` has the System/Data/Preboot/Recovery roles; Linux root/ESP are outside this boot-stub target | The user-run `diskutil addPartition` command is historical; create Linux root/ESP only in a later, separately reviewed storage step |
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

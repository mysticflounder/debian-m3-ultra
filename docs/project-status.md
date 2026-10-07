# Project status — 2026-10-07 UTC

Updated at task completion. Source/offline validation is not native-hardware
validation. External PR, VM and MacBook states below are last recorded states,
not a fresh remote or live-machine check.

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
the declared register window, with the hardware qualifications below. The next
primary implementation task is whole-boot failure handling. The
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
Startup still ignores AIC initialization failure before SMP; this caller cutoff
is next. HV trace-index guards remain separate. No native execution or MMIO.

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
| M3 m1n1 capacity / handoff cleanup | Upstream supplies capacity/cleanup; missing half-open bounds adapted and built | Retain old baseline; native handoff still unvalidated |
| Exact T6032/J575d board DT | Validated offline; official Linux 7.3 DT source confirmed | Reconcile official DTS/bindings during kernel integration; retain handoff regressions, native behavior still unvalidated |
| T6032 SoC identity / CPU startup | Cached 32-CPU preflight, packed masks, caller and readiness guards adapted; source-extracted host suites pass | Preserve full comparison regressions; qualify cold reset, release sequencing and RVBAR only after safety gates |
| Secondary-start failure handling | RVBAR/start-timeout/status/index and stop/reset containment pass offline checks; current readiness placement checked structurally | Raw SMP proxy matrix remains structural; native reset/deep-sleep/first-registration identity unqualified; no degraded-SMP recovery claim |
| MCC/cache initialization | MCC/carveout/mapping/readiness guards adapted; 24-patch build, five current-source fixtures and linked layout pass | All 64 controller/plane contexts, register access, cache effects and DMA still need hardware qualification |
| Six-cluster frequency / DVFS | 0011 payload cutoff and 0023 first-cluster failure containment adapted; 24-patch build and 48-case driver/payload mock suite pass | Safe raw APSC/default indices, pre-existing busy state, routing and feature/restore/voltage contracts remain open; default native dispatch disabled |
| Native console / interrupts / DMA | ADT declared bounds/relocation and AIC aperture/stride guards pass host suites and 24-patch build; hardware unvalidated | Next: whole-boot AIC failure cutoff; HV trace guards separate. Physical mapping/aliasing, register semantics and UART/AIC/DART behavior still need qualification |
| RAM-only Linux diagnostic boot | Not attempted; gated | Complete early initialization, boot entry and recovery validation before approved native testing |
| NVMe / USB / Ethernet | Pending hardware bring-up | Reconcile source support, initialization dependencies and device-tree descriptions; test only after early boot |
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

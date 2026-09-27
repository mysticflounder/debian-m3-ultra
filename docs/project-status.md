# Project status — 2026-09-26

Updated at task completion. Source/offline validation is not native-hardware
validation. External PR, VM and MacBook states below are last recorded states,
not a fresh remote or live-machine check.

| Workstream | Status | Next action / gate |
| --- | --- | --- |
| M3 persistent Debian VM | Previously validated; unchanged | Preserve working configuration; regression-test before promoting replacement QEMU |
| QEMU fork PRs 1–3 | Awaiting Adam's review | Review PMINTENCLR, PSCI and SDK27 changes; no merge or upstream submission assumed |
| QEMU regression / promotion | Pending qualification | Complete required SMP/PSCI, reboot and save/restore checks on the replacement binary; retain rollback |
| QEMU CPU feature coverage | Partial; separate from basic VM operation | Continue bounded feature probes where useful; do not treat optional gaps as bare-metal or VM blockers |
| QEMU upstream submission | Not sent | After approval, refresh/check patches and submit separate qemu-devel email series |
| M5 Max durable VM | Setup requested; completion unconfirmed | Confirm MacBook setup and capture persistence, SSH, console, networking and restart acceptance evidence |
| M3 m1n1 capacity / handoff cleanup | Validated offline | Two separate patches, seven-case handoff suite and full firmware build pass; no native execution |
| Exact T6032/J575d board DT | Validated offline | Four handoff cases pass on pinned six-cluster DT; retain regression coverage, native behavior still unvalidated |
| T6032 SoC identity / CPU startup | Masks, complete 32-node preflight and caller rejection implemented; eleven-patch cross-build passes | Resolve boot-CPU RVBAR/entry/recovery gates before enabling dispatch |
| Secondary-start failure handling | Pre-release guards, fatal timeout and caller status implemented offline; T6032 frequency failure now rejects before SMP, nine sanitizer cases pass | Validate native reset separately; no rollback or recoverable degraded-SMP claim |
| MCC/cache initialization | Boot diagnostic geometry/writeback traced; AMCC/cache-status record names and fields corroborated by live published metadata; 897 additional raw words verified | Resolve parent field `+0x14`, actual cache-transition and TZ contracts; register scope, early access, loader containment and DMA remain native gates |
| Six-cluster frequency / DVFS | Conditional routing and OSData provider traced; die-1 selectors 33/37/45 identified and captured; 61 input/adjacent tests pass | Resolve effective die-count writer/allocation contract, safe raw APSC/default indices and early-boot prerequisites; native dispatch disabled |
| Native console / interrupts / DMA | Source descriptions present; hardware unvalidated | Validate exact boot-chain integration, then UART/AIC/DART behavior after safety gates |
| RAM-only Linux diagnostic boot | Not attempted; gated | Complete early initialization, boot entry and recovery validation before approved native testing |
| NVMe / USB / Ethernet | Pending hardware bring-up | Reconcile source support, initialization dependencies and device-tree descriptions; test only after early boot |
| Recovery / boot-entry setup | Unverified; blocks native execution | Verify recovery host, cable, procedure and console/proxy access; no boot-policy changes yet |
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

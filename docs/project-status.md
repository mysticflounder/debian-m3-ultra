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
| T6032 SoC identity / CPU startup | Mask selection plus complete 32-node metadata preflight implemented; six-patch build and host checks pass offline | Propagate failure through callers; resolve boot-CPU RVBAR/entry/recovery gates before enabling dispatch |
| Secondary-start failure handling | Pre-release guards and fatal-timeout containment validated offline | Post-release timeout is now fatal; native reset unverified, recoverable status/stop handling remains separate work |
| MCC/cache initialization | Layout problem reproduced offline; driver correction pending | Obtain T6031 regression evidence and implement bounded, fail-closed register selection |
| Six-cluster frequency / DVFS | PMGR metadata captured; matching binary consumers located | Complete field/branch semantics before selecting bases/offsets; address die-1 performance metadata separately |
| Native console / interrupts / DMA | Source descriptions present; hardware unvalidated | Validate exact boot-chain integration, then UART/AIC/DART behavior after safety gates |
| RAM-only Linux diagnostic boot | Not attempted; gated | Complete early initialization, boot entry and recovery validation before approved native testing |
| NVMe / USB / Ethernet | Pending hardware bring-up | Reconcile source support, initialization dependencies and device-tree descriptions; test only after early boot |
| Recovery / boot-entry setup | Unverified; blocks native execution | Verify recovery host, cable, procedure and console/proxy access; no boot-policy changes yet |
| Linux storage / partitioning | Researched only; not authorized | Verify backup, refresh disk identifiers/limits, choose layout and obtain approval; no USB/internal-disk changes |
| MacBook project migration | Planned, not performed | Agree on transfer/verification plan; no deletion of Studio project data |
| NFS follow-up | Deferred by Adam | Resume only when requested; historical VM NFS evidence is not native-driver validation |

Details: [CPU work](m1n1-t6032-cpus.md),
[startup contract](m1n1-t6032-startup.md),
[PMGR metadata](m1n1-t6032-pmgr.md),
[local PMGR binary evidence](m1n1-t6032-pmgr-binary.md),
[32-CPU mask comparison](m1n1-t6032-cpu-masks.md),
[mask contract and mode selection](m1n1-t6032-mask-contract.md),
[whole-inventory preflight](m1n1-t6032-inventory-preflight.md),
[offline build and handoff](m1n1-cpu-offline-build.md),
[SoC gaps](m3-ultra-soc-status-2026-09-26.md),
[persistent VM](persistent-test-vm.md),
[QEMU CPU plan](qemu-apple-host-cpu-passthrough.md).

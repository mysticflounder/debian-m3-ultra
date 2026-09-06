# M3 Ultra PSCI CPU off/on results

The patched QEMU fork passes all 76 secondary CPU offline/online cycles at
8/16/24/32 vCPUs, plus a 1-vCPU control. The guest kernel used here is
`7.1.10+deb14-asahi` from the builder image, not the persistent VM's stock
Debian kernel. These are QEMU/HVF virtual CPU tests on the M3 Ultra.

## Reproduced failure and fix

The two-vCPU baseline on Homebrew QEMU 11.1.1 panicked during the first
OFF→ON cycle: `kernel BUG at arch/arm64/kernel/smp.c:385`, followed by
`Attempted to kill the idle task!`. CPU1 had been reported offline; execution
then reached the nonreturning `cpu_die()` path. Evidence is retained in
`out/psci-matrix.r0KOjZ/smp-2/`.

The Arm HVF patch fixes two related state-handling gaps:

- CPU_OFF, SYSTEM_OFF and SYSTEM_RESET leave the HVF execution loop with
  `EXCP_HLT`, allowing queued power-off work to run before guest reentry.
- Successful CPU_ON synchronizes the target's reset state after its queued
  reset work, so HVF receives the new entry PC and registers before reentry.

The halt-return change alone still reproduced the panic in the fork build
(`out/psci-matrix.UbI00m/smp-2/`). The combined change restored CPU startup
(`out/psci-matrix.mjJbMi/smp-2/`); that run then exposed a harness executable
placed on the guest's noexec `/run` mount. Moving the helper into the
disposable root overlay completed the workload check. The passing two-vCPU
smoke is `out/psci-matrix.DfkSw2/manifest.json`.

The patch is confined to `target/arm/hvf/hvf.c`. CPU_ON synchronization uses
the existing target-vCPU work queue and waits with BQL released. It makes a
successful CPU_ON wait for that synchronization; errors keep their previous
return behavior. Other architectures and accelerators are not modified.

## Validation

Run `scripts/psci-vm.sh` with `QEMU` set to the patched binary. CPU0 stays
online and controls the test. For each secondary CPU the guest verifies the
offline mask, online mask, singleton workload affinity, execution CPU, and an
arithmetic result. It restores the full mask before continuing. A second
clean boot checks persisted overlay state. The 1-vCPU run explicitly reports
secondary transitions as not applicable.

| vCPUs | Secondary cycles passed |
|---:|---:|
| 1 | Control; no secondary CPUs |
| 8 | 7/7 |
| 16 | 15/15 |
| 24 | 23/23 |
| 32 | 31/31 |

Full matrix evidence: `out/psci-matrix.EpBCcq/manifest.json`. All protected
hashes stayed unchanged, all overlays were removed, and temporary controls
were cleaned up. Tests use disposable overlays, with no network, firmware,
raw host disks, or host devices attached.

The patched binary also passed in-process guest reboot and shutdown at
1 and 32 vCPUs: `out/reboot-matrix.jCqznx/manifest.json`. Both retained the
same QEMU process through guest reset and passed the existing strict reboot
and cleanup checks.

`/bin/bash scripts/test-psci-fixtures.sh` checks generated guest shell syntax
and rejects incomplete, duplicate, and wrong-CPU transition evidence. It also
checks cleanup reporting for a skipped second boot. Historical failed-run
evidence is retained unchanged.

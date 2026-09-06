# M3 Ultra same-process save/restore

The QEMU/HVF same-process save/restore test passed at 1, 8, 16, 24, and
32 vCPUs (81 post-restore per-CPU workload checks). These tests use the Asahi builder kernel
`7.1.10+deb14-asahi`, not the persistent VM's stock Debian kernel.

## Scope and procedure

`scripts/save-restore-vm.sh` uses the patched local QEMU build with
`-cpu host`, HVF's kernel interrupt controller, 2 GiB RAM, and a disposable
qcow2 root overlay. Each CPU count runs inside one QEMU process with one
private QMP socket. This is same-process, same-configuration internal
snapshot restoration, not cross-process resume or cross-host migration.

The guest compiles `scripts/arm64-save-restore.c` and initializes a 4 MiB
RAM pattern and a synchronized disk sentinel. The host stops the guest and
saves an internal snapshot. After resuming, the helper mutates both RAM and
disk and acknowledges completion. The host stops the guest again, loads the
snapshot, then generates a fresh challenge and resumes execution.

Both QMP jobs must reach `concluded` without an error and be dismissed before
the harness advances. A successful command response alone is insufficient.
The restored helper must verify:

- the original RAM pattern and disk sentinel (disk reads use `O_DIRECT`);
- unchanged guest PID and Linux boot ID;
- a deterministic workload pinned separately to every configured vCPU;
- a newly created timerfd expiring and monotonic clock progression; and
- the fresh post-load challenge, preventing old serial output from passing.

The host also verifies unchanged QEMU process and QMP socket identities,
continued QMP responsiveness, clean guest-requested shutdown, overlay removal,
and unchanged hashes of protected inputs. Runtime artifacts and logs remain
in the evidence directory; the writable overlay is deleted after the run.

Timer coverage is deliberately limited: the timerfd is created after load.
This does not establish preservation of an already-armed timer or exhaustive
restoration of architectural state. One snapshot cycle per CPU count is a
correctness check, not a stress or longevity test.

## Evidence

- 1-vCPU smoke: `out/save-restore-matrix.v7MKpT/manifest.json` (passed).
- 8 vCPUs: `out/save-restore-matrix.mX75WZ/smp-8/evidence.json` (passed).
- 16/24/32 vCPUs: `out/save-restore-matrix.Qhaocr/manifest.json` (all passed).
- `/bin/bash scripts/test-save-restore-fixtures.sh`: 21 protocol/evidence
  checks passed, including sequential save/load against one accumulated QMP
  log, duplicate/wrong-type/error rejection, and invalid guest evidence.

The tests use QEMU fork commit `789e3d805f9ca84e64c40fe1b99129336ce911b8`
(the existing PSCI fix); no additional QEMU patch was needed for this matrix.
No network, firmware, NVRAM, raw host disks, or host devices are attached.
The persistent VM is not stopped or modified. The snapshot harness requires
6 GiB free space and caps each output file at 4 GiB.

The first 16-vCPU attempt in `out/save-restore-matrix.mX75WZ/smp-16/`
exposed a harness race, not a demonstrated QEMU failure. The guest emitted
all CPU checks and PASS, but the host captured an unterminated partial PASS
line and waited for that obsolete exact string. The run timed out and its
overlay was cleaned up; it does not count as a pass. The serial-reader fix
accepts only newline-terminated records, with a partial-record regression
fixture. Earlier failed evidence is retained unchanged.

To repeat the smoke or matrix:

```sh
SMP_LIST=1 scripts/save-restore-vm.sh
SMP_LIST="8 16 24 32" scripts/save-restore-vm.sh
```

The harness reuses the safety definitions from `scripts/reboot-vm.sh` through
a checked, retained regular-file extraction before its main-program boundary.
Both the original library and extracted definitions are protected inputs.

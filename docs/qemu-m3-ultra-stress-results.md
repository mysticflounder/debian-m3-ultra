# M3 Ultra bounded SMP and memory stress

The bounded gate passed at all five vCPU counts. This is a fixed-work correctness test, not a
throughput benchmark, thermal test, or long-duration stability qualification.

## Test contract

The test configures 1, 8, 16, 24, or 32 guest vCPUs. Each pinned worker owns
16 MiB, for a maximum 512 MiB test allocation inside the 2 GiB guest. Each
worker completes eight passes over its shard, checking address-dependent
patterns and their inverses. Barriers separate writing from checking, and
neighbor-shard reads exercise visibility between vCPUs. At one vCPU the
neighbor check is a self-check control, not inter-CPU evidence.

Workers also increment a shared atomic counter. The final count must equal
`vCPUs * 8 * 10000`; missing or extra increments fail. Per-CPU pass counts,
memory bounds, and execution affinity are checked, with a fresh host nonce
after completion to prove the same guest process still responds.

The host requires exact complete serial records for every CPU, the expected
total memory and atomic count, unchanged guest/process identity, responsive
QMP, and clean guest-requested shutdown. A timeout or incomplete evidence is
not a passing result.

## Safety and scope

The harness uses the existing patched QEMU fork, `-cpu host`, HVF's kernel
interrupt controller, and builder kernel `7.1.10+deb14-asahi`. It does not
exercise the persistent VM's stock Debian kernel or bare-metal hardware
drivers. Each writable root is a disposable qcow2 overlay over the protected
builder image. No network, firmware, raw host disk, or host device is attached.

Each QEMU launch is capped at 420 seconds by default (plus bounded termination
grace), and output files are capped at 256 MiB. Input identities and hashes are
checked, only owned test processes are stopped, and the persistent VM remains
untouched.

## Results

Validated on 2026-09-05 using the existing patched QEMU build; no new QEMU
patch was needed.

| vCPUs | Test memory (MiB) | Worker passes | Atomic increments | Result |
| ---: | ---: | ---: | ---: | :--- |
| 1 | 16 | 8 | 80,000 | PASS (self-check control) |
| 8 | 128 | 64 | 640,000 | PASS |
| 16 | 256 | 128 | 1,280,000 | PASS |
| 24 | 384 | 192 | 1,920,000 | PASS |
| 32 | 512 | 256 | 2,560,000 | PASS |

Across five runs, all 648 worker passes and 6,480,000 atomic increments
matched expectations. Each run passed the fresh-nonce response, retained
QEMU identity and QMP socket, and shut down cleanly. All overlays were
removed; all protected input identities and hashes matched before/after.
The no-VM suite passed 136 protocol/validator fixtures, including incomplete
and duplicate serial records, wrong counts, and identity/nonce mismatches.

Local evidence (generated artifacts, not tracked):

- One-vCPU smoke: `out/stress-matrix.wN0veh/manifest.json`.
- Remaining matrix: `out/stress-matrix.cJEfg0/manifest.json`.
- Each manifest's sibling `smp-N/` directory retains serial/QMP logs,
  launch arguments, and per-run evidence with protected input hashes.

This is one bounded run per count, not exhaustive memory-ordering coverage,
long-duration stability, or evidence for the persistent VM's stock kernel.
Pattern generation and expected-value checking share an implementation;
they are not an independent proof of CPU arithmetic correctness. Linux
CPU-feature selftests remain the next gate.

```sh
/bin/bash scripts/test-stress-fixtures.sh
SMP_LIST=1 scripts/stress-vm.sh
SMP_LIST="8 16 24 32" scripts/stress-vm.sh
```

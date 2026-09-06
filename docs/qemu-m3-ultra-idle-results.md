# M3 Ultra bounded idle and timer wakeup

All 1/8/16/24/32-vCPU runs pass, with 243 verified timer wakeups and low
measured host CPU use. This is a QEMU/HVF guest-idle test on the M3 Ultra,
not bare-metal power-management validation or a throughput benchmark.

## Measurement contract

Each configured vCPU gets a pinned guest worker. Workers block on timers
and verify execution after three ten-second waits. Guest Linux idle-time
accounting and per-CPU wakeup evidence distinguish successful wakeups from a
guest that merely remains reachable on its console.

The host uses the existing non-root QEMU thread CPU-time observer. It takes
the starting counter snapshot and acknowledges completion before the host
allows the guest to start its waits. The host requests the final snapshot
after receiving the guest's completion marker, while QEMU remains alive.
This host-observed window includes control/serial latency; it is not an exact
hardware WFI residency interval.

Report actual QEMU process, vCPU-thread, and management CPU-seconds separately.
Divide vCPU CPU-seconds by host elapsed seconds to express average host cores
consumed, or additionally divide by vCPU count for aggregate occupancy. These
are descriptive idle-consumption metrics, not fixed-work performance scores.
The observer checks stable vCPU thread identities and nondecreasing counters.
Sampling uncertainty and any permitted process/thread counter-skew clamp
remain in the retained JSON.

Low measured host CPU use together with Linux idle accounting supports the
conclusion that the tested guest can idle without sustained host spinning.
It does not count WFI instructions, prove a particular physical sleep state,
or exclude intermittent problems outside the measurement window. Wakeup
correctness and valid accounting are separate from the descriptive CPU-use
result; there is no arbitrary throughput threshold.

## Safety and scope

Tests use the builder kernel `7.1.10+deb14-asahi` with `-cpu host` and
HVF's kernel interrupt controller. Results do not cover the userspace
interrupt-controller path or the persistent VM's stock Debian kernel.
Only disposable qcow2 overlays are writable. No network, firmware, raw host
disks, or host devices are attached, and the persistent VM is left untouched.

## Results

| vCPUs | Wakeups | Host window (s) | vCPU CPU-seconds | Management CPU-seconds | Average host cores used by vCPU threads |
|---:|---:|---:|---:|---:|---:|
| 1 | 3 | 30.171211 | 0.035599 | 0.014636 | 0.001180 |
| 8 | 24 | 30.350452 | 0.101627 | 0.007816 | 0.003348 |
| 16 | 48 | 30.542792 | 0.159722 | 0.011751 | 0.005229 |
| 24 | 72 | 30.836019 | 0.218491 | 0.007710 | 0.007086 |
| 32 | 96 | 31.002195 | 0.272845 | 0.008271 | 0.008801 |

Every tested CPU accumulated positive Linux idle ticks and completed all three
wakeup/checksum checks. QEMU thread sets stayed stable and no process/thread
counter-skew clamp was needed. The 32-vCPU total is about 0.88% of one host
core, not 0.88% of all 32 cores. These samples show no sustained host-spin
behavior during the tested intervals; they do not establish long-run stability.

- Smoke evidence: `out/idle-matrix.HzHskQ/manifest.json`.
- 8/16/24/32-vCPU evidence: `out/idle-matrix.5qCzVt/manifest.json`.
- Each count retains raw serial per-CPU idle counters, QMP events, observer
  output, launch arguments, and before/after protected-input hashes.

All successful runs shut down cleanly, removed their overlays, and preserved
protected input hashes. No additional QEMU patch was needed. The host observer
compiles with strict warnings, its legacy/idle parser and zero-CPU fixtures
pass, and 20 harness protocol/accounting/FIFO fixtures pass.

```sh
/bin/bash scripts/test-idle-observer-fixtures.sh
/bin/bash scripts/test-idle-fixtures.sh
SMP_LIST=1 scripts/idle-vm.sh
SMP_LIST="8 16 24 32" scripts/idle-vm.sh
```

The harness rejects incomplete/duplicate markers, wrong thread counts,
invalid accounting boundaries, impossible occupancy, negative counters, and
inconsistent per-CPU wakeup evidence. Its window must last at least 30 host
seconds. Output files are capped at 256 MiB, and each test QEMU has a bounded
timeout. Compiled observer binaries and source inputs are hashed alongside
the immutable builder image; only owned test processes are stopped.

## Harness issues found before measurement

Preflight rejected the multiply linked `/usr/bin/clang` launcher. The harness
now resolves the real compiler using `xcrun --find clang` and supplies
`xcrun --show-sdk-path` explicitly as its sysroot. The single-link input check
was preserved.

The first booted attempt (`out/idle-matrix.0L0UOA/smp-1/`) failed while
transferring the guest source, before any idle interval. QEMU's stdio backend
makes its input descriptor nonblocking; the original parent FIFO descriptor
shared that open-file description. The larger write returned `EAGAIN`.
The host now reopens a separate blocking writer after autologin, and auxiliary
children close their unused serial descriptors. A bounded native FIFO fixture
checks independent flags and EOF delivery. The failed run's overlay was
removed; logs remain as failed evidence, not a passing measurement.

# T6032 frequency-init failure propagation

Offline Debian project work. No firmware was installed or executed, and no
hardware-register, boot-policy, disk or VM changes were made.

[Patch 0011](../patches/m1n1/0011-propagate-t6032-cpufreq-failures.patch)
changes only the kernel branch of `payload_run()`:

```c
int cpufreq_status = cpufreq_init();
if (chip_id == T6032 && cpufreq_status < 0)
    return -1;
```

This precedes the existing checked `smp_start_secondaries()` call, and hence
mitigations, TSO setup, device-tree preparation and kernel handoff. It calls
frequency initialization exactly once. Other chips retain their existing
best-effort frequency behavior; their existing SMP-result check is unchanged.

## Current unsupported path and future failures

On the pinned source plus patches 0001–0011, T6032 still has no cluster or
feature dispatch in `cpufreq_get_clusters()` / `cpufreq_get_features()`.
`cpufreq_init()` returns `-1` for either missing table before its cluster
programming loop. Consequently the new guard rejects the current unsupported
T6032 kernel path earlier than the existing closed CPU-start dispatch.
It does not add a frequency table, choose default/APSC states or enable CPUs.

A future supported initialization could fail after programming some clusters.
The new guard stops subsequent kernel-path work; it **does not roll back**
frequency changes, earlier initialization, loaded payloads or already-running
CPUs. Negative status means rejection, not a recoverable partial-start claim.

`chip_id` is the existing startup identity. An unknown value (`~0` initially)
is not classified as T6032 by this guard. Exact chip/board identity and the
other early-boot safety gates remain separate requirements.

## Unchanged callers and fallback

- Chainload returns before the kernel branch. Non-kernel paths do not acquire
  a new frequency-init call.
- `hv_init()` does not call `cpufreq_init()`; its existing SMP guard is
  unchanged. No frequency failure path is invented for HV.
- Proxy `P_CPUFREQ_INIT` already returns the function's result. Wire status,
  opcodes and all other proxy commands are unchanged.
- In `main.c`, `run_actions()` checks `payload_run() == 0`; a negative result
  follows its existing display/USB/proxy fallback. This is not a new recovery
  procedure or a global proxy command lockout. The fallback has not been
  validated on native T6032 hardware.

## Validation scope

[`test-m1n1-cpufreq-status.py`](../scripts/test-m1n1-cpufreq-status.py)
materializes hash-pinned source plus the existing CPU-status prerequisites
and 0011 in scratch. It extracts the real kernel caller prefix through
`mitigations_perform()` into a host-only harness with mocked frequency/SMP
operations. It does not run the complete payload, real frequency code or
hardware accesses. Source-order/scope checks complement the executed cases.

Nine cases pass under AddressSanitizer and UndefinedBehaviorSanitizer:
T6032 frequency results `-1`, `-7`, zero and positive; T6032/legacy SMP
failure after frequency success; legacy frequency failure/success; and the
unknown-chip sentinel `~0u` with frequency failure. The test checks exactly-once
calls and ordering, snapshots every materialized file to require that only
`payload.c` changes, and verifies that the prefix before the kernel branch
(including chainload) is unchanged. It executes only the kernel-true prefix;
chainload/non-kernel preservation is structural, not a simulated boot test.

```sh
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 scripts/test-m1n1-cpufreq-status.py
bash scripts/build-m1n1-cpu-offline.sh patched
```

The full offline build applies all eleven patches. The focused host test's
smaller prerequisite set is not represented as a full-series runtime test.
The [build record](inventory/m1n1-cpufreq-status-build-2026-09-26.json)
records the full-series artifacts and validation results.
The eleven-patch default cross-build passes with the same two warnings as
the ten-patch build. The existing SMP-status and runtime-mapping host suites
also pass against their respective seven- and ten-patch materializers.

## Driver-body host coverage — 2026-09-30

[`test-m1n1-cpufreq-driver.py`](../scripts/test-m1n1-cpufreq-driver.py)
adds a separate test of the real, hash-pinned `cpufreq.c` bodies rather than
mocking `cpufreq_init()`. It strips platform includes and compiles the source
with host MMIO/ADT/PMGR/polling mocks under ASan/UBSan. The eighteen-patch
series does not modify this driver file; its SHA-256 is
`d52a3c80a657485ba9288a91c7021fc90b4d1078f2e528091c212cd0f4b57b07`.

The five contract cases cover:

- T6032 initialization rejection and fixup skipping, with no MMIO events.
- T6031's three-cluster operation order: APSC request/poll, feature operations
  and waits, PMGR lookup, `0x440f8` restore write, then default request/poll.
- The existing equal-requested-state path, which skips writing and polling
  even when the mocked register also has the busy bit set.
- Busy-timeout and feature-wait failure: later operations on that cluster
  stop, but the outer loop still attempts the remaining clusters and reports
  failure overall.

Four controlled mutations must fail with the expected harness diagnostic and
exit status: unsupported-chip dispatch, feature-failure rejection, outer-loop
continuation and the restore write's position in the sequence. Compilation
failure, a signal or an unrelated sanitizer failure is not accepted as a
successful mutation check.

These are source-behavior tests, not approval of that behavior as a T6032
initialization policy. Poll completion and ADT/feature responses are simulated;
write values, elapsed timeout duration, electrical effects and hardware
readiness are not validated. The driver is unchanged. Its unsupported T6032
path and patch 0011's caller rejection remain in place.

Run independently of the nine-case caller harness:

```sh
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 python scripts/test-m1n1-cpufreq-driver.py
```

## Remaining gates

Resolve six-cluster/die routing, safe raw APSC/default indices, the
`0x440f8` operation, feature ordering and bounded polling before adding
frequency dispatch. MCC scope/protection, loader/DMA containment, boot entry
and recovery remain independent native-execution gates. This patch closes
one ignored-error path; it does not establish bare-metal readiness.

# T6032 CPU-start failure propagation

Offline Debian project work, 2026-09-26. No firmware installed or executed;
no MMIO, boot-policy, disk, or VM changes.

[Patch 0007](../patches/m1n1/0007-propagate-t6032-cpu-start-failures.patch)
adds a caller-visible result after the whole-inventory preflight in 0006.
The seven-patch default firmware configuration cross-builds successfully
with the same two existing warnings. T6032 startup dispatch remains closed.

## Contract

`smp_start_secondaries()` now returns a negative value for T6032 rejection.
Zero preserves the existing continuation policy for other chips; it does
**not** promise that all legacy CPUs started. The secondary leaf returns
false on pre-release rejection, true on an already-started or acknowledged
CPU, and retains the fatal post-release timeout from 0004. Allocation
ownership and reset-stack handling are unchanged.

For T6032, missing prerequisite nodes/register metadata, invalid inventory,
unsupported dispatch, absent boot CPU, leaf rejection, or missing secondary
acknowledgements reject continuation. The checks after dispatch are future
guards, not reachable native T6032 support: no T6032 case was added to the
startup switch.

| Caller | On negative SMP result | What is deliberately unchanged |
| --- | --- | --- |
| Payload kernel path | Return failure before mitigations, TSO, DT preparation or kernel handoff | Existing frequency-init prelude; main may enter its existing proxy fallback |
| Hypervisor initialization | Return failure before WFE, watchdog, page-table and hypervisor-register setup | PCIe/display/USB prelude and its ordering |
| Proxy SMP / HV-init commands | Set signed reply status `S_BADSTATE = -2` | Wire layout, opcodes and return-value field |

Existing Python clients already reject nonzero reply status with
`ProxyRemoteError`; no client protocol upgrade is required. A proxy failure
does not disable unrelated commands or establish a global command sandbox.

The caller preludes can have effects if firmware is eventually executed.
This patch neither moves nor rolls them back. It does not reclaim released
CPUs, implement recoverable degraded SMP, validate reset behavior, or make
native execution safe by itself.

## Validation

The [build record](inventory/m1n1-cpu-status-build-2026-09-26.json) records
the complete seven-patch cross-build and artifact hashes. Earlier bounds,
handoff, inventory and four-variant startup suites remain historical
regression controls, not evidence that every combination runs on hardware.

The dedicated host test, `scripts/test-m1n1-cpu-start-status.py`, passes
under ASan/UBSan. It executes source-extracted SMP functions with mocked
ADT/register access: missing prerequisite nodes/register metadata, malformed
inventory and closed dispatch reject T6032 while legacy continuation remains
zero. It also checks the leaf's pre-release boolean result, extracted caller
guards, both proxy cases' success/failure replies, and the pinned Python
client's actual signed-status decoder.

Payload/HV tests execute extracted guards in small mock callers and check
ordering in the real caller source; they do **not** execute complete payload
or HV initialization. The final all-secondary-flags check is source-checked
only: closed T6032 dispatch makes it unreachable in the unmodified test
function. No test-only native dispatch was enabled. Mock register operations
are not native register evidence. All earlier 71 Python regressions plus
bounds, synthetic/board handoff, inventory and four startup variants pass.

## Remaining gates and next work

Proceed to the MCC/cache register-layout correction and its T6031 regression
requirements, followed by six-cluster/two-die DVFS semantics. Native entry
level/features, MPIDR mapping, boot-CPU RVBAR policy, reset ordering and
recovery/console access still require separate evidence and authorization.
No passing host test or cross-build opens those gates.

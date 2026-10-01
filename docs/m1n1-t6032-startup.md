# T6032 CPU startup and execution-level contract

Offline audit, 2026-09-26. Source baseline:
`4184923ffb2dff079b384d6a32cc02142aa14572`. Local capacity and handoff-cleanup
patches do not change startup dispatch. No native code, firmware, MMIO,
boot-policy or disk changes are authorized by this audit.

## Identity is not enablement

The saved [CPU inventory](inventory/t6032-cpus-2026-09-26.json) identifies
J575d, chip `0x6032`, and 32 CPUs. The pinned `src/main.c:41–70`
`get_device_info()` reads the numeric `/chosen/chip-id`; it does not need a
`T6032` preprocessor constant to report the identity.

The pinned `src/soc.h` lacks that constant and a T6032 compile-time early-UART mapping.
Local patch `0005` now adds the identity constant for its
[mask preflight](m1n1-t6032-mask-contract.md), but still does not add a
compile-time UART mapping or a runtime T6032 CPU-start dispatch case.
Those omissions are distinct from runtime identification and runtime UART
discovery: `src/uart.c:17–39` selects `/arm-io/uart6/debug-console` or
`/arm-io/uart0` and translates its ADT register entry. `src/startup.c:194–203`
initializes UART before reading the chip identity. The assembly early debug
path uses `EARLY_UART_BASE` only when configured (`src/start.S:199`).

Consequently, adding a name or copying a known UART base is not CPU-start
support. Nor does a passing generic build prove the UART works on this host.
Actual startup requires independently supported register selection and entry
semantics, not just a chip-ID alias.

## CPU-start selection and address calculation

`src/smp.c:230–306` reads the PMGR base from ADT `reg[0]`, locates `/arm-io`
and `/cpus`, clears its CPU-node table, then selects a chip-specific start
offset. T6032 (`0x6032`) reaches the unknown-SoC return. This happens before
CPU enumeration, stack allocation or the secondary-start register writes.
It is a gate within this function, **not** proof that the entire boot image
has performed no earlier MMIO.

T6031 and several explicitly listed chips select `0x88000`; T6032 is not
among them. Subsequent [captured PMGR binary analysis](m1n1-t6032-pmgr-binary.md)
statically corroborates group 8 / map 0 / provider `reg[0]` / offset `0x88000`
and the die stride `0x2000000000`. This is stronger evidence than a compatible
string, but does not establish safe cold-boot access or release sequencing.
No production T6032 case is added.

For supported cases, `src/smp.c:308–394` builds the logical CPU table,
finds the boot CPU from ADT `state="running"`, decodes each secondary's ADT
affinity, and obtains `cpu-impl-reg` (with an older `/arm-io/reg` fallback).
`smp_start_cpu()` then uses these source-defined operations:

| Operation | Pinned implementation |
| --- | --- |
| Die-relative start base | PMGR base + selected offset + die × `0x2000000000` |
| System startup/status write | base + `0x4`, legacy non-T6032 value `1 << (4 * cluster + core)`; local T6032 helper uses the captured topology model |
| Core-start write | base + `0x8 + 4 * cluster`, value `1 << core` |
| Acknowledgement wait | At most 100 iterations, each delaying 1,000 μs if not acknowledged |

The die stride is defined in `src/pmgr.h:8`. Testing these calculations
against mocked writes verifies the implementation, not the register
semantics. In particular, the baseline formula produces overlapping bit positions
in the system startup/status expression (cluster 1/core 4 and cluster 2/core
0 both select bit 8). This is an unresolved semantics question, not proof of
a hardware bug or grounds to replace the formula speculatively. The subsequent
[mask preflight](m1n1-t6032-mask-contract.md) implements the captured mode-1
topology calculation offline; it does not enable register writes. Apple's path
writes the system mask and every cluster slice, including zero slices, whereas
the existing m1n1 release path writes the selected cluster only. Equivalence of
those side effects and their required ordering remain unresolved.

## Captured runtime callback path — 2026-09-30

The captured AppleARMPlatform binary narrows the CPU-release investigation:

| Anchor (unslid collection VA) | Static observation |
| --- | --- |
| `0xfffffe0008c946fc`, `0xfffffe0008c94700` | `AppleARMCPU::start(IOService*)` preserves provider in `x20` and `this` in `x19` |
| `0xfffffe0008c94cf4`–`0xfffffe0008c94d04` | Looks up `function-enable_core` through `AppleARMFunction::withProvider`, then stores the result at `this+0xd8` |
| `0xfffffe0007182746` | NUL-terminated `function-enable_core` string in the captured collection |
| `0xfffffe0008c95ecc`–`0xfffffe0008c95f24` | `startCPU(unsigned long,unsigned long)` tests bit 0 of `this+0xea`; when clear, calls the stored object's virtual slot `0x140` with `(1,0,0)`, then returns zero |
| `0xfffffe0007ff23f8` | Chained fixup for the base AppleARMFunction vtable slot (`vtable+0x10+0x140`) resolves to `callFunction` at `0xfffffe0008c97d30` |
| `0xfffffe0008c97d30`–`0xfffffe0008c97d80` | Base `callFunction` forwards its three arguments in `x4`–`x6`, reads target/data from object offsets `0x10`/`0x18`, and tail-dispatches the target's virtual slot `0x6e8` |

The wrapper does not forward its two incoming arguments or directly
write RVBAR. That is **not** evidence that downstream code does neither. The
base-class slot is resolved statically, not proof of the concrete runtime
receiver class. `withProvider` includes target lookup and alternate construction
paths; this initial checkpoint did not establish the provider, callback data or
concrete handler. The follow-up below advances that link. This remains a runtime
callback path, not an early-boot recipe.

Reproduction: run `scratch/mcc-evidence/verify-cpu-release-callback.py` with
the project's offline uv Python invocation. It verifies 2,273 instruction words
across four bounded extracts against both the inspection view and original
collection, plus the property string and vtable chain membership. Its SHA-256 is
`f5fb0e041a064b8c48324953761b02495fc903115546ea85c0cfe18b34b8056c`;
the report is `scratch/mcc-evidence/cpu-release-callback-evidence.json`.
The collection SHA-256 is
`a24fefccc060854cecc996b40983499e1319008e4f16c0717a5fef6c4d4828dc`
(125,992,960 bytes), with provenance recorded in the
[PMGR inventory](inventory/t6032-pmgr-binary-2026-09-26.json).
Independent receiver/prologue review agrees. These checks authenticate neither
Apple's signature nor live PAC, and do not establish a current-host image match.
No firmware was executed or register read.

### Provider-name and callback-data follow-up

A read-only, allowlisted IORegistry capture on J575d/T6032, macOS build
`26A428`, now records all 32 CPU callback properties and the PMGR parent-key
presence in [the callback inventory](inventory/t6032-cpu-enable-callbacks-2026-09-30.json).
No raw registry dump was retained. Each `function-enable_core` is exactly
12 bytes, interpreted as three little-endian 32-bit words:

| Word | Captured value |
| --- | --- |
| 0 | `0x182`, matching `/arm-io/pmgr`'s `AAPL,phandle` |
| 1 | `0x436f7265` (`Core` as a four-character integer selector) |
| 2 | `1 << cpu-id`, including `0x80000000` for CPU 31 |

`AppleARMFunction::getFunctionParentSymbol` calls the OSData byte accessor
and loads word 0 at `0xfffffe0008c97ce4`. It formats that value using
`IOFunctionParent%08X` (string VA `0xfffffe0007182fdf`).
`registerFunctionParentInternal` reads the property through the imported
`gIODTPHandleKey`, calls the same symbol helper at `0xfffffe0008c971ac`,
and sets the resulting key on its second service argument at
`0xfffffe0008c97224–0xfffffe0008c97234`. The queried AppleT6031PMGR service
exposes `IOFunctionParent00000182`. Only the key's presence and serialized
type are captured; its serialized bytes are not interpreted as an object.

This links the captured callback's parent identifier to PMGR registration,
without executing the callback. Metadata presence alone does not identify the
function subclass or prove a live handler invocation. The following separate
binary trace supplies the static subclass link:

| Step | Captured binary evidence |
| --- | --- |
| Factory request | `withProvider` loads its factory symbol from `0xfffffe000cc00be0` at `0xfffffe0008c976e0`; PMGR's comparison imports that same global through chained reference `0xfffffe00082a39d8` |
| `Core` selection | `ApplePMGR::callPlatformFunction` reads OSData word 1 at `0xfffffe0009b77f08`; selector comparisons at `0xfffffe0009b77f3c` and `0xfffffe0009b783e8` route `Core` to the specialized allocation/constructor at `0xfffffe0009b78410–0xfffffe0009b78418` |
| Concrete vtable | Constructor `0xfffffe0009bbe904` installs `ApplePMGRFunctionEnableCPUCore`'s vtable address point (`0xfffffe000829b580+0x10`); slots `0x138` and `0x140` resolve to its initializer and callback |
| Stored target and mask | Initializer `0xfffffe0009bbea10` calls the base initializer, casts its stored target to ApplePMGRBase and stores it at object `+0x28`; it reads OSData word 2 at `0xfffffe0009bbeaa8` and stores it at object `+0x30` |
| Enable call | Callback `0xfffffe0009bbe9bc` computes `enable=(arg1!=0)`, loads the stored mask into `w1`, and calls target slot `0xa88` at `0xfffffe0009bbea00` |
| PMGR target | AppleT6031PMGR's slot `0xa88` resolves to `ApplePMGR::enableCPUCores` at `0xfffffe0009b95c7c`, continuing into the previously traced `configMiscCores` path |

If the factory allocation and initialization succeed on the traced PMGR path,
the captured metadata produces a specialized callback forwarding
`(1<<cpu-id, true)` for the CPU-start invocation. It does **not** use the base-class forwarding body as
its callback. The fact that `enableCPUCores` itself calls slot `0xd20` is
the next call in the chain, not a conflicting slot assignment; see the
[mask/write-path contract](m1n1-t6032-mask-contract.md).
Allocation/initialization success and actual runtime invocation are not
observed here. This closes a static callback-to-PMGR link, not the native
RVBAR, reset-entry, release-order or early-initialization gates.

The local `scratch/mcc-evidence/verify-cpu-provider-evidence.py` checks
1,478 instruction words, the format-string bytes, twelve chained references
(including the concrete callback/PMGR slots and shared factory symbol), and all
32 callback records. Its SHA-256 is
`bdc8db520d7437de7e4f7f26646721e8cc67c7c2fbdc8e16b7d8dbf39b863804`;
the report is `scratch/mcc-evidence/cpu-provider-evidence.json`.
The live metadata build matches the recorded build label, not a newly
established byte-for-byte match of the running kernel collection.

## Execution-level and stack contract

The predicates in `src/utils.h:349–362` answer different questions:

| Predicate | Source input | Meaning in this code |
| --- | --- | --- |
| `in_el2()` / `in_el3()` | `CurrentEL` | Current execution level |
| `has_el3()` | Nonzero `ID_AA64PFR0_EL1[15:12]` | Whether to use the EL3 startup/stack path |

Thus EL2 execution alone does not justify bypassing `MAX_EL3_CPUS`.
`src/smp.c:118–146` rejects an index beyond the general limit, then rejects
indices 4 and above when `has_el3()` is true. That check precedes EL3 stack
indexing. The EL3 branch allocates separate EL3 and EL1 stacks; the other
branch allocates only the ordinary secondary stack.

The reset assembly (`src/start.S:147–194`) loads `_reset_stack` and branches
on `CurrentEL`. Non-EL3 entry calls `_cpu_reset_c()` directly. EL3 entry
calls it once for setup, then uses `_reset_stack_el1`, sets the return target
to `_cpu_reset_c()`, and executes `eret` into non-secure AArch64 EL1h.
`src/startup.c:218–241` performs the EL3 preparation or routes a non-EL3
secondary to `smp_secondary_entry()`. These are source observations; host
C tests cannot execute or validate that assembly transition.

## Failure handling: pre-release guards and fatal release timeout

The audit found existing control-flow hazards independently of the unknown
T6032 register map:

| Condition | Pinned baseline behavior | Local patch / remaining work |
| --- | --- | --- |
| RVBAR differs while `apple_sysregs_unlocked` is false | Logs a failure, then allocates stacks and issues start writes (`smp.c:127–165`) | `0003` returns before allocation or release writes; the existing predicate is unchanged |
| Stack allocation fails | Neither `memalign()` result is checked before pointer arithmetic (`smp.c:138–146`) | `0003` checks local allocations before publishing state; only an unpublished first stack is freed if the EL3 allocation fails |
| Secondary does not acknowledge | Bounded wait prints failure, then restores shared reset pointers and returns (`smp.c:166–180`) | `0004` enters the existing non-returning panic path before restoring pointers; no allocation or published state is reclaimed |
| Unsupported SoC or pre-release failure | `smp_start_secondaries()` is `void`; callers cannot inspect a result | `0007` propagates T6032 rejection through callers; legacy continuation is retained, recoverable degraded SMP remains separate work |

**Do not free a secondary's stacks merely because its acknowledgement timed
out.** The core may still enter late after the release writes. A safe timeout
design must retain/quarantine those allocations until cancellation or reset
has been established. Shared `target_cpu` and reset-stack state also cannot
be reused for another release while the first core could still enter late.
Pre-release allocation-failure cleanup is a different case and can be tested
independently.

In the pinned baseline, the direct-payload path calls `smp_start_secondaries()` and continues toward
`kboot_boot()` without receiving a status (`src/payload.c:316–350`); the
hypervisor and proxy callers likewise get none (`src/hv.c:56–66`,
`src/proxy.c:347–349`). `dt_set_cpus()` can prune secondaries whose alive flag
is unset (`src/kboot.c:573–581`). Therefore a bounded wait or unknown-chip
return does not by itself impose a whole-boot abort. This is a source control-
flow observation, not evidence that T6032 currently reaches Linux at all.

The separate [pre-release guard patch](../patches/m1n1/0003-guard-secondary-start-prerequisites.patch)
implements the first two corrections. Both required stacks are obtained
before clearing the spin table or changing `target_cpu`, the published stack
arrays, or reset pointers. On successful allocation, the original publication,
cache maintenance, barriers and release sequence are preserved.

The `0003` patch does not change the `void` API, SoC selection, EL3 limit,
timeout, or caller behavior.

The separate [fatal-timeout patch](../patches/m1n1/0004-abort-on-secondary-start-timeout.patch)
changes only the post-release timeout branch to `panic()`, before resetting
the shared stack pointers. This **intentionally makes an unacknowledged
release fatal on every supported SoC**, rather than allowing degraded boot
after an uncertain release. Successful starts, pre-release skips and the
polling deadline remain unchanged. Acknowledgement during the final delay
still reaches the existing timeout branch; no new final flag check is added.

The call-site audit found `smp_start_cpu()` is static and called only by
`smp_start_secondaries()`. A non-returning timeout therefore prevents that
invocation from progressing to another CPU, payload/kernel handoff, HV
initialization or proxy continuation. It needs no public ABI change or
new status protocol. Returning an error alone would not suffice: later
kernel handoff, proxy operations and teardown could still reuse uncertain
state. Recoverable operation would require explicit uncertainty tracking
and an independently established stop/reset proof.

This is a **control-flow containment measure, not proof of multicore stop
or successful reset**. `panic()` in `src/utils.h:447–451` prints and calls
`flush_and_reboot()` (`src/utils.c:129–132`). Console printing/flushing can
block on locks or device callbacks (`src/iodev.c:121–130,166–187,302–312`).
`reboot()` in `src/start.S:210–222` has an optional HVC path, arms the watchdog,
then loops forever. Watchdog reset is a no-op without a discovered base
(`src/wdt.c:51–58`). A late core may still enter while this terminal path
runs; its published stack and shared target are left intact. No test here
executes the real fatal handler, reset assembly or watchdog.

This patch does not fix best-effort secondary-stop timeouts, synchronous
SMP waits, or generic pre-release error reporting. Nor does it turn an
unsupported-chip return into a whole-boot safety gate.

## Missing evidence before enabling T6032 startup

1. Complete the T6032 CPU-start contract beyond the statically corroborated
   offset, die stride, callback path and conditional topology masks: establish
   whole-mask versus selected-cluster
   side effects, required release ordering/barriers and acknowledgement semantics.
2. Native boot-stage feature/entry evidence: `CurrentEL`,
   `ID_AA64PFR0_EL1`, boot MPIDR, RVBAR writability/value, and secondary entry
   level. Host inventory and HVF guest values do not establish this contract.
3. Recovery and console/proxy access verified before any native diagnostic.
   Even a RAM-only diagnostic executes privileged code and is not a macOS
   read-only inventory operation.
4. MCC and early frequency-initialization gates resolved before exposing a
   native Linux handoff. CPU-start-only tests must not bypass those gates.

More `ioreg` topology captures alone cannot fill the missing reset-time
register semantics. Offline failure-path hardening can proceed while those
hardware-evidence gates remain open.

The subsequent [whole-inventory preflight](m1n1-t6032-inventory-preflight.md)
validates every T6032 CPU's IDs, coordinates, boot-state string and explicit
implementation-register window before the existing startup loop. It avoids
the legacy fallback and copy-before-length-check helper. It is still not
whole-boot failure propagation, native RVBAR validation or dispatch enablement.

The subsequent [caller-status patch 0007](m1n1-t6032-start-status.md) returns
T6032 rejection through payload, HV-init and proxy callers. It preserves
legacy continuation policy and caller preludes, and leaves dispatch closed.

## Offline startup regression

The initial audit on 2026-09-26 passed the checks below against the original
startup implementation without changing firmware. The follow-up `0003`
patch adds pre-release guards; `0004` adds fatal timeout containment;
`0005` adds the T6032-only mask preflight. The runner compares four variants:
original, `0003`, `0003` plus `0004`, and then `0005` on top.
All four use CPU limits extracted from `0001`-patched `smp.h` (32 ordinary,
four EL3); "original" means original startup logic at that capacity, not an
unmodified 24-CPU firmware build.
The [three-patch build record](inventory/m1n1-cpu-startup-build-2026-09-26.json)
is retained, alongside the [four-patch build record](inventory/m1n1-cpu-timeout-build-2026-09-26.json)
and [five-patch build record](inventory/m1n1-cpu-mask-build-2026-09-26.json).
None of these builds was installed or executed.

All four startup variants pass under ASan/UBSan: the baseline retains the RVBAR
continuation negative control; the patched run rejects it and passes the
normal/EL3 allocation-failure cases. The allocator mock rejects foreign and
double frees, and failure fixtures check that prior published state survives.
The timeout tests use a non-returning mock intercepted with `setjmp`/`longjmp`.
They check retained normal/EL3 stacks, shared target and reset pointers,
absence of cleanup, and no caller continuation or subsequent release.
Original and `0003` variants reproduce timeout return and dummy-pointer
restoration as negative controls. Mock acknowledgements at delays 99 and
100 verify that the existing polling boundary has not changed.
The fourth variant additionally tests all 32 T6032 mask/address pairs,
per-die uniqueness, unchanged legacy masks for all 29 existing SoC constants
without ADT dependency, 24 rejected metadata/coordinate cases before startup
side effects, and preservation of output masks on helper failure. T6032
top-level dispatch still returns before starting a CPU. ADT CPU enumeration
is intentionally no-child mocked; these checks do not validate a complete
32-CPU boot transaction.
The existing 12 CPU, 15 MCC, CPU-bounds, seven synthetic handoff and four
board-DT checks also pass. The firmware build has no new compiler warnings
relative to the recorded baseline. These tests are not cross-machine native
regression coverage.

```sh
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 scripts/test-m1n1-cpu-startup.py
```

Preparation uses the pinned source described in
[the offline-build notes](m1n1-cpu-offline-build.md). The runner compiles
extracted C functions with host mocks under AddressSanitizer and fail-fast
UBSan. Numeric mock addresses are never dereferenced; register operations
only record calls. Stack storage is a host fixture, not firmware memory.
The runner checks source hashes for the startup implementation and relevant
headers, then extracts the functions, execution-level helpers and register
constants. Leak scanning is disabled for this harness; allocation uses static
mock storage and does not test the production allocator.

In particular, the pinned `src/dlmalloc/malloc_config.h` configures
`MALLOC_FAILURE_ACTION` to panic, and its `sbrk()` path calls
`heapblock_alloc()`, which can also panic. `panic` uses `flush_and_reboot()`
(`src/utils.h:447`). Thus a real out-of-memory condition may reboot before
`memalign()` returns NULL. The guards remain correct for a NULL return;
the fault-injection suite does not establish recoverable production OOM.

| Check | Expected outcome |
| --- | --- |
| T6032 chip selection | Unknown-offset return without secondary-start effects |
| T6031 / T6022 controls | Select existing `0x88000` / `0x28000` offsets |
| CurrentEL versus EL3 feature field | Independent predicates; EL2 does not imply `has_el3()==false` |
| Non-EL3 capacity / EL3 boundary | Ordinary index 31 can reach the mock start path; index 32 and EL3 index 4 cannot |
| Already-alive CPU | No new allocation or start writes |
| Two-die topology | Source arithmetic exercised across all 32 saved affinity tuples |
| Acknowledged / timed-out start | Early acknowledgement restores dummy pointers; timeout performs 100 mocked 1,000-μs delays |
| Fatal timeout, normal and EL3 | `0004` cannot return to caller or release another core; published target, reset pointers and allocations survive |
| Deadline boundary, normal and EL3 | Acknowledgement on delay 99 succeeds; acknowledgement on delay 100 retains the pre-existing timeout decision |
| Unwritable mismatched RVBAR | Baseline reproduces continuation; patched function returns before allocations or release writes |
| First allocation fails, with or without EL3 | Patched function returns without publishing state or freeing prior allocations |
| Second allocation fails under EL3 | Patched function frees only its new first allocation and leaves shared startup state untouched |

The selection fixture has no ADT CPU children: it checks dispatch and early
return, not end-to-end enumeration or CPU-property parsing. Direct calls to
the extracted per-CPU function bypass dispatch solely to check generic source
behavior, and do not establish T6032 support. No ARM reset assembly is run,
no CPU actually starts, and no real elapsed timeout is measured. Failed
allocation is injected by host mocks, not the production allocator. Baseline
NULL-pointer arithmetic is not deliberately executed in-process. Timeout
tests retain allocated stacks; they do not execute a late core, real panic,
console flush or reset, and do not validate late-core cancellation.

## Evidence boundary

The saved macOS inventory describes CPU topology, not reset-time `CurrentEL`,
physical CPU feature registers, RVBAR behavior or secondary acknowledgements.
QEMU/HVF guest registers are not substitutes for those native observations.

The four-entry EL3 storage limit remains unchanged. CPU count, current
execution level, and implementation support for EL3 must not be conflated.
No T6031 CPU-start offset is promoted to a T6032 fact by this document.

Source references are to the pinned revision, not a claim about the latest
upstream branch. This is AI-assisted Debian/project-fork work; no external
submission is part of this task.

# SMP shared-memory backport

2026-09-27. This is an offline source/build change, not a native boot result.
No firmware was installed or executed, no registers were probed, and no VM,
boot policy, partition or disk image was changed.

## Scope

The recorded sixteen-patch build used pinned m1n1
`4184923ffb2dff079b384d6a32cc02142aa14572` plus patches 0001–0016.
Patch [0015](../patches/m1n1/0015-smp-shared-memory.patch) adapts the upstream
shared-section design to our older dynamic-stack implementation. Patch
[0016](../patches/m1n1/0016-protect-smp-shared-mappings.patch) protects that
layout from later mapping changes and rejects unprepared MMU-on CPU startup.
The current default additionally includes patch 0017 for CPU-index validation;
see the follow-up below. The original sixteen-patch manifest is unchanged.
The original [opt-in experiment](m1n1-smp-shared-experiment.md) and its
manifest remain historical evidence, not the current default build record.

Nine control objects live in a 64-KiB-aligned `.data.smp_shared` interval:
the two reset-stack pointers, two secondary-stack pointer tables, WFE mode,
target CPU, spin table, boot-CPU index and boot-CPU MPIDR. Stack storage stays
normal memory. Identity and the three existing RAM aliases map the shared
interval as Device-nGnRnE, writable and non-executable. The release `dsb sy`
and secondary stack invalidation remain; only the two reset-pointer cache
maintenance calls are removed.

## Guards and lifecycle

Initial page-table construction remains possible before the shared mappings
are published. Once published, mapping helpers reject additional physical
aliases, changes to the four canonical aliases' translation, attributes or
permissions, and removal of those aliases. The framebuffer path checks before
cache maintenance. A no-op mapping does not change the invariant.

Raw addresses and permission bits are checked before descriptor construction.
Both translation-table registers use the same root in this baseline. The
mapping API, however, directly indexes its root with lower-48-bit addresses;
it does not accept upper canonical mirrors as inputs. The guard rejects
those inputs before side effects. The four mappings describe distinct
page-table regions, not a claim that their hardware upper mirrors do not exist.

Readiness resets on a real page-table rebuild and is published only after
all four mappings complete. CPU startup is allowed with the MMU off or with
the shared mappings ready. Both the bulk and individual CPU-start entry
points reject an inherited MMU-on configuration without readiness before
allocation or CPU-release side effects. This is a deliberate fail-closed
compatibility restriction, not support for importing arbitrary inherited
page tables. Patch 0014's separate T6032 MMU-entry checks remain intact.

This guards the supported mapping helpers, not arbitrary privileged page-table
writes, external translation-table replacement, concurrent table mutation,
or firmware outside this source tree. It is not a security boundary.

## Shared-state audit

The normal initial-start path was traced from assembly reset through
`_cpu_reset_c`, `smp_secondary_entry` and `mmu_secondary_setup`. The older
baseline's stack-pointer tables must be shared because a secondary reads
them before enabling its MMU. The nine-object set includes those tables.

Page-table and console pointers are initialized before the primary enables
its MMU and treated as immutable through secondary startup. The baseline's
global `cpu_features` points to the same immutable feature object across the
supported E/P cores. These assumptions are not generalized to arbitrary
runtime reinitialization or future heterogeneous feature tables. This patch
does not import newer upstream CPU reset/re-entry machinery or certify every
global variable in m1n1.

## Reproduce

With the existing local offline toolchain and hash-checked archive:

```sh
bash scripts/build-m1n1-cpu-offline.sh patched
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 python scripts/test-m1n1-smp-shared.py
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 python scripts/test-m1n1-smp-shared-guard.py
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 python \
  scripts/audit-m1n1-smp-shared-elf.py PATH_TO_BUILD_DIRECTORY
```

`smp-shared` remains a build-mode alias for the same patch series, with a
different version tag. To reproduce the old experiment, use commit `5435fd3`
in a separate worktree. Patches 0015–0017 apply with zero fuzz; historical
patches retain their existing application settings.

## Validation record

The recorded sixteen-patch cross-build passed. Both linked ELF variants place
all nine objects inside the aligned 64-KiB interval, and the Mach-O DATA
segment agrees with its linker-derived extent. The source/linker checks,
wrong-attribute and missing-mapping negative controls, and adjacent mapping,
MMU-entry, carveout and CPU-start-status host suites pass with the full series.
The historical bounds, handoff, board-DT, startup, MCC-layout and
frequency-failure suites also pass independently.

The dedicated sanitizer harness runs 4-KiB and 16-KiB boundary matrices,
executes the page-table readiness reset and all four remap calls, and injects
failure at each call to check that readiness stays false. It covers all four
aliases, subranges, adjacent ranges, overlapping removals, a genuine fifth
alias, malformed raw inputs and framebuffer rejection before cache effects.
Both extracted CPU-start entry points are also executed with readiness denied;
allocation, MMIO, cache, ADT and startup-state sentinels remain unchanged.

The [completion manifest](inventory/m1n1-smp-shared-finish-2026-09-27.json)
records source, patch, artifact and log hashes. These are host sanitizer
tests and artifact inspections, not execution of the linked ARM firmware.

## CPU-index follow-up (2026-09-30)

Patch [0017](../patches/m1n1/0017-validate-smp-api-cpu-indices.patch)
closes a separate indexing defect: the earlier upper-bound checks still
accepted negative `int` CPU IDs. Six public SMP helpers and the private
start/stop helpers now reject indices outside `[0, MAX_CPUS)` before array
access. The release-address helper also validates before forming a pointer.
Invalid start indices are rejected before consulting MMU readiness.

The eight CPU-index-taking SMP proxy cases check the original `u64` argument
before converting it to `int`, so values such as `2^32` cannot wrap to CPU 0.
Invalid SMP proxy requests retain the previous no-op/zero-return convention;
this patch does not introduce a new error status. Boolean/control operations
such as stop-secondaries and WFE-mode selection are not index-validated.

This is SMP API hardening, not a security boundary for the privileged proxy.
Separate MMU/HV index consumers remain follow-up work. In particular, HV
exit/unpin commands intentionally accept `-1`; any later ingress validation
must preserve those sentinels rather than applying a blanket opcode check.

The seventeen-patch cross-build and shared-layout audit pass. The new
[host runner](../scripts/test-m1n1-smp-api-indices.py) executes extracted SMP
functions and all eight indexed proxy cases with ASan/UBSan. It covers signed
limits, CPUs 0/31, raw 64-bit wraparound, boot-CPU no-op behavior, non-boot calls,
argument clearing and nonzero synchronous results. The first-sixteen-patch
negative control must produce the specific invalid-index sanitizer diagnostic,
not just any nonzero exit. Mutations dropping the EL0 synchronous result or
the raw proxy bounds checks must fail their designated regression cases.
The shared-memory runner includes this suite; adjacent mapping, MMU-entry,
carveout and CPU-start-status tests also pass against the seventeen-patch tree.

```sh
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 python scripts/test-m1n1-smp-api-indices.py
```

The [follow-up build record](inventory/m1n1-smp-api-indices-2026-09-30.json)
identifies the final patch, harnesses, cross-build and logs. Earlier draft
builds are not validation records for the completed fix.

## Remaining native gates

Host mocks and cross-builds cannot establish the physical load alignment,
cache/coherency behavior, hardware ordering or correct two-die CPU release.
T6032 CPU and DVFS dispatch remain disabled. MCC access/cache contracts,
CPU-release prerequisites and six-cluster early DVFS still need resolution.
Adam has no current verified backup; recovery readiness and explicit native
test approval are prerequisites, not tasks performed by this fix.

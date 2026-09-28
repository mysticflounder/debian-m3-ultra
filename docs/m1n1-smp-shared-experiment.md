# SMP shared-memory backport experiment

2026-09-27. Offline build and host tests only. No firmware installation,
native execution, MMIO probing, VM changes or disk changes.

## Scope

The default build remains pinned to m1n1
`4184923ffb2dff079b384d6a32cc02142aa14572` plus patches 0001 through 0014.
The `smp-shared` build mode explicitly adds
[experimental patch 0015](../patches/m1n1/experimental/0015-smp-shared-memory.patch).
It does not enable T6032 CPU or frequency dispatch.

The experiment adapts Sven Peter's
[upstream shared-memory change](https://github.com/AsahiLinux/m1n1/commit/f7124b8d42bcdd44131b4a455ad32e2f98fde166).
That change maps selected CPU-startup state as Device-nGnRnE so cores with
their MMUs disabled do not access it through a different cacheable view.
It is not a complete T6032 CPU-start implementation or a native boot result.

## Why a direct application does not work

The upstream patch expects newer static secondary stacks and reset/re-entry
state that our baseline does not contain. It also expects 64-KiB DATA
alignment, while the pinned linker scripts use 16 KiB. Our local carveout
preflight occupies the default-mapping tail where upstream adds its call.
The unmodified upstream patch fails a zero-fuzz application check.

This backport deliberately keeps the existing initial-start/reset flow.
It does not import the newer `smp_reset_stacks[]` lookup or claim to fix
secondary CPU re-entry. All local bounds, topology, locked-RVBAR, timeout
and caller-failure checks remain in place.

## Local adaptations

- Move reset-stack pointers, target CPU, spin table, WFE mode and boot-CPU
  globals into `.data.smp_shared`.
- Also move both secondary-stack pointer tables. Our older
  `mmu_secondary_setup()` reads `secondary_stacks[smp_id()]` before enabling
  its MMU; copying only upstream's variable list would miss that publication.
  Stack storage itself is not moved into Device memory.
- Align DATA before assigning `_data_start`, then reserve an aligned shared
  interval. Raising only the section alignment would let `_data_size` include
  a gap before DATA and misdescribe the Mach-O virtual segment extent.
- Map identity plus the three existing RAM aliases as Device-nGnRnE. The
  interval is writable and non-executable, including through the alias that
  normally permits executable RAM.
- Remove the two reset-pointer cache clean/invalidate calls, retaining the
  startup `dsb sy` and the separate stack invalidation during MMU enable.

The shared remap runs after generic `pmap-ranges` handling and before T6032
carveout validation/removal. Before publication, patch 0010 intentionally
permits initial mapping construction; the later preflight rejects carveouts
that overlap the loaded image. After publication, runtime mapping guards
remain unchanged. Patch 0014 still rejects unvalidated inherited MMU state.

## Reproduction

```sh
bash scripts/build-m1n1-cpu-offline.sh smp-shared
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 python scripts/test-m1n1-smp-shared.py
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 python \
  scripts/audit-m1n1-smp-shared-elf.py PATH_TO_EXPERIMENT_BUILD_DIRECTORY
```

Use the artifact directory printed by the build command for the final
argument. These commands compile or inspect local files and run host mocks;
they never connect to a target. The existing staged offline toolchain and
hash-checked source archive are prerequisites.

The experiment applies with zero fuzz. The existing fourteen-patch series
retains its established patch-application settings; a separate strict probe
rejected one existing patch-0008 context hunk, so this is not a claim that
every historical patch applies with zero fuzz.

## Validation boundary

The cross-build passes. Both ELF variants contain the nine selected objects
inside a 64-KiB shared interval; the Mach-O DATA file and virtual extents
match the linker symbols. The pinned Mach-O virtual-address bias is only
16-KiB aligned. Relative ELF alignment does not prove the eventual physical
load address or boot-entry state.

The [build/test manifest](inventory/m1n1-smp-shared-build-2026-09-27.json)
records the artifact, patch, script and log hashes. The extracted remap
function passes an ASan/UBSan host recorder test for all four calls, their
addresses, size, Device type, permissions and 4-KiB/16-KiB alignment. The
fixture supplies linker-symbol aliases; it does not install page tables.

Wrong-attribute and missing-mapping mutations fail their intended recorder
assertions. Missing shared annotations and linker inputs also fail the
source checks. Existing mapping-guard, seven-case MMU-entry, carveout and
CPU-start-status suites pass against freshly materialized experimental
source, not just the default tree. The all-secondary completion gate is
source-checked but remains unreachable while T6032 dispatch is disabled.

An independent artifact audit rejects missing shared symbols, incorrect
object sizes, altered DATA locations/sizes, incorrect Mach-O VM addresses,
truncated files and oversized files. It inspects only the ELF sections needed
for this layout check, not every possible malformed section in an ELF file.
No hardware validation is implied by these tests.

A fresh default fourteen-patch build also passes. Its Mach-O and raw binary
are byte-identical to the recorded patch-0014 artifacts; debug ELF hashes
differ with their build paths. The opt-in mode has not changed those default
firmware outputs.

The four default mappings do not prohibit a later privileged caller from
changing their memory attributes. General shared state outside these selected
objects, runtime relocation, firmware entry, real cache ordering and legacy
SoC behavior still require review or target testing. The experimental mode
is therefore not promoted to the default series.

CPU-release and six-cluster early-DVFS contracts remain unresolved. Adam has
confirmed that there is no current Studio backup. Native testing still needs
a verified backup, recovery readiness and separate explicit approval.

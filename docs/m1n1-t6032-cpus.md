# T6032 32-CPU capacity and two-die audit

2026-09-26: offline preparation for Debian on the M3 Ultra Mac Studio.
No m1n1 installation, native payload execution, firmware changes or MMIO
writes were performed. The persistent QEMU VM is unchanged.

## Local patch

Base: m1n1 `4184923ffb2dff079b384d6a32cc02142aa14572`.
The [review patch](../patches/m1n1/0001-expand-cpu-capacity-and-fix-bounds.patch)
changes only three lines:

- General `MAX_CPUS`: 24 to 32.
- `dt_set_cpus()` rejects CPU-node ordinal `>= MAX_CPUS`, preventing an
  out-of-bounds pruned-phandle write on an extra CPU node.
- `hv_switch_cpu()` rejects CPU index `>= MAX_CPUS`, preventing an
  out-of-bounds `hv_started_cpus` read.

`MAX_EL3_CPUS=4` and its startup gate are intentionally unchanged. The patch
does not add T6032 target dispatch or CPU-start/frequency register writes.
Larger arrays affect other targets too; the small host harness is not a
claim of complete cross-target regression coverage.

## Real topology

The [sanitized live capture](inventory/t6032-cpus-2026-09-26.json) passed
on this T6032/J575d host running macOS 27.0 build 26A428. CPU IDs are dense
0–31. Each die contains cluster 0 with 4 E cores and clusters 1/2 with 6 P
cores each. CPU 24 is die 1, cluster 1, core 4; CPU 31 is die 1, cluster 2,
core 5. The previous capacity therefore excluded eight CPUs on die 1.

The registry parent properties are `max_cpus=32` and `cpu-cluster-count=3`.
Here the latter matches the per-die count, not the six-cluster total.
The collector decodes four-byte little-endian ADT `reg` values using the
pinned m1n1 fields and cross-checks the explicit die/cluster/core properties.
It does not treat those values as measured architectural MPIDRs.

Raw registry data remains in memory; output contains allowlisted identity
and topology fields, no serial numbers, UUIDs or MMIO addresses. Missing,
duplicate, extra, malformed, wrong-endian and inconsistent CPU descriptions
fail closed. Shuffling nodes preserves CPU IDs. A passing inventory explicitly
reports `cpu_release_validated=false` and `hardware_validated=false`.

## Reproduce

The inventory tests require only Python's standard library:

```sh
PYTHONDONTWRITEBYTECODE=1 uv run --no-project --python 3.13 scripts/test-t6032-cpus.py
PYTHONDONTWRITEBYTECODE=1 uv run --no-project --python 3.13 scripts/audit-t6032-cpus.py --live
```

The live command is optional and read-only; it may need permission to query
IODeviceTree. Offline input is a saved `ioreg -a -l -p IODeviceTree` plist.
Do not commit raw plists.

For the C boundary tests, extract the
[pinned source archive](https://codeload.github.com/AsahiLinux/m1n1/tar.gz/4184923ffb2dff079b384d6a32cc02142aa14572)
under `scratch/m1n1-cpu-audit/`, retaining its `m1n1-4184923…` directory name,
then run:

```sh
PYTHONDONTWRITEBYTECODE=1 uv run --no-project --python 3.13 scripts/test-m1n1-cpu-bounds.py
```

This needs host `clang` with AddressSanitizer/UBSan and `patch`. It verifies
source-file SHA-256 values, applies the patch to a temporary scratch copy,
and compiles the actual extracted `hv_switch_cpu()` with harmless mocks.
It checks -1, 0, 23, 24, 31, 32 and an inactive CPU. The original function
is a negative control: index 24 triggers a sanitizer diagnostic. A second
control demonstrates the original `>` guard accepting the capacity itself.
Only the actual guard expression from `dt_set_cpus()` is compiled and tested
at 0, 23, 24, 31 and 32; this is **not** a full FDT pruning/handoff test.

Validation: 12 topology tests, all 15 existing MCC tests and the C harness
pass. The inventory was also checked against the live Studio. A full m1n1
firmware build, synthetic-FDT integration test and native hardware test
remain outstanding. Source capacity is not working CPU release.

## Next gates

1. Build the patched firmware offline and test full kernel DT pruning and
   release-address handoff, including dead secondaries and extra CPU nodes.
2. Establish T6032 CPU-start selection and execution-level behavior from
   evidence; do not assume the T6031 register offset or expand EL3 storage.
3. Resolve MCC layout and six-cluster frequency initialization separately.
4. Validate recovery and the supported boot-entry path before any RAM-only
   native test. Disk changes and firmware installation are not authorized.

This is AI-assisted local project work for Debian/project forks. No external
submission has been made.

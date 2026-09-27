# T6032 whole-inventory CPU-start preflight

2026-09-26 local time. Offline source work and allowlisted host metadata;
no native execution, register reads/writes, firmware or boot-policy changes.

## Why per-secondary mask checks were not enough

The pinned `smp_start_secondaries()` enumerates nodes into global
`cpu_nodes[]`, overwriting duplicate IDs and skipping out-of-range IDs. It
accepts the first `state="running"` node, then visits CPUs in ordinal order.
The boot CPU's separate path can write its RVBAR before a later CPU's
metadata is inspected. Per-secondary mask checks therefore cannot establish
that the complete inventory is valid before the first register access.

Two additional source hazards matter here:

- The older `/arm-io/reg` fallback compares a byte length against a `u64`
  element index before copying sixteen bytes. That is not a sufficient
  bounds check. T6032 must not fall back to it on missing metadata.
- In pinned `rust/src/adt.rs`, `adt_getprop_copy()` calls `copy_raw()` before
  comparing the copied length with the caller's requested size. An overlong
  property can overwrite a C buffer before the API returns `BadLength`.
  New preflight code uses `adt_getprop()`, checks lengths first, then decodes
  bytes explicitly. This is source evidence, not observed live corruption;
  patch 0006 does not repair that generic API or legacy fallback.

## The local preflight

[Patch 0006](../patches/m1n1/0006-preflight-t6032-cpu-inventory.patch) adds
a T6032-only check after locating `/cpus`, before clearing `cpu_nodes[]`,
selecting a boot CPU, or entering the RVBAR/release loop. It requires:

- Exactly 32 children, advertised capacity 32 and three clusters per die.
- Exact four-byte IDs/affinity properties, all ordinals 0–31 exactly once,
  no reserved `reg` bits, and agreement between encoded and explicit
  die/cluster/core coordinates.
- Validated mode-1 masks from patch 0005, unique physical coordinates,
  and complete 16-bit coverage on each of two dies.
- Exact eight-byte `running\0` or `waiting\0` state strings, exactly one
  running node, and agreement with `boot_cpu_idx` if already established.
- Explicit sixteen-byte `cpu-impl-reg` tuples: nonzero eight-byte-aligned
  bases, enough space for the existing RVBAR and `+0x100` status accesses,
  no address wrap, and no overlapping windows.

All bookkeeping is local. The helper does not read MPIDR, RVBAR or PMGR
registers and does not publish CPU/reset state. It does not infer physical
address validity or device semantics merely from non-overlapping ranges.
Other SoCs bypass the new preflight. A valid T6032 inventory still reaches
the existing unsupported-SoC return: **dispatch remains disabled**.

The ADT is assumed stable between preflight and the existing consumer loop.
This is not a transactional startup plan or a parser-hardening audit of the
whole ADT implementation. Before native enablement, consider consuming a
validated local plan directly rather than reparsing properties.

## Host metadata evidence

The [allowlisted capture](inventory/t6032-startup-metadata-2026-09-26.json)
has 32 records. CPU 4 is the sole node marked running; the other 31 are
waiting. Every `cpu-impl-reg` tuple is sixteen bytes and describes a
non-overlapping window of size `0x9010`. This is the host's device-tree
description, **not** a live execution-state observation or evidence of
RVBAR contents/writability at the future m1n1 entry point.

`scripts/audit-t6032-startup.py --live` reads the device tree in memory and
emits only allowlisted topology, state and range fields; it never accesses
those physical addresses. Its eight synthetic tests cover malformed states,
ambiguous boot identity, range errors, overlap, topology rejection and
private-field exclusion. Full raw device-tree data is not saved.

The [six-patch build](inventory/m1n1-cpu-preflight-build-2026-09-26.json)
passes with the same two existing warnings. Nothing was installed or booted.

The source-extracted `scripts/test-m1n1-cpu-preflight.py` harness exercises
the actual mask, bounded-property and inventory helpers plus the full
`smp_start_secondaries()` function under ASan/UBSan. Its ADT/register mocks
test valid and reordered enumeration, boot identity, duplicate IDs and
coordinates, malformed fields, and invalid/overlapping register windows.
An invalid inventory returns before clearing `cpu_nodes[]`; a valid one
still reaches the closed T6032 dispatch without hardware effects. Earlier
bounds, handoff, board-DT and four-variant startup tests remain separate
regressions; their passing results are not native execution evidence.

```sh
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 scripts/test-m1n1-cpu-preflight.py
```

## Remaining native gates

At patch 0006 the startup API still returned `void`, so rejecting metadata
did not stop every caller from proceeding. The subsequent
[caller-status patch](m1n1-t6032-start-status.md) propagates T6032 rejection
through payload, proxy and hypervisor initialization. It does not roll back
their existing preludes or enable native dispatch.

Native MPIDR-to-ADT mapping, entry level/features, reset/RVBAR ordering,
the boot CPU's separate RVBAR policy, register side effects, recovery and
console access remain unverified. MCC/cache and DVFS prerequisites also
remain open. Neither this preflight nor the successful cross-build removes
those gates.

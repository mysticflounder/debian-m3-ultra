# T6032 MMU entry and local initialization

2026-09-27. Offline source analysis and mocked tests only; no native execution,
register probing, DFU operation, installation, disk or VM changes.

## Gap in the thirteen-patch tree

`main.c` initializes MCC metadata and then calls `mmu_init()`. That function
returns immediately when `SCTLR_EL1.M` is set. On first entry, this can skip
page-table construction and the T6032 carveout preflight entirely. The
mapping guard deliberately permits construction before carveouts are ready;
it therefore does not validate inherited tables on this skipped path.

This is a source-level unsupported-entry case, not evidence that the Studio
actually enters m1n1 in that state. The real boot-entry contract is unknown.
The proxy also exposes `P_MMU_INIT`, so rejecting every MMU-on call would
break the existing idempotent path after successful local initialization.

## Local lifecycle guard

[Patch 0014](../patches/m1n1/0014-reject-uninitialized-t6032-mmu-entry.patch)
adds a zero-initialized, T6032-only software flag in `memory.c`:

- MMU on and no successful local initialization: panic rather than return.
- MMU off: clear the flag before resetting carveout state or building tables.
- Set the flag only after default mappings (including mandatory T6032
  preflight), configuration and the MMU-enable write have returned.
- A later MMU-on call after that successful setup remains a no-op.

Temporary disable/restore does not clear this flag or carveout publication.
A shutdown followed by a disabled-MMU rebuild clears it before rebuilding.
Legacy SoCs retain their prior behavior; secondary setup is a separate path.
Secondary setup and explicit register restoration are not guarded by this
primary initialization flag. Missing generic MMIO mapping properties can
still produce warnings and return; the flag is not a completeness check for
those mappings. `BRINGUP` skips the normal MCC/MMU initialization calls.
This does not adopt inherited tables, verify TTBR/TCR/MAIR, or detect later
privileged replacement of tables/registers. The flag records software control
flow, not hardware correctness. Panic/reset and console recovery remain
unvalidated, and earlier startup operations are not made safe by this check.

## Offline validation

The fourteen-patch default firmware build passes. The
[build/test manifest](inventory/m1n1-mmu-entry-build-2026-09-27.json) records
artifact and test hashes; no artifact was executed on the target.

`scripts/test-m1n1-mmu-entry.py` reuses the hash-checked source materializer
and extracts the actual `mmu_init()`, flag and SoC/SCTLR definitions. Seven
ASan/UBSan cases pass: initial inherited-MMU rejection, legacy no-op,
successful initialization/repeat, rebuild, injected default-mapping failure,
injected enable-write failure after a previous successful setup, and simulated
temporary disable/restore. Tests verify the flag is cleared before setup and
not published on these failure paths. The other initialization stages and
system registers are mocked; this does not execute native translation changes.

The runner also checks the actual T6032 preflight/failure-panic source and
initialization call ordering, and that disable/restore do not alter the flag.
These are source-shape checks, not execution of the full mapping stage.
The separate source-extracted carveout and mapping suites also pass with all
fourteen patches applied. Native panic, MMIO faults and recovery are untested.

## Recovery prerequisites remain external

Apple's current [revive/restore instructions](https://support.apple.com/en-us/108900)
use Finder on a host running macOS 14 or later; Configurator is not required
by that procedure. The host needs internet and download space (Apple says
32 GB should suffice), plus a USB-C cable supporting data and charging, not
a Thunderbolt 3 cable. A newer target OS may require a host software update.
Revive is intended to preserve data; restore erases the target.

The [official port table](https://support.apple.com/en-us/120694) identifies
the Studio's DFU port as the rightmost USB-C port when facing its rear. This
identifies a future connection, not a verified working recovery setup.

Channel request 18031 asks the MacBook agent for read-only host readiness;
18043 clarifies the Finder procedure. Adam confirmed on 2026-09-27 that the
Studio has no current backup. A completed, verified backup is required before
native testing or firmware/boot-policy/partition changes. The actual cable,
recovery operation and supported native boot entry remain unconfirmed.
No DFU entry, revive/restore or firmware test is authorized by this note.

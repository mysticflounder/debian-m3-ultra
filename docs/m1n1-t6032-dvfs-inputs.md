# T6032 DVFS: live inputs and feature consumers

This is metadata and offline binary evidence, **not a frequency driver**.
No MMIO, native firmware execution, installation or boot-policy changes were
performed. T6032 firmware dispatch remains disabled. Register addresses in
this note are logical arguments to Apple's accessors unless stated otherwise.

## Capture contract

[`audit-t6032-dvfs.py`](../scripts/audit-t6032-dvfs.py) captures only selected
`/arm-io/pmgr` properties. `--live` reads IODeviceTree metadata in memory;
`--plist PATH` inspects a supplied capture; `--firmware PATH` inspects a local
restore IM4P. These sources have distinct labels. The live/plist identity
must be J575d/chip `0x6032`; the template must be J575d/Mac15,14 with PMGR
compatible `pmgr1,t6031`. Its placeholder chip ID is labeled separately.
No raw ioreg dump is retained by the collector.

The allowlist contains four scalars, `perf-domains`, `perf-regs`, and base,
`-sram`, and `-extra` voltage-table names with suffixes 1/2/5/13/33/34/37/45.
These suffixes are **table selectors, not domain IDs**. The separately traced
die-1 consumer maps 1/5/13 to 33/37/45; 34 is comparison data, not the
ECPU replacement. Schema 2 checks the three captured CPU descriptors:
domain 2 selects table 1, domain 5 selects 5, and domain 13 selects 13.
Base tables 1/5/13 are required; table 2 is optional comparison data for a
different domain. Duplicate/missing CPU descriptors, wrong selector/mode or
non-28-byte descriptor lengths fail closed. Optional absences are reported.
Die-1 tables remain optional: the report labels their static selector mapping
as candidates and explicitly leaves runtime application unvalidated.
Properties must be nonempty, word-aligned bytes, at most 4096 bytes each;
scalars must be exactly four bytes. Base and SRAM tables additionally require
eight-byte alignment. The `-extra` layout is unresolved. Arbitrary identifiers
and properties are excluded; CLI failure output does not contain input data.

```sh
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 scripts/audit-t6032-dvfs.py --live
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 scripts/audit-t6032-dvfs.py \
  --firmware scratch/mcc-firmware-reference/DeviceTree.j575dap.im4p
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 scripts/test-t6032-dvfs.py
```

The [corrected sanitized inventory](inventory/t6032-dvfs-selected-inputs-2026-09-26.json)
retains the two schema-2 reports exactly. The
[original schema-1 capture](inventory/t6032-dvfs-tables-2026-09-26.json)
is historical comparison data: it omitted table 1 and therefore did not
capture the ECPU input. The follow-up
[die-1 live capture](inventory/t6032-dvfs-die1-live-2026-09-26.json) adds
table 33 without rewriting those historical records. Twenty portable
collector tests pass, including
identity, bounds, record alignment, required/optional fields, privacy, source
labels and sanitized CLI errors. Adjacent PMGR/firmware-DVFS/firmware-MCC
suites pass 7/18/16 tests, respectively: **61 total**. These tests validate
parsing and reporting, not register semantics or safe native operation.

## Restore tables are not live operating-state tables

| Property | Restore-template bytes | Live IODeviceTree bytes |
| --- | ---: | ---: |
| `voltage-states1` (CPU domain 2) | 24 | 48 |
| `voltage-states2` (domain 3, not ECPU) | 32 | 40 |
| `voltage-states5` | 24 | 160 |
| `voltage-states13` | 24 | 160 |
| `voltage-states1-sram` | Absent | 48 |
| `voltage-states5-sram`, `voltage-states13-sram` | Absent | 160 each |
| `voltage-states5-extra`, `voltage-states13-extra` | Absent | 76 each |
| `voltage-states37`, `voltage-states45` | Absent | 160 each |

Both reports contain `perf-domains` (364 bytes) and `perf-regs` (336 bytes).
The four little-endian scalars agree: `first-acc-dvfm-map-state=4`,
`nominal-performance1=0`, `boost-performance1=0`,
`mcx-fast-pcpu-frequency=0`. `voltage-states34` is absent in both.
Equality of these scalar values does not identify a safe boot state.

The matching ApplePMGR `initDriver` builds property names
`voltage-states%u-sram` and `voltage-states%u` at unslid PCs
`0xfffffe0009b7ea24–0xfffffe0009b7ea3c` and
`0xfffffe0009b7eaf8–0xfffffe0009b7eb10`. Length shifts at
`0xfffffe0009b7eab4` and `0xfffffe0009b7eb84` support eight-byte records.
The [follow-up state trace](m1n1-t6032-dvfs-states.md) establishes property
selection and the mode-1 reciprocal conversion into the getter array. It
does **not** establish raw voltage units, runtime state availability or
startup/APSC defaults. The metadata collector deliberately leaves those
claims false; do not divide table sizes to choose boot states.

## Second-die replacement tables

The [die-1 consumer manifest](inventory/t6032-die1-dvfs-2026-09-26.json)
records a separate path in `ApplePMGR::updateDie1CPUVoltages`, starting at
`0xfffffe0009bb46fc`. T6031 `initDriver` invokes it at
`0xfffffe0009f5a76c`, after its qualified base `initDriver` call. That base
call uses raw vtable symbol `0xfffffe0008292c58` plus `0xcc8`, whose checked
fixup resolves to `0xfffffe0009b7ca24`; this is not a runtime-vptr offset.

The update requires `this+0x631c >= 2`. It scans the `this+0x6328`
PerfDomain array with stride `0x118` and count `this+0x6330`, selecting
records with `+0x110 == 1` and descriptor byte 2 equal to 1. The initializer
stores its outer-loop quotient into `+0x110` at `0xfffffe0009b7e9e4`.
These are conditional software guards, not observed live object values.

The three byte pairs at `0xfffffe00076e0a4c` are `01 21 05 25 0d 2d`.
The routine matches descriptor **byte 0**, then uses the paired second byte
in `voltage-states%u` (`0xfffffe0009bb4868–0xfffffe0009bb49b0`). Thus the
mapping is from table selectors, not from domain IDs plus 32:

| Base selector | Replacement selector | Captured bytes, each | Raw records | Differing second words |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 33 | 48 | 6 | 5 |
| 5 | 37 | 160 | 20 | 9 |
| 13 | 45 | 160 | 20 | 18 |

All three replacement tables are present in the new allowlisted live
capture. First words match the corresponding base table and are nonzero;
the differing second words mean the raw tables must not be treated as
identical. No second-word voltage units are asserted. Replacement SRAM
tables 33/37/45 are absent; absence is reported rather than synthesized.

At `0xfffffe0009bb4a28–0xfffffe0009bb4a34`, replacement byte length divided
by eight must match the existing count at PerfDomain `+0x70`. The normal
path then replaces its data pointer at `+0x78` (`...4a64`) and recomputes
getter entries at `+0x98` using the existing mapping at `+0x90` and the same
`0x03e80000 / word0` conversion (`...4b2c–...4b3c`). Missing or mismatched
tables take other diagnostic paths; this bounded trace does not establish
their complete failure policy or make replacements universally mandatory.

This closes the missing table-33 capture and identifies the conditional
replacement consumer. It does not establish the effective die-count writer,
the allocation contract, successful six-record runtime construction, safe
raw APSC/default indices, or permission to execute this path at early boot.

## Feature names, dispatch and masks

The input collection SHA-256 and reproduction method are in the
[register contract](m1n1-t6032-dvfs-contract.md). All PCs below refer to that
same unslid collection. The bounded raw extracts and critical fixups are
listed in the [feature evidence manifest](inventory/t6032-dvfs-features-2026-09-26.json).

The base constructor copies `0x918` bytes from global table
`0xfffffe0008293e40` to object `+0x1d50` at
`0xfffffe0009b74058–0xfffffe0009b74070`. `ApplePMGR::start`, not
`initDriver`, indexes this table with stride `0x18`, looks up each property's
name and stores its presence/value at record `+8/+0xc`
(`0xfffffe0009b74690–0xfffffe0009b746c0`). Checked full-cache fixups map
entries 20/21/22 to `ppt-thrtl`/`llc-thrtl`/`amx-thrtl`, respectively.
This establishes the numeric/name link independently of cstring adjacency.

`_enableFeatureACC` (`0xfffffe0009b92560`) maps these IDs to throttler
selectors 1/11/12 and branches through vptr slot `+0xdb0`.
The T6031 constructor explicitly installs vtable-symbol **plus `0x10`**
at `0xfffffe0009f59a84–0xfffffe0009f59a9c`; the address point is
`0xfffffe0008365680`. Therefore slot `0xfffffe0008366430` resolves to
`0xfffffe0009f5d384`, the **four-argument** `enableThrottler` overload.
The adjacent slot `0xfffffe0008366428` points to the two-argument overload
at `0xfffffe0009f5d004`; using a mistaken `+8` address-point adjustment
would select that wrong function.

| Feature ID / name | Selector | Logical ACC offset(s) | Update |
| --- | ---: | --- | --- |
| 20 / `ppt-thrtl` | 1 | `0xe48400`, `0xe48408` | Preserve bits 62:0; bit 63 equals enable |
| 21 / `llc-thrtl` | 11 | `0xe40270` | Same |
| 22 / `amx-thrtl` | 12 | `0xe40250` | Same |

The selected overload saves incoming `x3` as the complex index and uses it
in the ACC calls; it does **not** loop across all complexes. These branches
pass zero as the separate low-level die argument. Thus complete virtual to
physical/in-die routing is still required before interpreting hardware scope.
For PPT it reads both registers before either write (`0xfffffe0009f5d400`,
`...d450`, then `...d4b8` and the tail-call through `...d610`). The second
offset is computed by OR-ing 8 into `0xe48400`, not loaded as a literal.

The low offsets and bit-63 masks correspond to pinned m1n1
`4184923ffb2dff079b384d6a32cc02142aa14572`'s `t6030_features`. This is
not complete sequencing equivalence: m1n1 updates its two PPT entries one
at a time. Apple's logical `0xe00000` prefix belongs to its mapping layer;
do not add it directly to an m1n1 cluster base.

The separate base `enableCPUFixedFreqRelock` at `0xfffffe0009b97690`
selects RegMap 9 for selector 0 or RegMap 21 for selector 7, checks map
availability, then updates bit 42 of offset `0x20`, preserving other bits.
The observed read/write die argument is zero. Other selectors go to a cold
error path. This confirms a mask correspondence, **not** that this method
is the applicable six-cluster T6032 boot path. Earlier
[live PMGR metadata](inventory/t6032-pmgr-cores-2026-09-26.json) records
APSC and the three throttlers as 1, fixed-frequency relock as 0; a property
value alone does not settle whether a disabled feature should be cleared,
skipped or left as firmware configured it.

## Remaining work before implementation

- Finish per-die runtime state construction and safe defaults; the mode-1
  conversion and correct property selection are now traced separately.
- Complete six-cluster runtime routing, including the complex index consumed
  by the indexed feature path and its separate die argument.
- Establish which operations are needed at early boot, their prerequisites,
  ordering/barriers and bounded failure behavior. Do not transplant runtime
  driver writes just because their masks match existing m1n1 constants.
- Keep CPU/frequency dispatch disabled until the independent MCC, protection,
  loader/DMA, boot-entry and recovery gates are met. The
  [MCC Pro review](m1n1-t6032-mcc-pro-review.md) returned family-level evidence,
  not a T6032 safety contract.

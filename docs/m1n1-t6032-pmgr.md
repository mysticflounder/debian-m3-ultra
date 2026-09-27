# T6032 PMGR evidence — 2026-09-26

This task adds host metadata, not firmware enablement. No MMIO access,
native payload, boot-policy change or storage operation was performed.

Follow-up: [matching local Apple PMGR binary analysis](m1n1-t6032-pmgr-binary.md)
now corroborates the die stride, separate group offsets and eight-byte
`acc-clusters` consumer stride. The observations below describe the earlier
metadata-only capture; full masks and safe CPU release remain unresolved.

## New read-only observations

The [allowlisted live capture](inventory/t6032-pmgr-2026-09-26.json) validates
J575d / chip `0x6032` before reading `/arm-io/pmgr`. The raw IORegistry tree
is parsed in memory and is not saved. Feature values are four-byte
little-endian integers:

| Property | Observed value |
| --- | --- |
| `cpu-apsc` | 1 |
| `apsc-snooze` | 0 |
| `ppt-thrtl` | 1 |
| `llc-thrtl` | 1 |
| `amx-thrtl` | 1 |
| `cpu-fixed-freq-pll-relock` | 0 |
| `cluster-ctl-offset` | `0x18000` |
| `acc-clusters` | 48 bytes, preserved without semantic decoding |
| `clusters` | 12 bytes, preserved without semantic decoding |

The offset is **not** the proposed CPU-start offset `0x88000`. Its name and
value do not authorize treating it as a replacement start offset or deriving
a second offset by arithmetic. Likewise, grouping the 48 bytes into six
eight-byte chunks is not proof of a hardware record schema. The collector
checks observed property shapes, not their register semantics.

The pinned `src/pmgr.c:474–485` reads named PMGR feature values;
`src/cpufreq.c:141–152` uses these flags to choose feature writes. This
capture therefore supplies inputs relevant to frequency initialization,
but does not establish the six cluster bases, register offsets, p-state
encoding or safe boot p-states. T6032 dispatch remains disabled.

## Public-source audit

- The [T6031/T6034 frequency correction](https://github.com/AsahiLinux/m1n1/commit/ae266e1d61a31d4d6330c0a310d1f1f570f7f71c)
  distinguishes APSC-snooze behavior and adds the second throttling write
  for M3 Max. The observed `apsc-snooze=0` is compatible with that rationale;
  it is not proof that all T6031 frequency operations apply to Ultra.
- The [original M3 MCC implementation](https://github.com/AsahiLinux/m1n1/commit/c45da55256fd15bfe1b4ecbc5331624d3427ee1e)
  introduced the T6031 plane/DCS/cache/TZ constants and register index 3.
  Its source does not supply a T6032 layout reference. Our independently
  captured four-header geometry still conflicts with that selection.
- The [T603x Linux DT submission](https://lists.openwall.net/linux-kernel/2026/07/24/1928)
  corroborates the two-die CPU topology and spin-table handoff, not PMGR
  CPU-release offsets or write masks.
- The [merged NVMe fix series](https://github.com/AsahiLinux/m1n1/pull/651)
  changes command/TCB DMA handling. Those changes are already present in
  our pinned `src/nvme.c`; importing the series again would not close a
  new gap. Its presence alone is not M3 Ultra storage validation.

The audited m1n1 revision remains
`4184923ffb2dff079b384d6a32cc02142aa14572`. Searches of public commits and
source are bounded negative evidence, not proof that no other implementation
or unpublished trace exists. A public source search did not establish a
T6032-specific CPU-start contract. The new registry properties deserve
consumer/schema tracing; topology-only captures cannot substitute for it.

The pinned `proxyclient/m1n1/adt.py:265–280` parses `clusters` as a sequence
of little-endian 32-bit integers, without establishing their CPU-start
meaning. No special decoder/consumer for `acc-clusters`, `soc-clusters` or
`cluster-ctl-offset` was found in that source tree. Independent review
confirmed that the new collector does not assign those fields a guessed
hardware schema.

## Reproduce and limits

```sh
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 scripts/test-t6032-pmgr.py
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 scripts/audit-t6032-pmgr.py --live
```

The collector also accepts a saved IODeviceTree plist or `-` for stdin.
Seven synthetic tests cover allowlisting, identity, both plist root forms,
missing/duplicate nodes, malformed/oversized properties, malformed hierarchy,
CLI parsing and error privacy. These are parser tests, not driver tests.
The live invocation passed and its JSON matches the saved inventory.
Independent review also passed. The shared live-input helper checks the
32 MiB input limit after capturing `ioreg` output, not while reading the
pipe; its timeout is bounded, but that limit is not a streaming memory cap.

Missing evidence remains: the CPU-release contract, MCC semantics/reference
on T6031, six-cluster frequency register semantics, and recovery/native-entry
validation. Register addresses must not be guessed from family resemblance.

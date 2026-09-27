# T6032 CPU-mask comparison — 2026-09-26

Follow-up: [mode selection and write-path evidence](m1n1-t6032-mask-contract.md)
establishes captured `acc-harvesting=1`, independently reproduces the masks
through the applicable non-2 branch, resolves the virtual write calls and
identifies topology `+0x7c`. The original investigation below remains a
record of the earlier mode-2-focused comparison, not the current gate list.

This is an offline comparison, not firmware enablement or a native-start
result. The [matching local PMGR binary](m1n1-t6032-pmgr-binary.md) supplies
consumer evidence; a new [allowlisted capture](inventory/t6032-pmgr-cores-2026-09-26.json)
supplies 32 eight-byte `acc-cores` records and the die stride. Schema 2 of
`audit-t6032-pmgr.py` requires those two additional properties; the earlier
schema-1 snapshot is preserved unchanged.

## Record and instruction evidence

In the captured records, bytes 6 and 7 match the physical core and combined
die/cluster bytes of the CPU inventory. Byte 7 is decoded as `die << 3 |
cluster` for this exact board, consistent with the previously validated ADT
`reg` bit fields. Matching is by affinity, not record order or assumed macOS
logical CPU numbering. Bytes 0–4 are retained but not interpreted by this
model; they must not be assumed irrelevant to Apple's initialization.

In `ApplePMGR::configMiscCores`, mode 2, the branch with topology flag bit 0
set scans `acc-cores` and compares record bytes 6/7. At `0xfffffe0009b9563c`,
`x8` starts at table base plus 7; each unsuccessful iteration adds 8 at
`0xfffffe0009b9566c`. On a match, `ldurb w11,[x8,#-2]` at
`0xfffffe0009b956e0` therefore loads **matched-record byte 5**. It is not an
unrelated topology byte despite the negative displacement.

The other mode-2 branch loads the per-core object's `+0xaf8` pointer and
then byte 5 at `0xfffffe0009b956ac`–`0xfffffe0009b956b0`. `initDriver`
stores the matched `acc-cores` pointer there at `0xfffffe0009b81138`.
Its initialization match also checks other metadata, so the host model
does not reproduce all conditions needed to construct that object.

Both paths feed byte 5 into `1U << shift` at `0xfffffe0009b95714`, accumulated
per die and passed to the virtual write call with group offset `+4`.
The separate per-cluster mask uses topology-record field `+0x7c`, directly
or through cached per-core field `+0xae8`. The model's `1 << core` cluster
mask remains a candidate based on captured `cluster-core-id`; the identity
of the binary's `+0x7c` field has not yet been proved.

Apple's [public CPU topology header](https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/osfmk/arm/cpu_topology.h)
provides useful field names, but its layout is **not** the matching local
kernel ABI: the local binary uses `0x88`-byte CPU records and a CPU-array
pointer at topology-info `+0x20`. Do not use a different revision's C struct
to silently label local offsets.

## Full-board comparison

For both dies, observed byte-5 shifts are contiguous 0–15:

| Cluster | Cores | Captured shifts | Legacy `4*cluster+core` shifts |
| --- | --- | --- | --- |
| E, cluster 0 | 0–3 | 0–3 | 0–3 |
| P, cluster 1 | 0–5 | 4–9 | 4–9 |
| P, cluster 2 | 0–5 | 10–15 | 8–13 |

All 32 affinities match exactly once. Twelve CPUs differ from the legacy
formula. The legacy formula aliases two pairs per die: cluster 1/core 4
with cluster 2/core 0 (`0x100`), and cluster 1/core 5 with cluster 2/core 1
(`0x200`). In the recorded ADT numbering these are CPU pairs 8/10, 9/11,
24/26 and 25/27. The byte-5 model has no such aliases.

This establishes a discrepancy between captured Apple mask inputs and the
legacy formula, not a hardware-validated fix. Still open: mode selection,
virtual-call target/write semantics, topology `+0x7c` meaning, early-boot
ordering and safe native entry/recovery. T6032 firmware dispatch remains
disabled. A future implementation should derive or validate masks from
metadata and fail before any release write if the mapping is inconsistent;
do not silently change other SoCs based on this one-board observation.

## Reproduce

```sh
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 scripts/test-t6032-cpu-masks.py
python3 scripts/model-t6032-cpu-masks.py \
  docs/inventory/t6032-pmgr-cores-2026-09-26.json \
  docs/inventory/t6032-cpus-2026-09-26.json > scratch/t6032-cpu-mask-model.json
```

The model requires exact board identity, supported schemas, 32 unique
affinities, bounded unique shifts, complete per-die coverage and the
observed die stride. Tests cover every CPU, record permutations, malformed
IDs/shifts/topology/schema and privacy. It emits candidates only and never
performs register access or writes firmware.

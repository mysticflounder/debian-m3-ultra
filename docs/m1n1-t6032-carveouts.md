# T6032 carveout evidence and remaining initialization contract

2026-09-26 local time; Mac Studio J575d, chip `0x6032`, macOS 27.0
build 26A428. Read-only registry metadata and offline source/binary analysis.
No hardware register access, native firmware execution, installation,
boot-policy, disk or VM changes.

## Narrow metadata capture

[`audit-t6032-carveouts.py`](../scripts/audit-t6032-carveouts.py) retains only
target/chip identity and the two named properties below. The raw registry
tree is parsed in memory and is not saved. Offline plist input is the default;
live collection requires `--live`. It reuses the existing MCC collector's
input-size, hierarchy, identity and sanitized-error checks.
Nine synthetic/offline tests pass, including privacy, malformed inputs,
identity, range bounds, plist formats and the saved allowlisted capture.
The existing fifteen MCC metadata tests also pass. No firmware patch changed
in this evidence task; the previous eight-patch build result remains separate.

The [live capture](inventory/t6032-carveouts-2026-09-26.json) confirms each
property has exactly sixteen bytes. Interpreting each as little-endian u64
address/size gives nonzero, page-aligned, non-overlapping intervals:

| Property | Candidate base | Candidate size | Exclusive end |
| --- | --- | --- | --- |
| `region-id-2` | `0x13fc6e48000` | `0x38400000` | `0x13fff248000` |
| `region-id-4` | `0x13fbafb4000` | `0x1fd8000` | `0x13fbcf8c000` |

These are **metadata observations, not MCC register values**. Do not hardcode
them into firmware: addresses can change between boots or configurations.
They do not establish register offsets, TZ slot numbering, enable semantics,
or whether all sixteen controller windows share the same configuration.

```sh
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 scripts/test-t6032-carveouts.py
# Explicit read-only registry capture (may require sandbox approval):
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 scripts/audit-t6032-carveouts.py --live
```

## Source interpretation and distinct consumers

Pinned m1n1 revision `4184923ffb2dff079b384d6a32cc02142aa14572` supplies
two relevant but different contracts:

- `src/mcc.c`, `mcc_unmap_carveouts()`: the comment identifies these two
  macOS properties as geometry references. The implementation instead reads
  plane 0 of controller 0 using the selected TZ table, treats `end` as an
  inclusive page index, shifts by twelve and ORs both endpoints with
  `ram_base`. It assumes all controllers/planes have identical settings.
- `src/kboot.c`, `dt_carveout_reserved_regions()`: selected display-firmware
  properties under the same node are decoded as two native little-endian
  u64 values, assigned to physical address and size. This supports the
  **encoding convention**, not a demonstrated runtime consumer for IDs 2/4.
  IDs 2/4 are not entries in those pinned display mapping tables.

The Linux memory-node path uses the boot-argument usable interval
`phys_base .. phys_base + mem_size`, not the `mcc_carveouts` array.
The array is exposed separately through `P_MCC_GET_CARVEOUTS`. Neither a
successful metadata parse nor a populated proxy array proves that a future
Linux handoff excludes the live TZ regions; that requires the corresponding
boot arguments and generated DT from the same boot.

## Rejected binary evidence

The matching Apple kernelcache SHA-256 is
`a24fefccc060854cecc996b40983499e1319008e4f16c0717a5fef6c4d4828dc`.
The offline AppleARMPlatform disassembly SHA-256 is
`8ad818a1ca02e6a205fa860504f81bef445e303caf476ab862b010d2dc4e1565`
(`scratch/mcc-evidence/AppleARMPlatform.disasm`).

The apparent `0x6d8`/`0x6dc` matches in `MCPolicyMgrPMP` are **ordinary
software object fields**, not MCC register offsets. Its constructor starts
at `0xfffffe0008c92300`; `x19` receives `this` at `0xfffffe0008c9232c`.
Provider-derived values are stored into `this+0x6d8` and `this+0x6dc` at
`0xfffffe0008c92530` and `0xfffffe0008c92590`, then checked/logged as policy
values. The generic controller constructs that object at
`0xfffffe0008cb90f0`. This is not a T6032 TZ-layout dispatch. No literal
`#0x6e4` access was found in this view. Numeric offset matches must not be
promoted into H15 hardware-layout evidence.

## Remaining implementation gates

The local eight-patch series already fixes MCC register selection and checks
initialization failure before MMU setup. It does **not** fix these separate
carveout issues in the pinned implementation:

1. Enabled inverted TZ intervals (`end < start`) are not rejected before
   subtraction/unmapping; `start == end` is skipped even though inclusive
   page-index arithmetic would describe one page. Hardware validity of that
   case must be established before changing its treatment.
2. The resulting interval is not checked against the actual mapped RAM
   extent, and OR-with-`ram_base` relies on an unverified address-field model.
   The 32-bit reads promoted to u64 make the shift itself fit within 44 bits;
   this is not evidence of an inherent 64-bit shift overflow.
3. `memory.c` ignores `mcc_unmap_carveouts()` failure. Region processing and
   mapping removal are incremental, without an all-regions preflight.
4. Controller-0/plane-0 representativeness on the two-die Ultra is unproved.

Next: design/test checked range decoding and fail-closed caller propagation
offline, while separately seeking a direct H15 TZ consumer or independently
validated layout. Do not add speculative register accesses or enable native
boot merely because the collector or an arithmetic harness passes.

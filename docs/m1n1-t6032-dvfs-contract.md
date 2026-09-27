# T6032 DVFS: static register-address and encoding trace

This is **offline evidence**, not an enabled CPU-frequency driver or a native
test. No register accesses, firmware execution, installation or boot-policy
changes were performed. T6032 dispatch remains disabled. This work targets
Debian and project forks; no submission is implied.

## Inputs and reproducibility

The local macOS 27.0 build 26A428 decoded kernel collection has SHA-256
`a24fefccc060854cecc996b40983499e1319008e4f16c0717a5fef6c4d4828dc`.
It contains `ApplePMGR` and `AppleT6031PMGR`. The latter's family name alone
does not establish Ultra support; the following actual call and mapping paths
are the evidence. All addresses below are unslid VM addresses in that input.

The J575d restore template `DeviceTree.j575dap.im4p` hashes to
`6c3ca4ac7272ecf9c05f6b2b413ef923ff2d3ff252469493fc700260b6938c60`.
Its decoded ADT is 589140 bytes, SHA-256
`4a818ecc7f3d71195c1def12c6eed0c90b287f82cad2a6a4ffd6f0849fe13c12`.
Its `/chosen/chip-id` is a zero placeholder, not live chip identification.

Run the bounded, allowlisted collector and portable synthetic tests:

```sh
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 scripts/inspect-firmware-dvfs.py \
  scratch/mcc-firmware-reference/DeviceTree.j575dap.im4p
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 scripts/test-firmware-dvfs.py
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 scripts/test-firmware-mcc.py
```

The collector uses the existing bounded ADT parser. Binary-derived map IDs
and provider indices are explicit constants, not claimed to be discovered
from ADT properties. It emits selected windows, translation and provenance,
not arbitrary properties or identifiers. A template is not the live,
iBoot-final ADT. Synthetic tests do not independently validate the binary trace.

For binary reproduction, create inspection views with
`scripts/inspect-local-kernelcache.py` and use `xcrun llvm-objdump --disassemble
--start-address=... --stop-address=... view.macho`, redirecting output to
scratch. Omit `--macho` to retain the address bounds. LLDB decoded incorrect
instructions from these synthetic views; that output was excluded.
Resolve vtable words against the full collection with
`scripts/inspect-kernelcache-fixup.py`; a successful format-8 chain resolution
does not authenticate PAC or prove the runtime object type.

## CPU path and register payload

`ApplePMGR::_updateCPUComplexPerfState` (`0xfffffe0009bae064`) reads the
CPUComplex domain byte at `+0x48` and a die argument at `+0x8dd0`, then calls
virtual slot `+0xe40` at `0xfffffe0009bae214`. With the AppleT6031PMGR
vtable address point `0xfffffe0008365680`, checked format-8 pointer
`0xfffffe00083664c0` resolves to `0xfffffe0009f5d7e8`,
`AppleT6031PMGR::setPerfState`.

Its domains 2, 5 and 13 share the ACC branch. It obtains a table index through
slot `+0xe50`, waits for APSC, obtains a complex via `+0x1120`, reads ACC via
`+0x1140`, then writes via `+0x1150`. The read/write argument is the **full**
`0xe20020` (MOV plus MOVK), not `0x20020`. At
`0xfffffe0009f5d968–0xfffffe0009f5d99c`, the payload preserves the old value
except bits 4:0, inserts the table index there and sets request bit 25.
`perfStateChangePending` reads the same logical offset and returns bit 31
(`0xfffffe0009f5dcd0–0xfffffe0009f5dcd4`). This supports a comparison with
m1n1's T6031 encoding; it does not establish safe initialization policy.

The separate generic `_setPerfState` at `0xfffffe0009babf98` accepts different
domains in its observed branch and is **not** used as the CPU contract here.

## ACC mapping and two-die candidates

`readACCReg` (`0xfffffe0009f5f9cc`) converts the virtual complex to a physical
complex within a die and selects its mapping table. Checked fixups at
`0xfffffe0008366908`, `...6910`, `...6918` point to tables at
`0xfffffe000778113c`, `...1184`, `...11dc`; counts at
`0xfffffe0007781308` are 9, 11, 11. `_getAccMapping`
(`0xfffffe0009f5f7c4`) checks logical offset containment using the map size.
For `0xe20020`, the first containing entries have logical base `0xe20000`
and RegMap IDs 9, 21, 33. Thus the map-relative offset is `0x20`.

`AppleT6031PMGR::initRegMaps` binds these IDs to provider `reg` indices
6, 15, 26 at `0xfffffe0009f59e24–0xfffffe0009f59e38`,
`0xfffffe0009f59efc–0xfffffe0009f59f10`, and
`0xfffffe0009f5a004–0xfffffe0009f5a018`. It repeats initialization per die.
The J575d `/arm-io/pmgr` node is `pmgr1,t6031`, with 60 register tuples;
each selected window has size `0x11e8`, containing the eight-byte access.

Root and `/arm-io` use two address and two size cells. Of 16 `ranges`
entries, entry 0 uniquely contains the selected windows: child 0 maps to
parent `0x200000000`, size `0x400000000`. Some unrelated ranges overlap;
the collector rejects ambiguity for selected windows, not unrelated overlaps.
This translation follows pinned m1n1 `rust/src/adt.rs` (revision
`4184923ffb2dff079b384d6a32cc02142aa14572`).

`ApplePMGR::initDriver` loads the `die-stride` property into `this+0x6320`
at `0xfffffe0009b74a94–0xfffffe0009b74ad4`. `initRegMap` gets the die-0
physical address and computes `physical + stride * die` at
`0xfffffe0009b7c7dc–0xfffffe0009b7c7ec`. It does not add the die to the
provider index. The template stride is `0x2000000000`.

| Physical complex within die | RegMap / provider index | Raw bus base | Die-0 P-state candidate | Die-1 P-state candidate |
| --- | --- | --- | --- | --- |
| 0 | 9 / 6 | `0x10e20000` | `0x210e20020` | `0x2210e20020` |
| 1 | 21 / 15 | `0x11e20000` | `0x211e20020` | `0x2211e20020` |
| 2 | 33 / 26 | `0x12e20000` | `0x212e20020` | `0x2212e20020` |

These match `T6031 cluster base + 0x20020`, with the evidenced die stride,
but remain **static candidates**, not permission to access those addresses.
Do not translate again after adding the stride.

## Remaining implementation gates

- Complete domain/virtual/physical-complex routing for all six clusters.
- Establish state-index policy: domain 2 returns requested state + 1;
  domains 5/13 add the global at `0xfffffe000cca0b28`, whose initialization
  and runtime value remain untraced. Do not choose default/APSC P-states yet.
- Trace `_waitAPSCPending`, error handling, policy-dependent pre-write steps,
  barriers, early-boot prerequisites and safe bounded polling.
- Establish feature masks before implementing `cpufreq_get_features`.
- Propagate unsupported/failed frequency initialization through relevant
  callers. Keep native dispatch off until independent startup/recovery gates
  are met; this report does not clear MCC, TZ, DMA or loader safety gates.

The `_cpuComplexInit` and `_initPerfDomainInfo` reviews found initialization
and performance metadata paths, but did not establish a direct mapping from
captured `acc-clusters` records to frequency-control registers. No such link
is assumed. Next bounded task: resolve the performance-state index global
and APSC wait contract, with portable tests before firmware changes.

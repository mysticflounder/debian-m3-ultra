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
The follow-up state-index, routing and wait extracts are hash-pinned in the
[DVFS binary evidence manifest](inventory/t6032-dvfs-binary-2026-09-26.json).

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

`ApplePMGR::start` loads the `die-stride` property into `this+0x6320`
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

## Domain routing and logical/physical complex numbering

`getPerfDomainIDToComplex` at `0xfffffe0009f5f638` selects a physical
complex, then tail-calls the imported `ApplePMGR::getPhysToVirtComplex`
through stub `0xfffffe0009f63018`:

| Domain | Die argument zero | Die argument nonzero |
| --- | --- | --- |
| 2 | Physical complex 0 | Physical complex 3 |
| 5 | Physical complex 1 | Physical complex 4 |
| 13 | Physical complex 2 | Physical complex 5 |

The distinction is zero/nonzero, not unrestricted `3 * die`; this code
does not establish support for more than two dies. Other domains reach
cold error paths. The normal `setPerfState` caller supplies zero to this
lookup, then supplies its separate die argument to the ACC accessor.
Do not interpret the returned logical index as a physical cluster number.

The base getters at `0xfffffe0009bb333c–0xfffffe0009bb34e4` use a
CPUComplex array at `this+0x3f150`, count at `+0x3f158`, stride `0x8e08`:

- `getVirtToPhysComplex` returns the input index if `this+0x238c == 1`;
  otherwise it reads the record's `+0x8df4` field.
- `getPhysToVirtComplex` returns the input under that same mode, or searches
  the forward mapping and returns the first match; no match gives `0xffffffff`.
- `getVirtToPhysComplexInDie` reads record `+0x5c` in mode 1, otherwise
  record `+0x8df0`. It bounds-checks the logical input first.
- `getComplexToDie` bounds-checks and reads record `+0x8dd0`.

The record initializer is in `ApplePMGR::initDriver`, not the later
`_cpuComplexInit` function. It retains the `acc-clusters` data pointer at
`this+0x6b190` and its eight-byte record count at `this+0x6b188`.
The captured 48-byte payload has record-byte pairs `(domain, selector)`:
`02/00`, `05/01`, `0d/02`, `02/08`, `05/09`, `0d/0a` (remaining bytes zero).
Here "selector" names the observed matching byte, not a proven MPIDR field.

At `0xfffffe0009b7ed74–0xfffffe0009b7edac`, the initializer searches this
table. It compares byte 1 with the second `getCorePhysID` output, byte 0
with the saved performance-domain ID, and requires a third equality with
a topology-derived value. The domain ID is reloaded from a saved stack
pair at `0xfffffe0009b7ed5c`; it is not the first `getCorePhysID` output.
On a match, it writes the domain byte to CPUComplex `+0x48`, the matched
record's **ordinal** to `+0x8df4`, and a topology-record value at `+0x78`
to CPUComplex `+0x8df0` (`0xfffffe0009b7edd4–0xfffffe0009b7ee1c`).

Together with the getters above, this links the captured record order to
the software physical-complex mapping. It does not establish all six runtime
CPUComplex records: the additional topology/performance-domain inputs and
mode selection still require validation. In particular, selector bytes
`08/09/0a` must not be substituted directly for global ordinals `3/4/5`.

## State-index global and chip-specific exception

The symbol at `0xfffffe000cca0b28` is
`AppleT6031PMGR::kPerfState0TableIndexPCPU`. Both the inspection view and
full collection contain initial little-endian `u32` value **2** there.
In the full collection it is file offset 97110824, within `__DATA`.
This is a file value, not a live-memory read.

The module's `initDriver` can overwrite it with **1** at
`0xfffffe0009f5a738–0xfffffe0009f5a740`, but only when the chip field at
`this+0x73d6c` equals `0x6031` and the first output of `getChipRev` is zero.
`_initChipIDs` obtains `/chosen`'s `chip-id`, safe-casts to OSData and
copies its first word to that field at `0xfffffe0009f5acc0–0xfffffe0009f5acc4`.
There is no normalization to a family ID in that copy. The OSData virtual
accessor's name remains an ABI inference. The same field is separately
compared with `0x6032` in `quiesceHW`.

Thus, **given a chip-id value of `0x6032`**, the observed initialization
does not take the T6031 revision-zero override. With the static initial
value retained, the CPU-domain table-index rules are:

| CPU domain | Table index for requested software state `s` |
| --- | --- |
| 2 | `s + 1` |
| 5, 13 | `s + 2` |

The search for writes was confined to the AppleT6031PMGR module; this is
not a whole-collection proof of absence of other writers, nor a capture of
the runtime global. The template's zero chip-id must not be substituted for
the live identity. These offsets also do **not** choose a safe boot state:
m1n1's cluster table stores raw hardware indices, whereas this Apple API
converts software states to indices. A default like 5 or 6 must be tied to
the actual state's voltage/frequency contract, not offset arithmetic alone.

## APSC control bit, separate from P-state request

`enableAPSC(bool, unsigned, unsigned)` at `0xfffffe0009f5c8e8` reads
logical ACC offset `0xe20020`. At `0xfffffe0009f5c960–0xfffffe0009f5c99c`
it preserves all bits except bit 23, which it clears for enable and sets
for disable, then writes through slot `+0x1150`. Both accessor calls pass
die argument zero, relying on complex-to-die routing rather than an explicit
die argument supplied to this function.

After the write, **disable only** loops on bit 7 of the same register
(`0xfffffe0009f5c9c0–0xfffffe0009f5c9f4`). No counter or deadline is present
in that loop. There is also a conditional virtual tail-call at slot `+0x1168`
controlled by `this+0x738d1`; its target is identified below.

The bit positions match pinned m1n1's `CLUSTER_PSTATE_M2_APSC_DIS` (23)
and `CLUSTER_PSTATE_APSC_BUSY` (7). That correspondence does not establish
the full T6032 feature table, a safe initial state, or equivalent sequencing:
m1n1's enabled `cpu-apsc` feature clears bit 23 and performs a bounded
bit-7 wait, whereas this Apple enable branch skips that loop.

### Transition waits and conditional error check

Despite its name, `_waitAPSCPending(unsigned char, unsigned)` at
`0xfffffe0009f5da6c` waits on **bit 31**, not the bit-7 APSC-disable
status above. It rejects domains greater than 13, then requires membership
in mask `0x2024`, admitting only 2, 5 and 13. Each iteration maps the
domain with die selector zero, reads logical ACC `0xe20020` with the saved
die argument, and branches back while bit 31 is set
(`0xfffffe0009f5db2c` to `0xfffffe0009f5dabc`). It has no deadline/counter
and exposes no recoverable status result.

The one-argument overload at `0xfffffe0009f5f420` likewise loops on bit 31
but directly uses the supplied complex and passes die argument zero.
There is no callback in this overload. `setPerfState` invokes the domain
wait before writing (`0xfffffe0009f5d888`) and optionally after writing
when its boolean wait argument is true (`0xfffffe0009f5da2c`). A future
bootloader contract must distinguish pre-existing busy state, request
completion and APSC-disable completion; it must not copy an unbounded wait.

Both the domain wait and APSC enable/disable function can conditionally
tail-call vtable slot `+0x1168`. This is a **vtable** offset, not a pointer
field at that offset in the PMGR object. Checked format-8 slot
`0xfffffe00083667e8` resolves to `0xfffffe0009f60528`, named
`AppleT6031PMGR::panicOnDvcDoneErr`. The bounded body reads PMGR SOC
voltage-manager offsets `0x64` and conditionally `0x68` per die, testing
their low 24 bits before an error path. It is not a timing barrier or a
successful-return guarantee merely because the busy bit cleared. The
register mapping, enable policy and applicability of this error check to
early boot remain separate questions.

## Remaining implementation gates

- Complete domain/virtual/physical-complex routing for all six clusters.
- State-index initialization is traced within the module, but runtime value,
  supported state tables and safe default/APSC P-states remain unvalidated.
- The two `_waitAPSCPending` loops and APSC enable bit are now traced;
  establish early-boot error policy, remaining pre-write steps, barriers,
  prerequisites and bounded polling before firmware implementation.
- Throttler masks and their indexed dispatch are traced in the
  [live-input/feature audit](m1n1-t6032-dvfs-inputs.md); establish early-boot
  applicability and ordering before implementing `cpufreq_get_features`.
- Propagate unsupported/failed frequency initialization through relevant
  callers. Keep native dispatch off until independent startup/recovery gates
  are met; this report does not clear MCC, TZ, DMA or loader safety gates.

The follow-up `initDriver` trace establishes a partial metadata-to-record
link; `_cpuComplexInit` and `_initPerfDomainInfo` alone did not establish it.
The [live-input/feature audit](m1n1-t6032-dvfs-inputs.md) captures the actual
allowlisted state-table properties and proves indexed throttler dispatch.
The [state-input trace](m1n1-t6032-dvfs-states.md) corrects domain 2's table
selection to `voltage-states1` and establishes mode-1 prefix/mapping/conversion
arithmetic. [Patch 0011](m1n1-t6032-cpufreq-status.md) propagates T6032
frequency-init failure before secondary startup. The
[ACC restore trace](m1n1-t6032-acc-restore.md) matches the extra `0x440f8`
write to Apple's logical `0xe440f8`, derives six static addresses and proves
that its zero die argument invokes complex-to-die routing. Next: finish
runtime routing and derive safe raw initialization states and ordering,
including the restore path's prerequisites and conditional APSC follow-on.
Restore templates cannot replace live tables, and runtime frequency conversion
does not by itself validate m1n1's raw-index boot policy.

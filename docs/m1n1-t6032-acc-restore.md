# T6032 ACC restore write: bounded offline trace

The previously unexplained m1n1 `base + 0x440f8 = 1` operation now has a
matching Apple software path and six static physical-address candidates.
This does **not** establish register semantics, safe early-boot access, or
permission to enable T6032 frequency/startup dispatch. No MMIO, native code,
firmware installation, boot-policy or disk changes were performed.

## Provenance and exact call

Input is the decoded macOS 27.0 / 26A428 collection and J575d restore ADT
identified in the [DVFS contract](m1n1-t6032-dvfs-contract.md). Addresses are
unslid. The [evidence manifest](inventory/t6032-acc-restore-2026-09-26.json)
records hashes, checked pointer targets, map bindings and disassembly bounds.

`AppleT6031PMGR::restoreACC(unsigned int, bool)` starts at
`0xfffffe0009f5b7e8`. Its sequence is:

1. At `0xfffffe0009f5b81c`, call the base `ApplePMGR::restoreACC`, passing
   the original complex index and Boolean. The pointer at
   `0xfffffe0008366b78` resolves to the **raw vtable symbol**
   `0xfffffe0008292c58`; its `+0xd08`
   slot resolves to `0xfffffe0009b926a0`. The base routine includes counter
   restoration and a conditional feature loop. This is not a standalone
   register write that can be transplanted with no prerequisites.
2. At `0xfffffe0009f5b858/85c`, construct `w2 = 0x00e440f8` using
   `mov #0x40f8` and `movk #0xe4, lsl #16`. Preserve the original complex
   as `x1`; set `x3 = 1`, `x4 = 0`; call `vptr+0x1150` at
   `0xfffffe0009f5b870`. The constructor-established vtable address point
   is `0xfffffe0008365680`; the checked slot `0xfffffe00083667d0`
   resolves to `AppleT6031PMGR::writeACCReg` at `0xfffffe0009f5fc24`.
3. At `0xfffffe0009f5b894`, tail-call `_initAPSC` with the same complex.
   It bounds-checks the index and, conditional on bit 0 of
   `this+0x73d67`, reads logical `0xe200f8` and writes the **read value OR
   bit 40** back. The read return in `x0` is not the saved `this` pointer.
   This conditional follow-on is not established as a required m1n1 step.

The base feature loop (`0xfffffe0009b927b8–0xfffffe0009b92828`) checks
feature validity, a virtual predicate and an object flag before calling
`_enableFeatureACC` with a Boolean derived from `getFeatureValue` and the
saved complex index. This links the earlier indexed-feature trace to restore
ordering; it does not prove that early firmware should reproduce the loop.

The raw base-table pointer above is not the runtime address point. The base
constructor at `0xfffffe0009b73f64–0xfffffe0009b73f7c` adds `0x10` before
storing its vptr. Thus ACC restore is runtime slot **`+0xcf8`**, not `+0xd08`.
With the T6031 address point, `0xfffffe0008366378` resolves to
`0xfffffe0009f5b7e8`. The original manifest mislabeled the raw base-table
pointer as an address point; that label is corrected here. The checked
qualified-base-call target and register-write target did not change.

## Conditional APSC flag

The follow-on `_initAPSC` operation is gated by **`apsc-snooze`**, not
`cpu-apsc`. In `initDriver`, `x23` is `this + 0x738d1` at
`0xfffffe0009f5a6a8/6ac`. The call at `0xfffffe0009f5a810` gets feature
`0x3f`; if nonzero, `0xfffffe0009f5a81c` stores byte 1 at `x23+0x496`,
which is `this+0x73d67`. A zero result skips this store; it does not explicitly
clear the flag in this branch.

The copied feature descriptor is at global `0xfffffe0008293e40 + 0x3f*0x18`.
Its checked name pointer `0xfffffe0008294428` resolves to string
`apsc-snooze` at `0xfffffe00076d0abe`. Its four remaining 32-bit words are
initially zero. `getFeatureValue` (`0xfffffe0009b75574`) reads the value
at `this+0x1d50 + feature*0x18 + 0xc`.

The [captured J575d metadata](inventory/t6032-pmgr-mode-2026-09-26.json)
records `apsc-snooze=0` and `cpu-apsc=1`. This is **not** a read of the
effective runtime feature or object flag: `ApplePMGR::start` first stores
the DT value, but can replace it using `PE_parse_boot_argn`
(`0xfffffe0009b74700–0xfffffe0009b74710`). The checked T6031 override-support
slot `+0xe10` resolves to `0xfffffe0009f6117c`, which returns 1.
We have not read or changed boot arguments. The evidence does not justify
unconditionally adding the bit-40 operation to m1n1, nor claiming that it
was skipped by the running macOS driver.

Apple's public XNU tag `xnu-12377.121.6` explicitly requests zeroed storage
in both ordinary size branches of `OSObject_typed_operator_new`; an enabled
`IOTRACKING` branch delegates elsewhere. This is supporting source evidence,
not a version match or proof of this object's runtime flag. The inspected
zero-feature branch itself only skips a store.
See [Apple's tagged OSObject implementation](https://raw.githubusercontent.com/apple-oss-distributions/xnu/xnu-12377.121.6/libkern/c%2B%2B/OSObject.cpp),
lines 294–323.

## Bounded runtime callers

These three base-driver paths dispatch through the corrected runtime slot
`+0xcf8`. They are runtime power/restore paths, not bootloader entry points.

| Caller | Dispatch PC | Arguments and immediate conditions |
| --- | --- | --- |
| `ApplePMGR::restoreHW(bool)` | `0xfffffe0009b93920` | Each index from 0 to `this+0x3f158` count minus 1; Boolean 0; zero count skips the loop |
| `ApplePMGR::enableCPUComplex(unsigned,bool)` | `0xfffffe0009b95fe8` | Saved complex index, Boolean 0; enable input true and `this+0x2494` nonzero, after the call through `+0xd28` |
| `ApplePMGR::enableCPUCluster(unsigned)` | `0xfffffe0009b962f0` | Saved complex index, Boolean 1; bounds/device-state checks, a call through `+0xd28`, nonzero `this+0x2494` and an intermediate indirect call precede dispatch |

The first loop tests its count at `0xfffffe0009b938f0` and rereads it
after each call. The cluster path rejects out-of-range indices and a
nonzero selected device-state byte; the purpose of `this+0x2494` and the
complete prerequisites of those preceding calls are not established here.
These conditions must not be reduced to “write every cluster at boot.”

Separately, `AppleT6031PMGR::restoreHW` directly calls `_initAPSC` at
`0xfffffe0009f5bbd4` for indices `0..count-1`, where count is
`this+0x73d84`. It rereads that count each iteration and skips the loop
when zero. The per-complex `restoreACC` tail call is therefore not the
only observed invocation of this conditional follow-on. Static loops do
not prove that all six runtime records are initialized correctly or that
every invocation is required for early boot.

The `_initAPSC` argument is a **complex index**, not an APSC performance-state
index. Neither this loop nor the per-complex tail call selects raw state 1.
The pinned m1n1 T6031 `apsc_pstate=1` and default states `5/6/6` remain
separate source constants, not T6032 initialization policy recovered from
these Apple restore paths.

Calls through runtime slot `+0xd08` in `initAON` and another part of
`restoreHW` are excluded: that slot is not the ACC restore override.

## Address and die mapping

The write helper first converts the virtual complex to a physical complex
within a die. At `0xfffffe0009f5fc70`, a **nonzero** fourth explicit argument
skips die derivation; zero calls `getComplexToDie` at `0xfffffe0009f5fc7c`.
Therefore the caller's zero argument is **not a die-0 restriction**. It still
depends on correctly initialized runtime complex records.

The three ACC tables have their `0xe40000` entries at ordinal 8, 10 and 10.
Their RegMap IDs are 10, 22 and 34. `initRegMaps` binds these to provider
`reg` indices 8, 17 and 28 at `0xfffffe0009f59e58`,
`0xfffffe0009f59f30` and `0xfffffe0009f5a038` respectively. J575d gives each
window size `0xb028`; relative offset `0x40f8` fits an eight-byte access.
The helper subtracts the mapping's logical base before its 64-bit write.

| Physical complex in die | RegMap / provider index | Bus window base | Die-0 candidate | Die-1 candidate |
| --- | --- | --- | --- | --- |
| 0 | 10 / 8 | `0x10e40000` | `0x210e440f8` | `0x2210e440f8` |
| 1 | 22 / 17 | `0x11e40000` | `0x211e440f8` | `0x2211e440f8` |
| 2 | 34 / 28 | `0x12e40000` | `0x212e440f8` | `0x2212e440f8` |

These use the previously traced unique ADT range (parent `0x200000000`)
and one die stride `0x2000000000`, after translation. They match m1n1's
candidate cluster bases plus `0x440f8`; they are not observed register state.
Selection is supported by the static tables and provider window layout,
not by a runtime dump of initialized RegMap objects.

## What this resolves, and what remains

Pinned m1n1 revision `4184923ffb2dff079b384d6a32cc02142aa14572`,
`src/cpufreq.c:207–212`, writes the same value for T6030, T6031, T6034 and
T8122. Its comment remains `Unknown`: the Apple method name does not identify
the register's hardware function, side effects or required barriers.

Resolved here: exact Apple logical offset/value, 64-bit accessor dispatch,
zero-argument die derivation, corresponding static windows, immediate
base-restore/write/conditional-APSC order, the snooze-feature setter and
override path, and three bounded runtime callers.

Still required before implementation: the runtime route for every one of six
complexes; a safe raw APSC/default-state policy; the full prerequisites
of the now-identified restore callers; applicability of the conditional
`0xe200f8` operation; and an independently justified early-boot sequence.
No claim is made that macOS restore ordering is the bootloader contract.
MCC/TZ, loader containment, recovery and native validation remain separate
gates. T6032 dispatch stays disabled.

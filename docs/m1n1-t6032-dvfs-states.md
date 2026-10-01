# T6032 DVFS property selection and mode-1 conversion

This is an offline trace of the pinned ApplePMGR collection identified in
the [register contract](m1n1-t6032-dvfs-contract.md), combined with
allowlisted live IODeviceTree metadata. It is not a native test, a frequency
policy, or authorization to program registers. CPU dispatch remains disabled.

## Correct input selection

`perf-domains` has 28-byte records. The byte loaded as the domain ID at
`0xfffffe0009b7e9d4` is **byte 3**. The property-name formatting at
`0xfffffe0009b7ea24` and `0xfffffe0009b7eaf8` instead reads **byte 0** for
`voltage-states%u-sram` and `voltage-states%u`. These fields are not aliases.

| Captured record ordinal | First four bytes | Domain ID | Base property | Conversion mode (byte 2) |
| ---: | --- | ---: | --- | ---: |
| 1 | `01 01 01 02` | 2 | `voltage-states1` | 1 |
| 3 | `05 01 01 05` | 5 | `voltage-states5` | 1 |
| 6 | `0d 01 01 0d` | 13 | `voltage-states13` | 1 |
| 2 | `02 04 00 03` | 3 | `voltage-states2` | 0 |

Thus the original table-2 capture was **not the ECPU input**. Collector schema
2 now requires base tables 1/5/13, validates the three CPU descriptors and
retains table 2 only as optional comparison data. It rejects duplicate,
missing, misaligned or unsupported CPU descriptors rather than reusing the
old domain-ID assumption. Tests include the crucial case where table 2 is
present but required table 1 is missing, and reordered descriptors.

The [corrected capture](inventory/t6032-dvfs-selected-inputs-2026-09-26.json)
has live table-1 and SRAM-table-1 lengths of 48 bytes each; the restore table
has only 24 bytes and no SRAM companion. Only metadata was read on the host.
The historical schema-1 inventory remains available, explicitly incomplete
for CPU-input analysis. No `-extra` consumer contract is established here.

## Prefix count, mapping and conversion

The following PCs are all within `ApplePMGR::initDriver`:

1. The base table's byte length is shifted right by three at
   `0xfffffe0009b7eb84`, giving eight-byte records stored as count `+0x70`;
   its data pointer is stored at PerfDomain `+0x78` at `...ebc4`.
2. `ldrb [x20,#2]!` at `...ebdc` (or `...ec38` on the empty path)
   advances the record pointer by two. Consequently `[x20]` in the later
   conversion code reads **byte 2**, not the original byte 0.
3. For mode 1, `...ebec–...ec24` scans raw word 0 until the first zero or
   the input count. It stores that nonzero-prefix count in both `+0x70`
   and `+8`. `...ec28–...ec34` rejects counts of 32 or more. This is a
   software parser bound, not proof of usable hardware states. The separate
   mode-0/other branches are not covered by this CPU-mode interpretation.
4. `...f120–...f130` allocates the byte mapping at `+0x90` using count `+8`.
   For mode 1, `...f190–...f198` writes `mapping[s] = s`; the loop is
   bounded by count at `...f1b0–...f1bc`. Allocation failure has an error
   branch. The mode-1 mapping does not use the separate nonidentity scan.
5. `...f1d4–...f1d8` allocates/publishes the count-times-eight array at
   `+0x98`. `...f214–...f244` loads the mapping byte, reads raw word 0 of
   that eight-byte record and stores unsigned integer
   `0x03e80000 / raw_word0` as an eight-byte entry. The numerator is
   initialized at `...e97c`; the intervening mode-2 topology path restores
   it at `...ef10` after temporarily reusing the register.

The getter `perfStateToFrequencyMHz` (`0xfffffe0009b8ddf8`) selects the
PerfDomain via the domain/die lookup, checks the requested state against
`+8`, then reads the low 32 bits at `+0x98 + state*8` (`...9b8de38–...de4c`).
This ties the arithmetic to a named frequency getter; it does not measure a
clock, validate voltage units, or prove all runtime records on both dies.

Applied offline to the captured CPU tables, the mode-1 arithmetic gives:

| Domain | Nonzero prefix length | Reconstructed getter values |
| --- | ---: | --- |
| 2 | 6 | 1020, 1320, 1704, 2088, 2484, 2568 |
| 5 | 20 | 1092 through 4056; nonuniform steps |
| 13 | 20 | Same sequence as domain 5 in this capture |

For example, table 1 begins with raw word 0 equal to 64250, so integer
`65536000 / 64250 = 1020`. Treat these as reconstructed values for the
MHz-named getter, not measured rates or a boot-state recommendation. The
collector itself remains a metadata report: it does not claim hardware
validation or a supported runtime state count.

## Runtime request producer — 2026-09-30

`ApplePMGR::_updateCPUComplexPerfState` (`0xfffffe0009bae064`) does not
supply a fixed APSC/default boot index. It loads the candidate from byte
`+0xf` of the object pointed to by `CPUComplex+0x50`; incoming `w2`
replaces that byte unless it is the `0xff` sentinel. A conditional cap
can lower the candidate before dispatch. The preceding parameter scan can
visit five entries, not four: its table contains `4,5,6,7,8`, and its
counter starts at 4 but continues while subtraction has no borrow.

The unequal-state path passes the domain byte from `CPUComplex+0x48` as
`x1` at `0xfffffe0009bae200`, and the candidate `w20` as `x2` at
`0xfffffe0009bae204`. The call at `0xfffffe0009bae214` uses vtable slot
`+0xe40`, resolving to the previously traced T6031 `setPerfState` method.
This connects runtime software-state requests to the conversion path; it
does not establish a bootloader policy.

An equal candidate and applied-state byte (`+0xc` of the same pointed-to
object) skips `setPerfState`, but is **not an immediate no-op**. The path
at `0xfffffe0009bae158–0xfffffe0009bae180` repeatedly calls slot `+0xe48`
until return bit 0 clears. The checked slot resolves to
`AppleT6031PMGR::perfStateChangePending` at `0xfffffe0009f5dba4`. There is
no timeout in that local loop; neither its termination nor the live state
is observed here. This does not justify copying an unbounded wait into m1n1.

The local `scratch/dvfs-evidence/early-state-verify.py` checks all 301
instruction words in the bounded function against the pinned collection,
the five parameter-table words and the pending-method fixup. Its SHA-256 is
`59c743dd72226aba31404e697d882c669a244a5c038c7096a349b3917dd40cf9`;
the report is `scratch/dvfs-evidence/early-state-evidence.json`. These are
static control-flow findings, not raw boot-state recommendations. The
backing record's initialization is now identified below; the first state
actually consumed on a particular cold boot remains unresolved.

## Initial backing record and early-firmware metadata — 2026-09-30

`ApplePMGR::initDriver` stores the record-array pointer at `this+0x6328`
(`0xfffffe0009b7e888`) and, after rejecting null, clears `count * 0x118`
bytes via the call at `0xfffffe0009b7e89c`. Its authenticated stub is
`0xfffffe0009bd9f1c`; the checked collection fixup at `0xfffffe00082a3808`
resolves to the kernel's `_bzero` at `0xfffffe000c636b40`.

The selected record is computed as that array plus `index * 0x118` at
`0xfffffe0009b7e998–0xfffffe0009b7e9a4`, then attached through the complex's
`+0x50` field at `0xfffffe0009b7edd8`. This is the pointer loaded by the
runtime consumer at `0xfffffe0009bae0a8`, which reads byte `+0xf` at
`0xfffffe0009bae0e0`. The backing byte is zero immediately after the clear.
This is not an exhaustive alias/later-write proof, a guarantee of its first
consumed value, or a raw hardware default. In particular, software state zero
must not be relabeled APSC index zero or copied into a new T6032 cluster table.

The local `scratch/dvfs-evidence/initial-state-verify.py` compares all 37
instruction words in six bounded spans with the pinned collection bytes,
checks allocation/null-guard and stub instructions, resolves the `_bzero`
fixup, and pins the symbol listing identifying its target. This is a bounded
byte/dataflow check, not execution or exhaustive alias analysis.

The pinned iBoot image supplies a separate bounded frequency-property path.
At image-relative `0x3e1bc–0x3e274`, selectors passed to `0x693e8` correspond
to the following subsequent property operations:

| Selector | Property |
| ---: | --- |
| 0 | `clock-frequency` |
| 2 | `memory-frequency` |
| 3 | `bus-frequency` |
| 1 | `peripheral-frequency` |
| 4 | `fixed-frequency` |
| 5 | `timebase-frequency` |

The helper at `0x41880` stores the **returned value**, not the input selector,
in a caller-stack slot before the property marshaller at `0x414b0`. The second
name pointer is the string's end bound, not the next adjacent property name.
Selectors 0–5 share the branch at `0x69474`, initialize a local result, call
`0x164250` with operation `0x1500`/flags `0x10000`, and load that local output.
This establishes bounded frequency-metadata plumbing, not an APSC index,
voltage policy or register-programming sequence. Calls beyond these bounded
spans are not claimed free of MMIO or other side effects.

The local `scratch/dvfs-evidence/frequency-export-verify.py` checks 105
instruction words against the pinned decoded iBoot bytes, all six strings,
selector/property associations and the outlined helpers. The iBoot SHA-256 is
`bed91c680ce5471ed1210be017ef9a33542e47c83bb7721f03e0aac209ca1c9e`.
Neither this firmware trace nor the runtime zero-filled record supplies safe
T6032 APSC/default indices. No native execution or frequency write was made.
Both checks pass on rerun; source and local-artifact hashes are recorded in
[the evidence inventory](inventory/t6032-dvfs-initial-state-2026-09-30.json).

The next bounded trace is the operation `0x1500` record lookup through
`0x164250`, `0x164154`, `0x163fa0` and `0x1641a4`: identify the first value
source for this frequency-metadata request. Stop at an unresolved callback or
side-effect boundary. Finding metadata alone will not establish APSC policy.

## Implications for early boot

Pinned m1n1 has no CPU MHz conversion in its early initialization. Its
T6031 table uses **raw hardware indices**: APSC 1 for all three clusters,
default 5 for ECPU and 6 for both PCPU clusters. It switches to the APSC
index, applies feature operations, writes the T6031-specific `base+0x440f8`
value 1, then switches to the default index. This is reference behavior,
not a validated six-cluster T6032 initialization sequence.

The separately traced Apple index conversion is conditionally `s+1` for
domain 2 and `s+2` for domains 5/13. In particular, PCPU APSC raw index 1
is below software state zero under that mapping. The visible frequency
table cannot justify copying that APSC index. Likewise, finding a normal
index within a table does not prove it is safe at boot.

Remaining implementation requirements are six-cluster/die routing, the
APSC/default raw-state policy, restore prerequisites, feature ordering and
bounded failure propagation. The [ACC restore trace](m1n1-t6032-acc-restore.md)
now matches the `0x440f8` write and six static windows; it does not establish
early-boot applicability. Runtime MHz derivation
is not itself a prerequisite for an m1n1-style raw-index initialization.

The ten-patch baseline ignored `cpufreq_init()`'s return before secondary
startup. [Patch 0011](m1n1-t6032-cpufreq-status.md) now rejects that failure
on T6032 before SMP and kernel handoff while preserving legacy behavior.
Proxy `P_CPUFREQ_INIT` already returns the status; `hv_init()` does not call
frequency initialization and needs no fabricated frequency guard. This does
not resolve the raw-state policy or enable frequency dispatch.

## Reproduction

Use the same bounded `llvm-objdump` procedure as the register contract.
The input hash is `a24fefccc060854cecc996b40983499e1319008e4f16c0717a5fef6c4d4828dc`.
The [state evidence manifest](inventory/t6032-dvfs-state-trace-2026-09-26.json)
pins the local extracts and boundaries. These are reproducibility pointers,
not a claim that proprietary binaries are included in the repository.

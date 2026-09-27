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

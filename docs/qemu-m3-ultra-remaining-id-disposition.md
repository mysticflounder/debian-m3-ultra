# Remaining newer-ID exposure evidence

## Scope — 2026-09-11

Read-only reconciliation of the existing 71-record macOS feature capture,
the calibrated guest newer-ID capture, the completed RPRES comparison, and
pinned local Apple/QEMU sources. No fresh host feature query or VM run was
performed. This is a disposition of available evidence, not a new raw
physical-register measurement.

The feature capture contains 40 values of `1`, 30 values of `0`, and one
aggregate `caps` decimal string. A flag's name is not enough to assign it
to a newer register: use its source mapping and account for older encodings.

## What the current evidence covers

| Register/surface | Available evidence | Disposition |
| --- | --- | --- |
| ISAR2.RPRES | macOS flag `1`; prior guest field `0`; 28 matched host/guest instruction results | Advertisement mismatch; no sampled execution mismatch |
| ISAR2.WFXT, BC, CSSC | macOS flags WFxT/HBC/CSSC all `0`; guest fields all `0` | Consistent non-advertisement; behavior not tested |
| Other ISAR2 fields | No corresponding positive newer-field evidence established in this capture | Unknown, not proof that the guest zeros are correct |
| PFR2 | Installed SDK groups `FEAT_MTE_STORE_ONLY` under PFR2; captured flag is `0`. Older pinned XNU has an empty export section | One mapped zero flag, not a raw PFR2 read; other fields remain unknown |
| MMFR3/MMFR4 | No mapped exports for these registers in the pinned feature list/initializer | Public-source coverage gap; cannot reconstruct host values |

The pinned XNU ISAR2 initializer exports exactly WFxT, RPRES, CSSC and HBC
(`out/hvf-public-controls.4UPiNq/xnu-commpage.c:540-558`). Its PFR2
initializer is at `:661-669`; the feature groups are in
`xnu-arm_features.inc:35-105`. These snapshots are revision
`f6217f891ac0bb64f3d375211650a4c1ff8ca1ea` (XNU 12377.1.9), not proven to
be the exact source of installed macOS 26.6.2. The installed SDK 26.5
`Kernel.framework/Headers/arm/arm_features.inc:108-109` adds
`FEAT_MTE_STORE_ONLY` under PFR2; QEMU calls the field `MTESTOREONLY`.
The SDK also groups MTE/MTE2/MTE3/MTE4/MTE_ASYNC under PFR1 and labels
MTE_CANONICAL_TAGS/MTE_NO_ADDRESS_TAGS as derived flags. This newer mapping
is useful but does not establish raw register values or prove the exact
installed kernel implementation. A header snapshot is retained at
`scratch/remaining-id-audit/sdk-arm_features.inc`.

Host PAuth2/FPAC positives were already accounted for by guest ISAR1.API=4;
they do not demonstrate missing ISAR2.APA3. ECV, AFP and LSE2 map to MMFR0,
MMFR1 and MMFR2 respectively in the pinned source, not MMFR3/MMFR4. Missing
exports are unknown. The zero MTE-related runtime flags are not a raw PFR2
capture and do not establish every PFR2 field's value.

## Testing policy correction

Unadvertised does not universally mean execution must raise `SIGILL`.
RPRES is an observed counterexample to that proposed test policy: the
instructions exist without the enhanced precision feature. Future tests
must separate advertisement, instruction availability and result semantics.
The roadmap now requires a feature-specific expected result or fault,
instead of declaring every successfully executed unadvertised case a bug.

## Bounded candidate and completed follow-up

The [CSSC scalar comparison](qemu-m3-ultra-cssc-behavior.md) has since
completed: host/guest agree on 24 caught `SIGILL` cases and three successful
ADD controls. The proposal below records its scope, not outstanding work.

A matched CSSC scalar integer min/max test is a useful next **coverage**
candidate, not an identified bug. Both captured advertisements are zero;
QEMU gates scalar `SMAX_i`/`SMIN_i`/`UMAX_i`/`UMIN_i` on `aa64_cssc`
(`target/arm/tcg/translate-a64.c:5178-5185`). This provides a concrete
instruction family to investigate without memory-system reconfiguration.

Before execution: verify the exact scalar encodings and applicable
architectural behavior; do not confuse them with older SIMD min/max.
Use isolated, time-bounded child processes with core dumps disabled, a
baseline integer positive control, and explicit signal-versus-result
reporting. Match host and disposable guest inputs. A fault is a measured
outcome, not an assumption based solely on a feature flag. The reconciliation
itself was read-only; the linked follow-up contains the later execution evidence.

There is no newly established QEMU transformation bug or supported newer-ID
override to implement from this evidence. Keep the existing RPRES API gap
open and scoped; do not repeat unavailable getters, infer whole physical
registers, or fabricate a chip-specific CPU model.

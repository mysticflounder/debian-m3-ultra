# Public HVF controls and host feature evidence

## Result — 2026-09-11 UTC

The public-control audit found no documented, named way in the installed
SDK 26.5 to import or override PFR2, ISAR2, MMFR3 or MMFR4. The read-only host
feature capture did identify a concrete advertisement mismatch:
macOS reports `hw.optional.arm.FEAT_RPRES: 1`, whereas the prior calibrated
guest EL1 capture has `ID_AA64ISAR2_EL1.RPRES = 0`.

This is a host/guest feature-advertisement mismatch, not a measured
instruction-behavior mismatch. A macOS feature flag is not a raw host
register value and cannot reconstruct the whole ISAR2 register. No new VM
was launched, no setter API was called, and no QEMU feature override was made.

## Host evidence

The normal host account read `/usr/sbin/sysctl hw.optional.arm` on macOS
26.6.2 build 25G83. The subtree contained 71 records. Decimal values are
retained as strings so the large aggregate `caps` value does not lose bits
through JSON floating-point conversion.

| Feature | macOS flag | Guest field in zero ISAR2 | Disposition |
| --- | --- | --- | --- |
| RPRES | `1` | RPRES `[7:4] = 0` | Advertisement mismatch; behavior untested |
| WFxT | `0` | WFXT `[3:0] = 0` | Consistent non-advertisement |
| HBC | `0` | BC `[23:20] = 0` | Consistent non-advertisement |
| CSSC | `0` | CSSC `[55:52] = 0` | Consistent non-advertisement |

QEMU defines these fields in `target/arm/cpu-features.h:231-245` and tests
RPRES at `:1070-1073`. Host PAuth2/FPAC flags do not imply a second ISAR2
mismatch: the captured ISAR1 already has `API=4`, which QEMU interprets as
FPAC-level pointer authentication (`cpu-features.h:956-975`). Missing sysctl
keys are unknown, not zero. The flags do not establish complete PFR2/MMFR3/
MMFR4 contents or prove that every guest-zero field is correct.

Artifacts:

- `out/hvf-public-controls.4UPiNq/host-features.txt` and `host-features.json`.
- `out/hvf-public-controls.4UPiNq/provenance.json`: OS/SDK versions,
  command, exit status and source-text SHA-256.
- `out/hvf-public-controls.4UPiNq/comparison.json`: selected field comparisons.
- Guest evidence reused, not rerun:
  `out/el1-fork.Iy4tyA/smp-1/evidence.json`.

Apple's published XNU implementation reads ISAR2 and sets `gARM_FEAT_RPRES`
from its RPRES field ([commpage.c, lines 545–551](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/arm/commpage/commpage.c#L545)).
Its feature list and generic read-only sysctl binding expose that variable
([arm_features.inc](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/arm/arm_features.inc),
[kern_mib.c, lines 1143–1148](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_mib.c#L1143)).
These links pin XNU `12377.1.9`, revision
`f6217f891ac0bb64f3d375211650a4c1ff8ca1ea`; copies and commit metadata are
in the host artifact directory. This establishes the published mapping,
not that this release exactly matches the installed macOS kernel. The
measured sysctl remains a capability boolean, not a captured raw host ID.

## Public API and QEMU boundary

The installed public headers have no named feature-query enums or
system-register constants for these four IDs. The configuration feature API
is getter-only. Generic `hv_vcpu_get_sys_reg()` and `hv_vcpu_set_sys_reg()`
exist, but their presence does not document acceptance of unnamed newer-ID
encodings or writable guest-ID policy. The previous numeric getter experiment
returned `HV_BAD_ARGUMENT` for all four; setters were not tested.

`hv_vm_config.h:90-105` explicitly documents PMU behavior under the EL2
setting and modification of DFR0 through `hv_vcpu_set_sys_reg()`. That is a
specific DFR0/PMU control, not evidence of a generic newer-ID override. No EL2,
PMU or interrupt-controller configuration changes were attempted.

QEMU revision `789e3d805f9ca84e64c40fe1b99129336ce911b8` models the four
registers as constant cpregs in `target/arm/helper.c:6621`, `:6714`, `:6759`
and `:6764`. However:

- `target/arm/hvf/sysreg.c.inc:95-108` omits them from register transfer.
- `target/arm/hvf/hvf.c:1138-1174` has no host feature query for them.
- The cpreg transfer loops and vCPU list construction at `:922`, `:1073`
  and `:1425` therefore do not provide another newer-ID import path.

The [calibrated trace](qemu-m3-ultra-trace-calibration.md) supports the four
guest reads bypassing QEMU's userspace sysreg handler. Filling QEMU's local
ISA fields alone is therefore not an established way to change these guest
reads. No passthrough-only QEMU patch is justified by this audit.

## Next bounded test

Design a matched host/guest RPRES instruction probe before changing any
advertised feature. Compare reciprocal and reciprocal-square-root estimate
results under explicitly controlled FP state, preserving and restoring that
state. Use scalar single-precision `FRECPE` and `FRSQRTE`, fixed positive
finite inputs, and FPCR.AH clear/set with readback. Save and restore both
FPCR and FPSR; record raw result bits and establish discriminating expected
vectors before interpreting a difference as RPRES behavior.
This should test instruction behavior and the advertisement/behavior
relationship, not elapsed performance.

### Host probe implementation — 2026-09-11 UTC

`scripts/arm64-rpres-probe.c` now collects 28 scalar observations: seven
positive finite FP32 inputs, two operations, and AH clear/set. It uses
integer bit patterns and inline assembly, saves/restores FPCR and FPSR,
records control readback and result/status bits, and calls libc only after
restoration. It changes only the executing thread's temporary FP state,
not host configuration, firmware, or QEMU feature settings.

Host runs at `-O0` and `-O2` produced identical JSON and reported restored
state. For input `1.0`, both operations returned `0x3f7f8000` with AH clear
and `0x3f7ff000` with AH set. These are observations, not an independently
validated oracle or a guest comparison. `scripts/test-rpres-probe.sh`
passed ten checks (two valid captures, their equality, seven malformed
result rejections); artifacts: `scratch/rpres-test.K8VUHf`.

`scripts/validate-rpres-probe.jq` checks sample coverage, control readbacks,
zero exception flags, raw result formatting and state restoration. It does
not classify result precision.

Follow-up host validation added `scripts/rpres-state-fixture.c`: both `-O0`
and `-O2` preserve FPCR `0x00400000` (non-default rounding) and FPSR `0x11`
(pre-set sticky flags). The integer reference in `scripts/rpres-reference.c`
matches all 28 host result bits. It is derived from the pinned QEMU
`vfp_helper.c`, scoped to the seven fixed inputs, and is not an independent
Arm-specification proof. The expanded suite passes 16 checks, including
comparison equality, a deliberately changed result and multiple-document
rejection. Latest host artifacts:
`scratch/rpres-test.v4oaOs`, with compiler/OS/time records and verified source
hashes. `scripts/compare-rpres-results.sh` compares complete validated captures
without treating equality on these inputs as proof of full CPU passthrough.

The [matched disposable-guest follow-up](qemu-m3-ultra-rpres-behavior.md)
is now complete: all 28 results match the host. RPRES remains an advertisement
gap, without a behavior mismatch observed for these inputs. See that report
for the successful run, rejected first attempt and limits.

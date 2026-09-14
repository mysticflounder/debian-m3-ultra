# M3 Ultra CSSC scalar instruction comparison

## Result — 2026-09-13 UTC (September 12 locally)

Host and current-fork HVF guest agree on all **27** observations:

- 24 scalar CSSC cases raised caught `SIGILL`: W/X forms of signed/unsigned
  immediate min/max, each with three fixed input bit patterns.
- Three ordinary X-register `ADD #1` controls executed with correct results.

This is consistent with the earlier host `FEAT_CSSC=0` and guest
ISAR2.CSSC=0 advertisements. It demonstrates rejection of the eight tested
scalar immediate encodings, not the absence of every CSSC instruction or
complete CPU equivalence. No new QEMU behavior mismatch was found.

## Encoding and semantics

Apple clang assembled all eight mnemonics with `-march=armv8.7-a+cssc`;
the object words match QEMU's scalar immediate decoder and feature gate
(`target/arm/tcg/a64.decode:166-169`, `translate-a64.c:5178-5185`).
Compile-only evidence: `scratch/cssc-encoding/cssc.s` and `cssc.o`.
These are not the older SIMD min/max operations.

| Operation, destination/source register 0, immediate 1 | W encoding | X encoding |
| --- | --- | --- |
| SMAX | `0x11c00400` | `0x91c00400` |
| SMIN | `0x11c80400` | `0x91c80400` |
| UMAX | `0x11c40400` | `0x91c40400` |
| UMIN | `0x11cc0400` | `0x91cc0400` |

Inputs are `0xfffffffffffffffe`, zero and two. W forms use the low 32 bits
and zero-extend results. The probe and validator independently compute the
expected result **if executed**. They accept either correct execution or
`SIGILL` for CSSC, but require successful ADD controls. Thus successful
unadvertised execution would be recorded, not automatically called a bug.

Each observation runs in a child process with a two-second alarm, core dumps
disabled, and a `SIGILL` handler that exits with a dedicated status. `SIGILL`
in the report means that handler was invoked, not an uncaught crash. Pipe
data distinguishes computed results from fault outcomes; errors and timeouts
invalidate the capture. No CPU settings or shared host state are changed.

## Accepted evidence

- Guest manifest: `out/rpres-vm.cWsPl4/manifest.json`, `probe_kind=cssc`.
- Guest observations: `out/rpres-vm.cWsPl4/guest.json`.
- Matched host: `scratch/cssc-test.QIfa0z/host-o2.json`.
- Comparison: `out/rpres-vm.cWsPl4/host-guest-comparison.json`.
- Protected snapshots and raw serial/QMP logs accompany the guest manifest.

The existing RPRES lifecycle runner now accepts only `PROBE_KIND=rpres`
(default) or `cssc`, selecting fixed source and validator paths. Historical
directory/marker names remain `rpres`; the manifest explicitly identifies
the selected probe. There is no arbitrary program-path override.

The guest used one vCPU, 2 GiB, no network, a read-only source share and a
disposable overlay; the probe ran as UID 65534 with no new privileges. QEMU
SHA-256 remained
`ea37dd7dfff94f9702af1c37eb12016842b6b371a53a8dc50ccf7779deb1a60a`.
All 19 protected input hashes and identities matched before/after. QMP
recorded a clean guest-originated shutdown. The overlay, FIFOs, QMP socket,
PID control and shared lock were removed. No persistent VM, firmware or
QEMU source/feature configuration was modified.

## Checks and reproduction

The CSSC host suite passes 13 checks, including `-O0`/`-O2` agreement,
acceptance of correct executing fixtures, malformed/faulted-control
rejection, and rejection of multiple JSON documents. Latest artifacts:
`scratch/cssc-test.ow7op8`. The existing 16 RPRES host checks also pass
(`scratch/rpres-test.Q8Oapk`). These are host suites, not a new RPRES VM run.
Independent encoding, safety and validator reviews preceded guest execution.

```sh
bash scripts/test-cssc-probe.sh
PROBE_KIND=cssc bash scripts/rpres-probe-vm.sh
bash scripts/compare-cssc-results.sh HOST_JSON GUEST_JSON
```

## Remaining scope

CSSC scalar min/max now has matched rejection coverage. The RPRES
advertisement gap and unknown physical newer-ID fields remain as previously
documented. The [HBC follow-up](qemu-m3-ultra-hbc-behavior.md) now has matching
fault/control outcomes. WFxT is still untested; review its feature-specific
semantics and safe controls before choosing another probe. This result does
not justify a QEMU feature override or another performance benchmark.

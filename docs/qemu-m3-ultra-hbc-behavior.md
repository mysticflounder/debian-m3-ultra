# M3 Ultra HBC conditional-branch comparison

## Result — 2026-09-14 UTC (September 13 locally)

Host and current-fork HVF guest agree on all eight observations:

- Four HBC cases (`BC.EQ`, `BC.NE`, each with two flag conditions) raised
  caught `SIGILL`.
- Four ordinary `B.EQ`/`B.NE` controls returned correct taken/untaken results.

This is consistent with the earlier host `FEAT_HBC=0` and guest ISAR2.BC=0
advertisements. It establishes matching rejection for these two HBC encodings,
not full CPU equivalence, every branch condition, or branch-predictor behavior.
No new QEMU execution mismatch was found. No fresh ID-register capture was
performed in this EL0 instruction run.

## Encoding and controls

| Operation | Forward +8 encoding |
| --- | --- |
| B.EQ | `0x54000040` |
| B.NE | `0x54000041` |
| BC.EQ | `0x54000050` |
| BC.NE | `0x54000051` |

Each asm block compares input zero/one against zero, then branches over a
single instruction setting the result to one. The initial result is zero:
taken returns zero, untaken returns one. Input/result use separate fixed
registers and the flags clobber is declared. QEMU's decoder distinguishes
the HBC bit (`target/arm/tcg/a64.decode:205-211`); its translator gates HBC
then uses ordinary conditional-branch semantics (`translate-a64.c:1779-1800`).
The compiled host disassembly is retained under `scratch/hbc-preflight/`.

The probe isolates each observation in a child process, disables core dumps,
sets a two-second alarm, and catches `SIGILL` with a dedicated exit status.
The report's `SIGILL` means the handler was invoked, not an uncaught crash.
Baseline branches must execute correctly. HBC may fault or execute correctly;
timeouts/errors invalidate the capture. The separate validator independently
checks all eight `(operation,input)` pairs and expected results. This test
does not measure branch prediction, speculation, or elapsed performance.

## Evidence and safety

- Accepted manifest: `out/rpres-vm.ik7mHa/manifest.json`, `probe_kind=hbc`.
- Guest: `out/rpres-vm.ik7mHa/guest.json`.
- Matched host: `scratch/hbc-test.3UDMTs/host-o2.json`.
- Comparison: `out/rpres-vm.ik7mHa/host-guest-comparison.json`.
- Protected before/after snapshots and raw serial/QMP logs accompany the run.

The guest used one vCPU, 2 GiB, HVF with kernel IRQ chip and `-cpu host`.
QEMU SHA-256 remained
`ea37dd7dfff94f9702af1c37eb12016842b6b371a53a8dc50ccf7779deb1a60a`.
The probe ran as UID 65534 with no new privileges. Source was read-only and
its hash was checked; guest writes went to a disposable overlay. No network,
host-device attachment, firmware change, or persistent VM change was used.
All 19 protected file hashes/identities matched. QMP recorded a clean
guest-originated shutdown. Overlay, FIFOs, socket, PID control and shared
lock were removed. The runner now accepts the fixed `hbc` mode alongside
`rpres` and `cssc`; its lifecycle protections are unchanged.

## Validation and remaining work

The HBC host suite passes 14 checks: `-O0`/`-O2` observations agree, correct
executing fixtures are accepted, synthetic fault/execution differences are
detected, and malformed/multiple-document captures are rejected. Compiler,
OS/time, and source hashes are retained in `scratch/hbc-test.3UDMTs`.
Existing CSSC (13 checks, `scratch/cssc-test.gEpf7s`) and RPRES (16 checks,
`scratch/rpres-test.kFzTJT`) host suites also pass; they are not new guest runs.
Independent code/validator safety review preceded host and guest execution.

```sh
bash scripts/test-hbc-probe.sh
PROBE_KIND=hbc bash scripts/rpres-probe-vm.sh
bash scripts/compare-hbc-results.sh HOST_JSON GUEST_JSON
```

Next: review WFxT timeout/event semantics and trap controls before proposing
a bounded probe. Do not infer its behavior from a zero advertisement or
treat host scheduling delays as CPU-semantic failures. The RPRES advertisement
gap and unknown newer physical ID values remain; HBC supplies no reason for
a speculative QEMU override. M5 HBC is separately advertised and untested.

# M3 Ultra: expired-deadline WFxT observations

The [semantics review](qemu-m3-ultra-wfxt-review.md) selected a narrow test:
WFET X0 and WFIT X0 with X0 explicitly set to zero immediately before each
instruction. No future deadline, ordinary WFI/WFE, or explicit counter read
is used. This is not a timing benchmark or a complete WFxT feature test.

## Host evidence

On 2026-09-23, both `-O0` and `-O2` host builds produced four matching rows:
NOP returned its marker, ADD returned one, and WFET/WFIT each produced caught
SIGILL. Captures and provenance are in `scratch/wfxt-test.0RL7aP`;
`host-comparison.json` compares the two host builds, despite the comparator's
generic host/guest field names. macOS remains 26.6.2, build 25G83.

Independent named-instruction assembly confirms WFET X0 `0xd5031000` and
WFIT X0 `0xd5031020`; `scratch/wfxt-encoding.s` and accompanying object,
disassembly and word dumps retain that check. Probe disassembly at both
optimization levels is retained with the host captures.

## Matched HVF guest

Accepted evidence: `out/rpres-vm.KKpZIN/manifest.json` (`probe_kind=wfxt`),
`guest.json`, and `host-guest-comparison.json`. All four observations match
the host: two correct controls and two caught SIGILL outcomes, no timeouts.

The guest used one vCPU, 2 GiB, HVF with kernel IRQ chip and `-cpu host`.
The probe ran as UID 65534 with no new privileges. Network was disabled;
source was read-only and hash-verified; guest writes used a disposable
overlay. All 19 protected hashes/identities matched before and after.
QMP recorded a clean guest shutdown; overlay, control FIFOs, QMP socket,
PID file and shared probe lock were removed. No persistent VM or firmware
change was made. QEMU SHA-256 remains
`ea37dd7dfff94f9702af1c37eb12016842b6b371a53a8dc50ccf7779deb1a60a`.

Reproduce build/fixture checks and the disposable guest with:

```sh
bash scripts/test-wfxt-probe.sh
PROBE_KIND=wfxt bash scripts/rpres-probe-vm.sh
bash scripts/compare-wfxt-results.sh HOST_JSON GUEST_JSON
```

Host execution is intentionally separate from the build/fixture script;
run its generated `probe-o0` and `probe-o2` binaries only after review and
with the outer timeout described below.

## Containment and validation

Each case uses a separate child with core dumps disabled and a one-second
alarm. The parent checks child completion against a three-second monotonic
deadline, killing an unreaped child if needed. Host execution additionally
used `gtimeout --signal=TERM --kill-after=2 30`; the existing guest helper uses
the corresponding Linux timeout. These are process-containment measures,
not a guarantee against an OS-level uninterruptible task or a timing bound
on instruction behavior. Timeout/error invalidates the capture.

The independent validator requires exactly four unique zero-input cases,
correct controls, and either correct markers or caught SIGILL for timed
instructions. It checks expected values independently of the capture.
The build/disassembly/synthetic-fixture suite passes 16 checks, including
missing rows, duplicates, wrong values, missing results, timeout, illegal
control faults, and multiple JSON documents. The suite itself does not run
the WFxT binary. Independent safety review preceded instruction execution.

Existing host regressions also pass: HBC 14 checks (`scratch/hbc-test.sYQLWt`),
CSSC 13 (`scratch/cssc-test.iXAMkx`), and RPRES 16
(`scratch/rpres-test.OVB86c`).

## Interpretation

An observed return or fault does not identify the hardware/HVF/kernel trap
path. Prior public M3 WFxT=0 and guest ISAR2=0 evidence is historical, not a
same-run raw-register capture. No CPU-feature override follows from these
tests. Future-deadline, event delivery, wakeup accuracy and M5 behavior remain
separate work; host scheduling delay is not a CPU-semantic failure.

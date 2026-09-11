# M3 Ultra RPRES instruction comparison

## Result — 2026-09-11 UTC

All **28** scalar guest observations match the host exactly: seven fixed
positive finite FP32 inputs, `FRECPE` and `FRSQRTE`, FPCR.AH clear/set.
Both captures report exact FPCR/FPSR restoration, requested control readbacks,
and zero exception flags during the samples. The host also matches a
QEMU-derived integer reference for these inputs.

This supports host-equivalent reciprocal-estimate behavior in the sampled
guest configuration despite the **previous** calibrated EL1 capture reporting
ISAR2.RPRES zero. It does not establish full CPU passthrough, all RPRES cases,
or raw physical register values. The new EL0 run did not reread ISAR2.

For input `1.0`, both operations produced:

| FPCR.AH | Host result bits | Guest result bits |
| --- | --- | --- |
| 0 | `0x3f7f8000` | `0x3f7f8000` |
| 1 | `0x3f7ff000` | `0x3f7ff000` |

The reference mirrors the integer algorithms in QEMU revision
`789e3d805f9ca84e64c40fe1b99129336ce911b8`,
`target/arm/tcg/vfp_helper.c`; it is not an independent Arm-specification
proof. QEMU's translator selects the enhanced FP32 helpers when both AH and
RPRES are present. The actual comparison uses HVF, not those TCG helpers.

## Evidence and safety

- Accepted run: `out/rpres-vm.aiJNkm/manifest.json`.
- Guest: `out/rpres-vm.aiJNkm/guest.json`.
- Comparison: `out/rpres-vm.aiJNkm/host-guest-comparison.json`.
- Matched host/reference: `scratch/rpres-test.6mtam4/host-o2.json` and
  `reference.json`; compiler, OS, time and source-hash records accompany them.
- Prior guest ID evidence: `out/el1-fork.Iy4tyA/smp-1/evidence.json`.

The accepted guest used one vCPU, 2 GiB, `-cpu host`, HVF with kernel IRQ chip,
and the current fork binary SHA-256
`ea37dd7dfff94f9702af1c37eb12016842b6b371a53a8dc50ccf7779deb1a60a`.
The standalone probe ran as UID 65534 with no new privileges. Its source
hash was checked against the protected host source. Guest writes went only
to a disposable qcow2 overlay; the source share was read-only. No network,
firmware, physical host device, or persistent VM configuration was attached
or changed. All 19 protected inputs had identical before/after hashes and
identities. QMP recorded a guest-originated shutdown; the overlay, FIFOs,
socket, PID control and shared lock were removed.

The first attempt, `out/rpres-vm.ExSX24`, executed the probe and shut down but
was rejected: terminal control text prefixed the source-hash marker. No
success manifest was produced. A leading newline fixed marker framing; the
accepted evidence above is from a fresh run, not a relaxed parser.

## Checks and reproduction

`bash scripts/test-rpres-probe.sh` passes 16 checks. These cover host `-O0`
and `-O2` equality, the reference comparison, non-default FP state restoration,
comparison mismatch detection, multiple-document rejection and malformed
observation rejection. Latest suite artifacts: `scratch/rpres-test.v4oaOs`.
Shell syntax checks pass for the host and guest runners. Independent reviews
covered the reference and VM runner before launch.

Run the disposable guest with `bash scripts/rpres-probe-vm.sh`, then compare
complete validated captures using:

```sh
bash scripts/compare-rpres-results.sh HOST_JSON GUEST_JSON
```

## Disposition

RPRES remains an advertisement/API-exposure gap, with no instruction-behavior
mismatch observed in this bounded test. Do not add speculative QEMU feature
overrides: the earlier trace showed the ID reads bypassing its userspace
handler, and no documented named public-HVF override has been found.

Next: incorporate this disposition into the remaining newer-ID gap analysis
and identify the next evidence-backed exposure issue. Broader FP corner-case
coverage and an independent architectural reference would strengthen this
result, but are not evidence of a currently observed execution failure.

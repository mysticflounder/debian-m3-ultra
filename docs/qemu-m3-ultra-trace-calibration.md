# M3 Ultra newer-ID trace calibration

## Result — 2026-09-10 UTC

The one-vCPU run passed, with exactly three trace records:

```text
qmp_enter_query_status {}
hvf_sysreg_read sysreg read 0x00280402 (op0=2 op1=0 crn=1 crm=1 op2=4) = 0x0000000000000000
qmp_enter_query_status {}
```

The OSLSR trace matches its successful guest read exactly. Both selected
events were enabled in all four pre/post QMP state replies. PFR2, ISAR2,
MMFR3 and MMFR4 again returned zero in the guest, but none produced a
`hvf_sysreg_read` record between the working controls.

This calibrated capture supports the conclusion that these four sampled
reads bypassed QEMU's userspace sysreg handler, including its RES0 fallback,
in this configuration. Handling below that path is the supported attribution;
the experiment does not distinguish HVF/kernel handling from hardware behavior,
and does not establish the physical CPU's ID values or feature absence.
There is no demonstrated QEMU newer-ID import defect to patch from this
evidence. Broader configurations and M5 Max remain untested here.

Evidence:

- `out/el1-fork.Iy4tyA/manifest.json` (`all_pass:true`).
- `out/el1-fork.Iy4tyA/trace-calibration-summary.json`.
- `out/el1-fork.Iy4tyA/smp-1/hvf-sysreg.trace` and `qmp.events.jsonl`.
- `out/el1-fork.Iy4tyA/smp-1/trace-control.json`, `new-ids.json`,
  `trace-control-markers.txt`, `new-id-markers.txt`, and `serial.raw.log`.
- Fresh host controls: `out/el1-trace-host.9LO8pS/host.json` and
  `provenance.json` in that directory.

QEMU 11.1.50 has SHA-256
`ea37dd7dfff94f9702af1c37eb12016842b6b371a53a8dc50ccf7779deb1a60a`.
The guest used kernel `7.1.10+deb14-asahi`, one vCPU and 2 GiB. The existing
register/cache controls passed: eleven exact comparable IDs, the known
virtual-PMU DFR0 difference, two SVE/SME `not_read` records and three exact
cache comparisons. All 25 protected inputs had equal before/after hashes
and identities. QEMU exited zero after a clean guest-requested shutdown;
the disposable overlay and runtime controls were removed. No persistent VM,
host device, firmware or CPU-feature setting was changed.

Follow-up: the [public-control audit](qemu-m3-ultra-public-hvf-controls.md)
found a macOS RPRES flag / guest ISAR2.RPRES advertisement mismatch, without
a documented named override. The [controlled instruction follow-up](qemu-m3-ultra-rpres-behavior.md)
matched all 28 sampled host/guest results; RPRES remains an advertisement gap.
Do not infer raw host values from guest zeros or make a speculative
QEMU feature override. This is not a performance-test gap.

## Scope and controls

This follows the [first guest newer-ID capture](qemu-m3-ultra-new-id-registers.md),
which read four zero values but produced an empty, uncalibrated trace.
The CPU model and interrupt-controller configuration remain unchanged:
one vCPU, `-cpu host -accel hvf,kernel-irqchip=on`.

The opt-in `NEW_IDS=1` probe now reads OSLSR_EL1 before the four newer IDs.
OSLSR is read-only debug OS-lock status, encoded as S2_0_C1_C1_4. QEMU has an
explicit handler returning `env->cp15.oslsr_el1`; a matching trace, if present,
would establish that the read actually reached this handler. The runner's
pass gate does not require an OSLSR trace record.

PMCR_EL0 was not selected: QEMU's explicit PMU read handler is gated by
`!hvf_irqchip_in_kernel()`. Changing interrupt-controller mode to make that
control work would change the configuration being investigated. OSDLR_EL1
was also avoided; its current handler returns without assigning the value.

Two independent controls are used:

- QMP verifies `hvf_sysreg_read` and `qmp_enter_query_status` are enabled
  immediately before the guest reads and after their completion.
- The same trace file must contain exactly two `qmp_enter_query_status`
  records from the pre/post status queries. This validates the logging
  pipeline independently of whether any guest register read traps to QEMU.

The OSLSR attempt/value records have their own strict parser. Neither a
missing value nor a fault is converted into zero. The existing fatal-guest
handling, default 420-second VM deadline, private overlay and owned-process cleanup
remain in place. No advertised CPU features or QEMU source are changed.

## Source anchors

In QEMU revision `789e3d805f9ca84e64c40fe1b99129336ce911b8`:

- `target/arm/hvf/hvf.c:189`, `:1757`: OSLSR encoding and read handler.
- `target/arm/debug_helper.c:262`: OSLSR's read-only access definition.
- `target/arm/hvf/hvf.c:1707`: PMU handler's interrupt-controller condition.
- `target/arm/hvf/hvf.c:2479`: successful sysreg-trap read tracepoint.
- `util/log.c:300`: log tracing sets `LOG_TRACE`; no extra `-d` is needed.
- `trace/control.c:247`: the log backend's trace-file setup.
- `qapi/trace.json:46`: QMP event-state query.

The generated trace headers in `out/qemu-fork-pmintenclr-build/trace/`
confirm that both selected events use the same log backend. A passing QMP
control alone is not an observation of the OSLSR handler or proof of
physical register passthrough.

## Reproduction and fixtures

Build/capture fresh host controls with `scripts/hvf-host-cpu.c`, then set
`HOST_JSON` to that capture:

```bash
NEW_IDS=1 SMP_LIST=1 HOST_JSON=/absolute/path/to/fresh/host.json \
  /bin/bash scripts/el1-fork-vm.sh
```

No-VM validation: 19 trace-control/QMP fixtures, 17 newer-ID fixtures and
27 EL1 harness fixtures passed before the real run. An independent read-only
safety review also passed. Fixtures test fault rejection; the runtime probe
does not deliberately execute a faulting instruction.

# Newer ID registers: HVF API-boundary investigation

## Host API result — 2026-09-09

The installed runtime rejects all four candidate newer-register encodings
through `hv_vcpu_get_sys_reg()`, returning `HV_BAD_ARGUMENT` (`0xfae94003`).
Seven named-register controls succeed and exactly match their HVF
configuration values. No newer-register value was obtained, and no QEMU
feature override is justified by this experiment.

| Candidate | Architectural tuple | HVF encoding | Runtime result |
| --- | --- | --- | --- |
| ID_AA64PFR2_EL1 | S3_0_C0_C4_2 | `0xc022` | rejected; value null |
| ID_AA64ISAR2_EL1 | S3_0_C0_C6_2 | `0xc032` | rejected; value null |
| ID_AA64MMFR3_EL1 | S3_0_C0_C7_3 | `0xc03b` | rejected; value null |
| ID_AA64MMFR4_EL1 | S3_0_C0_C7_4 | `0xc03c` | rejected; value null |

This establishes rejection by this getter on a default, never-run vCPU in
this runtime. It does **not** establish physical CPU feature absence, zero
register contents, rejection by every possible API/configuration, or the
value a guest MRS instruction would observe.

## Guest EL1 result — 2026-09-09

The subsequent one-vCPU disposable run completed all four MRS instructions.
PFR2, ISAR2, MMFR3 and MMFR4 each returned
`status=read value=0x0000000000000000`. These are measured guest zeros, not
missing reads or values synthesized from the host getter's errors.

The existing 15-register/cache controls also passed: eleven exact comparable
registers, the known minimal virtual PMU DFR0 difference, two explicit
SVE/SME `not_read` records, and three exact cache comparisons.

The enabled `hvf_sysreg_read` trace produced an empty file. The binary has
`CONFIG_TRACE_LOG`, and the saved command line contains the event option,
but this run has no positive trace control. It therefore does **not** prove
that QEMU's RES0 fallback supplied these zeros, or that the physical CPU
supplied them. Their servicing layer remains unresolved.

- Manifest: `out/el1-fork.BCVEz8/manifest.json` (`all_pass:true`).
- Raw newer-ID results: `out/el1-fork.BCVEz8/smp-1/new-ids.json`.
- Attempt/value records: `out/el1-fork.BCVEz8/smp-1/new-id-markers.txt`;
  live console and replay are retained in `serial.raw.log` in that directory.
- Trace: `out/el1-fork.BCVEz8/smp-1/hvf-sysreg.trace` (zero bytes).
- Fresh host controls: `out/el1-new-id-host.OI1YTU/host.json`, with
  `provenance.json` in the same directory.
- QEMU 11.1.50 SHA-256:
  `ea37dd7dfff94f9702af1c37eb12016842b6b371a53a8dc50ccf7779deb1a60a`.
- Guest kernel: `7.1.10+deb14-asahi`; one vCPU, 2 GiB,
  `-cpu host -accel hvf,kernel-irqchip=on`.
- Process exit zero, clean guest-requested QMP shutdown, no QMP errors.
  All 24 protected inputs had identical before/after hashes; the disposable
  overlay, FIFOs, QMP socket, PID file and shared probe lock were removed.

This closes the guest-value question for this configuration only. It does
not establish physical host values, correctness of individual feature bits,
or the contract on other CPU counts or M5 Max. No QEMU patch is justified by
the four zeros alone.

## API contract versus experiment

The installed macOS SDK 26.5 headers name none of these four registers in
either `hv_feature_reg_t` or `hv_sys_reg_t`. The feature-query enum and the
system-register enum are different interfaces; architectural encodings must
not be passed to the configuration feature-query API.

Apple describes a system-register getter taking an `hv_sys_reg_t`, called
from the vCPU's owning thread. Its documented contract does not promise
acceptance of these unnamed numeric IDs. Passing their encodings is an
explicit runtime experiment, not use of a documented supported-register
list. See Apple's [system-register getter](https://developer.apple.com/documentation/hypervisor/hv_vcpu_get_sys_reg%28_%3A_%3A_%3A%29?language=objc)
and [configuration feature getter](https://developer.apple.com/documentation/hypervisor/hv_vcpu_config_get_feature_reg%28_%3A_%3A_%3A%29?language=objc).

The probe compares configuration and initial vCPU values for named PFR0/1,
ISAR0/1 and MMFR0/1/2. All seven controls succeeded and matched exactly.
Successful reads of these controls show the getter was operational; they
do not turn the four rejected queries into successful zero reads.

## Safety and evidence

`scripts/hvf-new-id-probe.c` creates a configuration object and one default
VM/vCPU, performs getters on the owning thread, then destroys the vCPU and
VM and releases the configuration object. It refuses host-root execution.
It never maps guest memory, executes a guest, writes registers, or opens disk
images, firmware, devices or networking. No persistent VM was touched.

- Runtime: macOS 26.6.2, build 25G83; SDK 26.5.
- Result: `out/hvf-new-id.OGYRNq/result.json`.
- Source/binary/result hashes and host version metadata:
  `out/hvf-new-id.OGYRNq/metadata.json`.
- Process exit status: zero. VM create, vCPU create, vCPU destroy and VM
  destroy all returned success. Candidate rejection is a collected result,
  not a claim that those registers are supported.
- Execution had a 15-second deadline and core dumps disabled. The executable
  was ad-hoc signed with only `com.apple.security.hypervisor`.

There were no QEMU source edits. The inspected QEMU checkout remains
`789e3d805f9ca84e64c40fe1b99129336ce911b8`. This standalone framework probe
does not instantiate QEMU or reproduce QEMU's CPU-finalization sequence.

## QEMU source trace and disposition

`qemu/target/arm/helper.c:6621`, `:6714`, `:6759`, and `:6764` define the
four architectural register tuples. The probe's bit layout is checked at
compile time against named PFR0 and MMFR2 SDK constants.

`qemu/target/arm/hvf/hvf.c:1135` initializes the host ID-register snapshot
and queries named configuration feature IDs. PFR2, ISAR2 and MMFR3 are
explicitly left for future HVF support; MMFR4 is also not imported.

For a trapped, otherwise-unhandled architectural ID read, the range check at
`hvf.c:1693` and fallback at `:1875` return RES0. These reads do not fall
through to `hv_vcpu_get_sys_reg()`. This is source behavior **if the read
traps and reaches that fallback**. The guest follow-up measures zero values
but does not establish that these reads took this QEMU path.

Disposition: retain an API gap for the inspected named interfaces and record
the experimental getter rejection, alongside the measured guest zeros. Do
not infer a QEMU defect merely from the absent import, and do not fill fields
using chip-name guesses. The bounded follow-up was to calibrate tracing with
a known QEMU-serviced read and verify event enablement before attributing
the newer-ID read path.
Physical host values remain a separate requirement before any import patch;
guest zero alone is not a safe host import source.

Follow-up completed: the [calibrated trace](qemu-m3-ultra-trace-calibration.md)
records the OSLSR control in QEMU's userspace handler, with both trace events
enabled before/after, but none of the four newer-ID reads. All four again
returned zero. This supports handling below QEMU's userspace sysreg handler
rather than its RES0 fallback, while leaving HVF/kernel versus hardware
behavior and physical host values unresolved.

## Guest follow-up protocol

The current-fork EL1 runner has an opt-in `NEW_IDS=1` mode. Its default
remains the existing 15-register/cache capture. The opt-in module emits an
ATTEMPT immediately before each newer MRS, and a VALUE only after it returns.
The separate parser requires all four ordered attempt/value pairs per CPU;
successful zero is a read value, never an exception or a missing result.

There is no in-module UNDEF recovery. The disposable guest sets
`panic_on_oops=1`, `panic=0`, and enables console logging before insertion.
A guest oops/panic, absent completion, or malformed record aborts the run;
the owned-process cleanup and VM deadline bound the failure. Registers after
a fault remain untested. No value is inferred from an attempt marker alone.

The opt-in run also enables the existing `hvf_sysreg_read` tracepoint. A
matching tuple/value records QEMU servicing a trapped read; lack of a trace
does not establish physical passthrough. CPU features, QEMU source, and the
persistent VM remain unchanged. The test uses a disposable root overlay,
read-only backing/build/source inputs, and no network or host devices.

## Reproduction and fixtures

Run from this repository as the normal host account, with a new output
directory. The only entitlement used is the existing one-key QEMU HVF plist.

```bash
probe_dir=$(mktemp -d "$PWD/out/hvf-new-id.XXXXXX")
clang -std=c11 -Wall -Wextra -Wpedantic -Werror -O2 \
  scripts/hvf-new-id-probe.c -framework Hypervisor -o "$probe_dir/probe"
codesign --sign - --entitlements qemu/accel/hvf/entitlements.plist "$probe_dir/probe"
codesign --verify "$probe_dir/probe"
ulimit -c 0
/opt/homebrew/bin/gtimeout --foreground --signal=TERM --kill-after=2 15 \
  "$probe_dir/probe" > "$probe_dir/result.json"
```

`/bin/bash scripts/test-hvf-new-id-probe.sh` passed five no-VM mocked cases:
rejected candidates with null values, a successful numeric zero, control
failure, vCPU-create failure, and vCPU-destroy failure. All VM/vCPU lifecycle
and runtime register entry points are replaced with mocks; the real calls
remaining in that test are the VM-free configuration API. The actual
diagnostic also compiled with warnings treated as errors and passed a
separate read-only safety review before execution.

For the guest follow-up, build/capture fresh host controls using
`scripts/hvf-host-cpu.c`, then run:

```bash
NEW_IDS=1 SMP_LIST=1 HOST_JSON="$PWD/out/el1-new-id-host.OI1YTU/host.json" \
  /bin/bash scripts/el1-fork-vm.sh
```

Replace the recorded `HOST_JSON` path with the fresh capture for a new run.
Validation passed 17 no-VM newer-ID parser cases, 27 EL1 runner/parser cases
(including synthetic oops/panic rejection), and 85 ABI-matrix regression
cases. Fault handling was tested with fixtures, not an intentionally faulting
guest instruction. Independent code/safety review preceded the real run.

# Newer ID registers: HVF API-boundary investigation

## Result — 2026-09-09

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
traps and reaches that fallback**, not a measurement that these four reads
actually trap or return zero in our guest.

Disposition: retain an API gap for the inspected named interfaces and record
the experimental getter rejection. Do not infer a QEMU defect merely from
the absent import, and do not fill fields using chip-name guesses. The next
bounded measurement is the guest EL1 view of these four registers, with
explicit exception/fallback handling and no changes to advertised CPU
features. That would distinguish guest exposure from host-side getter
availability; it would not by itself establish a safe host import source.

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

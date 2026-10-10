# J575d experimental select polling — 2026-10-09

This optional Linux prototype exercises ACE3 logical-register selection
without a select interrupt. It is an offline development artifact. The
existing four-interrupt path remains the default, and the J575d device-tree
candidate remains disabled.

## Why this work can proceed

Pro consult `01M4EWE11E4FR4ZNSBYPZBFKYQ` completed in channel message 18760.
Its primary-source review supports using the established Linux SPMI API as
the boundary for an offline prototype. Native command equivalence still
needs independent controller evidence; the offline prototype can test its
software policy before that evidence is available.

The [Linux SPMI API](https://github.com/torvalds/linux/blob/master/drivers/spmi/spmi.c)
provides register-zero writes and register reads. The October 1
[Apple controller command patch](https://lkml.iu.edu/2610.0/02377.html)
is already represented in the retained USB-common source closure. It does
not establish J575d selection freshness or replace the missing board IRQ
evidence. Native command kinds 6/7 and modes `0x2`/`0x12` are not equated
with Linux wire opcodes.

## Prototype policy

Polling requires `apple,experimental-select-polling` with the three named
interrupts `irq`, `sleep`, and `wake`. A missing or failed select-IRQ lookup
does not enable polling. Deferred IRQ domains, malformed metadata, and
mapping errors remain errors.

Every logical operation writes its selector, including consecutive operations
on the same register. A new local observation starts on each call: polling
must see the matching busy value and then the exact ready value within a
monotonic deadline. A ready-only trace cannot reach payload transfer. Bus
errors propagate, mismatched status terminates the operation, and timeout
returns `-ETIMEDOUT`. The existing regmap mutex continues to cover selection,
status checks, and payload transfer.

This policy is intentionally conservative. It can reject a valid completion
whose busy interval was too short to observe. Observing busy then ready does
not prove a new hardware command epoch: an earlier timed-out operation or
another client remains an unresolved case. Host tests establish the stated
software behavior only.

### Timeout/retry ambiguity — 2026-10-10

An additional actual-source host fixture now exercises two complete read
callbacks on the same driver/device object. The first times out while status
remains busy and performs no payload transfer. Without resetting the driver
or modeled clock, the second writes the same selector, observes busy then
ready, and transfers one payload byte. The environment labels those two
status samples as belonging to the older request; those labels are deliberately
invisible to the driver. The same visible trace could instead be a fresh
completion. Thus the result demonstrates an observational ambiguity, **not**
that J575d hardware actually returns stale status.

Clean busy/ready success and ready-only rejection also pass. Both baseline
and mutation builds use ASan/UBSan; removing the busy-observation guard fails
the designated ready-only assertion with exit 1. Main review strengthened the
first-timeout case to invoke the full read callback, checked both selector
writes and second-call payload transfer, and reran the suite. Receipts:
`scratch/j575d-selector-epoch-fixture-2026-10-10/parent-review/epoch-27km9xva/`.
The runner SHA-256 is
`de348ae5d7c311a7a6ff42399aad980e24c30f9a3b46691620005426372c2498`;
the extracted patched driver is
`dd78cc3bbd35b2283363d9a3e49b69bec84bc66ea6454b3b1ae872a4b2104f1d`.

The bounded native HPM trace does not resolve this ambiguity. In the basic
read method, a matching ready sample can enter the post-poll path without
observing busy first (`0x9805c44..0x9805cc0`). Counter exhaustion can also
reach that path when the tracked helper result is zero. Imported
`IOEventSource::closeGate/openGate` establish local serialization, not the
age of hardware status or exclusion of every other client. These observations
are not a reason to copy native error/timeout policy into Linux. The original
image verifier passes; retained report and verifier are under
`scratch/j575d-selector-freshness-2026-10-10/`.

Further host tests cannot establish the missing device semantics. Promotion
needs independent evidence that selector submission invalidates prior state,
or a documented completion/abort/reset contract that distinguishes requests
(or a qualified select-IRQ route). No such hardware operation is inferred
or authorized here. Keep the prototype default-off; do not add speculative
reset writes or claim that busy/ready alone proves freshness.

## Validation

Patch `0006-typec-tipd-experimental-select-polling.patch` is optional and
requires the existing `0004-apple-spmi-and-ace3-bindings.patch` binding overlay.
The standalone build script applies both to a copy of the prepared
`j575d-phy-usb-common.W3594q` tree. Neither patch is inserted into a normal
build recipe by this change.

The polling budget is 100 ms, with a 1–1.5 ms sleep and a separate limit of
128 status samples. The deadline includes the selector write and is checked
before and after status reads. Selectors with bit 7 set are rejected.

The following checks pass:

- The Clang ASan/UBSan host fixture compiles the actual patched polling,
  selection, read/write, IRQ, metadata-validation and probe functions. It
  checks repeated selection, ready-only rejection, late completion, distinct
  bus/parser errors, payload cutoffs, IRQ deferral, malformed opt-ins and the
  legacy path. It does not exercise kernel scheduling or real regmap locks.
- Removing the busy-observation guard makes the designated stale-ready test
  fail with exit 1. The unmodified control passes.
- `dt-doc-validate` passes. Two valid and seven invalid compiled DT fixtures
  pass their expected schema outcomes. A separate empty `interrupts;`
  fixture compiles, but is not counted as a schema rejection: cached dtschema
  2026.9 crashes decoding it. Runtime tests reject zero parsed IRQ entries.
- The ARM64 build completes in-tree modpost for the prepared 20-module
  dependency set, with no compiler warnings or unresolved symbols. The
  offline package contains the three TIPD modules. Host-test and module-build
  `spmi.c` are byte-identical; the ten recorded base inputs are unchanged.

Reproduce with the existing prepared tree, builder image and offline cache:

```sh
UV_CACHE_DIR=scratch/j575d-schema-validation-2026-10-07/uv-cache \
  uv run --offline --no-project python scripts/test-j575d-select-polling.py \
  --output-dir scratch/select-polling-host-check
UV_CACHE_DIR=scratch/j575d-schema-validation-2026-10-07/uv-cache \
  uv run --offline --no-project python tests/test-j575d-select-polling-binding.py
scripts/build-j575d-select-polling-offline.sh
```

The [validation inventory](inventory/j575d-select-polling-prototype-2026-10-09.json)
records final source, test and build receipts. These checks do not qualify
polling for J575d hardware or establish cross-client serialization.

## Remaining qualification

Native controller completion/error semantics, repeated-selector freshness,
window-reset behavior, actual interrupt routing, and J575d applicability
remain open. CIO80 protocol/resource mapping and the USB2 tuple
consumer/base/role phase are separate unresolved contracts. This prototype
does not supply those mappings or change their register values.

The 822-record candidate, normal build recipes, persistent VM, and default
native-dispatch setting are outside this prototype's changes. Native testing
still requires verified backup and recovery readiness plus separate approval.

# J575d native SPMI dispatch — 2026-10-10

The retained Apple image resolves more of the native command path than the
October 8 audit established. This is static evidence, not native execution or
approval to enable the experimental polling driver.

## Corrected dispatch

The original-address call from `sendCommand` at `0xfffffe0008cb5bc4` to
`0xfffffe0008ceaa78` reaches an authenticated stub for
`_ml_get_interrupts_enabled`, not an SPMI transaction implementation. The
target at `0xfffffe000be75860` reads DAIF and tests `~DAIF & 0x1c0`.
The false-result branch sets bit `0x4` at command offset `0x10` before taking
the controller's own dispatch path.

The constructors install vptrs at the vtable symbol plus `0x10`. Omitting
that address-point adjustment produced incorrect method labels in the first
October 10 scratch report. Independent review and the corrected byte checks
establish these mappings for the retained base factory/constructor path:

| Receiver | Runtime vptr offset | Effective symbol-relative offset | Target |
| --- | --- | --- | --- |
| Command gate at controller `+0xe0` | `+0x1e8` | `+0x1f8` | `IOCommandGate::runAction`, `0xfffffe000c50b93c` |
| Controller base | `+0x980` | `+0x990` | `AppleARMSPMIController::executeLoggedCommand`, `0xfffffe0008cb4d2c` |
| Concrete `AppleSPMIController` | `+0x958` | `+0x968` | `AppleSPMIController::executeCommand`, `0xfffffe0009de2c64` |

`executeLoggedCommand` logs the command, invokes the controller's nested
slot `+0x958`, logs the returned result, and returns it. The wrapper alone
does not establish response decoding, completion or wire-command encoding.

## Concrete implementation exists

The abstract `AppleARMSPMIController` table's nested slot points to
`___cxa_pure_virtual`. That is not evidence that the concrete implementation
is absent. A fresh full-image symbol search finds `AppleSPMIController`,
including its vtable at `0xfffffe0008307c60`, `executeCommand` at
`0xfffffe0009de2c64`, `registerReadWriteCommand` at
`0xfffffe0009de1e98`, and `extendedReadWriteCommand` at
`0xfffffe0009de5678`.

The retained service registry also identifies this concrete class below
both relevant providers: `nub-spmi-a0` with HPM0–3 and `nub-spmi-a2` with
HPM4–5. This connects the captured service class to a concrete implementation
available for further static tracing; it is not a live vptr or execution
observation. The concrete constructor also installs symbol plus `0x10`;
its execution slot resolves to `executeCommand`. The next step is to follow
the transaction helpers reached by that dispatcher, including their wire,
completion and error paths. The bounded follow-up below establishes part of
that path, but not hardware qualification.

## Command packing and completion follow-up

The reviewed helper bodies establish a kind-indexed table containing `0x60`
for kind 6 and `0x80` for kind 7. Kind 7 requires a zero register parameter
and one data byte. Its packed word includes that byte at bits 24–31, but does
not OR it into the low byte. The helper's boolean controls bit 15; the field
at controller offset `0x194` is shifted by eight. The identity of that field
must not be assumed from its position alone.

For a seven-bit selector `d`, the retained Linux controller instead packs:

```text
0x80 | d | (sid << 8) | 0x8000 | (d << 24)
```

Thus, even assuming the same shifted field and bit 15, the two intermediate
words differ in their low seven bits for nonzero selectors. This is not a
demonstrated wire mismatch or Linux bug: downstream register interpretation
and handler behavior still need tracing. No driver change follows from this
comparison.

The Linux reference executes five extracted source functions in a sanitized
host fixture. The parent reviewed the runner and fixture and reran all 2,048
zero-write cases (16 USIDs × 128 selectors) and 512 ordinary-read cases
(16 × 32 addresses), plus the invalid-address cutoff. They pass. Raw command
wrappers are captures, not a bus simulation; the test establishes software
packing only. Receipts are in
`scratch/j575d-spmi-linux-packing-2026-10-10/linux-packing-5d80c701/`.

The native helper's runtime slot `+0x9c0`, after the address-point adjustment,
resolves to `waitForResponse` at `0xfffffe0009de1500`, not `lockBus`.
Its interrupt and polled branches resolve to `runInterruptMode` and
`runPolledMode`. The helpers subsequently call `queuePop`.

`queuePop` obtains a descriptor through handler slot **0**: `0x198` in the
authentication sequence is a PAC discriminator, not a vtable offset. It loads
the state through the pointer at descriptor `+8` and tests the mask at
`+0x2c`. While the mask is set it waits and retries, propagating a nonzero
wait result. When clear, it reads the status through the pointer at `+0x18`
and copies that word to the caller. This does not yet identify those pointers
as hardware registers or prove a fresh response to this command.

The requested flag values are hexadecimal `0x2` and `0x12`; both have bit
`0x4` clear in the caller's boolean gate. The register helper's optional
payload-byte packing depends on `((kind - 1) & 0xf9)`, not these flags.
Neither numeric flag is assigned a protocol meaning by this trace.

The remaining immediate edge is the concrete handler/descriptor construction
and register mapping, followed by response decoding and command freshness.
Helper and completion byte checks pass; their corrected semantic review is
retained in `scratch/j575d-spmi-controller-2026-10-10-review/`.

## Evidence and limits

Input: `scratch/kernelcache-tool-reviewed.macho`, SHA-256
`a24fefccc060854cecc996b40983499e1319008e4f16c0717a5fef6c4d4828dc`.
The corrected extraction and independent review are retained under
`scratch/j575d-spmi-controller-2026-10-10/` and
`scratch/j575d-spmi-controller-2026-10-10-review/`.
The parent reran `verify.py` successfully after reviewing its checks: full
image and four function-range hashes, authenticated targets, corrected table
entries and constructor address-point instruction anchors. These checks
verify the selected static receipts, not every aspect of runtime dispatch.
The separate `execute/verify.py` also passes: it checks the abstract table's
pure-virtual entry, the concrete override and the concrete constructor and
execution-body hashes. The two verifier script hashes are respectively
`000e9f485fbe1464482e15fcc98d3adbc6287c057102bc310ec5d51b58d2528d`
and `4696b060e6a19e6614daa024814f56b0504472f8d3d42cf12dcaccc988396e44`.

Registry source: the prior audit's `host-registry/ioreg-service-text.txt`,
SHA-256 `cf4f681047520d666fea5f9ddfbb4b4b87875240740ecde3cc147e29c524ebad`.
Relevant hierarchy lines are 39118–39876 and 40200–40434. The complete
191-line concrete-class symbol selection is retained in
`scratch/j575d-spmi-controller-2026-10-10/execute/parent-symbol-hits.txt`.

No native kind-to-Linux-opcode equivalence follows yet. Repeated-selector
freshness, hardware window reset, CIO80 protocol mapping and the USB2 tuple
consumer remain unqualified. The polling prototype stays default-off;
no board candidate, driver, VM or hardware state changes follow from this
trace. Native validation still requires backup/recovery readiness and
separate approval.

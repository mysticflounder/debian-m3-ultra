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

The constructors install primary vptrs at the vtable symbol plus `0x10`. Omitting
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

Helper and completion byte checks pass; their corrected semantic review is
retained in `scratch/j575d-spmi-controller-2026-10-10-review/`. The subsequent
mapping trace below closes the descriptor-construction edge; response
decoding and command freshness remain separate work.

## Gen3 descriptor and provider mapping

Both captured HPM providers, `nub-spmi-a0` and `nub-spmi-a2`, have
`gen=<03000000>`. The factory selects `AppleGen3SPMIHandler`, whose vtable
slot 0 is `getSPMIRegisters`. It returns the embedded descriptor at handler
offset `0x28`.

The controller maps provider resource index 0, retaining the `IOMemoryMap*`
at `self+0x110` and its `getVirtualAddress()` result at `self+0x118`.
Resource index 1 uses distinct fields `self+0x1aa8` and `self+0x1ab0`.
Both values passed to handler initialization are mapped virtual addresses,
not memory-map objects. Call arguments, stores and biased virtual slots were
independently reviewed and the strengthened byte verifier passes.

For the first mapped address `base`, Gen3 initialization establishes:

| Descriptor field | Value | Traced use |
| --- | --- | --- |
| `+0x8` | `base` | Pointer used for queue-state reads |
| `+0x10` | `base + 4` | Pointer used for command-word writes |
| `+0x18` | `base + 8` | Pointer used for response-word reads |
| `+0x2c` | `0x01000000` | Queue response-empty mask, bit 24 |

These offsets and the empty mask agree with the retained Linux register
definitions. The captured first physical resources are `0x2a1188000` for a0
and `0x2a11a8000` for a2, each `0x4000` bytes. Numeric kernel virtual
addresses are not captured, and this is not a live hardware test.

Receipts are under `execute/handler/` and `execute/provider-map/` within the
SPMI scratch directory above. Their checks pin the image and registry, verify
the scoped generation properties and explicitly decode the mask as a
little-endian 32-bit value. The first scratch interpretation, `0x10000`, was
incorrect and is superseded by `0x01000000`.

Register-window provenance is now established at this static/captured-metadata
boundary. Remaining work includes response decoding, the meaning of the
shifted controller field, downstream selector-bit interpretation and
freshness. Matching register offsets alone does not settle those contracts.

## Linux FIFO recovery correction

Patch `0007-spmi-apple-fifo-recovery-register.patch` corrects the retained
Linux recovery write from `SPMI_RSP_REG` (`+0x8`) to `SPMI_ACT_REG`
(`+0xa4`). It changes only the flush target when `prev_fail` is set.
The [published upstream v10 FIFO patch](https://lists.openwall.net/linux-kernel/2026/10/01/2633)
already uses ACT; this is alignment with that authored correction, not a
claim of a new upstream discovery or of mainline acceptance.

All four USB/Fabric/USB-common/select-polling offline recipes include the
correction. Historical build receipts remain unchanged. A fresh build at
`scratch/j575d-select-polling-offline.dfzHSr/` exits 0 and links the
20-module closure. The package includes the three TIPD modules and the
corrected `spmi-apple-controller.ko`, which is byte-identical to the built
module (SHA-256
`c128daf99e96a5527c94fb7fa1ff4bf212415c6d5ead931d9340a481cec3082f`).
The earlier `p34D6W` build compiled the correction but omitted it from the
package; it is retained as historical evidence, not the corrected overlay.
The final build's `SHA256SUMS`, `PACKAGE_SHA256SUMS`,
patch-application log and bounded base-input manifests retain the evidence.

`scripts/test-j575d-spmi-fifo-recovery.py` copies the retained source into a
disposable tree, applies the patch with zero fuzz, extracts the actual
pack/wait/raw-command functions and compiles them with ASan/UBSan.
The normal command emits no recovery write; a timeout followed by retry
emits an ACT flush before the next command. ACK/reset counts and final
`prev_fail` state are checked, but their relative ordering is not separately
asserted. Reverting the target to RSP causes exactly exit 1 at the designated
ACT-address assertion. Payload loops, parity/ACK errors, concurrency and
hardware behavior are outside this fixture's coverage.

The independent audit and original test receipt are retained under
`scratch/j575d-spmi-fifo-recovery-2026-10-10/`; the parent rerun is
`parent-review/fifo-recovery-un32vx1j/`. Patch SHA-256:
`5c14ed442baf9aa557d0d64a59a0c739ad5904521777d50ce639ee90fea3227f`.
Patched controller SHA-256:
`480acad25605cd8b3867b71fb4e3abab50fa7a9fc42ca6d7bbb7e7df4d70e389`.
The correction does not enable experimental polling or authorize native
testing; response interpretation and selector freshness remain unresolved.

## Native response comparison

The original-address table at `0xfffffe000774673c` supplies mask `0x0fe0`
for kind 6 and `0x0f80` for kind 7. The helpers test
`(response ^ submitted_word) & mask` at `0x9de23c4/0x9de23c8` and
`0x9de2adc/0x9de2ae0`. Zero difference reaches further checks, not an
immediate success return. A mismatch with controller flag `+0x125` bit 0
set marks `+0x1a8` and takes an error return. With that flag clear, a
virtual call at runtime `+0x960` reaches `spmiPanic`, as resolved below.
This is not a traced command retry or a freshness guarantee.

For kind 6, the later register path requires response bit 16 before consuming
a second FIFO word through `queuePop` at `0x9de2540`. A cold helper copies
that word's low byte into the supplied destination at `0x9de7c8c/0x9de7c90`.
The kind-7 payloadless path checks response bit 15 at `0x9de2bec`.
These bit positions correspond structurally to Linux's one-byte parity and
write-ACK checks, but that comparison alone does not establish complete
protocol or error-policy equivalence.

Unlike Linux's baseline below, native code therefore contains a masked
response-versus-command comparison. Whether Linux needs such a check on
this hardware remains unresolved. The static configuration producer and
mismatch policy are traced below; the hardware response contract still needs
qualification. No driver change is inferred from this difference alone.
The reviewed original-address
disassembly and passing byte/table verifier are retained under
`scratch/j575d-spmi-response-2026-10-10/native/`.

## Mismatch diagnostic target

Concrete runtime slot `+0x960` is vtable-symbol offset `+0x970`, containing
raw pointer `0x8011ca6802de29b0`. It resolves to
`AppleSPMIController::spmiPanic` at `0xfffffe0009de69b0`. The reviewed body
converges on the four-instruction authenticated veneer at `0x9de828c`.
That veneer's data slot at `0x8308fd8` contains `0x8011000005614edc`, which
rebases to the full-image `_panic` symbol at `0xfffffe000c618edc`.
The extracted wrapper has no return instruction and calls the internal panic
implementation. This is a kernel-panic dispatch, not an ordinary returning
log call. The internal panic implementation was not executed or qualified.

The response helper's policy guard is controller `+0x125` bit 0. A separate
`+0x124` test inside `spmiPanic` controls additional diagnostic work; it does
not replace the helper's guard. The bounded `start` path calls
`getIntParam` at `0x9de0f10` with the exact name
`req-resp-mismatch-no-panic` (string at `0x7747ad2`), index zero and a
zero-initialized output word. A successful nonzero result sets `+0x125`;
missing/failed lookup or a zero value leaves it clear. Thus this observed
initialization selects an error-return opt-out versus kernel-panic dispatch
for a masked mismatch. This is static policy evidence, not a read of the
running controller's flag or an exhaustive audit of all writers. Linux
should not acquire a kernel-panic policy merely to imitate this implementation.
Receipts and the reviewed verifier are under
`scratch/j575d-spmi-mismatch-policy-2026-10-10/`.

## Configuration-field provenance

The concrete `setConfig(AppleARMSPMIConfig*)` body at
`0xfffffe0009de3718` loads the first 32-bit configuration word and stores it
at controller `+0x194` (`0x9de3720/0x9de3724`). Its concrete vtable entry
is symbol-relative `+0x960`, hence runtime slot `+0x950` after the address
point adjustment. The bounded byte/vtable verifier passes.

This establishes the configuration-to-field edge. The command helper shifts
the full 32-bit field left by eight without an observed narrowing mask; its contribution
must not be described as confined to bits 8–15. An immediate-offset scan
found this matching store, but cannot exclude computed or other access
forms. Receipts are under
`scratch/j575d-spmi-response-2026-10-10/controller-field/`.

A follow-up identifies `AppleARMSPMIController::updateConfig` at `0x8cb48e8`
(runtime slot `+0x968` in both base and concrete vtables). It zeroes 24
stack bytes, calls its source object's runtime slot `+0x888` with that output
buffer, and passes the same buffer to `setConfig` through runtime `+0x950`.
It then retains the source object at controller `+0xf8`. The reviewed bytes
and passing verifier for this buffer handoff are retained in
`scratch/j575d-spmi-config-producer-2026-10-10/`.

### Device configuration source

The full retained module names the source method
`AppleARMSPMIDevice::getSPMIConfig` at `0x8cb64ac`. Its complete 48-byte
body copies device `+0x90..+0xa7` to the caller's 24-byte buffer, or returns
`0xe00002c2` for a null output pointer. The device constructor installs the
vtable address point at symbol `0x7fffdc8 + 0x10`; runtime slot `+0x888`
therefore resolves to this getter. The adjacent runtime `+0x890` resolves
to `setSPMIConfig` at `0x8cb64dc`.

`initWithRegistryEntry` requests the literal `reg` property at
`0x8cb6d28..0x8cb6d38`, casts it to `OSData`, requires a length of at least
24 bytes (`0x8cb6d78/0x8cb6d7c`), and passes its bytes to `setSPMIConfig`
at `0x8cb6dd0`. The setter copies those 24 bytes only after its controller
interface's runtime `+0x10` returns a set low bit. Its diagnostic paths also
return zero, so the initializer's return-value test is not by itself a
write-success witness.

For the retained concrete `AppleSPMIController`, the constructor installs
the secondary interface vptr at object `+0xa0` using **symbol `+0xa50`**,
not primary address point `+0xa50`. At address `0x83086c0`, interface slot
`+0x10` contains encoded qword `0x80110f8201cb21d0`, which resolves under
the pinned collection's image-base/low-32-bit convention to `0x8cb61d0`.
That inherited `isValidConfig` adjustor body returns one. `publishBelow`
passes controller `+0xa0` to the device factory, and the device initializer
stores that interface at device `+0x88`. This closes the validation gate for
this static construction path; it does not measure live object contents.

The captured registry's six `AppleARMSPMIDevice` HPM children provide these
little-endian configuration words:

| Device | First `reg` word | Remaining five words |
| --- | --- | --- |
| hpm0 | 12 | 3, 0, 4, 0, 0 |
| hpm1 | 10 | 3, 0, 4, 0, 0 |
| hpm2 | 8 | 3, 0, 4, 0, 0 |
| hpm3 | 6 | 3, 0, 4, 0, 0 |
| hpm4 | 12 | 3, 0, 4, 0, 0 |
| hpm5 | 10 | 3, 0, 4, 0, 0 |

These are captured inputs to the proven initialization path, not sampled
controller `+0x194` values. The public setter can replace the device's
configuration later. No complete writer census, runtime USID observation,
or wire-equivalence claim follows. Registry evidence is retained in
`scratch/j575d-select-irq-audit.dzecri/host-registry/ioreg-service-text.txt`;
getter/initializer/interface receipts are in
`scratch/j575d-spmi-config-getter-2026-10-10/`.

### Configuration refresh before commands

The secondary interface's first entry at `0x83086b0` resolves to
`0x8cb5c9c`, the `sendCommand` adjustor which subtracts `0xa0` from the
interface receiver before entering `0x8cb5ba8`. Device register commands
place the device pointer in command word zero and dispatch through the
interface stored at device `+0x88`.

With interrupts enabled, `sendCommand` bypasses the command gate only when
controller byte `+0x100` is set and command word zero equals the source
retained at controller `+0xf8`. Otherwise it tail-calls `runAction` on the
command gate. The gated enqueue path calls `updateConfig` with command word
zero at `0x8cb4aa0`, then `executeLoggedCommand` at `0x8cb4adc`. The explicit
bus-lock path calls `updateConfig` with its device argument at `0x8cb4c9c`
before setting byte `+0x100`; final unlock clears the retained source.
These establish refresh/serialization edges, not hardware completion.

When interrupts are disabled, `sendCommand` instead sets command flag
`0x4` and dispatches directly; this body does not refresh configuration on
that branch. It is therefore incorrect to claim that every command refreshes
configuration. Likewise, the startup load at `0x8cb4130` is runtime
`+0x978` method-pointer setup, not an `updateConfig` call. Reviewed caller
receipts are in `scratch/j575d-spmi-config-callers-2026-10-10/`.

Both final verifiers pass against the pinned original image. Main review
also checked the disassembled branches and receiver/argument flow; byte
hashes alone do not prove those interpretations. Final verifier SHA-256s:

- Getter/source: `8ba098e12a4cf84d228c19be86690ab2777aa1ab38555741a9f46e23339d519a`.
- Callers: `d28b6473074557d484827675af7adb2cad0884b9736fd2d36dea4c884bfc3a2b`.

The next functional questions are selector freshness and the remaining
CIO80/USB2 contracts, not the now-traced 24-byte configuration source.

## Linux response baseline

The corrected Linux source checks bit 15 for an acknowledgment when no input
payload is requested. For a one-byte read it instead checks bit 16 of the
reply's parity-status field and copies the low byte of a second FIFO word.
ACK is not required for that read. It does not compare the response's command
or slave fields against the submitted word in this path.

An actual-source ASan/UBSan fixture exercises two write-ACK cases, all 256
payload bytes times two parity states times two ACK states (1,024 reads),
missing/extra FIFO data and a completion timeout. Typed, ordered status and
response-read queues must be fully consumed. An invalid register offset is
rejected by the fixture. ACK/parity failures return `-EIO` without setting
`prev_fail`; missing payload data and timeout set it. Extra FIFO data sets it
but does not by itself fail the otherwise valid command. A failed parity
check occurs after the byte has been copied; callers must honor the error.

The explicit mismatched-header case (`reply = BIT(16) | 0x1234`, request
opcode `0x60`, slave 1) still returns the supplied byte successfully. This
records source behavior, not a demonstrated hardware failure or a decision
to add response matching. It does not establish freshness.

Main review and rerun passed at
`scratch/j575d-spmi-response-2026-10-10/linux/parent-review/response-yeiqxwvv/`.
Both ACK-condition and parity-condition mutations fail with exit 1 at their
expected assertions. The runner, fixture and scoped report are in the parent
`linux/` directory. These tests simulate register reads; they do not run the
native implementation or validate hardware timing, interrupt delivery,
multi-byte transactions or concurrent callers.

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

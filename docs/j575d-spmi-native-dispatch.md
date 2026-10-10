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
completion and error paths.

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

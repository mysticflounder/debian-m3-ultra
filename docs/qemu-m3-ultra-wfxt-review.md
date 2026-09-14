# WFxT: bounded-probe review

Status: source/semantics review only; no WFxT instructions executed. No QEMU,
CPU-feature, firmware, or persistent VM changes. Reviewed 2026-09-14 against
QEMU source `789e3d805f9ca84e64c40fe1b99129336ce911b8`.

## Scope and evidence

M3 public host inventory reports WFxT=0; the imported M5 Max inventory reports
WFxT=1. These booleans are not raw ID field values. QEMU's TCG feature predicate
requires `ID_AA64ISAR2_EL1.WFXT >= 2` (`target/arm/cpu-features.h`). Prior M3
guest ISAR2 reads were zero; no new guest ID capture was performed here.

Arm describes WFIT as a hint with timeout/wakeup behavior, feature-gated
decoding, and possible higher-EL trapping when execution would enter a
low-power state. Returning alone does not establish that a timed wait happened.
See the [Arm instruction reference, WFIT page 1076](https://documentation-service.arm.com/static/67e40f3398aa3c3b6eea6a85).

Current local QEMU sources distinguish these paths:

- `target/arm/tcg/a64.decode:280`: WFET X0 is `0xd5031000`; WFIT X0 is
  `0xd5031020`. The distinguishing bit is bit 5, not bit 0; the low five bits
  select the source register. Recheck with the assembler before execution.
- `target/arm/tcg/translate-a64.c:2168`: TCG gates both instructions on WFxT.
- `target/arm/tcg/op_helper.c:408`: system-mode WFIT compares the virtual
  counter against the unsigned source-register deadline and returns when
  expired or work is pending, before raising a selected WFx trap. It computes
  the trap target earlier; computation is not exception delivery.
- `target/arm/tcg/op_helper.c:639`: WFET can consume an existing event, or
  return for pending work/expired deadline, before checking traps.
- `target/arm/hvf/hvf.c:2496`: the userspace WFx exit handler distinguishes
  event versus interrupt waits but does not decode a WFxT deadline operand.
  If a timed wait reaches this handler, its operand is not handled as a WFxT
  deadline. Whether HVF routes the tested instruction here is unproven.

TCG helper behavior is not evidence of the HVF execution path. In particular,
the historical [QEMU WFxT implementation proposal](https://lists.gnu.org/archive/html/qemu-devel/2024-04/msg04801.html)
described WFET as a NOP; current local system-mode WFET has event/timer logic.
Neither version justifies inferring wakeup correctness from a simple return.

## First probe to implement

1. Independently assemble/disassemble WFET X0 and WFIT X0 and verify the words
   above. Use a fixed X0 containing zero, with a post-instruction result marker.
   Zero is already expired under the unsigned virtual-counter comparison;
   no explicit CNTVCT read or counter-frequency assumption is needed.
2. Add ordinary NOP/integer-result controls. Do not use ordinary WFI/WFE as
   controls: those deliberately introduce unbounded waits.
3. Isolate each case in a child with core dumps disabled, caught SIGILL,
   a short alarm and an outer process deadline. Record returned marker,
   caught SIGILL, or failure. Timeout/error invalidates the capture; neither
   is a semantic mismatch or success. An alarm is containment, not proof
   that every possible trapped implementation can be interrupted promptly.
4. Validate complete unique cases and markers independently. Accept observed
   return or caught SIGILL without hard-coding an M3 result into M5 tests.
   Test validators against malformed captures and both outcome fixtures.
5. Only after code/safety review, run host tests, then the existing disposable
   one-vCPU HVF guest lifecycle: unprivileged probe, no network, read-only
   source, overlay-only writes, protected hashes and clean shutdown checks.
   Keep existing feature settings unchanged. Clearly distinguish historical
   guest ID evidence from any same-run capture.

The comparison answers only whether these expired-deadline instruction cases
return correctly or fault on each OS path. It does not prove absence of traps,
actual sleeping, future-deadline accuracy, event/interrupt delivery, full WFxT
support, or native performance. Host scheduling delay is not a CPU failure.

Future-deadline tests remain deferred pending a separate trap/routing and
watchdog review, particularly for M5 where WFxT is publicly advertised. There
is no observed WFxT behavior mismatch yet and no basis for a feature override
or a speculative HVF patch.

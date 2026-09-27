# J575d boot-image address model and first code references

2026-09-26. Static analysis of the exact decoded files in the
[boot-artifact record](inventory/t6032-boot-firmware-2026-09-26.json).
No native execution, register access, firmware installation or boot-policy
change. All instruction locations below are **decoded-file offsets**.

## Inspection model and startup constants

These files do not have top-level Mach-O/ELF load commands. Inspection-only
Mach-O objects embed each full image byte-for-byte in a zero-address text
section with no relocations. This makes LLVM's displayed locations file
offsets, not observed runtime addresses. Verification checked section size,
address, relocation count and every byte against the hash-pinned raw input.
The wrappers were never executed. Marking a section executable for a
disassembler does not turn embedded data into instructions.

Startup provides more evidence than the file format alone:

| Image | Literal at `0x380`: preferred destination | Literal at `0x388`: copy-end constant | Difference / decoded file bytes |
| --- | --- | --- | --- |
| iBoot | `0x10071a94000` | `0x10071da1480` | `0x30d480` / `0x30d470` |
| LLB | `0x1fc088000` | `0x1fc383980` | `0x2fb980` / `0x2fb968` |

At `0x1c–0x24`, startup derives x0 from the current PC page and loads x1
from literal `0x380`. It calls an image-specific helper, then compares x1
with x0 at `0x2c`. iBoot's helper at `0x38a34` is a bare `ret`. LLB's helper
at `0x2afd0` uses system-register and MPIDR-derived inputs but preserves x0
and x1 on its returning path; its completion is not proven on hardware.

The unequal path constructs source/destination extents and selects an
overlap-aware copy path. The copy loops at `0xf0` and `0x128` transfer
64 bytes per iteration, followed by instruction-cache maintenance and
barriers. The preferred-destination value was saved in x7 at `0x54`;
the later `br x7` is at `0x188`. The equal path branches to `0x18c`.
This supports **preferred relocation destination**, not current installed
firmware placement or successful execution. Both preferred destinations
are 4-KiB aligned; zero-origin ADRP arithmetic remains conditional on that
alignment in the path being analyzed.

Pool entries `0x3e8`, `0x3f8`, and `0x400` equal the respective preferred
base plus `0x160`, `0xf0`, and `0x128`. Literal `0x418` is zero in both
files. Do not equate the copy-end difference with the file length: the
constants extend beyond the decoded bytes by 16 and 24 bytes respectively.
The LLB range `0x2b048–0x2b057` is another literal pool, not code, even
though the generic disassembler prints instruction mnemonics there.

## Confirmed iBoot reference flow

| Reference | Instructions and immediate continuation | What this establishes |
| --- | --- | --- |
| AMCC diagnostic | `0x65084/0x65088` forms x2 pointing to string offset `0x2c6190`; `0x6508c` calls `0x15ece4` | A diagnostic-format reference, not cache initialization |
| T6032 revision error | `0x715bc/0x715c0` forms x1 pointing to `0x2c667b`; branch at `0x715c4` reaches the x0=0/call sequence at `0x715b4/0x715b8` | A T6032-labeled error path, not proof that this board takes it |
| Inclusive TZ property | `0x133960/0x133964` forms x4 pointing to `0x2c7517`; x6 becomes x4+19, then calls `0x13410c` and `0x150340` | String/range argument flow under a bit-4 guard, not a TZ register write |

The shown TZ-block predecessor tests bit 4 of the halfword at
`sp+0x120` (`0x13394c/0x133950`) and calls `0x133f90`. Helper
`0x13410c` copies x4 to x5 and x28 to x7, then returns. Its name and the
semantics of the later callee are not inferred from the string. Resolving
those consumers is still necessary before making a protection claim.

## Cache-offset data-record lead

The separate constructor at `0x3b6a4` has a direct caller at `0x357c0`.
In its bounded `0x3b7f8–0x3b860` region, an x26-relative record receives
`0x40000` at `+0x10` and `0x1c0000` at `+0x14`. Another record, addressed
through x8 after the call at `0x3b844`, receives `0xc1` at `+0`, `0x1c00`
at `+8`, 1 at `+12`, and zero at `+16`.

These are **record construction stores**, not a demonstrated write of 1 to
an MCC register. The numerical resemblance of `0x1c0000 + 0x1c00` to the
kernel's logical `0x1c1c00` makes this a useful next lead, but combining
those fields into an address requires the consumer and record schema.
No broadcast scope, boot-stage access permission or hardware equivalence
is established by this observation.

## Validation and next work

The [evidence record](inventory/t6032-boot-offsets-2026-09-26.json) pins
the byte-check report and disassembly extracts. Two wrapper payloads and
316 displayed 32-bit words were checked against the original files. This
is byte validation, not proof that every displayed word is executable code.
Peer review checked the startup interpretation and the bounded record lead.

Next: trace the record consumer and TZ property's caller/callee contracts;
identify actual cache-control/carveout accesses, guards and translations;
then compare them with the [MCC handoff ledger](m1n1-t6032-mcc-handoff-ledger.md).
Native access, cache effects, TZ scope, loader/DMA containment and recovery
remain separate open gates.

# T6032 MCC cache-mode contract: offline trace

2026-09-26 local time. This resolves part of the cache-control evidence gap;
it does not validate native cache initialization. No firmware patch, MMIO,
installation, boot-policy, disk or VM change is made by this investigation.

## Evidence boundary

The matching kernelcache, extracted H15 inspection view and disassembly
hashes are recorded in the [binary evidence manifest](inventory/mcc-binary-evidence-2026-09-26.json).
The live service identity is `AppleH15MemCacheController`, matching
`mcc,t6031`; that compatible string does **not** restrict the driver to
chip ID `0x6031`. Its `start()` explicitly handles `0x6032`.

### Aperture selection

The following is static dataflow, not a live address translation:

| Observation | Instruction address / field |
| --- | --- |
| Chip ID `0x6032` selects register-list base index 4; other IDs select 3 | `0xfffffe00096e156c`–`158c`, stored at `this+0x880` |
| `start()` passes its aperture array and capacity 16 to `_mapApertures` | `0xfffffe00096e1bdc`–`1be8`, array `this+0x460` |
| Provider call receives base index plus controller ordinal and zero | `0xfffffe00096e28ec`–`291c`, virtual slot `+0x710` |
| Mapping records have stride `0x18`; mapping address and length occupy `+8` and `+0x10` | `0xfffffe00096e2920`–`2964`, `2990`–`29a4` |
| Protected-write helper adds the complete requested offset to the selected record's address | `0xfffffe00096e4d40`–`4d7c` |

The virtual methods are identified by ABI/call-shape inference as
`mapDeviceMemoryWithIndex`, mapping virtual-address getter and length getter.
The ordinal arithmetic and record accesses are directly visible. Alongside
the [Ultra/Max firmware geometry](m1n1-t6032-mcc-layout.md), this corroborates
the conditional T6032 path and its expected Ultra indices 4–19. The binary
alone does not show which branch a particular boot took, or prove an
early-boot m1n1 translation equals a running macOS virtual or physical address.

### Protected-write call

`mccEnableCacheMode` constructs **`0x1c1c00`**, not `0x1c00`:
`mov w3,#0x1c00` at `0xfffffe00096e4f0c` followed by
`movk w3,#0x1c,lsl #16` at `0xfffffe00096e4f10`. It passes value one.
The helper preserves this full offset; immediately before its tail branch,
`x0` is aperture address plus offset, `w1` is the value, and `w2` is four
(`0xfffffe00096e4dec`–`4df4`).

The tail branch at `0xfffffe00096e4e1c` reaches authenticated import stub
`0xfffffe00096ecc64`. `otool -Iv` identifies this stub and GOT slot
`0xfffffe000819ba40` as `_pmap_iofilter_protected_write`. Resolving that slot
in the complete hash-matched kernelcache gives `0xfffffe000be6381c`, also
named `_pmap_iofilter_protected_write` in its symbol table. The resolver
checks format-8 chain membership and cache level zero. It does **not**
authenticate PAC or read live memory. The disassembler's nearby
`_sysctlbyname+...` annotation is not the callee's identity.

This establishes the call ABI:
`_pmap_iofilter_protected_write(aperture_address + 0x1c1c00, 1, 4)`.
It is not, by itself, proof that the protected operation succeeds or that a
bare m1n1 store would have the same permission, ordering or hardware effect.

### Inside the protected-write wrapper

The bounded offline LLDB transcript is also hash-pinned in the manifest.
At `0xfffffe000be63834`–`383c`, the wrapper saves width, value and original
virtual address in `x19`, `x20` and `x21`. Its call to
`0xfffffe000bc90a54` translates that address using `AT S1E1R` and `PAR_EL1`,
preserving the low twelve address bits. A zero result or failed subsequent
physical-address type query reaches a panic path.

The type-byte comparison at `0xfffffe000be63860`–`3864` is decisive:

| Condition | Statically reachable path |
| --- | --- |
| Type is not `0x1b` | Branch to width dispatch at `0xfffffe000be63890`; width four reaches `str w20,[x21]` at `0xfffffe000be638d0` |
| Type is `0x1b` | Additional policy branches select calls to `0xfffffe000c60feb4` or `0xfffffe000c61033c`, passing translated address, saved value and saved width |

The latter veneers load operation selectors `0x21` and `0xa00000005` and
contain protected `tenter` paths; their deeper execution is not traced here.
The direct-store block is bypassed after those calls, but is **not** globally
unreachable: the non-`0x1b` branch reaches it. No MCC offset is stripped or
rebased in the inspected wrapper. The queried runtime type for the MCC
address is unknown, so this does not establish which path macOS takes or
what access is permitted before macOS during m1n1 execution.

### Ordering and status checks

Apple completes the controller write-call loop before calling
`_mccWaitForWaysPwrOn(12)` (`0xfffffe00096e4f00`–`4f34`). The wait helper
iterates controller and plane counts from `this+0x87c` and `this+0x874`.
Its status offset is `0x1c04 | (plane << 18)` (`0xfffffe00096e4954`–`4958`).
For the four-plane layout this is `0x1c04 + plane * 0x40000`.

It polls bits **13:9**, then bits **8:4**, separately until each equals the
requested count (`ubfx` at `0xfffffe00096e4978` and `0xfffffe00096e4a00`).
The `ubfx` operands are starting bit and width, not endpoint bit numbers.
The retry branches at `0xfffffe00096e49e0` and `0xfffffe00096e4a58` have no
timeout in this loop. This is not the same sampling behavior as m1n1's
bounded combined-field poll; the two fields need not have matched in the
same Apple sample.

| Current ten-patch m1n1 path | Observed Apple normal-enable path |
| --- | --- |
| Four control offsets per bank: `0x1c00`, `0x41c00`, `0x81c00`, `0xc1c00` | One protected-write call per bank at offset `0x1c1c00` |
| Write each plane, then immediately poll it | Complete bank write-call loop, then poll planes |
| Bounded combined-field poll | Separate field polling with unbounded retries in the inspected loop |

Arithmetic resemblance to a seventh plane stride does **not** establish
that `0x1c1c00` is a broadcast register. Its scope remains an evidence gate.

## Remaining implementation gates

The normal enable branch requires both its boolean request and a nonzero
field at `this+0x90` (`0xfffffe00096e4e9c`–`4ea4`). `start()` also checks
this field before its virtual cache-enable call (`0xfffffe00096e265c`–`2684`).
`setWayMask` clamps values at least 13 down to 12 (`0xfffffe00096e4abc`–`4acc`).

The follow-up parent-driver trace resolves the field's initial provenance.
H15's call at `0xfffffe00096e1fc0`–`1fe0` uses imported superclass vtable
slot `+0x600`. Two checked format-8 fixups resolve GOT `0xfffffe000819bab8`
to `0xfffffe0008002488`, then its slot at `0xfffffe0008002a88` to
`AppleMemCacheController::start` at `0xfffffe0008cb8af0`. This confirms the
callee beyond a virtual-method-name inference; it is still not live PAC
authentication or evidence of successful execution.

Once its policy object at `this+0xa8` is non-null, parent `start` applies:

| Order | Input / condition | Effect on `this+0x90` | Instruction address |
| --- | --- | --- | --- |
| 1 | Default | Store `0xffffffff` | `0xfffffe0008cb9154`–`9158` |
| 2 | Provider `disable-mcc`, castable to OSData, first word nonzero | Store zero | `0xfffffe0008cb915c`–`91c4` |
| 3 | Boot argument `-disable_mcc` present | Store zero; skip clamp parsing | `0xfffffe0008cb91c8`–`91e0` |
| 4 | Otherwise, `mcc_clampwaycount` successfully parsed into four bytes | Store parsed word | `0xfffffe0008cb9238`–`9254` |

Consequently, a clamp argument can overwrite the property-based disable,
but cannot override the boot-argument disable through this path. The parent
uses `_PE_parse_boot_argn` import `0xfffffe0008cea108`, not the disassembler's
nearest-symbol annotation. The string addresses are `0xfffffe0007187ed3`,
`0xfffffe0007187edf` and `0xfffffe0007187f3f`, checked by translating their
VM addresses through the full collection's file-backed segment table.
The OSData cast is symbol-backed; naming its virtual data accessor is still
ABI inference. This is a software policy trace, not a claim about this
machine's current boot arguments or the correct policy for m1n1.

An alternative configuration path calls `setWayMask` when a cached global
equals one. Its initialization call at `0xfffffe00096e4e6c` resolves via
import stub `0xfffffe00096ec8f4` to `_PE_parse_boot_argn`, **not**
`sysctlbyname`; the requested string is `amcp_nolock`. This establishes a
boot-argument branch, not its applicability to m1n1. These preconditions and
the early-boot protection state must be understood before copying this
sequence into early-boot firmware.

The other inspected control users (`_mccFlush`, call sites
`0xfffffe00096e132c`/`1370`, and `setWayMask`, `0xfffffe00096e4b80`/`4c28`)
also loop over mapped apertures with full offset `0x1c1c00`, using values zero and one.
That corroborates the repeated per-window control operation; it does not
independently establish a hardware broadcast alias or prove the existing
per-plane m1n1 path incorrect. No inspected string names this offset as a
broadcast register. Further firmware changes need independent register
evidence or separately planned and authorized native validation, rather
than another assumption based on the same offset arithmetic.

Do not promote the existing per-plane sequence as hardware-validated, or
replace it with a guessed broadcast store. A future T6032-only change needs
an established control-register scope and early-boot access contract,
bounded failure handling, legacy-path regression tests, an offline build,
and separately authorized native validation. TZ offsets, loader payload
containment, DMA protection and recovery/entry gates remain independent.

## Reproduce the binding check

With the existing decoded kernelcache under project scratch:

```sh
otool -Iv scratch/mcc-evidence/AppleH15MCD.macho
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 \
  scripts/inspect-kernelcache-fixup.py scratch/kernelcache-tool-reviewed.macho \
  0xfffffe000819ba40
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 \
  scripts/inspect-kernelcache-fixup.py scratch/kernelcache-tool-reviewed.macho \
  0xfffffe000819bab8
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 \
  scripts/inspect-kernelcache-fixup.py scratch/kernelcache-tool-reviewed.macho \
  0xfffffe0008002a88
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 scripts/test-kernelcache-fixup.py
```

All seven synthetic fixup tests pass. The real-slot check returns the pinned
kernelcache hash, target `0xfffffe000be6381c`, `chain_membership_validated:
true`, `pac_authenticated: false` and `live_memory_read: false`.
The two parent-call checks return vtable `0xfffffe0008002488` and function
`0xfffffe0008cb8af0`, also with validated chain membership and no live PAC
authentication. All nine manifest artifact hashes match their local files.

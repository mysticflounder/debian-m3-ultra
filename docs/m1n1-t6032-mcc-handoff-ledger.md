# T6032 MCC handoff/access ledger

2026-09-26. Offline source evidence, not native execution permission.
Base revision: `4184923ffb2dff079b384d6a32cc02142aa14572`.
Patched line references below refer to the eleven-patch tree recorded in
[the build manifest](inventory/m1n1-cpufreq-status-build-2026-09-26.json).
Relevant changes are [0008](../patches/m1n1/0008-validate-t6032-mcc-layout.patch),
[0009](../patches/m1n1/0009-preflight-t6032-carveout-removal.patch), and
[0010](../patches/m1n1/0010-guard-t6032-runtime-mappings.patch).

## Accesses and ordering in our source

| Phase | Access / transformation | Guard and remaining limitation |
| --- | --- | --- |
| Early `mcc_init()` | ADT metadata only; select sixteen translated 32-MiB windows after four headers | Validate geometry, lengths, bounds and overlap before publication; this does not prove register semantics |
| Initial MMU setup | Controller 0, plane 0: up to four sets of three 32-bit TZ reads | Software prerequisites precede reads; an invalid candidate exits early. Register access safety and all-controller representativeness remain unproven |
| Carveout publication | Decode page indices; validate aliases/image/heap; adjust heap limit and remove stage-1 mappings | No mapping/heap-limit changes until all candidates validate; does not establish DMA isolation or loader correctness |
| Later stage-1 mapping requests | Check physical ranges against published carveouts | Only active after publication; not a hardware protection boundary against privileged writes or other translation stages |
| `kboot_boot()` | Per-controller/per-plane enable write, then status polling | Reject failure before continuing kernel handoff; prior writes remain and the loop continues after timeout |

### Early layout and TZ accesses

Patched `src/main.c:157-163` calls `mcc_init()` before `mmu_init()` and
panics on a T6032 layout error. `src/mcc.c:264-323` stages the configuration
without MCC MMIO. The corresponding clean layout code is at
`src/mcc.c:406-457,509-539`.

The translated controller bases come from `adt_get_reg()` over `reg`
entries 4 through 19. T6032 uses the T6031 plane offset **zero**, plane
stride `0x40000`, and four planes. Thus the later plane access formula is
`translated_controller_base + plane * 0x40000 + register_offset`;
`0x1c1c00` is not a hidden base term in this calculation.

The initial carveout routine (`src/mcc.c:408-483`) reads controller 0,
plane 0, slot `i` at offsets `0x6d8 + i*0x14` (start),
`0x6dc + i*0x14` (end), and `0x6e4 + i*0x14` (enable), in that order.
All three are read even for a disabled slot. There are twelve reads if all
four iterations are reached, fewer if an earlier validation fails.
The read values are not obtained by this audit.

For enabled slots, source decoding uses a 12-bit page shift, inclusive end
converted to an exclusive end, and OR with `ram_base`. It checks that the
OR transformation is affine over the interval before removing the identity
and three additional aliases. These checks validate the software model,
not the target's TZ register encoding. The clean legacy path is at
`src/mcc.c:201-243`.

Patched `src/memory.c:549-551` invokes this preflight after default mappings
and `mmu_remap_ranges()`, before `mmu_configure()` and MMU enable.
`mmu_init()` returns early if the MMU is already enabled; otherwise it starts
an unpublished carveout setup before constructing mappings (`586-600`).
Patch 0010 guards later mapping requests only after successful publication.
MMU disable/restore alone does not clear that published state.

### Deferred cache writes

Patched `src/mcc.c:326-369` (clean `156-198`) issues a 32-bit write of 1
at offsets `0x1c00`, `0x41c00`, `0x81c00`, and `0xc1c00` for each of the
sixteen configured controllers. Each write is followed by a bounded poll
at the corresponding offset plus four, using combined fields 13:9 and 8:4
with expected count 12. The timeout argument is 10000.

The accessors (`src/utils.h:86-96`) are inline `ldr`/`str` with compiler
memory clobbers, not Apple's protected-write wrapper. They contain no
explicit hardware barrier. `poll32()` (`453-463`) decrements before each
iteration, allowing at most 9999 polling reads for that timeout argument,
with `udelay(1)` after each unsuccessful sample. This software retry bound
does not bound a single stalled hardware access or prove device ordering.

A timeout triggers a status read for diagnostics and records failure, but
does not stop the remaining iterations or undo writes. The generic code
also has a conditional disable-register store; T6032's staged
`cache_disable = 0` makes that branch inactive for this configuration.
`src/kboot.c:2918-2923` rejects a negative cache result for T6032 before
the subsequent tunable/clock/USB/PCIe/DAPF operations. That is failure
propagation, not transactional initialization or hang containment.

## Evidence still needed from the boot firmware

The [Apple runtime trace](m1n1-t6032-cache-contract.md) establishes a
protected-write call at logical offset `0x1c1c00`, followed by a different
polling sequence. It does not establish early-boot access permissions or
inherited state. The [Pro source review](m1n1-t6032-mcc-pro-review.md)
adds family-level evidence, not T6032 validation.

For a boot-firmware trace, first bind the artifact to an archive build,
BuildIdentity, board/chip identifiers, exact member path and hash. A matching
restore archive is still not proof of the firmware actually running on this
Mac. Separately establish the relevant boot stage and handoff path.
For each observed access, record aperture translation, width, guard,
ordering/barriers, security mediation, status polling and error handling.
Absence from a bounded search cannot establish that firmware never accesses
the block, or that retaining inherited state is safe.

### Matching archive candidates located

The [artifact locator record](inventory/t6032-boot-artifact-locator-2026-09-26.json)
pins Apple's macOS 27.0 / `26A428` root BuildManifest (SHA-256
`22949db91be2ddd0009a0047ceba37336452b76af3ff915f496d842b85cce6a7`).
The successful range retrieval transferred 1,736,898 bytes; the manifest
decompresses to 31,194,642 bytes. No whole IPSW was downloaded.

Exact target identities are indices 33, 93 and 153: `j575dap`, chip
`0x6032`, board `0x44`. Their variants are erase, upgrade and macOS Customer.
Do not substitute nearby `j575cap` / `0x6041` / `0x02` entries.
All three name `Firmware/all_flash/iBoot.j575d.RELEASE.im4p`;
the two restore identities also name `Firmware/all_flash/LLB.j575d.RELEASE.im4p`.
LLB's absence from the third identity is not proof of absence from the boot
chain. Shared component digests are recorded as raw plist bytes without
assuming their algorithm or hashed byte scope.

The locator task retrieved only BuildManifest and ZIP metadata. Subsequent
[bounded acquisition and decoding](m1n1-t6032-boot-firmware.md) now pins
both exact members and records boot-stage/T6032/AMCC string leads. The next
step is code-reference tracing, not native testing. Matching this archive
to the kernel build does not establish the installed boot firmware version
or a safe native execution path.

Open gates remain: register effects and TZ layout; controller/plane scope;
inherited cache state and early access prerequisites; loader containment;
DMA isolation; native MMU/TLB behavior; recovery and boot entry.
**Disabled CPU/frequency dispatch does not guard these independent MCC
paths.** No firmware execution, installation, register probe or boot-policy
change was performed or authorized by this audit.

## Offline regression check

On 2026-09-26 all five existing runners passed: `test-m1n1-mcc-layout.py`,
`test-t6032-mcc.py` (15 tests), `test-t6032-carveouts.py` (9 tests),
`test-m1n1-carveout-preflight.py`, and `test-m1n1-mapping-guard.py` under
`scripts/`. These are metadata and source-extracted host harnesses, not
tests of the actual register model, native cache state, or boot firmware.

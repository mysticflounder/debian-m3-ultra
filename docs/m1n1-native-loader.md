# J575d native loader contract

This is Debian/project-fork work, not an Asahi submission. Source analysis,
host fixtures and comparison builds do not authorize or establish native boot.
The default m1n1 pin and disabled native dispatch remain unchanged. Native
testing still requires a verified backup, recovery readiness and separate
approval.

## Inputs and entry requirements

The diagnostic artifacts are recorded in the
[kernel/initramfs inventory](inventory/m1n1-j575d-kernel-build-2026-10-07.json).
The pinned Linux source is `602042bf29f6efde39cfb5fdd9289bf4854bc0c5`;
the comparison loader is m1n1 `2460b604c6f016956ead711823605eea840c602e`.
Linux's authoritative requirements are in that source's
`Documentation/arch/arm64/booting.rst`.

| Item | Established offline | Remaining native contract |
| --- | --- | --- |
| Image | AArch64, little-endian, 16 KiB pages; file 43,010,560 bytes; declared `image_size` 44,040,192 bytes (42 MiB), `text_offset=0` | Place at a 2 MiB-aligned base with the full declared span available in usable RAM |
| DTB | Official J575d Kbuild output passes schemas and mocked CPU handoff | Provide actual physical memory/reservations and release addresses; 8-byte alignment, at most 2 MiB, compatible mapping attributes |
| Initramfs | Reproducible static AArch64 diagnostic PID1; RAM-only HVF boot passed | Place in usable RAM without conflicting reservations, in a 1 GiB-aligned window of at most 32 GiB that also covers the Image |
| CPU entry | Source prepares the Image entry and physical DTB in x0, clears x1–x3, and follows an MMU/cache shutdown path | Qualify physical backing, cache visibility/coherence, DMA quiescence, exception level, timers/system registers and secondary release |

The compiled board DTB's 8 GiB memory span and zero-valued CPU release addresses
are placeholders, not measurements of the Studio. The loader must replace them
from a valid handoff and reserve the release slots and resident secondary code.
The prior HVF boot used QEMU's virtual DTB, not this board DTB or m1n1.

## Payload packaging

Upstream documents that a kernel must be compressed or last in an inline
payload. `payload_run()` supplies size zero; the uncompressed Image handler
returns no next payload pointer. Therefore `Image + DTB + initramfs` is not a
supported package. Use a compressed Image or put the uncompressed Image last.
This is a packaging contract, not a newly demonstrated loader defect.

The uncompressed copy path uses the declared Image span when its input length
is unknown. A future package builder must account for that span; the shorter
file length alone does not establish readable source padding. No native boot
package has been produced or approved by this milestone.

## Decompression destination guard

Both gzip and XZ previously advertised a 1 GiB destination after a zero-byte
heap allocation. The allocator checked the decoded allocation only afterward;
that is too late to prevent a decoder from writing beyond a smaller heap limit.
Comparison patch 0031 bounds the destination before either decoder runs:

1. Check the nonzero heap cursor and its 2 MiB alignment arithmetic.
2. Use the installed heap limit when present. Otherwise use the checked legacy
   normal-RAM end, `phys_base + mem_size`, and require the destination to be
   within that reported RAM interval.
3. Reject an empty or invalid span; cap a valid span at the existing 1 GiB
   maximum and pass that capacity to the decoder.
4. Preserve zero-byte allocation and reserve only the actual decoded length
   through the existing finalization path.

This deliberately does not reserve 1 GiB up front or override an installed
limit with legacy RAM metadata. A T6032 limit reflects the checked
RAM/carveout preflight at publication time. These arithmetic checks do not prove
that the declared physical range is mapped, powered or actually backed by RAM.
Patch 0031 alone did not synchronize later top-down reservations:
`display_init()` can enlarge a framebuffer with `top_of_memory_alloc()` after
MMU/MCC initialization has published the limit. That allocation lowers
`mem_size`, but does not lower the explicit limit. The fallback branch sees the
reduced RAM end; the explicit-limit branch can still include that reservation.
This conditional allocator-overlap issue is addressed by comparison patch
0032's [coordinated top-down reservation ceiling](m1n1-topdown-reservations.md).
It is not asserted to occur on every native boot. The effective heap limit
now retains live top-down reservations even if a requested limit is cleared
or widened; the decompression helper uses that effective limit unchanged.

## Compressed source bounds and consumption

Comparison patch 0033 replaces both decoders' size-zero/unbounded input with
a finite capacity. Known input sizes must fit `uint32_t` and have a checked
end. Inline input must start at or above `_payload_start` and below the checked
handoff `top_of_kernel_data`; its remaining capacity is capped at `UINT32_MAX`.
This handoff boundary is a declared upper bound, **not an exact file length or
proof of readable physical backing**. Linker payload reservation size is not
used as a file length.

The full compressed capacity and bounded output capacity must be disjoint
before decoding. Touching intervals are allowed; overlap and wrapping ends
are rejected. Overlap rejection can follow zero-byte heap alignment, so the
entire wrapper is not claimed to be transactional. A truncated decode may
write bounded partial output, but cannot finalize it.

XZ previously returned the caller's nonzero capacity rather than actual bytes
consumed. Once input is bounded, that can skip a following payload. The decoder
now returns `BfTell()` on success, as its header contract specifies. Both wrappers
check nonzero consumption within the supplied capacity before finalization.
The proxy caller does not use this returned consumption. Parser object-size
semantics and compressed-or-last Image packaging are unchanged.

gzip's existing nonzero-size API instead requires an exact stream length,
including its footer. New explicit bounded-prefix APIs locate the actual
deflate endpoint and validate gzip's actual footer/ISIZE/CRC, allowing a
following payload without treating the capacity-end bytes as the footer.
The original gzip/raw-deflate APIs retain their strict and legacy behavior;
only the payload wrapper opts into prefix decoding.

These finite capacities alone are not a proof of every decoder-internal read.
The pre-existing XZ seek-wrap and intentional unsigned-rewind behavior required
the separate repair below; the wrapper's consumption check was not enough.

## Checked XZ seeks and range-decoder failures

Comparison patch 0034 checks `Offset <= SoftLimit <= Size` and forward lengths
against `SoftLimit - Offset`, avoiding 32-bit addition wrap. The two intentional
backwards movements now use a separately checked `BfRewind`. Failed seeks and
limit changes preserve the offset/limit; XZ position queries and size-only skips
must succeed before dependent accounting is committed.

Range initialization checks its five initial bytes and computes the remaining
chunk end after those bytes. Failed refills are sticky failures rather than
synthetic zero bytes. Buffered final-symbol decoding at `position == Limit`
remains allowed; requiring another byte at that boundary fails. The compressed
chunk count is widened so encoded `0xffff + 1` remains 65,536. Raw chunk counts
were already wide enough.

The full32 `xz-seek-guards` build and linked-layout audit pass. Sanitized host
tests exercise actual input-buffer/range-decoder code, real compressed/raw XZ,
tail consumption, empty-stream rewind, truncation and footer rejection, and four
exact negative controls. A synthetic compressed-size-65,536 packet exercises
the metadata/size-only seek path, **not entropy decoding of a valid compressed
packet**. Range-state probes test endpoint buffering and failed-refill atomicity.
The near-`UINT32_MAX` endpoint fixture uses a real demand-backed host mapping;
it does not require a 4 GiB physical buffer or access to the Studio's hardware.

The separate [XZ evidence ledger](inventory/m1n1-xz-seek-2026-10-07.json)
records these inputs and regressions. These checks do not establish physical
source backing or prove every other codec operation safe.

## Separate open issues

| Issue | Why the output guard does not resolve it |
| --- | --- |
| Inline compressed input extent | 0033 establishes a finite declared handoff bound; exact readable file extent and physical backing still require a trustworthy producer contract |
| Decoder-internal arithmetic | 0034 resolves the reviewed XZ seek/rewind, range-refill and chunk-width defects; other decoder operations are not universally proven safe |
| Top-down physical eligibility | Patch 0032 coordinates upward/downward bounds, but does not establish physical backing, mapping or carveout eligibility; requested MCC/proxy limits remain independently mutable |
| Source/output overlap | 0033 rejects compressed-source/output capacity overlap; eligibility and separation from other live reservations remain separate |
| Complete payload parser | Dispatcher headers, variables and remaining object spans are not bounded by these decoder guards; failure cutoff is not yet a whole-boot transaction |
| Initrd end and placement | The setter accepts a raw pointer/size, and chosen-property creation uses unchecked `start + size`; valid native addresses, reservations and the Linux window constraint still need checks |
| Image/DTB staging | Alignment and declared sizes do not independently establish readable source backing or every native reservation |
| Physical handoff | Offline source/layout tests cannot validate the real EL/MMU/cache/DMA/timer/release state |

Next: bound the complete dispatcher/object parser and propagate rejection;
establish exact producer-backed payload and staging spans, and validate initrd
end arithmetic and Linux's placement window.
Add targeted bounds/placement checks with source-extracted fixtures.
Keep native hardware qualification behind the recovery gates.

## Offline validation — 2026-10-07 UTC

The full29 `payload-guards` comparison build and linked-layout audit pass with
the same six existing C warnings. Of 215 canonical C/header/assembly/Rust
sources, only `src/payload.c` differs from the full28 board-handoff tree.
Real pinned gzip/XZ decoders pass ten helper-boundary and sixteen wrapper cases,
including inline size-zero input, exact/short spans, strict limits and actual
length/padding finalization. Four original/dropped-cap controls compile cleanly
and fail with exact designated exit-1 diagnostics, without sanitizer errors or
backing-store overflow. Heap/bootargs/payload-dispatch behavior is mocked.

The final tree also passes the 90-case BUSY regression with two controls and
four official-board handoff scenarios with two controls. The
[inventory](inventory/m1n1-native-loader-2026-10-07.json) binds 232 inputs and
artifacts, the exact execution records and source comparison. This inventory
records the full29 milestone's historical inputs; the builder has since gained
the full30 mode. Native hardware behavior is not among these results.

The subsequent [full30 milestone](m1n1-topdown-reservations.md) adds persistent
reservation tracking and checked allocator arithmetic. It passes fifteen
real-allocator/helper cases and two exact overlap controls, plus the same
decoder/BUSY/board/layout regressions. Its separate
[inventory](inventory/m1n1-topdown-reservations-2026-10-07.json) binds that
milestone's builder and final sources. Historical inventories remain unchanged;
subsequent runner/builder edits do not retroactively match their input hashes.

Full31 `payload-input-guards` adds the compressed-source checks and XZ
consumption correction. The build/layout retains the same six C warnings;
only `src/payload.c`, `src/minilzlib/xzstream.c` and the three tinf API/implementation
files change among 215 canonical sources versus full30. Source-extracted host tests use both actual decoders,
with 16 input-helper cases, 10 output-helper cases, 25 wrapper scenarios and
six exact controls, plus 16 direct prefix/strict decoder API cases. These
check strict and legacy zero-size behavior, prefix source/output zero caps,
truncation and actual-footer CRC/ISIZE validation. Output-cap removal controls are deliberate mutations,
including mutations of full30; they are not evidence that unmodified full30
still has that output defect. The unmodified full30 XZ control separately
witnesses incorrect consumed-pointer advancement for a known span with a tail.
The allocator/BUSY/board/layout regressions also pass. See the separate
[inventory](inventory/m1n1-compressed-input-2026-10-07.json) for final inputs and
execution records. These are host/source results, not native qualification.
The 12:28:21 UTC official-API refresh still finds unchanged upstream heads.

A fresh 11:09:01–11:09:02 UTC upstream check again found unchanged m1n1, Linux
and QEMU default-branch revisions. No pinned revisions, external forks or
submissions changed.

Reproduce with the retained source tree, substituting its absolute path:

```sh
bash scripts/build-m1n1-upstream-offline.sh payload-input-guards
UV_CACHE_DIR="$PWD/scratch/uv-cache" PYTHONDONTWRITEBYTECODE=1 \
  uv run --no-project --offline --python 3.13 python \
  scripts/test-m1n1-upstream-payload-bounds.py \
  --source-tree /path/to/full31/tree --base-tree /path/to/full30/tree
```

Neither command installs, boots or connects to a physical target.

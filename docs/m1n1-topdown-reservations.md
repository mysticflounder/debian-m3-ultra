# Coordinated top-down reservations — 2026-10-07 UTC

Comparison patch 0032 closes the source-demonstrated allocator coordination
gap left after the decompression-output guard. This is local Debian/project-fork
work, not an Asahi submission or approval to boot a physical machine.
The default pin and disabled native dispatch remain unchanged.

## Contract

Framebuffer, ISP, kernel-log, GPU and SIO allocations use
`top_of_memory_alloc()`, interleaved with upward heap allocations. Previously
they reduced boot-argument `mem_size` without reducing the published heap limit.
A decoder or ordinary upward allocation could therefore still include a live
top-down reservation. Returning zero on failure would be unsafe: these callers
immediately use the returned address. Failure retains the allocator's panic
policy, before publishing a top-down reservation or changing RAM metadata.

The fix maintains a separate, non-increasing `heap_top` ceiling. The effective
limit is the minimum of that ceiling and any requested heap limit. Clearing or
widening a requested limit cannot reopen live top-down reservations; a stricter
requested MCC/proxy limit still takes precedence. Requested limits themselves
remain mutable: this is not an immutable MCC/carveout policy.

Let `E` be the checked current RAM end, `A` the checked size rounded up to
16 KiB, and `G = 16 KiB`:

| Call | New normal-RAM end / upward ceiling | Returned address |
| --- | --- | --- |
| First | `E - A - G` | `E - A` |
| Later | `E - A` | `E - A + G` |

This preserves the original placement and one movable guard page. A first
zero-size request still reserves the guard; later zero-size requests consume
no additional space. No new alignment requirement is imposed on the reported
RAM end. Overflow, insufficient remaining space, a null ceiling, a collision
with the upward cursor, or an attempt to raise a live ceiling is rejected
before top-down metadata and guard-state changes.

Pre-initialization reservations are permitted; heap initialization retains
the ceiling and must fit its initial cursor alignment below it. This does not
make a failed heap initializer transactional: it still installs its initial
cursor before calling the checked zero-byte allocation.
Upward allocations reject zero/non-power-of-two alignment and alignment/end
overflow before cursor commit, and enforce the effective ceiling. Requested
limit logging uses checked integer differences, avoiding pointer-subtraction
undefined behavior for NULL, pre-init or below-cursor requests.

## Offline evidence

The full30 `topdown-guards` comparison build passes with the same six existing
C warnings. Linked layout passes for eight shared objects, a 64 KiB shared
region, two static stacks and the Mach-O interval. Of 215 canonical source
files, only `src/heapblock.c`, `src/heapblock.h` and `src/utils.c` differ from
the full29 tree.

Source-extracted real heapblock methods pass fourteen arithmetic/state cases
and one real decompression-helper integration case. Tests cover first/later
placement, zero-size behavior, strict/widened/cleared limits, reservation
failure atomicity, pre-init ceilings, alignment/end overflow and exact bounds.
The helper's output capacity equals the available effective span. Two original
or dropped-reservation controls produce exact exit-1 cursor-overlap witnesses
inside oversized host backing; they perform no unsafe writes. ASan/UBSan are
clean. Bootargs and panic handling are host boundaries, not native evidence.

The final source also passes the existing real gzip/XZ suite (10 helper and
16 wrapper cases, four controls), 90 BUSY cases with two controls, and four
official-board handoff scenarios with two controls. Exact sources, execution
records and checksums are bound in the
[inventory](inventory/m1n1-topdown-reservations-2026-10-07.json).

The fresh official-API refresh at 11:47:47 UTC finds m1n1 `2460b60`, Linux
`602042bf` and both QEMU mirrors `f9587d4` unchanged from the earlier checkpoint.
No fetch, rebase, pin change, fork update, submission or push occurred.

## Remaining work

Next establish exact readable inline input extent and source/output separation;
validate initrd end arithmetic and Linux's placement window; qualify Image/DTB
padding, reservations and staging. The allocator checks do not prove a top-down
destination's physical backing, mapping, carveout eligibility or DMA coherence.
Native entry/cache/interrupt/storage/network validation still requires a
verified backup, recovery readiness and separate approval. No physical MMIO,
firmware, disk, persistent-VM or native-boot changes were made.

Reproduce with fresh full30 and retained full29 source paths:

```sh
bash scripts/build-m1n1-upstream-offline.sh topdown-guards
UV_CACHE_DIR="$PWD/scratch/uv-cache" PYTHONDONTWRITEBYTECODE=1 \
  uv run --no-project --offline --python 3.13 python \
  scripts/test-m1n1-upstream-topdown.py \
  --source-tree /path/to/full30/tree --base-tree /path/to/full29/tree
```

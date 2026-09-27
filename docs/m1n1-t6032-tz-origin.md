# T6032 TZ origin versus mapped RAM

2026-09-27. Local offline implementation; no native execution, register
probes, boot-policy, disk or VM changes.

## Decoder correction

[Patch 0012](../patches/m1n1/0012-decode-t6032-tz-relative-origin.patch)
separates two previously conflated coordinates:

- The TZ encoding origin is `B = 0x10000000000` (1 TiB), as used by the
  pinned J575d [range producer and masked writer](m1n1-t6032-boot-tz-inputs.md).
- `ram_base` is the beginning of m1n1's mapped RAM window, derived from
  boot arguments. It is used for containment, not as an encoding operand.

The T6032 decoder now reconstructs the physical half-open interval as:

```text
start = B + (u64(first) << 12)
end   = B + ((u64(last) + 1) << 12)
```

It rejects either input above `0x0fffffff` rather than masking unknown
bits. With these bounds the largest exclusive endpoint is `2*B`, without
overflow. Addition handles that endpoint correctly; OR with B does not.
The existing conservative rejection of first=0 and last<=first is retained.

The decoder still requires a nonzero, non-wrapping RAM interval, supported
4-KiB/16-KiB granularity, aligned endpoints and complete containment in
`[ram_base, ram_base + mem_size_actual)`. It changes the output object only
after every check passes. The OR helper remains in use for virtual aliases;
alias-affinity, overlap, loaded-image/heap protection and staged publication
checks are unchanged.

For example, a mapped RAM window beginning at `B + 4 GiB` can contain a
TZ range encoded relative to B. The decoder can validate that range without
requiring the mapped window itself to begin at B. Unrelated windows that do
not contain the reconstructed range fail the containment check.

## Why this changes the investigation

The earlier OR decoder needed `ram_base == B` to agree with this producer
model. Proving that BootArgs always land in the first 4 GiB was therefore
an additional decoder dependency, not a demonstrated hardware requirement.
This patch removes that particular dependency instead of imposing it as a
new boot restriction. BootArgs ABI, actual usable RAM, and final handoff
validation remain necessary for native bring-up.

This is not justified by a detached constant match: the evidence traces
the explicit subtraction/shift, named TZ0 descriptor, masked payloads and
write-consumer path. It still establishes only a conditional software
model for the pinned image. Masking loses address information; the model
does not prove live ranges or rule out another hardware interpretation.

## Verification and remaining gates

The complete twelve-patch firmware cross-build passes:
`scratch/m1n1-firmware-patched.bs28PS/`, with patch hashes in
`PATCH_SHA256SUMS` and artifact hashes in `SHA256SUMS`.
The tracked [build manifest](inventory/m1n1-tz-origin-build-2026-09-27.json)
pins the patch stack, build script and artifacts.
The binary SHA-256 is
`e20b74009513ba624abe7a0607ff3f85f3d79bf3a4e6a159564a7572323eed70`.
The build does not run the resulting firmware.

Both source-extracted runners now apply all twelve patches and pass under
AddressSanitizer and fail-fast UndefinedBehaviorSanitizer:

- `scripts/test-m1n1-carveout-preflight.py`: fixed-origin arithmetic,
  shifted-window acceptance and below-window rejection, the `2*B` endpoint
  at both granules, reserved-bit rejection, unchanged output on decode
  failure, and no mapping/heap effects after a bad enabled slot.
- `scripts/test-m1n1-mapping-guard.py`: existing mapping lifecycle, physical
  overlap, virtual aliases, framebuffer ordering and legacy bypass checks.

MMIO, page-table and heap effects are mocked. The high-bit decoder tests
use a RAM window large enough to contain the invalid-field addresses, so
ordinary containment cannot hide a missing field-width guard. Adjacent MCC
layout and nine-case frequency-status suites also pass; those use their
existing patch subsets, not the complete twelve-patch source.

A scratch-only mutation removing the 28-bit guard fails specifically at
the endpoint/reserved-bit regression (exit 1), while the unmodified suite
passes. The log is `scratch/mcc-evidence/tz-origin-mutant.log`; the tracked
patch was not modified for this negative check.

Only the T6032 decoder changes. Register addresses, number/order of reads,
enable handling, cache writes and legacy-SoC decoding remain unchanged.
No safety gate is lifted: early MCC permissions, controller/plane agreement,
the F-adjusted versus direct-aperture relationship, inherited cache state,
DMA, boot entry and recovery remain unqualified. CPU/frequency dispatch
remains disabled; that switch does not guard initial-MMU MCC reads.

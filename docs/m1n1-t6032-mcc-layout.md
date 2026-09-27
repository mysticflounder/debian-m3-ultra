# M3 Max / Ultra MCC register-layout correction

2026-09-26 local time. Offline source and firmware-template analysis only.
No MMIO, native firmware execution/installation, boot-policy, disk or VM changes.

## Primary comparison evidence

Two device-tree members were retrieved from
[Apple's macOS 27.0 build 26A428 restore archive](https://updates.cdn-apple.com/2026FallFCS/afcfc88e-bbe6-44bf-a5da-07c56eebc06c/UniversalMac_27.0_26A428_Restore.ipsw).
Only 299,145 bytes were received through bounded HTTP range requests, not
the 26,626,436,228-byte archive. ZIP member CRCs were checked on extraction.
No firmware signature verification is claimed. The members are:

- `Firmware/all_flash/DeviceTree.j516cap.im4p` — 63,442 bytes,
  SHA-256 `61d447e3aeb9b5d938e6b7e9d7c2ef9cb0c041f7548de33590e22431ff239312`.
- `Firmware/all_flash/DeviceTree.j575dap.im4p` — 67,509 bytes,
  SHA-256 `6c3ca4ac7272ecf9c05f6b2b413ef923ff2d3ff252469493fc700260b6938c60`.

The downloaded J575d member is byte-identical by SHA-256 to this Studio's
local Preboot restore copy. Reading that file did not install or execute it.

The [allowlisted inspection](inventory/mcc-firmware-layout-2026-09-26.json)
records input/decompressed hashes and only identity/MCC geometry. Both
templates use `mcc,t6031` with four planes and four DCS channels per instance.

| Firmware target | Model | Headers | 32-MiB MCC windows | Correct list indices |
| --- | --- | --- | --- | --- |
| J516c, M3 Max | Mac15,9 | 3 | 8 | 3–10 |
| J575d, M3 Ultra | Mac15,14 | 4 | 16 | 4–19 |

The Ultra adds a second `0x4000` header at index 3. The existing m1n1
`reg_offset = 3` algorithm selects that header as its first controller and,
after its sixteen-instance cap, omits the actual final controller. The
Max's three-header layout must not be changed to four indiscriminately.

These are **restore-firmware templates, not live or iBoot-final ADTs**.
Their `chosen/chip-id` fields are zero placeholders; target/model strings
identify the template, not the running SoC. The [existing live Ultra capture](inventory/t6032-mcc-2026-09-26.json)
independently agrees on counts, sizes and geometry. A live Max capture is
still absent. Raw template addresses are ADT bus addresses, not translated
physical MMIO targets.

## Reproduce the inspection

Given the two hash-matching members under project scratch:

```sh
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 scripts/inspect-firmware-mcc.py \
  scratch/mcc-firmware-reference/DeviceTree.j516cap.im4p \
  scratch/mcc-firmware-reference/DeviceTree.j575dap.im4p
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 scripts/test-firmware-mcc.py
```

The inspector bounds input/decompression and ADT recursion/counts, checks
lengths before decoding, rejects duplicate selected nodes/properties and
malformed geometry, and emits no unrelated properties. Its sixteen
synthetic tests require neither proprietary firmware nor macOS compression.
Actual LZFSE decoding uses macOS's compression library.

An independent parse using the pinned m1n1 `ADTPropertyStruct` and
`ADTNodeStruct` definitions with Construct 2.10.68 agreed exactly on the
two boards' identity, counts and every MCC register tuple. The schema source
is `proxyclient/m1n1/adt.py` at m1n1 revision
`4184923ffb2dff079b384d6a32cc02142aa14572`, SHA-256
`b1d0c1af0ea83f73b9e6003efb9b42a4892cb35be8efb9c7566d3512c1846a3f`.
The cross-check is in `scratch/crosscheck-mcc-firmware.py`; downloads,
input binaries and inspection-only disassembly remain untracked scratch.

## Matching Apple driver corroboration

Initial analysis found only generic `AppleMemCacheController` implementation
in `AppleARMPlatform`. Its default `getAmccCount()` returning one was not
evidence of the active subclass's behavior.

Allowlisted live IOService metadata instead identifies
`AppleH15MemCacheController`, bundle `com.apple.driver.AppleH15MCD`, provider
`AppleARMIODevice`, matching `mcc,t6031`. The already-matched local
kernelcache has SHA-256
`a24fefccc060854cecc996b40983499e1319008e4f16c0717a5fef6c4d4828dc`.
An inspection-only view of that bundle has SHA-256
`465f34b50ad2b92d3c4a78202c04a7f0a075c3920f894d5f0934e174e543d99f`.
Neither artifact was loaded or executed.

| Binary observation | Evidence location |
| --- | --- |
| `start()` reads the chosen chip ID; comparison with `0x6032` selects base index 4, otherwise 3 | `0xfffffe00096e156c`–`0xfffffe00096e158c`; result stored at `this+0x880` |
| Register count is property byte length divided by 16; subtract base index for window count | `_getPropertyCount("reg", 16)` call at `0xfffffe00096e18e0`, subtraction/store through `0xfffffe00096e18f8` into `this+0x87c` |
| `_mapApertures` requests base index plus loop ordinal, with second argument zero | `0xfffffe00096e28ec`–`0xfffffe00096e291c`; loop bound reload at `0xfffffe00096e2a8c` |

The provider method is a virtual call through slot `+0x710`; identifying its
name as `mapDeviceMemoryWithIndex(index, 0)` is ABI-based inference from the
call shape, imported methods, and returned mapping object's address/length
uses. The base-index arithmetic and requested indices are directly visible.
Together with the two ADTs this corroborates Max's indices 3–10 and Ultra's
4–19. H15's `getAmccCount()` returns this window count, not the generic
superclass's constant or a separately established physical-controller count.

The [binary evidence record](inventory/mcc-binary-evidence-2026-09-26.json)
pins the files and records the allowlisted service identity. Disassembly is
retained under `scratch/mcc-evidence/`. This is not a runtime trace, nor
validation of m1n1's cache/TZ register values or early-boot ordering. Native
cache/TZ behavior, entry/reset/recovery and CPU/DVFS gates remain open.

Further H15 disassembly corroborates plane stride `0x40000` (`start`,
`0xfffffe00096e16e4`/`0xfffffe00096e1718`) and DCS stride `0x200000`
(`0xfffffe00096e1814`/`0xfffffe00096e1848`/`0xfffffe00096e187c`).
`mccEnableCacheMode` writes offset `0x1c00`; `_mccWaitForWaysPwrOn`
polls `0x1c04` and extracts bits 13:9 and 8:4. `setWayMask` reads
`0x1c08` and clamps its way count at twelve. These corroborate offsets
and field widths, **not all m1n1 enable values, expected status values,
mode transitions or early-boot ordering**.

The candidate TZ offsets `0x6d8`, `0x6dc`, `0x6e4` were not established
in H15's active path. The subsequent [carveout audit](m1n1-t6032-carveouts.md)
rejects the AppleARMPlatform `MCPolicyMgrPMP` matches: they are software
object fields, not MCC registers; no literal `#0x6e4` access was found there.
Independent register-layout and carveout evidence remains required before
promoting MCC/cache support to native-ready.

## Local implementation boundary

[`0008`](../patches/m1n1/0008-validate-t6032-mcc-layout.patch) adds a
T6032-only initializer. It validates the compatible, exact property lengths,
four header sizes, sixteen 32-MiB windows, four planes and four DCS channels.
Raw and translated ranges must be nonzero, aligned, non-wrapping and
non-overlapping; derived register extents must fit the selected windows.
Overlap is checked within each address space, never across raw/translated
spaces; equal numeric addresses in different spaces do not establish aliasing.
All translations complete before configuration is published. A failed
initialization, including a failed retry, leaves the T6032 configuration invalid.

The existing T6031 path retains its three-header selection. T6032
initialization failure stops the main boot path before MMU setup; a
cache-enable error stops kernel boot before tunables and clock setup.
Initialization itself does not perform MMIO. The existing cache-enable
routine still would, if firmware were later executed; this is not permission
to execute it. No rollback after partial cache writes is claimed.

The patch carries forward the existing T6031 register configuration where
semantics remain incompletely validated. It corrects layout selection and
failure handling, **not the entire cache/TZ bring-up contract**. T6032 CPU
startup dispatch remains disabled.

## Offline validation

`scripts/test-m1n1-mcc-layout.py` verifies the pristine sources against the
pinned archive, applies all eight patches in a fresh scratch copy and extracts
the actual MCC functions/constants into a host C harness. ASan and UBSan run
with recovery disabled. Hash-pinned committed firmware geometry supplies both fixtures;
a synthetic address translation separates raw bus addresses from mock targets.

The tests cover Ultra's sixteen windows, the unchanged Max initializer's eight
windows, malformed/missing properties, sizes, overlap, alignment and wrap,
failure at the last translation, reinitialization failure and missing nodes.
Initialization must perform zero mock MMIO. Cache-enable tests verify all 64
Ultra writes/polls (32 on Max), address/value/mask/timeout arguments, and an
injected final-poll failure. Caller ordering is checked in the actual patched
main/kboot source; the full callers and hardware are **not executed**.

All 87 Python unit tests and the existing CPU host harnesses also pass. The
[eight-patch default firmware cross-build](inventory/m1n1-mcc-build-2026-09-26.json)
passes with the same two pre-existing warning categories and no new warnings.
The artifacts remain uninstalled and unexecuted.

```sh
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 scripts/test-m1n1-mcc-layout.py
bash scripts/build-m1n1-cpu-offline.sh patched
```

## Next evidence gate

A subsequent [allowlisted capture](m1n1-t6032-carveouts.md) now records
`/chosen/carveout-memory-map`'s `region-id-2`/`region-id-4` properties.
Both are sixteen bytes and decode into plausible address/size pairs under
the pinned source's convention. This does not establish candidate TZ register
offsets or prove that every die shares one map. Next address the identified
runtime range-validation/caller-propagation gaps offline, while keeping the
register-layout evidence gate open. No hardware register read, native
execution or installation is authorized by these metadata results.

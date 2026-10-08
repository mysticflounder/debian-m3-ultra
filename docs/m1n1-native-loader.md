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
file length alone does not establish readable source padding. At this earlier
checkpoint no package had been assembled or approved. The later host-only
assembly below produces an **unqualified comparison package**, not a native
boot artifact.

## Inline package assembly — 2026-10-07 UTC

The new `build-j575d-inline-package.py` assembles actual candidate and official
packages from hash-pinned retained inputs: full32 raw loader
`edb04ff16c0e467a6179392ac99674faa59005aeb9b89c9e062f8305fcb154cb`, raw ELF
`67827c952c4e79268960597e31afd3f344fe1dd22d2854555bd5781ea0dc3b04`, the
unchanged Image `ad9b573e66738d13d7758619809cc7e8ff09cf9498e23ccec352dfe42b285f50`,
and the retained module initramfs. The raw ELF symbols establish `_base=0`,
`_end=_payload_start=0x3b0000` (3,866,624 bytes), matching raw-binary EOF.
The Image remains the original 43,010,560-byte gzip input with declared
`image_size=44,040,192`; full32 finalization reserves the additional 1,029,632
bytes, but zero-fill of that tail is not proven or required by this package.

Retained outputs are `scratch/j575d-inline-package.zv0ik1p4` (candidate DTB
SHA-256 `e92e5c9dc86731d76dc060759bb622cbad073e4e32e831bf0ca68deef3ff4cd5`)
and `scratch/j575d-inline-package.z0up7d3d` (official Kbuild DTB SHA-256
`abd4d0760dabe647048cb3c4ea3e68116e37fcb9dcdb022ded29449d6c43ee79`). Each
contains `manifest.json`, `payload.bin`, `UNQUALIFIED-m1n1-inline.bin`,
`Image.gz`, `initramfs.wrapper` and `README.txt` explicitly marked **NOT BOOT
APPROVED**; there is no installer. The [inline-package inventory](inventory/m1n1-j575d-inline-package-2026-10-07.json)
records the exact inputs and outputs.

The contiguous payload is, with no alignment padding: a
`chosen.bootargs` record, gzip Image, exact DTB, the 14-byte
`m1n1_initramfs` magic without NUL plus little-endian compressed-initramfs
length and bytes, then a 64-byte zero trailer. The default bootargs are
`earlycon console=ttySAC0 rdinit=/init`; no QEMU PL011 address or baud is
invented. The shipped inline packet retains runtime bootargs/placeholders;
post-fixup DTBs from the handoff fixture are test outputs only and are never
substituted into it. The zero trailer supplies lookahead backing for this
assembly; no parser patch is claimed.

The actual combined-binary host tests compile/run the retained `payload.c`,
tinf and libfdt sources. Official and candidate runs pass with compile/run
exit zero, zero mismatches, actual compressed consumption, setters and boot
tail checks: `scratch/m1n1-inline-package-tests-2026-10-07/run-smvjc7ad`
(official) and `run-m46s1y2s` (candidate). The test compiles a 32-CPU target
configuration but makes no native CPU-matrix claim.

The separate Linux handoff fixture uses the actual packaged official Kbuild
and candidate DTBs at `scratch/m1n1-linux-package-handoff.mlaq_etg`. Its input
DT placeholder is 8 GiB; the retained `dt_set_memory()` function changes it to
a synthetic 16 GiB RAM span at `0x10000000000` for the host check. Image,
initrd and CPU-release addresses remain synthetic and this does not qualify
physical placement or whole-`kboot_prepare_dt` behavior.

Reproduce assembly and host checks with retained paths:

```sh
UV_CACHE_DIR="$PWD/scratch/uv-cache" PYTHONDONTWRITEBYTECODE=1 \
  uv run --no-project --offline --python 3.13 python scripts/build-j575d-inline-package.py --board candidate
UV_CACHE_DIR="$PWD/scratch/uv-cache" PYTHONDONTWRITEBYTECODE=1 \
  uv run --no-project --offline --python 3.13 python scripts/build-j575d-inline-package.py --board official
UV_CACHE_DIR="$PWD/scratch/uv-cache" PYTHONDONTWRITEBYTECODE=1 \
  uv run --no-project --offline --python 3.13 python scripts/test-m1n1-inline-package.py \
  --payload scratch/j575d-inline-package.zv0ik1p4/UNQUALIFIED-m1n1-inline.bin \
  --image scratch/linux-j575d-kernel.HdzQNm/build/arch/arm64/boot/Image \
  --dtb scratch/m1n1-board-dt/t6032-j575d.dtb \
  --initramfs scratch/j575d-initramfs.lQ4Gr7/output/initramfs.cpio.gz \
  --bootargs 'earlycon console=ttySAC0 rdinit=/init'
UV_CACHE_DIR="$PWD/scratch/uv-cache" PYTHONDONTWRITEBYTECODE=1 \
  uv run --no-project --offline --python 3.13 python scripts/test-m1n1-inline-package.py \
  --payload scratch/j575d-inline-package.z0up7d3d/UNQUALIFIED-m1n1-inline.bin \
  --image scratch/linux-j575d-kernel.HdzQNm/build/arch/arm64/boot/Image \
  --dtb scratch/linux-j575d-kernel.HdzQNm/build/arch/arm64/boot/dts/apple/t6032-j575d.dtb \
  --initramfs scratch/j575d-initramfs.lQ4Gr7/output/initramfs.cpio.gz \
  --bootargs 'earlycon console=ttySAC0 rdinit=/init'
```

The assembled files and host fixtures do not install, boot, touch
firmware/MMIO, or qualify physical source/destination disjointness, native
allocation, firmware state or kernel entry.

## Driver modules and module-capable initramfs

The fresh module producer compiles six Kbuild goals together against pinned
Linux `602042bf29f6efde39cfb5fdd9289bf4854bc0c5`, the original
`scratch/linux-j575d-kernel.HdzQNm` build, and its unchanged Image/config
hashes. The retained package is
`scratch/j575d-driver-modules.WpGKk3/package`, release `7.3.0-rc6`, containing
`apple_mailbox`, `apple_rtkit`, `apple_sart`, `nvme_core`, `nvme_apple` and
`apple_dart`. Real modinfo/vermagic records, `modules.dep`, `modules.alias` and
empty depmod stderr were checked. The [module inventory](inventory/m1n1-j575d-driver-modules-2026-10-07.json)
records the package inputs and outputs. The producer requires exactly these six
manifest entries; the consumer accepts an ordered manifest generically so a
future USB/Ethernet closure can reuse the same initramfs path.

The optional `--module-package` mode of
`build-j575d-initramfs-offline.sh` copies that package, while static PID1 uses
`finit_module` in manifest order, emits `module_loaded` markers, and reports
`/proc/modules` plus registered-driver diagnostics. The module initramfs is
`scratch/j575d-initramfs.lQ4Gr7/`, SHA-256
`7bfb73c02f74a285f6defb02741b85cb880fdbeb7d4a27f458c4c32b62383f30`; the
no-module baseline is `scratch/j575d-initramfs.LdEBjk/`, SHA-256
`aa94d06ef49767977a2ff86d37c80292821e21f70d5104023e92295e967cd6df`.
These are fresh scratch artifacts; any VM rerun must use the exact matching
Image, initramfs and module-package hashes.

Build a fresh module package with
`bash scripts/build-j575d-driver-modules-offline.sh`. Each builder prints a
unique scratch output path; use the printed package path with
`--module-package`, then the printed initramfs path and its actual SHA-256
when testing those new outputs. For example, the retained package can be used
to build fresh module and no-module initramfs variants with:

```sh
bash scripts/build-j575d-initramfs-offline.sh \
  --module-package scratch/j575d-driver-modules.WpGKk3/package
bash scripts/build-j575d-initramfs-offline.sh
```

The following commands recheck the already-retained, accepted artifacts,
not the newly printed build directories:

```sh
UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --offline --no-project scripts/test-j575d-artifacts-vm.py \
  --initramfs scratch/j575d-initramfs.lQ4Gr7/output/initramfs.cpio.gz \
  --initramfs-sha256 7bfb73c02f74a285f6defb02741b85cb880fdbeb7d4a27f458c4c32b62383f30 \
  --module-package scratch/j575d-driver-modules.WpGKk3/package \
  --expect-module apple_mailbox --expect-module apple_rtkit --expect-module apple_sart \
  --expect-module nvme_core --expect-module nvme_apple --expect-module apple_dart
UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --offline --no-project scripts/test-j575d-artifacts-vm.py \
  --initramfs scratch/j575d-initramfs.LdEBjk/output/initramfs.cpio.gz \
  --initramfs-sha256 aa94d06ef49767977a2ff86d37c80292821e21f70d5104023e92295e967cd6df
```

Both fresh RAM-only QEMU/HVF acceptance runs pass: module run
`scratch/j575d-artifact-vm-2026-10-07/run-s11woxm1` loads all six modules and
reports them in `/proc/modules`; baseline `run-1qm_6azy` confirms no module
autoload. Both use four CPUs and 16 KiB pages, keep PID1 alive, have no disk,
network or firmware, and exit cleanly after cleanup. The retained
serial/error records contain no module errors; QEMU stderr is the expected
81-byte termination receipt and cleanup exits are zero. This does not validate
physical Apple probing, DT binding, native MMIO or hardware behavior.
Default native dispatch remains disabled; native work still requires a
current verified backup, recovery readiness and separate approval.

## I/O module closure — 2026-10-08 UTC

The new `build-j575d-io-modules-offline.sh` overlays a cloned build with only
four resolved Kconfig changes: `CONFIG_APPLE_TUNABLE=m`, `CONFIG_AQTION=m`,
`CONFIG_PHY_APPLE_ATC=m` and `CONFIG_NET_VENDOR_AQUANTIA=y`. The original
`.config` is unchanged; the overlay is intentional. The retained COW build is
`scratch/j575d-io-modules.RBhuUf/package`, whose closed dependency manifest
contains 17 modules in generated order. It preserves the prior Image and
`vmlinux.o`, `System.map` and `vmlinux.symvers` hashes
(`ad9b573e66738d13d7758619809cc7e8ff09cf9498e23ccec352dfe42b285f50`,
`c374260adf8be4dfd7e73a0be79f2136e6a939fa5a5ab7bad840ec19c310faf5`,
`f8013c17497ce293cad4d01be6723173cffb5a0e325f86e2890c9cecb9d69a59`,
`2be09f0907b6c19975e4defbbcfc5e6ec232c07d291205f71c3cb107e1054b0e` respectively);
the package extends the prior six with PCIe, Apple GPIO, Pasemi I2C
core/platform, Apple tunable/ATC PHY, Type-C/TCPM/TCPci/TPS6598x and Aquantia
Atlantic. Its AQC113 PCI alias resolves to `atlantic`.

The 17-module initramfs is
`scratch/j575d-initramfs.g1ScGZ/output/initramfs.cpio.gz`, SHA-256
`0923b9e2ca20deaf63dab4d01b1ae037cce19ce36ba9eaa1d2ba612434d3096d`. Its
RAM-only HVF acceptance run is
`scratch/j575d-artifact-vm-2026-10-07/run-_c1kxiz_`: all 17 load markers,
17 `/proc/modules` members and every diagnostic marker pass, with no network,
disks or persistent VM and cleanup exit zero. The legacy-six and extended-17
manifest checks pass in `scratch/j575d-module-manifest-checks.c32siftq`.

Read-only host I/O inspection identifies primary AQC113 PCI ID `1d6a04c0`,
Apple subsystem `106b0223`, bound driver port 2/BDF `2:0:0`. In the cached
candidate before the separate profile, port 02/DART2 is disabled and cached
m1n1 does not enable a Linux DT node; `pcie_init` is hardware initialization
only. This is not a native probe
or USB qualification. USB remains open: the driver compatible is only `t8103`
against T6031/T8122 candidates, full32 ATC fixup misses die-1 aliases, restore
ADT tunables use device/host topics not expected here, and the Type-C graph is
absent. Do not label USB hardware complete. Native dispatch remains disabled.
No candidate-schema resolution is implied by this module package.

Reproduce the build/package portion with the retained recipe shape:

```sh
bash scripts/build-j575d-io-modules-offline.sh
bash scripts/build-j575d-initramfs-offline.sh \
  --module-package scratch/j575d-io-modules.RBhuUf/package
```

These are build/package and disposable HVF checks only; no native commands,
MMIO, firmware, disk, persistent-VM, security-fix or submission action is
authorized by this milestone. The [I/O module inventory](inventory/m1n1-j575d-io-modules-2026-10-08.json)
records the exact scope.

## Live USB and functional backport contract — 2026-10-08 UTC

The subsequent [filtered live USB inventory](inventory/j575d-usb-live-contract-2026-10-08.json)
supersedes using the restore template as the only tunable source: all six live
PHYs expose fourteen named tables, and six ACE3 controllers use SPMI banks
`nub-spmi-a0`/`nub-spmi-a2`, not the older I2C-only PD path. The collector
`scripts/collect-j575d-usb-metadata.py` emits only public selected fields and
table bytes; unfiltered ioreg output stays in memory. This is macOS metadata,
not a final iBoot handoff. Complete generation-aware M3 PHY and ACE3/SPMI
driver ports have now been built as described below. Subsequent provider
metadata resolves the second bank's physical address and exposes the board
layout correction described below. Four named IRQs, six connector graphs and
faithful tunable conversion remain prerequisites. Neither module loading nor
the existing PCIe profile proves
physical USB support. New combined m1n1 tests remain unexecuted pending the
retained tree's policy decision.

## Functional USB driver backports — 2026-10-08 UTC

The [USB driver inventory](inventory/j575d-usb-drivers-2026-10-08.json) binds
three source-root-relative patches against Linux `602042bf`: complete Apple
SPMI command/FIFO/optional-IRQ support, the generation-aware M3 USB2/USB3 PHY
implementation, and a semantic TIPD common/I2C/ACE3-SPMI split. The split
preserves the pinned newer status layouts, power-status callbacks and TPS66993
support. The PHY uses the intentional `t6031,t8122` fallback, not a bare alias;
DisplayPort functionality is not established or required for this stage.

`scripts/build-j575d-usb-drivers-offline.sh` patches and builds only fresh APFS
clones. The final workspace `scratch/j575d-usb-drivers.6s0L0J` resolves exactly
six module-overlay config changes and packages twenty modules, including
`spmi-apple-controller`, `tps6598x-core`, `sn201202x` and the rebuilt PHY/I2C
front end. The baseline config, Image and built-in ABI artifacts remain
unchanged; depmod reports no unresolved symbols and both new OF aliases resolve.

The initramfs `scratch/j575d-initramfs.twYPeR/output/initramfs.cpio.gz` has SHA-256
`430cc4ddf9a9786ed7e754730ac98a937f8d727cf65d13b3b6114c6bfbf4959c`.
RAM-only HVF receipt `scratch/j575d-artifact-vm-2026-10-07/run-44cq22hk` (created
October 8 UTC; harness output-directory name retained) passes thirty markers
and records all twenty modules in `/proc/modules`, with no load/symbol errors.
The disposable guest has no disks, network, firmware or host-device passthrough;
the persistent VM is untouched. This checks module ABI/registration, not Apple
SPMI transactions, PHY calibration, IRQ delivery, power sequencing or USB traffic.

The inherited SPMI FIFO-recovery code defines ACT at `0xa4` but writes its flush
through RSP at `0x8`. This is recorded as an unverified reliability question,
not a proven security issue; no register guess or issue filing was introduced.
Board-layout correction, four-IRQ/connector graphs, per-port tunable handoff and
native qualification remain open. The default loader/native-dispatch setting
is unchanged, and no boot-entry or disk action is authorized by this milestone.

## USB physical layout and companion bindings — 2026-10-08 UTC

The [routing inventory](inventory/j575d-usb-routing-2026-10-08.json) records
an additional read-only macOS observation. The collector retains public
IODeviceTree/IOService resource descriptors and explicit USB-to-mapper-to-DART
joins; unfiltered archives stay in memory. Eleven offline filter fixtures pass,
and two in-memory wrong-die controls are rejected. This does not read registers
or qualify hardware operation.

Translated addresses establish four USB/PHY pairs on die 0 and two on die 1,
not the generic candidate's three-plus-three arrangement:

| Firmware port | Physical DWC3 base | Linux source pair |
| --- | --- | --- |
| 1 | `0x702280000` | `dwc3_0` / `atcphy0` |
| 2 | `0xb02280000` | `dwc3_1` / `atcphy1` |
| 3 | `0xf02280000` | `dwc3_2` / `atcphy2` |
| 4 | `0x1302280000` | Missing `dwc3_3` / `atcphy3` and two DART nodes |
| 5 | `0x2702280000` | `dwc3_0_die1` / `atcphy0_die1` |
| 6 | `0x2b02280000` | `dwc3_1_die1` / `atcphy1_die1` |

The existing `dwc3_2_die1` / `atcphy2_die1` pair is not witnessed as a J575d
port; do not assign the sixth connector to it. Port 4's DART windows are
directly observed at `0x1302f00000` and `0x1302f80000`, with DART IRQ 1450,
distinct from its USB provider's fifth raw IRQ word 858. Source-subdivided
DWC3/ATCPHY windows are not all separate, directly observed resource lengths.
The die-0 PMGR already provides the fourth-port power-domain templates.

SPMI a2 also resolves into die 0, at `0x2a11a8000`, with observed AIC
controller `0x170` and IRQ number 767. Its first live window contains the
driver's complete `0x100` register footprint. A parent level-high IRQ and
`ps_nub_spmi_a2` are reviewed source-level candidates; the power-domain join
and physical transactions are not runtime-validated. This supersedes the
earlier unresolved-address finding, not the native qualification gate.

Companion patch `0004-apple-spmi-and-ace3-bindings.patch` adds the matching
SPMI interrupt/domain schema and ACE3's four named IRQs/connector binding.
Zero-fuzz application and offline `dtschema==2026.9` document/reference checks
pass; no full board-DTB schema validation is claimed. It is not applied to the
frozen twenty-module build recipe/receipt. The next source change is the actual
four-plus-two board layout, followed by connector graphs and faithful per-port
calibration. The default DT/loader is unchanged and the m1n1 policy-held lane
remains held.

## PCIe four-port DT profile — 2026-10-08 UTC

The independent `build-j575d-pcie-dt.py` profile (SHA-256 prefix `574e2cf4`)
uses `configs/j575d-pcie-ports.dtsi` (SHA-256 prefix `1408e38c`) and produces
`scratch/j575d-pcie-dt.z4iac0rm/manifest.json`. Its 19-file closure is
verified; the baseline DTB remains unchanged at SHA-256
`e92e5c9dc86731d76dc060759bb622cbad073e4e32e831bf0ca68deef3ff4cd5`, while
the profile DTB is `ed4623024f6d06bd816fc483735027e53798ad7f3de489775b77c5c2f5ea54a6`.
Exactly six status changes are made: ports 01/02/03 and DARTs 1/2/3 change
from `disabled` to `okay`; all other DT properties, maps, resets, compatibles
and resources remain unchanged. All four ports and DARTs are enabled in the
profile. All 41 final command receipts exit zero.

Both old and profile DTBs retain six DTC warnings in the
`unit_address_vs_reg` and `simple_bus_reg` categories. Cached dtschema 2026.9
receipts contain 431 stderr lines for each DTB; the zero exit code is not a
clean-schema result. Relative-filename normalization in
`scratch/j575d-pcie-schema.4npcqmf0/normalized-comparison.json` confirms the
diagnostics are identical. No candidate schema issue is silently resolved.

Read-only host inspection maps ports 0–3 to Wi-Fi/BT, SD, AQC113 and ASM3142
xHCI. Corrected interpretation: a disabled DT node does not exclude ECAM
enumeration despite the stale `pci_set_of_node` comment. Linux slot order gives
buses 1–4 only conditionally, for four ordinary visible bridges without extra
bus reserves; this is not a guessed bus-2 map and does not establish physical
config/setup, fallback T602x behavior, link, DMA, IRQ or driver binding. Do not
claim USB, Wi-Fi, Bluetooth or SD hardware completion, and do not claim
port-3 Type-C SoC PHY support.

Reproduce the host profile only with:

```sh
UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --offline --no-project scripts/build-j575d-pcie-dt.py
```

The profile leaves the original DTB, default m1n1, native dispatch and all
hardware/firmware/VM state untouched. The [PCIe profile inventory](inventory/m1n1-j575d-pcie-profile-2026-10-08.json)
binds the retained inputs, output and warning/schema receipts; the
[independent review](../scratch/m3-pcie-dt-final-review-2026-10-08.md) records
the final interpretation.

The candidate compatible tables already select fallback implementations, but
this is not a hardware contract. NVMe uses SART/mailbox/RTKit/reset and three
direct PMGR domains (seven domains including transitive parents), with no `iommus` property;
DART is separate. `CONFIG_APPLE_PMGR_PWRSTATE=y`. The actual
`apple_nvme_attach_genpd` loop handles all domains; the binding's max-two limit
is schema-only and is not a runtime defect. Candidate DTC's six warnings and
full-schema validation's 431 diagnostic lines remain open. No alias or copied
hardware-ops patch is justified.

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

Next: establish a working Image/DTB/initrd package and native placement
contract, then qualify the packaged SoC-driver closure against the candidate
DT. Native hardware qualification remains behind the backup/recovery and
approval gates. Defensive parser hardening and security fixes are outside
project scope; report findings rather than making them prerequisites for
bring-up.

## Report-only issue candidates

On 2026-10-07, a host fixture demonstrated that the retained full32 loader
advances 64 bytes for a signature whose declared handoff span is only 12 bytes.
The fixture has 128 bytes of actual backing; this proves a declared-boundary
violation, not an out-of-bounds crash, exploit, or native failure. The original
dispatcher also uses a null result for both malformed input and normal package
termination, allowing previously collected boot state to remain usable.

These are issue candidates, not established security vulnerabilities. A
security report needs the affected upstream behavior and a relevant input/trust
boundary established first; no additional hardening or exploit investigation is
planned here. Evidence is retained in
[the issue-candidate record](inventory/m1n1-loader-issue-candidates-2026-10-07.json).
No upstream issue has been opened. Tell Adam if the evidence warrants filing;
do not submit an issue or disclosure without approval.

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

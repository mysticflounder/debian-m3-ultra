# J575d native loader contract

## Boot-stub provisioning checkpoint — 2026-10-13

The portable Debian disk now passes two standalone UEFI/GRUB cold boots under
HVF; see [the VM inventory](inventory/debian-portable-uefi-2026-10-13.json).
That validates the guest disk, not Apple's physical boot chain. The chosen
route remains a minimal Apple boot stub, with a full second macOS install as
a fallback rather than a prerequisite.

Offline provisioning work uses installer source
`e93743d52178b3e26e428fa05174ef549abf30cb` and the official Apple 27.0/26A428
restore archive. `scripts/plan-j575d-boot-stub.py` selects the exact
`j575dap` / `0x44` / `0x6032` macOS Customer identity from local metadata.
`scripts/measure-j575d-stub-inputs.py` verifies local receipt sizes and SHA-256
hashes and measures known logical inputs. Neither script installs, mounts,
personalizes, or changes boot policy.

The fetched closure contains 125 non-BaseSystem members (95,078,532 bytes),
plus the previously verified 1,308,622,848-byte BaseSystem asset. The 21
unique selected identity payloads account for 57,198,538 bytes; summing all
23 manifest references would double-count two paths.

Known System, Preboot and Recovery logical inputs total 1,372,620,386 bytes.
This is **not an installed footprint or proof that an 8 GB container fits**:
generated firmware, local installer files, personalization, APFS allocation
and peak temporary space are not established. Installer-data exports are
accounted separately because their destination is not yet fixed.

**Current incompatibility:** the actual 26A428 `bootcaches.plist` has no
`bless2.RestoreBundlePath`, while the pinned installer indexes that field
directly. Adding the board to its allowlist is therefore insufficient.
The measurement report explicitly leaves layout qualification false and
the 8 GB fit decision unknown. Do not guess the missing path.

A bounded follow-up read of Apple's 15.6.1/24G90 restore archive also found
the exact J575d identity, but its `bootcaches.plist` lacks the same field.
Thus that older archive does not resolve the incompatibility. Neither archive
has been submitted for machine-specific personalization. The next step is to
establish the supported modern Preboot/restore-bundle layout from independent
evidence before implementing a local installer adaptation; a full macOS stub
remains the fallback if the minimal layout cannot be established.

Source pins and local artifact receipts are recorded in the
[provisioning inventory](inventory/j575d-boot-stub-inputs-2026-10-13.json).

The user has confirmed a verified backup and a USB-C data cable. DFU recovery
has not been exercised. The user-created free extent is 130,329,329,664 bytes;
Linux partitions have not been created. The proposed 8 GB stub / 2 GB ESP /
120 GB root split remains provisional. The user will run physical partition
commands, and provisioning/personalization/native testing require separate
approval. This checkpoint made no physical-disk or boot-policy changes.

## Fork package integration — 2026-10-11

The explicit `fork-current` profile packages fork revision `b91ede42` with
the retained Linux Image and updated 20-module diagnostic initramfs. Historical
defaults are unchanged. Use `scripts/build-j575d-inline-package.py --profile
fork-current --board official` or explicitly select `--board event`.

Both assembled packages passed the actual combined-input host fixture with
zero mismatches. The fixture compiles the selected payload parser and decoders;
it does not execute the ARM loader prefix. Five builder tests and two synthetic
DT handoff checks also passed. All seven PHY nodes remain disabled in the event
candidate, and its existing schema caveats remain. Synthetic post-fixup DTBs
are not packaged. Input pins, output hashes and receipts are in
[the integration inventory](inventory/m1n1-fork-inline-package-2026-10-11.json).

These are **UNQUALIFIED offline packages**, not boot-approved artifacts. There
was no VM or native boot. Backup, recovery readiness and native-test approval
remain outstanding; physical memory placement, cache visibility and hardware
bring-up still require qualification.

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
frozen twenty-module build recipe/receipt. The independent Linux profile below
now corrects the four-plus-two provider layout; connector graphs and faithful
per-port calibration remain open. The default DT/loader is unchanged and the
m1n1 policy-held lane remains held.

## Disabled ACE3/Type-C graph candidate — 2026-10-08 UTC

The separate `configs/j575d-ace3-candidate.dtsi` fragment adds the missing
die-0 a2 SPMI bank and six ACE3 connector graphs after the corrected USB4+2
profile. The new bank and all six ACE3 children are explicitly disabled.
Neither the pinned board nor the default loader/profile is replaced.

The read-only `collect-j575d-ace3-routing.py` receipt confirms six actual
`AppleHPMARMSPMI` services and unchanged bank/SID/dock/port joins. All 426
retained byte tuples verify; eight collector fixtures pass. Both registry
planes still expose only three interrupts per HPM, and no `interrupt-names`,
GPIO or PMGR relationship closing the remaining routing questions.

| Firmware port | SPMI bank / SID | DWC3 / PHY | Candidate select IRQ |
| --- | --- | --- | --- |
| 1 | a0 / c | `dwc3_0` / `atcphy0` | 13 |
| 2 | a0 / a | `dwc3_1` / `atcphy1` | 39 |
| 3 | a0 / 8 | `dwc3_2` / `atcphy2` | 65 |
| 4 | a0 / 6 | `dwc3_3` / `atcphy3` | 91 |
| 5 | a2 / c | `dwc3_0_die1` / `atcphy0_die1` | 13 |
| 6 | a2 / a | `dwc3_1_die1` / `atcphy1_die1` | 39 |

The select values are **sibling-board source convention, not J575d witnesses**.
Linux requires four named interrupts and does not derive the fourth from SID
or the logical-register selection command. The a2 power-domain association
also retains its source-derived status. No native qualification follows.

With the retained Linux closure and receipts present, run
`uv run --offline --no-project --cache-dir scratch/j575d-spmi-routing-uv-cache
python scripts/build-j575d-ace3-candidate.py`. Then run
`python tests/test-j575d-ace3-candidate.py <workspace>` through the same uv
environment. These commands only compile/inspect offline DT artifacts.

Two independent builds reproduce the unchanged USB baseline `af9ba709` and
candidate `832bdc15`. The candidate adds 103 nodes and 49 symbols, including
36 endpoint nodes forming 18 reciprocal connections. Checks require exact
connector/DWC3/ATCPHY ownership, port indices, the four-die0/two-die1 mapping,
and preservation of existing resources and resolved reference identities.
Eleven regression tests pass on each build; eight designated builder controls
also reject wrong routing, ownership, resource, status and unrelated changes.
All four DTC diagnostic files are byte-identical and retain six warnings;
this is not complete DTB schema validation. The
[candidate inventory](inventory/j575d-ace3-candidate-2026-10-08.json)
binds the evidence, including the unchanged USB driver package regression.

Next: faithful six-port calibration and an independent select-IRQ witness.
SPMI power/recovery, PHY initialization, IRQ/DMA and Type-C operation still
need native qualification. No calibration, aliases, bootloader handoff,
firmware, disk or VM change is included; the retained m1n1 policy-held lane
and backup/recovery/native-approval gates remain unchanged.

## Native PHY record normalization — 2026-10-08 UTC

The retained macOS 27.0 / 26A428 collection contains
`com.apple.driver.AppleT6032TypeCPhy`. Static inspection of that driver now
supplies twelve named-property-to-register selectors and the actual
`applyTunables` input/write contract. The 42-by-8 native register table matches
all 252 captured address/size tuples for the six J575d ports, uniquely selecting
columns 0–5. Columns 6–7 do not establish two additional physical ports.
The [normalization inventory](inventory/j575d-phy-calibration-2026-10-08.json)
binds the binary views, instruction/table receipts, source captures and tests.
An independent byte check matches 4,542 disassembled instruction words and all
336 register-table cells to the retained view, and verifies eight chained
dispatch targets against the original collection. This is not PAC or runtime
authentication.

Native records are three little-endian u32 words. The observed high-five-bit
value is 4; the offset is the sign-extended low 27 bits, not an M1-derived
low-24-bit offset or a Linux resource index. The mismatch path writes
`(read32 & ~word1) | word2` at the selected bank plus that offset.
The decoder deliberately supports only the captured class-4, aligned,
nonnegative records; it is not a general native record interpreter.

```sh
uv run --offline --no-project --cache-dir scratch/j575d-spmi-routing-uv-cache \
  python scripts/decode-j575d-phy-calibration.py
uv run --offline --no-project --cache-dir scratch/j575d-spmi-routing-uv-cache \
  python tests/test-j575d-phy-calibration.py
```

These commands require the inventory's retained inputs. They generate only
diagnostic JSON under `scratch/`, not a DTB, DTS property or loader payload.
Two independent runs produce identical decoded bytes. Ten tests check all
852 records independently, including masks/values, bank additions, record
order, source provenance and port-specific differences; fixture controls
reject wrong byte order, banks, board/ports, unsupported offsets and ambiguous
containment. These are fixture controls, not implementation-mutation tests.

| Current compiled Linux window containment | Records |
| --- | ---: |
| AXI2AF | 312 |
| Core | 150 |
| No current window: ATC_FABRIC | 390 |

Containment does **not** assign a Linux calibration property. In particular,
port 1's fabric bank is `0x703244000 + 0x4000`, outside its declared
`0x703000000 + 0x4c000` core window and all four other windows. The pinned
Linux driver maps five resources and loads seven T8122 tunable properties;
it has no separate fabric channel. Whether early firmware already owns this
programming or Linux needs an explicit resource/property is still open.
Do not invent core-relative offsets or enlarge the core aperture to hide it.

Whole-collection pointer-chain resolution confirms native USB helper calls
in the order `AUS40CMN_SHM`, `AUSPLL_CORE`, `CIO4PLL_CORE`. The proven generic
USB dispatch does not call the separate CIO80-default helper; those lane
defaults must not simply be copied into USB properties. The Linux common-a /
common-b and lane split, full initialization path, and separate USB2 host/device
consumer remain open. The twelve USB2 source records are verified but not
converted. No Linux properties are emitted and the disabled ACE3 candidate,
twenty-module package, default loader, persistent VM and native-dispatch
setting are unchanged. The m1n1 policy-held lane and physical safety gates
remain unchanged too.

## Generic PHY calibration integration — 2026-10-08 UTC

The native init-to-calibration edge is now resolved: `aciophy_phy_init`
dispatches part B, whose `vptr + 0xbe0` target is the generic tunable helper.
That helper requests AXI2AF, Fabric, LN0 RX-clock and LN1 RX-clock in that
order before its mode-specific helpers. Its `0x4004` tests select diagnostic
logging paths; they do not disable Fabric calibration. An independent check
matches 65,685 disassembled words against the original collection and views,
three complete function ranges, four logging-branch targets and eight
format-8 pointer targets. These remain static witnesses, not runtime binding
or PAC authentication.

The [Linux-only Fabric patch](../patches/linux/j575d-602042bf/0004-apple-atcphy-m3-fabric-calibration.patch)
adds an explicit sixth `fabric` resource and `apple,tunable-fabric` channel.
It is opt-in through the T6031-compatible descriptor used by J575d's
T6031/T8122 pair. Both new resource and property must be present together;
both absent preserve the five-resource path. Other generation descriptors
reject the new channel. The resource is separate, not an enlarged core
aperture. Application is after AXI2AF and before common-b under the existing
configure lock. Six source-extracted host tests check compatibility gating,
legacy/new call order, pair validation, big-endian tuples and bounds; these
are not a blanket cross-architecture or hardware regression proof.

```sh
bash scripts/build-j575d-phy-fabric-offline.sh
uv run --offline --no-project --cache-dir scratch/j575d-spmi-routing-uv-cache \
  python scripts/build-j575d-phy-fabric-dt.py
uv run --offline --no-project --cache-dir scratch/j575d-spmi-routing-uv-cache \
  python tests/test-j575d-phy-fabric.py
uv run --offline --no-project --cache-dir scratch/j575d-spmi-routing-uv-cache \
  python tests/test-j575d-phy-fabric-dt.py
```

The fresh isolated Linux build applies all four patches and produces twenty
AArch64 modules with checked dependency closure, depmod and aliases. Base
Image and kernel link artifacts are unchanged. It is a separate package,
not installed or booted; the previously validated persistent VM and package
remain unchanged.

The new DT candidate assigns only the proven generic sequence:

| Linux property | Native source groups | Records, six ports |
| --- | --- | ---: |
| `apple,tunable-axi2af` | ATC0AXI2AF | 312 |
| `apple,tunable-fabric` | ATC_FABRIC | 390 |
| `apple,tunable-common-b` | LN0 RX-clock, then LN1 RX-clock | 48 |

All 750 offsets, masks, values and record order are checked independently
against little-endian capture bytes and big-endian compiled DT properties.
The five legacy windows stay byte-identical; the sixth translates to each
port's native Fabric bank, including die 1. All six PHY nodes are explicitly
disabled and all six ACE3 nodes stay disabled. Only 36 targeted properties
change; other nodes, graphs, phandles and resources are unchanged. DTC
round-trip compilation preserves the tree, boot CPU and reservation map.
Independent candidate outputs are byte-identical, and four DT tests pass.

This is an inert integration candidate, **not boot approved**. Seventy-two
USB-helper records still need a mode-scoped channel; thirty CIO80-default
records must not be assigned without their caller/protocol evidence. The
twelve USB2 records remain unconverted: generic SDB parsers match their
shape, but neither named routing nor the base/role sequence is established.
The apparent difference between captured role values and Linux's hardcoded
host field is not a proven bug and no role-bit change is made. The existing
scratch-only dt-schema 2026.9 cache is available offline; no dependency
download is needed. Validation caught two redundant resource `maxItems`
declarations and a property-level `minItems: 1` that caused the schema processor
to infer a one-row maximum. The corrected Fabric property
inherits the shared matrix type's nonempty, unbounded row count; no driver
code changed for these binding corrections. Binding-document validation,
the fresh twenty-module build and all twenty source/DT/decoder tests pass.
The full processed-schema run reports no ATCPHY errors and no new diagnostics
relative to the frozen parent. The whole board is **not schema-clean**:
80 existing validation errors and 86 unmatched compatibles remain for
functional triage, including PMGR, DART, NVMe, SPMI and USB descriptions.

Copy-only controls accept 65 Fabric rows and diagnose malformed/empty rows,
missing resources and the wrong generation. For a conditional-only missing
Fabric property, dt-schema 2026.9 skips the disabled-node mismatch but rejects
an otherwise identical enabled copy. This validator limitation does not make
the pair optional: the driver and exact-property DT builder enforce it
independently. The separate bounds fixture exercises the DT builder, not the
kernel parser. Select IRQ, power/clocks, IRQ/DMA and physical operation remain
open.

The complete native USB helper also establishes an ordered 1/7/4-row sequence
for AUS40, AUSPLL and CIO4PLL, all within the core resource. A single ordered
USB-common property is a possible next implementation only if it retains
all twelve records per port, their order and USB-only mode gating, after
generic calibration and before lane setup. No such mode channel is implemented
here, and static ordering does not qualify the Linux reset/analog timing.

The [integration inventory](inventory/j575d-phy-fabric-integration-2026-10-08.json)
retains the patch, builds, byte checks and tests. The original normalization
receipts remain reproducible. No default payload, native dispatch, firmware,
NVRAM, disk, partition or persistent-VM setting changes. The m1n1 source-policy
hold, verified-backup/recovery requirement and separate native approval remain.

## Opt-in T6031 USB-only calibration — 2026-10-08 UTC

The [USB-common patch](../patches/linux/j575d-602042bf/0005-apple-atcphy-m3-usb-common-calibration.patch)
extends the frozen Fabric source through a separate optional
`apple,tunable-usb-common` property. Only the T6031 descriptor permits it;
other generations reject its presence. Absent properties preserve the legacy
path, including M3 without a Fabric pair. Present properties must contain
nonempty complete triples before resource mapping; the existing core-relative
big-endian parser checks alignment and bounds. No window is added or enlarged.

| Source group | Rows per port | Linux resource |
| --- | ---: | --- |
| AUS40CMN_SHM | 1 | core |
| AUSPLL_CORE | 7 | core |
| CIO4PLL_CORE | 4 | core |

All twelve rows per port retain source order, masks and values. The channel
runs once after generic common-b and before existing lane programming, only
for symbolic Linux USB3 and USB3/DP modes. DP-only, TBT, USB4, USB2 and OFF do
not apply it. This is a constrained semantic caller mapping, not a claim that
Linux and native numeric enum values are identical or that reset/analog timing
has been qualified physically.

```sh
bash scripts/build-j575d-phy-usb-common-offline.sh
uv run --offline --no-project --cache-dir scratch/j575d-spmi-routing-uv-cache \
  python tests/test-j575d-phy-usb-common.py
uv run --offline --no-project --cache-dir scratch/j575d-spmi-routing-uv-cache \
  python tests/test-j575d-phy-usb-common-dt.py
```

The fresh twenty-module package passes closure, depmod, aliases, AArch64 ELF,
vermagic and baseline invariance checks. It is not installed or booted. Six
source tests execute the complete extracted apply function across 56 cases
(seven modes, USB present/absent, Fabric present/absent and both orientations),
including both real lane calls and register bases. A compiling mode-gate
mutation fails with the designated exit 1, rather than accepting any runtime
fault as a witness. Separate source-extracted parser/validation fixtures check
generation, lengths, big-endian tuples and bounds.

Eight independent DT tests check all 822 compiled records against raw capture:
750 generic plus 72 USB-only. Only 42 properties differ from the frozen
pre-Fabric parent; all six PHY and ACE3 nodes stay disabled, legacy windows and
all other nodes stay unchanged, and DTC round-trip/header/reservation checks
pass. The frozen Fabric suite and its pinned CLI log are not rewritten.
Final full-schema comparison produces byte-identical path-normalized diagnostics
for the actual 822-record candidate and frozen 750-record baseline: 449 lines,
80 existing schema errors and 86 unmatched compatibles, with no ATCPHY or new
diagnostics. The binding document itself validates without diagnostics. Seven
copy-only controls qualify the targeted USB property: enabled copies accept
12 and 65 rows and an absent optional property; malformed and empty matrices
are rejected. Other-generation copies reject USB-common with Fabric and its
sixth resource removed, whether enabled or disabled. No disabled-node gap was
observed for this USB restriction; the separate Fabric pair limitation above
is unchanged. Canonical PHY nodes remain disabled, and neither a clean whole
board nor physical/native functionality is claimed.

The [USB-common inventory](inventory/j575d-phy-usb-common-integration-2026-10-08.json)
also retains whole-board triage. Missing exact M3 driver names do not prove
missing drivers: several advertised fallback compatibles already match the
pinned source. The 16 PMGR property errors are eight boolean
`apple,externally-clocked` entries on MCA0..3 domains across both dies,
reported by both parent and child schemas. Linux has no identified consumer,
but hardware meaning remains unproven; neither allowing nor deleting the
property merely to silence validation is justified.

Thirty CIO80-default records, twelve USB2 records and the select-IRQ witness
remain separate work. Physical power/clock/IRQ/DMA, native kernel entry,
source-policy, verified-backup/recovery and separate-approval gates are unchanged.
No default loader, native dispatch, persistent VM, firmware, NVRAM or disk changes.

The [remaining Type-C contract audit](inventory/j575d-native-typec-contract-gaps-2026-10-08.json)
narrows the three missing producer edges. Fresh, nonprivileged IODeviceTree
and IOService captures still expose only three interrupts for each of six
HPMs. The native `AppleHPMInterface::initSingleHPM` registration loop is
traced, but neither that generic edge nor the public properties identify the
J575d select hwirq; absence from public metadata is not hardware absence.
The captured `AppleHPMARMSPMI::writeRegs/readRegs` paths instead poll provider
register 0 after requesting selection. Bit 7 denotes busy; the requested
register with bit 7 clear denotes ready. This is a native polling witness,
with unresolved provider semantics: selection modes `0x12`/`0x2` still need
mapping to Linux's register-zero transaction and synchronous completion.
Stale-ready behavior is unproven, and the native busy-loop
exhaustion falls through without a distinct timeout error; that behavior is
not adopted as Linux policy. A proven polling path could remove the functional
dependency on the missing select IRQ without inventing a board mapping.
On Linux, the default regmap mutex spans selection, polling and payload;
the SPMI controller separately completes each command with ACK/parity checks.
A missing `select` in a valid name list returns `-ENODATA`, not `-ENXIO`.
An eventual explicit three-IRQ polling opt-in must preserve the cached Apple
binding's four-IRQ default and must not reinterpret malformed metadata,
`-EPROBE_DEFER` or IRQ-zero mapping failure as absence. The optional offline
prototype described below now implements an explicit experimental opt-in.
The native adapter reaches `AppleARMSPMIDevice::register0Write` (kind 7) and
`registerRead` (kind 6), then `AppleARMSPMIController::sendCommand`. Two
receiver implementations remain unresolved: the object at `controller+0xe0`
with vtable slot `+0x1e8`, and the controller's slot `+0x980`. Method names
and command kinds alone do not qualify the wire encoding, completion or error
translation. Corrected exact-address views supersede rebased call-site
evidence; the main verifier checks 520 original instruction-byte lines and
27 same-line address/instruction anchors. Basic `readRegs` ends at
`0x9805e40`; the fixed register-`0x20` payload instruction is in its separate
length-taking overload, not that basic body.
Native CIO mode 2 now traces from `cioClientSetACIO` through `initACIO` and
part B. The generic dispatcher directly invokes CIO and then CIO80; the CIO
helper itself does not call CIO80. Its Linux protocol crosswalk remains
unproven. USB2's twelve records have offset 8 and mask `0x7000`, but captured
HOST/DEV values have opposite polarity to the existing Linux role path;
native consumer/base/timing remain unproven. No guessed mapping is added.
The 822-record disabled candidate and the normal build patch set remain unchanged.
Linux completion/serialization and exact IRQ-name errors now have pinned
source receipts. The bounded native audit stops at those two unresolved
receiver implementations; independent source-backed help is needed before
qualifying a Linux polling change. CIO80 and USB2 also need independent
evidence. Pro consult `01M4EWE11E4FR4ZNSBYPZBFKYQ` subsequently completed
in channel message 18760; its source review distinguishes offline logical-API
testing from a claim of native command identity. The
[experimental polling prototype](j575d-select-polling-prototype.md) requires
observed busy then ready, resets that observation for every selection, and
keeps the four-IRQ path as the default. This conservative policy can miss a
fast busy interval and does not prove a new hardware epoch. Sanitized
actual-source host tests, an exact-exit-1 mutation control, two valid/seven
invalid binding fixtures and the ARM64 20-module dependency build pass.
The empty-interrupt schema case remains limited by a dtschema decoder crash;
runtime zero-entry rejection is tested. No native or device-register
operation was used.

## Corrected USB4+2 provider profile — 2026-10-08 UTC

Run `uv run --offline --no-project --cache-dir scratch/j575d-spmi-routing-uv-cache
python scripts/build-j575d-usb-layout.py`
with the existing nineteen-file Linux DT closure and routing receipts present.
The builder includes the pinned board, the unchanged PCIe fragment and
`configs/j575d-usb-layout.dtsi` in that order. It does not execute m1n1, install
anything, launch a VM or access hardware. The [profile inventory](inventory/j575d-usb-layout-2026-10-08.json)
binds the build and regression evidence.

The fragment adds `dwc3_3`, `atcphy3` and two DARTs on die 0. It disables
`dwc3_2_die1`, `atcphy2_die1` and their two DARTs without deleting the generic
source nodes. Six witnessed DWC3/PHY pairs and twelve USB DARTs are active
in the offline profile. All six provider groups' translated resources, PHY,
reset, IOMMU/stream-ID and power-domain links are checked. New register
subdivisions and AIC tuples retain their source-derived status; the unassigned
raw DRD IRQ words are not assumed to be ACE3 SPMI child interrupts.

The unchanged baseline DTB hash and independent PCIe status-only check pass.
Full-tree comparison resolves phandle identities, rather than rejecting valid
dtc renumbering or silently comparing stale numeric IDs. The intended delta is
four nodes, four symbols and four disabled statuses. Mutation controls check
resources, DART IRQ/size, IOMMU links, an unwitnessed port and unrelated root
changes. Run `uv run --offline --no-project --cache-dir scratch/j575d-spmi-routing-uv-cache
python tests/test-j575d-usb-layout.py
<compiled-workspace>` for the independent regression suite.

All three compile variants retain six DTC warnings, in `simple_bus_reg` and
`unit_address_vs_reg`; no complete board-DTB schema qualification is claimed.
This profile does not add connector graphs, calibration tables or loader
aliases, or change the frozen twenty-module build. Native USB power, IRQ,
DMA, SPMI and PHY operation remain untested. Default loader/native dispatch
and backup/recovery/explicit-native-approval gates are unchanged.

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

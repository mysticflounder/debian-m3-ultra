# M3 Ultra / T6032 SoC work — 2026-09-26

Target: the project's 32-core Mac Studio, `Mac15,14`, `J575d` / `J575dAP`,
chip `0x6032`. This is not the M3 Max or the secondary M5 Max target.

Scope: resume offline bare-metal preparation while preserving the working
QEMU/HVF VM. No partitioning, Apple boot-policy modification, m1n1 install,
native payload execution, physical-disk attachment, or MMIO writes were
performed by this work. The separate [m1n1 roadmap](m1n1-t6032-bringup.md)
retains the hardware-test gates.

## Refreshed source baselines

These revisions are the inspected branches, not a claim that every public
development branch or pending patch was searched.

| Component / branch | Inspected revision |
| --- | --- |
| Asahi m1n1 `main` | `4184923ffb2dff079b384d6a32cc02142aa14572` |
| Asahi U-Boot `asahi-releng` | `ec49c9d70e6ab003813d6f475fec62dc1c0f4bfe` |
| Asahi Linux `asahi` | `77cb8f24c2381a8abb7272d7bbdec548d6426a8a` |
| Mainline Linux `master` | `fd179f8a05be3ccae366b9b96e176b51fbe54aab` |

Pinned references:

- [m1n1 source](https://github.com/AsahiLinux/m1n1/tree/4184923ffb2dff079b384d6a32cc02142aa14572/src)
- [U-Boot source](https://github.com/AsahiLinux/u-boot/tree/ec49c9d70e6ab003813d6f475fec62dc1c0f4bfe)
- [Asahi T6032 DTS](https://github.com/AsahiLinux/linux/blob/77cb8f24c2381a8abb7272d7bbdec548d6426a8a/arch/arm64/boot/dts/apple/t6032.dtsi)
- [Mainline T6032 DTS](https://github.com/torvalds/linux/blob/fd179f8a05be3ccae366b9b96e176b51fbe54aab/arch/arm64/boot/dts/apple/t6032.dtsi)
- [Asahi J575d board DTS](https://github.com/AsahiLinux/linux/blob/77cb8f24c2381a8abb7272d7bbdec548d6426a8a/arch/arm64/boot/dts/apple/t6032-j575d.dts)

## What is present, and what remains a gate

The [official M3 status table](https://asahilinux.org/docs/platform/feature-support/m3/)
is a useful high-level guide, not proof that this board boots. It labels
several Ultra blocks `linux-asahi`, including AIC, UART, DART and PCIe, while
USB and NVMe remain `TBA`. USB-PD is `WIP`, not completed. The Studio installer
cell is `-`; that does not establish a supported installation path.

| Boot-path block | Source observation | Required next work |
| --- | --- | --- |
| SoC identity / early console | m1n1 `soc.h` has no T6032 target definition | Target-definition and console-path audit; UART address alone is not full board enablement |
| 32-CPU / two-die representation | m1n1 `smp.h` still has `MAX_CPUS 24` | Audit every bound, mask, allocation and kboot CPU-node path before changing capacity |
| Secondary CPU release | T6032 startup remains a roadmap gap | Confirm the CPU-start register contract; do not infer it solely from T6031 compatibility |
| MCC / cache initialization | m1n1 M3 parser still starts register instances at index 3 | First local work item: geometry regression for Ultra's four-header layout, then a separately reviewed fail-closed implementation design |
| Early CPU frequency setup | m1n1 `cpufreq.c` has no T6032 dispatch | Validate six-cluster register semantics before adding writes or copying a Max table |
| Kernel topology / interrupt / console | T6032/J575d CPU, AIC, PMGR, UART and watchdog descriptions exist | Compile and validate the exact handoff DT; a present node is not a hardware test |
| CPU performance metadata | Asahi `asahi` supplies OPP/capacity/performance domains for the inherited die-0 CPUs but omits them on T6032's added die-1 CPUs; mainline lacks this metadata on both sets | Keep the downstream die-1 completion distinct from mainline's broader missing DVFS integration; not the first console-boot gate |
| NVMe | Inspected Asahi T6032 DTS includes the NVMe fragment on die 1; inspected mainline T6032 DTS does not | Reconcile implementation, bootloader and hardware validation; do not call it working because a node exists or absent merely because the table says TBA |
| USB / Ethernet | No enabled USB or Ethernet description found in the inspected T6032/J575d composition | Later peripheral work; neither is required for a RAM-only diagnostic shell |
| U-Boot | No bundled T6032/J575d board DTS found in the inspected release branch | Audit generic Apple support with the m1n1-supplied DT; missing bundled DTS alone does not prove a new board port is required |

We are not starting a new generic CPU driver. First establish the bootloader
and kernel handoff prerequisites. USB/internal-storage selection is downstream
of reaching a diagnostic Linux shell from RAM.

## First implementation: an offline MCC geometry audit

`scripts/audit-t6032-mcc.py` is local diagnostic tooling, not an m1n1 driver
patch. It accepts an IODeviceTree plist offline or, only with `--live`, runs
the fixed read-only `ioreg` query. The raw tree stays in memory during live
collection; output is restricted to allowlisted identity and geometry fields.

The observed T6032 `mcc,t6031` node has four planes, four DCS channels and
20 register entries. Entries 0–3 are smaller blocks, followed by sixteen
32 MiB windows at indices 4–19. In contrast, the pinned m1n1 M3 algorithm
starts at 3 and caps the count at 16: it selects 3–18, includes a 16 KiB
block and omits entry 19. Its later plane offsets exceed that small block.

The audit checks identity, encodings, counts, window sizes and range validity;
unexpected input is an error rather than permission to guess a register map.
It reports indices 4–19 as geometry-derived candidates only. It does not
prove register semantics, translate raw ADT addresses into MMIO targets,
enable caches, or make the existing m1n1 path safe to run.

Run the synthetic tests and an optional live inventory:

```sh
uv run --no-project --python 3.13 scripts/test-t6032-mcc.py
uv run --no-project --python 3.13 scripts/audit-t6032-mcc.py --live
```

The T6031 regression capture required before changing the shared driver is
still missing. Synthetic T6032 fixtures cannot substitute for it. The
unknown CPU-start offset and six-cluster initialization semantics also remain
unresolved. Do not enable native kboot merely because this audit passes.

Validation on 2026-09-26: all 15 synthetic tests pass. An explicit live run
on this M3 Ultra, macOS 27.0 build 26A428, exits 0 with the expected layout.
The [sanitized JSON result](inventory/t6032-mcc-2026-09-26.json) contains no
serial numbers, UUIDs or register addresses. The independent review found
the original arbitrary-dictionary search and XML shape handling inadequate;
the final collector follows the exact registry node hierarchy, with negative
fixtures for those failures. No driver correction or hardware validation is
claimed. Offline input reads are capped before parsing; the fixed live
`ioreg` command is time-limited and its captured output size is checked
before parsing.

The live XML collector needs `ioreg -a -l -p IODeviceTree`: without `-l`,
the archive omits the properties needed for identity and register decoding.
On this macOS 27 host the archive has a `Root` wrapper, a `device-tree`
child, and nested single-entry lists in `IODeviceMemory`. Synthetic tests
must represent these shapes, not only a flattened invented tree. The
read-only byte-order cross-check observed first size bytes
`0000020000000000`, decoding to `0x20000` little-endian, and all 20 decoded
sizes agree with the registry's translated-window sizes.
The pinned [m1n1 ADT decoder](https://github.com/AsahiLinux/m1n1/blob/4184923ffb2dff079b384d6a32cc02142aa14572/rust/src/adt.rs)
also corroborates this: it assembles low cells first, uses little-endian
byte conversion, and the build is little-endian AArch64. This is Apple ADT
encoding, not the big-endian cell encoding of a standard flattened Linux DT.

## 32-CPU / two-die preparation

The pinned m1n1 source has a global `MAX_CPUS=24`. Its ADT CPU `reg`
decoder already separates core bits `[7:0]`, cluster bits `[10:8]` and die
bits `[14:11]`; representing a second die does not require widening those
fields. These are ADT fields, not proof of architectural MPIDR values.

The source audit also found two upper-bound checks using `cpu > MAX_CPUS`
where `cpu >= MAX_CPUS` is required: `dt_set_cpus()` in `src/kboot.c`
can overrun its pruned-phandle array, and `hv_switch_cpu()` in `src/hv.c`
can read beyond `hv_started_cpus`. The local patch and source-derived
regression tests are described in [the CPU work notes](m1n1-t6032-cpus.md).

The ordinary secondary stacks, spin table and CPU-node arrays scale with
`MAX_CPUS`. The 64-bit hypervisor guest mask and 32-bit AIC IPI CPU field
can represent indices through 31. This is a capacity audit, not evidence
that interrupts or secondary CPU release work on T6032.

The separate `MAX_EL3_CPUS=4` allocation and startup gate stay unchanged.
Raising the ordinary capacity does not bypass that gate. T6032 CPU-start
selection, the actual execution-level contract, MCC initialization and
six-cluster frequency setup remain unresolved hardware-test prerequisites.

The [offline firmware build](m1n1-cpu-offline-build.md) now passes for both
the pinned baseline and capacity-patched default configuration, with the
same compiler warnings. Dependencies were staged under project scratch;
no host toolchain installation or target execution was performed.
The full `dt_set_cpus()` host harness also passes seven scenarios with real
libfdt and mocked SMP state. Its pre-existing successful CPU-map allocation
leak is fixed in a separate local `0002` patch, with zero outstanding tracked
allocations on success/error paths and an original-leak negative control.
The two-patch firmware build also passes. Four host-mocked handoff cases
using the actual pinned J575d DT pass, including CPU-24 and whole-cluster
pruning. Its six-cluster CPU ordering agrees with the saved live inventory;
this does not validate hardware CPU startup or AIC operation.

The subsequent [startup-contract audit](m1n1-t6032-startup.md) confirms that
generic ADT chip identification is distinct from missing T6032 startup
dispatch. The pinned secondary-start function returns on unknown chip IDs;
that return does not propagate an error to the overall boot path. Existing
RVBAR mismatch, allocation-failure and timeout handling need hardening.
Neither the T6032 start-register contract nor native execution-level behavior
is established; the four-CPU EL3 gate remains unchanged.

## Development-host split

Adam plans to move most project work to the MacBook to free Studio storage
for eventual Linux use. Keep offline audits and tests portable; the MacBook
can be the development/control host while the Studio supplies T6032-specific
captures and, after the safety gates, native test results. M5 Max results
still cannot substitute for M3 Ultra evidence. No project copying/deletion
or macOS removal is authorized by this plan.

## Next bounded milestones

1. Reproduce the MCC selection mismatch with sanitized live evidence and
   negative fixtures; preserve explicit `hardware_validated=false`.
2. Capacity patch, inventory tests, full offline builds, synthetic and
   exact-board handoff tests, and allocation cleanup are complete.
   None of these are native CPU-release evidence.
3. Obtain a reference T6031 MCC layout and review a bounded, fail-closed
   register-selection design without executing register writes.
4. Confirm startup and early frequency-control contracts from appropriately
   sourced evidence; then build diagnostic payloads offline.
5. Before any target execution, verify recovery equipment and procedure,
   console/proxy access and the supported boot-entry path. A MacBook's
   existence alone is not a tested recovery plan. Start with RAM-only tests;
   do not repartition or enable the public installer as a shortcut.

## Contribution provenance

This AI-assisted work targets Debian and our project forks. Adam has ruled
out submissions to Asahi while its policy remains unchanged. Preserve
provenance and check each receiving project's requirements before submission;
Asahi's policy is not a blocker for this local development work. No external
submission is authorized by the roadmap.

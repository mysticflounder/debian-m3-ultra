# T6032 CPU-release / early-DVFS evidence search

Public-source research captured on 2026-09-27; not a fresh upstream check.
No native execution, register probing, boot-policy, firmware, disk or VM
changes. The search began against the fourteen-patch series; subsequent
[SMP shared-memory work](m1n1-smp-shared.md) is now complete offline.
See [project status](project-status.md) for the current build and next work.
None of this enables T6032 dispatch.

## Bounded public-source check

The [public m1n1 CPU-start switch](https://raw.githubusercontent.com/AsahiLinux/m1n1/main/src/smp.c)
observed today selects the T6031 offset family for several nearby chips but
has no T6032 case. Its default reports an unknown offset and returns.
That is evidence of a missing dispatch case, not evidence that copying the
T6031 offset is correct. The source's conditional RVBAR write does not
establish target-specific inherited reset state.

The [public m1n1 cluster dispatch](https://raw.githubusercontent.com/AsahiLinux/m1n1/main/src/cpufreq.c)
observed today returns a three-cluster table for T6031/T6034 but has no
T6032 case. Its unsupported default returns NULL. This does not establish
six-cluster routing, safe raw default/APSC indices or an early-boot sequence.

These are mutable branch observations, not a newly pinned source baseline.
The project continues to build its recorded pin plus local patches. Two
separate bounded primary-source searches found no target-matched CPU-release
or six-cluster boot-initialization proof. This is not an exhaustive claim
that no such source or working native implementation exists.

The [official M3 feature table](https://asahilinux.org/docs/platform/feature-support/m3/)
still labels Ultra cpufreq `linux-asahi`, while Ultra NVMe/USB remain `TBA`
and the Studio installer cell is `-`. Linux driver status does not establish
m1n1's early initialization contract or all-six-cluster runtime validation.
Source presence, table labels and native boot evidence must remain separate.

## Focused independent consult

Pro request `01M3HYKV2MJ5THADJNPEB2G38M` completed in `#debian-m3` and
was reviewed on 2026-09-27.
The local prompt is `scratch/mcc-evidence/cpu-dvfs-pro-question.md`.
It asks specifically for T6032 CPU-release offset/RVBAR/ordering evidence,
safe six-cluster early DVFS initialization, and any target-matched basis for
preserving inherited frequency state during a RAM-only diagnostic boot.
The earlier completed MCC consult is not being repeated.

The full response is retained locally at
`scratch/mcc-evidence/cpu-dvfs-pro-response.md`. Independent source checks
confirmed the central findings below; the response is not hardware evidence.

At pinned m1n1 revision
[`06088c7c90ed3db790a791b5ec079a921e8e4af2`](https://github.com/AsahiLinux/m1n1/tree/06088c7c90ed3db790a791b5ec079a921e8e4af2),
`src/smp.c` still lacks T6032 startup dispatch. `src/cpufreq.c` lacks T6032
cluster/feature dispatch and p-state decoding/writing support. Its M3 Max
table has three clusters, not an established six-cluster Ultra path.
The [T6032 Linux device tree](https://github.com/torvalds/linux/blob/67d9574cf8ed1c81c472b932a9d9819f47fb5286/arch/arm64/boot/dts/apple/t6032.dtsi)
leaves die-1 CPU release addresses for the loader to populate. The
[M3 PMP proposal](https://github.com/AsahiLinux/linux/pull/525) explicitly
reports testing only T6034. None supplies a verified T6032 early-boot recipe.

## Completed compatibility experiment: SMP shared memory

Sven Peter's
[`f7124b8d42bcdd44131b4a455ad32e2f98fde166`](https://github.com/AsahiLinux/m1n1/commit/f7124b8d42bcdd44131b4a455ad32e2f98fde166)
adds a 64-KiB-aligned `.data.smp_shared` section and maps it Device-nGnRnE
through the identity mapping and three aliases. It moves CPU-startup shared
state into that section and removes corresponding cache-maintenance calls.
Independent source review confirmed these changes, but no T6032 dispatch or
native Ultra execution evidence. A subsequent
[opt-in backport experiment](m1n1-smp-shared-experiment.md) now cross-builds
against our pinned fourteen-patch tree. It adds local pointer-table and
linker-alignment adaptations. That historical experiment has been superseded
by the [default backport plus mapping/startup guards](m1n1-smp-shared.md).

The original experiment tests compatibility in an isolated scratch source tree against our pinned
baseline plus patches 0001 through 0014. Check prerequisites and conflicts
explicitly rather than assuming the newer commit applies alone. Verify:

- Linker alignment and inclusion of the section within the image boundaries.
- All four mappings retain patch 0010's protected-range checks, including
  rejection of overlaps in synthetic tests; static layout checks do not
  establish the Studio's actual carveout contents.
- Patch 0014's inherited-MMU rejection and initialization ordering remain intact.
- MMU-off secondary accesses and the removed cache operations are accounted
  for in the source audit; passing mocked tests does not prove hardware ordering.
- Existing host regression suites and the cross-build still pass.

Keep native dispatch disabled. This experiment is preparation, not a reason
to replace the current source pin or weaken failure handling automatically.

## Remaining evidence and safety gates

The bounded public search did not establish a complete target-matched CPU
release or six-cluster early-DVFS contract. Existing local mask and runtime
routing evidence remains useful, but is not independently proven boot-entry
behavior. Skipping DVFS writes alone does not establish that inherited power
and frequency state is safe across the rest of initialization.

The most useful additional artifact would be a revision-pinned, known-working
J575d bootloader plus an existing native boot log and firmware identity,
with CPU-release/reset ordering and six-cluster controller/table/initial-state
annotations. Partial evidence closes only the corresponding questions.
No maintainer contact or upstream submission has been made.

Adam confirmed on 2026-09-27 that the Studio has no current backup. Native
tests, firmware/boot-policy changes and partitioning remain gated on a verified
backup, recovery readiness and separate explicit authorization. These practical
prerequisites do not by themselves establish register safety.

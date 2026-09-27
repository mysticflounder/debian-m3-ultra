# T6032 CPU-release / early-DVFS evidence search

2026-09-27. Research only. No native execution, register probing, boot-policy,
firmware, disk or VM changes. Local implementation remains at the
fourteen-patch offline-tested series; this search does not enable dispatch.

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

Pro request `01M3HYKV2MJ5THADJNPEB2G38M` was queued in `#debian-m3`.
The local prompt is `scratch/mcc-evidence/cpu-dvfs-pro-question.md`.
It asks specifically for T6032 CPU-release offset/RVBAR/ordering evidence,
safe six-cluster early DVFS initialization, and any target-matched basis for
preserving inherited frequency state during a RAM-only diagnostic boot.
The earlier completed MCC consult is not being repeated.

The first bounded wait returned no response; a quiet timeout is not failure
or completion. Resume with `nthdegree consult wait` for this same request.
Any returned claims require independent source verification before changes.

If no evidence is found, the next external request should seek a known-working
J575d boot implementation or a target-specific register/entry contract from
a knowledgeable developer, not permission to guess values on the Studio.
No maintainer contact or upstream submission has been made. Recovery/backup
readiness remains a separate prerequisite and cannot prove register safety.

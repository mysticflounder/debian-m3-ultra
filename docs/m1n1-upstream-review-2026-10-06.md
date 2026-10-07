# m1n1 upstream review — 2026-10-06

Read-only review of official upstream sources. The local build remains pinned
to `4184923ffb2dff079b384d6a32cc02142aa14572`; no source upgrade, firmware
execution, VM change or upstream submission was performed.

GitHub's API resolved `main` to
[`2460b604c6f016956ead711823605eea840c602e`](https://github.com/AsahiLinux/m1n1/commit/2460b604c6f016956ead711823605eea840c602e),
with committer timestamp `2026-10-06T06:49:16Z`. The
[pinned-to-current comparison](https://github.com/AsahiLinux/m1n1/compare/4184923ffb2dff079b384d6a32cc02142aa14572...2460b604c6f016956ead711823605eea840c602e)
contains 44 commits ahead, zero behind.

## Changes that affect our next work

| Upstream change | Relationship to our work |
| --- | --- |
| [T6032/M3 Ultra support](https://github.com/AsahiLinux/m1n1/commit/1a0e368532b63c3b22b91325e231842146b35203), committed September 29 | Raises `MAX_CPUS` to 32 and adds two-die cpufreq/MCC/SMP offsets and early UART. Compare with local capacity, topology and initialization patches rather than continuing from an outdated support assumption. |
| [HV CPU-start offset](https://github.com/AsahiLinux/m1n1/commit/647ae30533bcbb457fe544ab6a8d64f77b90ce1f) | Adds the corresponding T6032 HV startup case; reconcile with our guarded CPU-index paths. |
| [Cache startup ADT data](https://github.com/AsahiLinux/m1n1/commit/7ec85ae4242af6eba41180f6194b88ccb9ff2a5d), [static stacks](https://github.com/AsahiLinux/m1n1/commit/e327b97f4ab9c8da27a1fac703dcc14fd0562653), [MPIDR recovery](https://github.com/AsahiLinux/m1n1/commit/1b469fcb618f1bb125b8566c28ec8cd2fc0cba9c) | Change startup/reset assumptions and overlap the SMP work; retain our safety checks only after checking their new call sites. |
| [Shared-state Device mapping](https://github.com/AsahiLinux/m1n1/commit/d16a2f4e3c4d2753c38ef1bb3f756add5822ee15) | Upstream counterpart of the earlier shared-memory backport. Do not apply duplicate patches; rerun linked-layout and guard regressions on the new baseline. |
| [ADT first-child error handling](https://github.com/AsahiLinux/m1n1/commit/4e06076e390f005f8368b272c445b932c4aa2d28) | Removes one panic. The current ADT diff otherwise only changes its license header: our copy-before-validation and payload-view/template-flag fixes are not superseded. |

HV source files moved under `src/hv/`, with additional CPU-state and trap
changes. Applying the existing 21-patch series unchanged is not a safe upgrade
strategy. The next task is a patch-by-patch disposition matrix: already
upstream, still needed, or requiring adaptation. Preserve the current pinned
build as a comparison baseline and test a separate offline candidate.

Follow-up: the [21-patch reconciliation](m1n1-upstream-reconciliation-2026-10-06.md)
is complete; the subsequent SMP/MCC/mapping/DVFS adaptation also accounts for
every retained original guard. The 21-patch comparison build and linked-layout
audit pass. Raw DVFS states, physical-input bounds and hardware qualification
remain separate gates; no comparison artifact is boot-approved.

Upstream also changed its license declarations. The
[current README/license clarification](https://github.com/AsahiLinux/m1n1/commit/2460b604c6f016956ead711823605eea840c602e)
distinguishes MIT releases through 1.9.9 from GPL-2.0-or-later code starting
with 2.0.0. Any new baseline must preserve applicable notices and provenance;
this review does not change the local source license or provide legal advice.

## Source support is not a boot qualification

The official [M3 feature-support page](https://asahilinux.org/docs/platform/feature-support/m3/)
lists J575d/T6032, but still marks the M3 Ultra Studio installer as unavailable.
Its SoC feature table has entries for basic blocks while GPU/display, USB3,
Thunderbolt and NVMe remain WIP/TBA. These upstream statuses do not prove that
our board, Debian image, firmware sequence or recovery path has been validated.
Native CPU/DVFS dispatch remains disabled; backup, recovery readiness and
separate native-test approval remain gates.

Captured API responses, pinned/current raw files, targeted diffs and hashes are
retained under `scratch/upstream-review-2026-10-06/`. The tracked
[review inventory](inventory/m1n1-upstream-review-2026-10-06.json) records their
identity. This is an m1n1 and M3 platform-status review, not a fresh QEMU PR or
complete Linux commit audit.

## Freshness follow-up — 2026-10-07 UTC

The requested read-only refresh again resolves m1n1 `main` to `2460b604`.
The [reviewed-to-main comparison](https://github.com/AsahiLinux/m1n1/compare/2460b604c6f016956ead711823605eea840c602e...main)
is identical; the strict post-commit query is empty. No new default-branch
change supersedes our SMP, MCC, DVFS, AIC or ADT guards. This does not audit
every unmerged branch or submission. The default pin remains unchanged.

The broader refresh confirms that official Linux `v7.3-rc6` and `master`
contain `t6032.dtsi` and `t6032-j575d.dts` from the
[T6032 device-tree commit](https://github.com/torvalds/linux/commit/67d9574cf8ed1c81c472b932a9d9819f47fb5286)
and the [T603x binding commit](https://github.com/torvalds/linux/commit/7a867322cd14ec54783fb2fdc3ce875c89ba3b16).
These landed on August 1; they are confirmed source availability, not a new
post-review merge or evidence of a native Debian boot. Use these official
files as comparison inputs for the later kernel/board-DT integration task.
The installer remains unavailable in the upstream M3 support table.

QEMU `master` at `3377670ee96b5a68361016680a95b9013709d4b7` and `v11.1.2`
still lack our PMINTENCLR, PSCI and guarded SDK27 feature-import changes in
[`target/arm/hvf/hvf.c`](https://gitlab.com/qemu-project/qemu/-/blob/3377670ee96b5a68361016680a95b9013709d4b7/target/arm/hvf/hvf.c).
The three fork candidates remain pending review. Public pending-MR lookup
was denied, so absence from all unmerged work is not established. Refresh
the patch base and qualify a replacement binary before promotion; do not
replace the working VM's QEMU as part of this read-only check.

Evidence: `scratch/upstream-freshness-m1n1-2026-10-07.md`,
`scratch/upstream-freshness-m1n1/`,
`scratch/upstream-freshness-kernel-qemu-2026-10-07.md` and
`scratch/upstream-freshness-kernel-qemu/`. No source upgrade, fetch/merge,
external submission, native execution, VM or disk change was performed.

### Second freshness check — 2026-10-07 UTC

Fresh official API reads again resolve m1n1 `main` to `2460b604` and Linux
`master` to `602042bf29f6efde39cfb5fdd9289bf4854bc0c5`. The m1n1
[HV AIC trace source](https://github.com/AsahiLinux/m1n1/blob/2460b604c6f016956ead711823605eea840c602e/src/hv/hv_aic.c)
still contains the NULL/divisor, die-partition and bitmap-bound defects;
comparison-only patch 0028 remains needed. Linux's unchanged head does not
qualify native boot or replace the kernel/board integration work.

The initial QEMU refresh returned conflicting refs from the
[official GitHub mirror ref](https://api.github.com/repos/qemu/qemu/git/ref/heads/master)
and the
[GitLab branch API](https://gitlab.com/api/v4/projects/qemu-project%2Fqemu/repository/branches/master)
(`f9587d4045c67cd0d8d8bdcd5d0bb5b6b395b63c` versus `d7a65d1793...`).
Later exact retained responses resolve **both** refs to `f9587d4045c67cd0d8d8bdcd5d0bb5b6b395b63c`,
superseding the earlier `3377670e...` default-branch freshness assertion.
Its [commit-qualified HVF source](https://github.com/qemu/qemu/blob/f9587d4045c67cd0d8d8bdcd5d0bb5b6b395b63c/target/arm/hvf/hvf.c)
still lacks our PMINTENCLR, PSCI and SDK27 candidate changes. This is source
evidence, not an exhaustive pending-series audit or ancestry comparison.
Neither response changes the project pin or working VM; rebase and replacement
qualification remain separate tasks.

Exact API bodies/headers are retained as `scratch/upstream-hv-ref-*-2026-10-07.*`,
with raw source in `scratch/upstream-hv-aic-main-raw-2026-10-07.c` and
`scratch/upstream-hv-qemu-hvf-f9587d-2026-10-07.c`. The bounded report is
`scratch/upstream-refresh-2026-10-07-followup.md`; its earlier hand-authored
summaries are not primary full-response evidence. The HV trace inventory
records the retained identities. No fetch, pin update or submission occurred.

### DVFS freshness recheck — 2026-10-07 08:54 UTC

The additional requested check retains four new HTTP-200 API bodies and
headers. m1n1 remains `2460b604c6f016956ead711823605eea840c602e`, Linux remains
`602042bf29f6efde39cfb5fdd9289bf4854bc0c5`, and both QEMU remotes remain
`f9587d4045c67cd0d8d8bdcd5d0bb5b6b395b63c`. Each body is byte-identical to
the preceding exact capture. This ref-only check found no newer default-branch
change to reconcile; it does not inspect unmerged work. The earlier raw-source
checks remain applicable at those unchanged commits.

Evidence: `scratch/upstream-dvfs-refresh-2026-10-07.md` and the paired
`scratch/upstream-dvfs-ref-*-2026-10-07.{json,headers}` responses. Pins, working
VMs and submission status remain unchanged.

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

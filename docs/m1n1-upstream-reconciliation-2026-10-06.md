# m1n1 upstream reconciliation — 2026-10-06

The [upstream review](m1n1-upstream-review-2026-10-06.md) identified new T6032
support at `2460b604c6f016956ead711823605eea840c602e`. This follow-up compares
all 21 local patches against that exact source revision. The current default
build remains pinned to `4184923ffb2dff079b384d6a32cc02142aa14572`.

This is Debian/project-fork work. No Asahi submission, source-pin replacement,
firmware installation, MMIO probe, native execution, VM or disk change occurred.
Upstream comparison artifacts contain upstream's T6032 dispatch and are
**not approved for booting**. They do not include all our startup/MCC guards.

## Patch disposition

“Drop” means redundant on this reviewed revision, not deletion from the old
pinned series. “Retain/adapt” means preserve the invariant while reconciling
new data structures, call sites or patch dependencies—not force old hunks.

| Patch | Disposition on reviewed upstream | Reason / required adaptation |
| --- | --- | --- |
| 0001 CPU capacity/bounds | Split/adapt | Capacity is already 32. Retain half-open bounds checks in `kboot.c` and moved `src/hv/hv.c`. |
| 0002 pruned CPU cleanup | Drop | Both normal completion and no-CPU-map return now free the list. |
| 0003 startup prerequisites | Split/adapt | Heap-stack allocation guards are obsolete with static stacks. Retain the stop on locked/mismatched RVBAR. |
| 0004 startup timeout | Retain/adapt | Upstream still continues after timeout; adapt non-returning containment to the new startup function. |
| 0005 T6032 masks | Retain/adapt | Die offset and dispatch are upstream, but generic four-core mask spacing does not implement the metadata-validated 4/6/6 layout. Use cached `cpu_info` coordinates. |
| 0006 CPU inventory | Retain/adapt | Complete 32-node identity/topology preflight is absent. Move validation to cached-data initialization before any release. |
| 0007 startup failure propagation | Retain/adapt | Void/best-effort paths remain. Adapt status propagation and callers, including moved HV files. |
| 0008 MCC layout | Retain/adapt | Upstream uses the matching fourth-record offset, but lacks header/window/overlap validation. Avoid competing initializers. |
| 0009 carveout preflight | Retain/adapt | Generic controller-0 removal is still unguarded. Preserve staged alias removal, protected extents and failure propagation. |
| 0010 runtime mapping guards | Retain/adapt | Published carveout exclusions and lifecycle checks are absent. Preserve checks at current mapping entry points. |
| 0011 cpufreq failure propagation | Retain/adapt | Six-cluster source support exists; the payload caller still ignores failure. Its patch context depends on 0007's rebased startup status. |
| 0012 TZ origin decoding | Retain after 0009 adaptation | The specialized fixed-origin decoder is absent; do not transplant it into generic legacy-SoC behavior. |
| 0013 TZ plane consistency | Retain after MCC adaptation | Upstream still samples one controller/plane; preserve the all-64-context comparison before publishing carveouts. |
| 0014 inherited-MMU guard | Retain after mapping adaptation | Inherited `SCTLR.M` still bypasses initialization. Retain lifecycle-marker rejection. |
| 0015 SMP shared-memory backport | Drop | Shared placement/Device mappings are upstream; static stacks supersede pointer-table hunks. Verify new linked layout rather than transplanting the old profile. |
| 0016 shared mapping guards | Retain/adapt | Upstream constructs Device mappings but lacks our mapping/removal/readiness guards. |
| 0017 SMP index guards | Retain/adapt | Negative direct indices and raw proxy narrowing remain unchecked; re-audit new helpers. |
| 0018 MMU/HV index guards | Retain/adapt | Validation remains absent; adapt relocated HV files and preserve sentinel semantics. |
| 0019 AIC metadata | Retain; license-context adaptation | Source body is unchanged. Only the patch context's upstream SPDX declaration differs. |
| 0020 ADT copy guard | Retain unchanged | Applies at zero fuzz; upstream has no equivalent. |
| 0021 ADT payload view/template flag | Retain unchanged, after 0020 | Applies at zero fuzz; upstream child-error handling does not repair payload lengths. |

The detailed independent reports are retained in
`scratch/upstream-reconcile-smp.md`, `scratch/upstream-reconcile-mcc-dvfs.md`
and `scratch/upstream-reconcile-adt-aic/reports/adt-aic-disposition.md`.
The [inventory](inventory/m1n1-upstream-reconciliation-2026-10-06.json) records
source identities, reports, build and regression evidence.

## Separate comparison builds

The new [build recipe](../scripts/build-m1n1-upstream-offline.sh) pins the
reviewed source archive and reuses prepared project-local tools. Cargo runs
offline and locked. Each build gets a fresh retained scratch tree; the old
source archive and default 21-patch recipe are unchanged.
The archive and extracted canonical source must already exist under
`scratch/m1n1-upstream-audit/`, alongside the previously prepared build tools.
The immutable [source archive](https://codeload.github.com/AsahiLinux/m1n1/tar.gz/2460b604c6f016956ead711823605eea840c602e)
has SHA-256 `aa0ffbeb7ae9cc0eb7a5653f44474e26f826809cf7f0564f8deb395d25203b01`.

```sh
bash scripts/build-m1n1-upstream-offline.sh baseline
bash scripts/build-m1n1-upstream-offline.sh input-guards
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 python scripts/test-m1n1-upstream-input-guards.py
```

`baseline` is unmodified reviewed upstream. `input-guards` applies only
adapted 0019 and unchanged 0020–0021, in that order. The optional `adt` mode
applies only 0020–0021. None is a full guarded native candidate. The adapted
AIC patch preserves upstream's GPL declaration; the old MIT-context patch
remains unchanged for the old source pin.

The host wrapper reuses all three existing AIC/ADT regression runners,
including archive/source hash checks, zero-fuzz materializers, baselines and
original/mutation controls. Only source identities and the AIC patch path
change. These are synthetic host tests, not physical register tests.

The unmodified baseline and three-input-guard firmware builds both pass.
Both builds emit the same six upstream C warnings: one flexible-union field
warning and five unnamed-parameter/C23-extension warnings.
The upstream AIC/ADT regressions also pass all original and mutation controls.
Shared-layout auditing uses a separate explicit upstream profile: the eight
shared objects include the new reset-stack table, while static stack arrays
live in `.bss`. The old nine-object pinned profile remains the default.
Neither profile qualifies reset-time hardware or CPU execution.
Both reviewed builds pass the explicit upstream profile; the old full21 build
passes the unchanged default profile. Wrong-profile and altered source
alignment/dimension controls fail closed. The upstream CLI requires
`--profile reviewed-upstream-2460b604c6f016956ead711823605eea840c602e`
and `--source-tree` pointing to the recorded canonical tree.
The upstream profile requires the canonical source tree to derive/check its
layout. The profile name is not provenance verification; the inventory also
records source hashes and their archive identity.

Prepared toolchains and extracted sysroots remain trusted local inputs, as
in the original recipe. This is not a hermetic or cross-host bit-reproducibility
claim. Preserve the upstream license notices and existing Debian provenance.

## Next implementation order

1. Rebase the retained SMP protections onto cached CPU records and static
   stacks: half-open bounds, RVBAR stop, timeout containment, metadata-validated masks,
   complete inventory, status propagation and direct/proxy index checks.
2. Rebase mapping/readiness and MCC/carveout guards, preserving the exact
   record offset, origin decoder, all-plane checks and MMU lifecycle.
3. Retain cpufreq failure propagation while reviewing the new cluster/voltage
   paths against the unresolved early-state contract.
4. Assemble a fully guarded offline candidate and rerun dependency-specific
   host regressions, complete cross-builds and linked-layout audits.
5. Resolve remaining ADT physical bounds, AIC aperture/stride and whole-boot
   failure propagation. Reconcile current kernel/board support for boot and I/O.
6. Only after a verified backup, recovery readiness and separate native-test
   approval: qualify cold entry, RVBAR/release, MCC/cache/DVFS and UART/AIC/DART,
   then a RAM-only kernel boot and persistent storage/network bring-up.

The full M3 Ultra SoC objective is not complete. New source support replaces
some implementation work; it does not prove register access, cache effects,
safe early DVFS states, recovery or a working native Debian boot.

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

## Startup/index adaptation follow-up

The startup/index adaptation is now implemented in the reviewed comparison
series: 0001, 0003–0007 and 0017–0018. The original pinned patches remain
unchanged. New comparison-only 0022 contains additional stop/reset transitions.

T6032 preflight now accepts the cached CPU/node arrays only after every one
of the 32 records passes; it skips the legacy scalar/fallback parser afterward.
This is all-or-nothing validation, not concurrent atomic publication. Start
and stop both use the captured mode-1 4/6/6 layout and packed shifts 0/4/10.
Status propagation follows the current payload, proxy and relocated HV paths.

0022 makes a T6032 normal-stop timeout non-returning without clearing or
reusing published state. Reset entry checks its index before array access and
rejects an unknown MPIDR that would overwrite an already registered T6032
fallback slot. First registration into the upstream `~0ULL` sentinel slot
remains allowed; no ADT-to-MPIDR encoding is invented. Deep sleep's presumed
10 ms stop and the identity/entry sequence of an unregistered slot remain
native-unqualified. Panic containment is not proof that a late core stopped
or that hardware recovery works.

```sh
bash scripts/build-m1n1-upstream-offline.sh smp-guards
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 python scripts/test-m1n1-upstream-smp.py
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 python scripts/test-m1n1-upstream-hv-api-indices.py
```

`smp-guards` applies those nine startup/index/state patches plus 0019–0021
(twelve total). Its complete build and both ELF/Mach-O layout checks pass,
with the same six upstream C warnings. It does **not** include adapted MCC,
mapping/readiness or DVFS guards and is not a fully guarded or boot-approved
candidate. The current-source MMU/HV fixture and three safe raw-ingress/sentinel
mutation controls pass. The SMP host suite also passes with ASan/UBSan,
five function-scoped structural controls and seven executed, designated
failure controls. It extracts current init/start/stop/reset-entry helpers,
uses source constants and captured CPU affinities, and tests caller status
cutoffs. Its raw SMP proxy-index coverage is structural; the separately
executed MMU/HV ingress matrix is not a substitute for that matrix.
Six unchanged pinned-source SMP/cpufreq suites and the three upstream
AIC/ADT suites also pass. Evidence, patch/artifact identities and qualified
gaps are recorded in the
[SMP adaptation inventory](inventory/m1n1-upstream-smp-2026-10-06.json).

The mock stop-status getter initially returned the host RVBAR/vector value
for `impl_reg + 0x100`, causing a false timeout and an unexpected jump into
an expired test frame. Separate status behavior, an aligned vector fixture
and armed-panic checks resolve the harness defect with both sanitizers
enabled. Earlier diagnostic artifacts remain retained; no source/hardware
alignment defect or native failure is inferred from that mock error.

## Mapping/readiness and MCC adaptation follow-up

The reviewed comparison now also retains 0008–0010, 0012–0014 and 0016.
The original pinned patches and default source pin remain unchanged.

0008 combines the formerly overlapping MCC dispatch/invalidation hunks and
preserves current `mcc_init()` → `mmu_init()` → `aic_init()` → `smp_init()`
caller order. 0009 now removes T6032 carveouts **after**
`mmu_remap_smp_shared()`, the final current default-mapping stage. The fixed
TZ origin, 28-bit field checks, all-controller/plane consistency, staged
allocator/mapping effects and runtime mapping exclusions remain intact.
0014 retains the inherited-MMU rejection and local initialization latch.
0016 protects the four shared aliases and adapts readiness gates to the
cached-CPU startup API, after index validation and before release-side work.

```sh
bash scripts/build-m1n1-upstream-offline.sh memory-guards
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 python scripts/test-m1n1-upstream-memory-guards.py
```

The nineteen-patch comparison build passes with the same six upstream C
warnings. Both ELF layouts and Mach-O coverage pass; all nineteen patch and
four artifact hashes verify. Twelve relevant source files are byte-equal
between the host-fixture tree and the complete cross-build tree, despite
their disjoint input/state patch application order.

Five current-source fixtures pass with ASan/UBSan: MCC layout/cache helpers,
carveout preflight/plane consistency, runtime mappings, MMU entry/lifecycle
and shared-mapping guards. A bounded inherited-MMU guard mutation fails at
its designated assertion without sanitizer diagnostics. Source-scoped
caller/order checks and five unchanged pinned-source adjacent suites pass.
Independent review and a separate current-source rerun also pass. The
runner never calls the legacy extractor materializers; their unchanged C
fixtures are tied to the reviewed source constants. `.orig` offset backups
are normal patch artifacts; `.rej` files are rejected.

These fixture executions do not run the full startup/main path or physical
MMIO. Caller coupling and cached-SMP readiness placement are structural
checks; AIC/ADT patches are applied here but their behavior is covered by
the separate input suites, not these five fixtures. The existing raw SMP
proxy-ingress gap remains. No register scope/access safety, atomic TZ
snapshot, cache/DMA coherence, CPU reset/deep-sleep sequence, or native
recovery is established. The fixed decoder origin remains a traced software
assumption, not a hardware qualification.

Evidence is recorded in the
[memory adaptation inventory](inventory/m1n1-upstream-memory-2026-10-06.json).
Comparison artifacts contain upstream native dispatch and remain **not
boot-approved**. Cpufreq failure propagation (0011), early-DVFS contracts
and the remaining physical-input/whole-boot gates are not complete.

## DVFS adaptation follow-up — 2026-10-07

Adapted 0011 now checks the native payload's `cpufreq_init()` result and
stops T6032 before secondary startup on a negative result. Comparison-only
0023 stops the T6032 cluster loop at its first negative result, before any
later cluster is programmed. All other SoCs retain the best-effort loop and
aggregate status. The proxy's existing returned-status contract is unchanged.
Neither cutoff rolls back writes already performed on the failing or earlier
clusters, and neither establishes a degraded-state recovery path.

The reviewed source has six T6032 records with raw APSC index 1 and default
indices 5 for ECPU / 6 for PCPU, sharing the six `t6030_features` records.
Its local sequence is APSC request/poll, feature masks/APSC poll,
`base + 0x440f8 = 1`, then default request/poll. The records do not prove
safe initial states, direct-register access, per-complex feature policy,
voltage behavior, restore prerequisites or barriers. Already-desired states
currently bypass the busy poll; observing that branch in a mock does not
qualify completion when busy was already set.

```sh
bash scripts/build-m1n1-upstream-offline.sh cpufreq-guards
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 python scripts/test-m1n1-upstream-cpufreq.py
```

The complete adapted comparison stack has 21 patches: the 19 memory-stage
patches plus 0011 and 0023. It accounts for every retained original guard;
original 0002 and 0015 remain dropped only on the reviewed baseline because
upstream supplies those changes. New 0022 and 0023 add containment for the
current reset/stop and DVFS APIs. The full build and linked-layout audit pass
with the same six upstream warnings. This is the complete adaptation of the
existing guard series, not a fully qualified native candidate.

The final source-extracted DVFS fixture passes 48 cases with ASan/UBSan.
It checks the six cluster/feature records, enabled/disabled feature policies,
exact request/mask/restore/poll order and arguments, preserved unrelated
register bits, all 18 T6032 failure positions, legacy T6031 continuation and
the actual driver-to-payload-prefix cutoff. Removed cluster fail-fast,
payload cutoff and restore-write controls each fail at their designated
assertion without sanitizer diagnostics. Five MCC/MMU/shared-mapping fixtures
also pass on the complete 21-patch source. An independent rerun passes.
The two unchanged pinned-source cpufreq suites pass as adjacent regressions.

All 215 canonical files under `src/` and `rust/src/` are byte-equal between
the final host tree and cross-build tree, excluding normal `.orig` patch
backups. This covers the disjoint `0022`/input-patch ordering difference;
the complete patch inventories and artifact hashes verify. The
[DVFS adaptation inventory](inventory/m1n1-upstream-cpufreq-2026-10-07.json)
records retained inputs, outputs and remaining gates. The new runner applies
AIC/ADT guards but does not re-execute their behavior suites, and the raw SMP
proxy-ingress gap remains structural. The executed boot caller is its
extracted kernel-branch prefix, not the full native payload/main path.

## ADT declared-span follow-up — 2026-10-07

Comparison-only 0024 centralizes byte-range validation against global `adt`
and the handoff's `devtree_size`. It rejects negative C offsets, null or
misaligned bases, wrapping extents and out-of-range records before pointer
arithmetic or reference construction. Nodes require their complete eight-byte
header before count reads. Properties require their complete 36-byte header,
masked wire length and four-byte-padded payload before DST construction.
Checked offsets also cover mutable properties, child/sibling advances,
`reg`/`ranges` cells and C offset returns. The existing payload-size ceiling,
template flag and global `_dt`-ignored ABI are preserved.

The C next-property function still returns the current record's checked end,
which may be a node or one-past the tree. Empty `ranges` remains an identity
translation; nonempty short tuples are rejected. Register paths are scanned
at most eight entries. The C trace producer rejects eight nonzero components
before writing its output, reserving one slot for the required zero sentinel;
the Rust breadcrumb API is unchanged.

Comparison-only 0025 checks virtual subtraction, translation addition and
both virtual/physical span ends before publishing `adt` or walking `/cpus`.
Invalid arithmetic or a short/null/misaligned result takes the existing early
debug-marker-and-halt pattern. It makes no new `mem_size`/physical-window
assumption. These are checks of the **handoff-declared extent**, not proof of
the underlying physical allocation, mapping or native access contract.

The new `adt-bounds` comparison mode adds both patches after the complete
21-patch adapted stack. The default old pin and its dispatch-off policy
remain unchanged. Comparison artifacts still contain upstream native dispatch
and are not boot-approved. Physical mapping/allocation, `'static` lifetime and
mutable aliasing, caller-owned C strings/buffers, raw C `ADT_PROP` access and
resource-exhaustion policy remain separate gates.

```sh
bash scripts/build-m1n1-upstream-offline.sh adt-bounds
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 python scripts/test-m1n1-upstream-adt-bounds.py
```

The 23-patch build and both ELF/Mach-O shared-layout checks pass with the same
six upstream C warnings and no new warnings. The actual Rust module passes
exact/truncated spans, signed offsets, C wrappers, mutable rejection, bounded
paths and the captured 771-node/9,999-property J575d restore tree. Twelve
flagged/unflagged payload cases cover sizes 0/3/4/8/256/257, DST size, exact
copy/set behavior, rejected copy lengths and unchanged flags/canaries. Three
safe Rust guard mutations fail at designated assertions without panic. These
Rust binaries are not sanitizer-instrumented; this is not an aliasing proof.
The source-extracted C relocation helper passes fourteen cases and four safe
guard controls under ASan/UBSan. Early halt ordering is checked structurally,
not by running `_start_c` or a native boot.

An independent final rerun passes. The existing 48-case DVFS/payload-prefix
mock suite, three controls and five MCC/MMU fixtures also pass on the complete
23-patch source, through `scratch/upstream-adt-bounds-adjacents.py`. All 215
canonical C/Rust files match the build, primary host, reviewer and adjacent
trees. The [declared-span inventory](inventory/m1n1-upstream-adt-bounds-2026-10-07.json)
records final retained inputs, outputs and remaining gates.

## AIC aperture/stride follow-up — 2026-10-07 UTC

Comparison-only 0026 retains the first ADT `reg` size instead of discarding it.
It checks the nonzero, four-byte-aligned base and non-wrapping aperture before
any register read. Both capability words and the event/IACK word must fit
before the first AIC2/3 capability read. AIC1 keeps its fixed 0x8000 window
and checks that window before reading INFO.

After capability reads, the driver validates the supported capacity and the
first complete bank block, then checks the last indexed span for config,
software set/clear and mask set/clear. Strides remain independent: they need
not equal the fallback, but must be aligned, large enough for their own bank
when there are multiple dies, and fit the declared aperture. Multiplication
casts the die to u64 first. Signed software-IRQ ingress rejects negative,
out-of-die and out-of-local-IRQ inputs; raw writes and acknowledge reads are
also aperture-bounded. Public initialization clears a stale AIC on failure,
and AIC2's config fallback/AIC3's required config are reset on each call.

The bank-address formula is deliberately unchanged. `max_irq` must be positive,
at most 4096 and divisible by 32; `nr_irq` must not exceed it. A zero actual
IRQ count remains accepted at initialization. This is an explicit supported-
layout precondition, not a theorem that future hardware cannot have partial
banks. Both the reviewed m1n1 source and
[official Linux driver](https://github.com/torvalds/linux/blob/602042bf29f6efde39cfb5fdd9289bf4854bc0c5/drivers/irqchip/irq-apple-aic.c#L1022)
derive bitmap-bank addresses using `max_irq >> 5`; changing to a ceiling would
invent a different register layout without independent hardware evidence.
The raw `max_die` field remains informational. The separate HV event-hook
extent stays `event + 4`, rather than expanding to the full ADT aperture.

The allowlisted captured restore template supplies relative AIC base
0x92400000, size 0x1cc000 and the first arm-io translation to 0x292400000.
It supplies offsets 4/12, config 0x10000 and strides 0x4a00, but does **not**
contain `aic-iack-offset`. The separate September 30 live metadata supplies
IACK 0x40000. The
[official T6032-inherited die-zero DTS](https://github.com/torvalds/linux/blob/602042bf29f6efde39cfb5fdd9289bf4854bc0c5/arch/arm64/boot/dts/apple/t6031-die0.dtsi#L9)
independently describes core base 0x292400000/size 0x1cc000 and a separate event
entry at core + 0x40000. These are distinct sources, not a reconstructed final
handoff or captured capability-register values. They permit this arithmetic
layout; physical register access is still unvalidated.

The complete 24-patch comparison cross-build and shared-layout audit pass,
with the same six upstream C warnings and no additional warnings. Unchanged
ADT/relocation and 48-case DVFS/payload plus five MCC/MMU host fixtures pass on
the complete 24-patch tree. Their canonical source files match the build.
The new AIC1/2/3 host suite and independent terminal rerun pass seven fixture
groups with ASan/UBSan. Four source mutations must exit exactly 1 with their
designated diagnostic and no sanitizer/runtime error; generated sources,
production/host headers and compile/run logs are retained. The sparse MMIO
observer does not dereference fake addresses, including the large-stride
case. Actual register capabilities in the J575d-style fixture are synthetic.
The [AIC aperture inventory](inventory/m1n1-upstream-aic-aperture-2026-10-07.json)
records retained evidence and the limited validation scope. Explicit AIC3
capability/IACK aperture rejection is covered; independently testing short
AIC2 windows at each fixed capability offset remains a coverage extension.

Run the driver suite with:

```sh
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 python \
  scripts/test-m1n1-upstream-aic-aperture.py
bash scripts/build-m1n1-upstream-offline.sh aic-guards
```

This does not prove power state, physical mapping, cross-bank non-overlap,
HW_STATE-per-die placement, IRQ routing/target semantics or native boot.
At the 24-patch checkpoint, `main.c` ignores the void `aic_init()` result
and continues into `smp_init()`. Quiet no-op runtime
helpers are not a successful interrupt-controller initialization contract.
HV trace null/divisor/die/bitmap-index guards are separate follow-ups.
Default source pin/native dispatch remain unchanged; comparison
artifacts are not boot-approved. No physical MMIO, VM, disk or firmware changes.

## AIC startup failure cutoff — 2026-10-07 UTC

Comparison-only 0027 makes `aic_init()` return zero on initialization success
and negative with the public `aic` pointer cleared on every failure. The sole
caller, normal `m1n1_main()` startup, consumes the status immediately after
`mmu_init()` and before `smp_init()`, using the existing noreturn
`panic("AIC initialization failed!\n")` convention. Failed initialization
cannot enter SMP or subsequent payload/proxy/next-stage actions on this path.
Private aperture storage is not required to be zero on every failure exit;
the cleared public pointer prevents access to it.

The cutoff is shared by all normal AIC1/2/3 startup, not T6032-only. Those
paths share the unconditional initializer and downstream interrupt/IPI/HV
consumers; keeping failed initialization nonfatal on other SoCs would retain
the same invalid boot state. Valid legacy initialization remains unchanged,
and the existing explicit `BRINGUP` bypass is unchanged. There is no other
C initializer caller or Rust/Python/proxy initializer ABI to update. The
prototype changes in `aic.h`; guarded runtime helper semantics do not change.

The complete 25-patch comparison cross-build and shared-layout audit pass
with the same six existing C warnings. Unchanged ADT/relocation,
48-case DVFS/payload and five MCC/MMU fixtures pass on the complete source;
all 215 canonical C/Rust files match the build and both adjacent test trees.
The MCC caller-order audit now recognizes `aic_init()` rather than only the
old void-call spelling, so both historical and checked calls retain its
ordering check. Runtime cutoff coverage is separate from that structural audit.

The final main and independent caller-suite runs pass with ASan/UBSan:
normal startup and `BRINGUP`, the retained seven-group aperture baseline,
status/failure/reinitialization checks, and four designated mutation controls.
The real AIC driver and `m1n1_main` prefix from `firmware_init()` through
`run_actions()` are compiled with bounded host mocks. Synthetic AIC1/2/3
combinations use production T6032/T6031/T6020 constants; they are not captured
hardware capabilities. Failed startup asserts the exact panic, null AIC,
no SMP/actions, and no later initializer events. `BRINGUP` asserts that AIC
was not called, rather than merely checking the absence of SMP calls.
Removing the status result/cutoff, moving the cutoff after SMP, or calling
AIC from `BRINGUP` must exit exactly 1 with a designated stderr witness and
no sanitizer/runtime diagnostic. This is four new controls, not a rerun of
the four aperture-arithmetic mutations from the preceding checkpoint.

All 215 canonical source files also match both final caller-suite trees.
The build and host materializers use the same 25 patches in slightly different
orders: host SMP 0022 precedes input guards 0019/0020/0021, whereas the build
places it afterward. The inventory records both orders and the byte-equality
checks, rather than assuming identical order. Unchanged production headers,
the separate Darwin-adjusted host types, production SoC constants, full source,
extracted prefix, compiler arguments, exit codes, hashes and logs are retained
in each 57-file final run. The
[startup cutoff inventory](inventory/m1n1-upstream-aic-boot-cutoff-2026-10-07.json)
records the final evidence and remaining gates.

```sh
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 python \
  scripts/test-m1n1-upstream-aic-boot-cutoff.py
bash scripts/build-m1n1-upstream-offline.sh boot-guards
```

This is an initialization-status/control-flow contract, not proof of register
availability, native reboot/recovery, SMP release, interrupt delivery or a
working native Debian boot. The startup prefix does not qualify other entry
points or the full next-stage tail. The separate SMP policy retains legacy
one-core/proxy continuation and T6032 downstream readiness rejection; this
patch does not make `smp_init()` failure fatal in `main` or claim degraded-SMP
recovery on T6032.
HV tracing still needs its own null/divisor/die/bitmap ingress guards.
Default source pin/native dispatch remain unchanged; these comparison
artifacts are not boot-approved. No physical MMIO, VM, disk or firmware changes.

## Remaining implementation order

1. Address remaining AIC/HV caller guards and startup failure propagation,
   keeping the complete adapted stack under
   regression. Do not confuse declared bounds with physical mapping qualification.
2. Continue early-DVFS qualification: six-complex/die routing, safe raw states,
   pre-existing busy state, feature/restore prerequisites and voltage error policy.
   Do not infer these from upstream constants or a successful mock build.
3. Reconcile current kernel/board support and initialization dependencies for
   native boot and storage/network I/O.
4. Only after a verified backup, recovery readiness and separate native-test
   approval: qualify cold entry, RVBAR/release, MCC/cache/DVFS and UART/AIC/DART,
   then a RAM-only kernel boot and persistent storage/network bring-up.

The full M3 Ultra SoC objective is not complete. New source support replaces
some implementation work; it does not prove register access, cache effects,
safe early DVFS states, recovery or a working native Debian boot.

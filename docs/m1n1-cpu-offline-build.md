# Offline m1n1 CPU-capacity build

2026-09-26: both the unmodified m1n1 baseline and the local 32-CPU patch
compile and link successfully on the M3 Ultra host, as does the subsequent
capacity-plus-cleanup series, the three-patch pre-release-guard series, and
the four-patch fatal-timeout series, five-patch T6032 mask series and
six-patch CPU-inventory preflight series and seven-patch caller-status series.
This is a **build result,
not a native boot result**. No artifact was installed or executed.

Source: `4184923ffb2dff079b384d6a32cc02142aa14572`; local patch series:
[`0001` capacity/bounds](../patches/m1n1/0001-expand-cpu-capacity-and-fix-bounds.patch)
plus [`0002` allocation cleanup](../patches/m1n1/0002-free-pruned-cpus-after-handoff.patch)
plus [`0003` startup guards](../patches/m1n1/0003-guard-secondary-start-prerequisites.patch)
plus [`0004` fatal timeout](../patches/m1n1/0004-abort-on-secondary-start-timeout.patch)
plus [`0005` T6032 masks](../patches/m1n1/0005-t6032-cpu-start-masks.patch)
plus [`0006` inventory preflight](../patches/m1n1/0006-preflight-t6032-cpu-inventory.patch)
and [`0007` caller status](../patches/m1n1/0007-propagate-t6032-cpu-start-failures.patch).
The [initial build record](inventory/m1n1-cpu-build-2026-09-26.json) records
baseline/capacity-only artifacts; the [cleanup-series build record](inventory/m1n1-cpu-cleanup-build-2026-09-26.json)
records the two-patch build; the [startup-guard build record](inventory/m1n1-cpu-startup-build-2026-09-26.json)
records the three-patch build; the [timeout build record](inventory/m1n1-cpu-timeout-build-2026-09-26.json)
records the four-patch build; the [mask build record](inventory/m1n1-cpu-mask-build-2026-09-26.json)
records the five-patch build; the [preflight build record](inventory/m1n1-cpu-preflight-build-2026-09-26.json)
records the six-patch build; the [caller-status build record](inventory/m1n1-cpu-status-build-2026-09-26.json)
records the seven-patch build. These records include hashes and scratch
locations. The recipe builds the default firmware configuration, not every
optional feature combination. It does not introduce T6032 startup dispatch.

## Toolchain

- Apple clang 21.0.0 (`clang-2100.3.34.2`), targeting `aarch64-none-elf`.
- Rust/Cargo 1.95.0; bare-metal target `aarch64-unknown-none-softfloat`.
- Rust's bundled `rust-lld` and `rust-objcopy`, LLVM 22.1.2.
- GNU Make 4.4.1, built under project scratch. Apple's Make 3.81 does not
  correctly support the grouped-target rules used by this m1n1 revision.

The precompiled Rust target component is sufficient: `BUILDSTD=1` and
`rust-src` are not needed. A target-specific Cargo rustflags setting points
to its isolated sysroot, while the host-side procedural macro uses the
existing host toolchain. Nothing was added to the installed Rust toolchain
or Homebrew. The default build uses bundled binary artwork; missing artwork
submodule PNG symlinks do not prevent it.

## Reproduce on this host

After the preparation below, both commands are offline:

```sh
bash scripts/build-m1n1-cpu-offline.sh baseline
bash scripts/build-m1n1-cpu-offline.sh patched
```

The script validates the source archive digest and Rust version, extracts a
fresh scratch tree per run, applies all seven patches only to the patched copy,
sets a local version tag and passes `--offline --locked` to Cargo. Logs and
artifacts are retained on failure or success. There is no install/boot step.
The source archive stays unmodified. This is a repeatable build recipe, not
a claim of byte-for-byte reproducibility across machines or scratch paths.
It is not a fully isolated, content-pinned toolchain: the script checks the
source archive and Rust version but trusts the prepared tools, extracted
target sysroot and Cargo cache. Preparation digests must be checked manually;
they do not authenticate subsequent changes to extracted files. The build
records identify the patch digests used for each recorded patched build.

Preparation needs network access once. Run from the repository root:

```sh
mkdir -p scratch/m1n1-build-tools scratch/m1n1-cpu-audit
curl -fL https://codeload.github.com/AsahiLinux/m1n1/tar.gz/4184923ffb2dff079b384d6a32cc02142aa14572 -o scratch/m1n1-cpu-audit/source.tar.gz
curl -fL https://ftpmirror.gnu.org/make/make-4.4.1.tar.lz -o scratch/m1n1-build-tools/make-4.4.1.tar.lz
curl -fL https://static.rust-lang.org/dist/2026-04-16/rust-std-1.95.0-aarch64-unknown-none-softfloat.tar.xz -o scratch/m1n1-build-tools/rust-std.tar.xz
shasum -a 256 scratch/m1n1-cpu-audit/source.tar.gz scratch/m1n1-build-tools/make-4.4.1.tar.lz scratch/m1n1-build-tools/rust-std.tar.xz
```

**Stop if any digest differs.** Verified inputs:

| Archive | SHA-256 |
| --- | --- |
| m1n1 source | `6425983260ab96d55c36fdaab3b456830c3bd80f06b7759a61ed2bcca924d973` |
| GNU Make 4.4.1 | `8814ba072182b605d156d7589c19a43b89fc58ea479b9355146160946f8cf6e9` |
| Rust target component | `54d691468e25e7989b022a171337beadf78b5202877b312b75182b7f93efbb8b` |

The Make digest came from Homebrew's published formula metadata; the Rust
component URL/digest came from the installed toolchain's channel manifest.
The m1n1 digest records the downloaded commit-addressed archive, not an
independent release signature. Then:

```sh
tar -xf scratch/m1n1-cpu-audit/source.tar.gz -C scratch/m1n1-cpu-audit
tar -xf scratch/m1n1-build-tools/make-4.4.1.tar.lz -C scratch/m1n1-build-tools
tar -xf scratch/m1n1-build-tools/rust-std.tar.xz -C scratch/m1n1-build-tools
(cd scratch/m1n1-build-tools/make-4.4.1 && ./configure --disable-dependency-tracking --without-guile && /usr/bin/make -j8)
CARGO_HOME="$PWD/scratch/m1n1-build-tools/cargo-home" cargo fetch --locked --manifest-path scratch/m1n1-cpu-audit/m1n1-4184923ffb2dff079b384d6a32cc02142aa14572/rust/Cargo.toml
```

Cargo fetch populates only the isolated cache, including optional locked
dependencies. The firmware build itself does not fetch dependencies.

## Validation limits

All recorded builds emit ARM64 ELF images, a Mach-O arm64e image and a raw binary.
They have the same two compiler warnings: the pre-existing variable-sized
union in `dcp_iboot.c`, and an unused Rust `crate::println` import. No new
compiler warning was observed with any of the recorded local patch series.

The CPU handoff tests below are separate host-side tests using libfdt
and mocked SMP state; none execute the firmware. Hardware CPU-start,
execution-level, MCC and frequency-control prerequisites remain open, as
do recovery and native boot validation.

## Full CPU handoff regression

```sh
PYTHONDONTWRITEBYTECODE=1 uv run --no-project --python 3.13 scripts/test-m1n1-cpu-handoff.py
```

This compiles the entire extracted `dt_set_cpus()` from the checksum-checked
pinned `kboot.c`, after applying the two patches, with the source tree's
real libfdt. Firmware/SMP operations are mocked. AddressSanitizer and UBSan
are enabled with fail-fast undefined-behavior checking.

Seven scenarios pass with zero outstanding tracked allocations:

| Input | Expected result |
| --- | --- |
| 32 CPUs; boot CPU ordinal 5 | 32 nodes retained, 31 secondary release addresses and stack reservations |
| 32 CPUs; secondary CPU 20 dead | 31 nodes retained; CPU 20 removed from AIC affinities and CPU map |
| 33 CPUs | Error before indexing beyond CPU capacity |
| DT/SMP MPIDR mismatch | Error with temporary allocation released |
| Missing CPU `reg` | Error with temporary allocation released |
| 24 CPUs | Success; 23 secondary release addresses and stack reservations |
| Missing CPU map | Success; existing early-free path remains correct |

The harness checks exact surviving AIC/CPU-map phandle membership, not just
counts, and checks release addresses including the boot-CPU exception.
Linux FDT values use big-endian cells. The synthetic MPIDRs split CPUs into
two groups representing dies; they are not measured M3 Ultra MPIDRs. Its
two-group CPU map is a functional fixture, not the board's actual six-cluster
device tree. The exact board-DT test below is separate; EL3-mode testing
remains outstanding.

**Fixed by the separate `0002` patch:** the pinned function failed to free
`pruned_phandles` when it successfully processed an existing CPU map.
The capacity-only negative control still observes that allocation (128 bytes
at `MAX_CPUS=32`) and reclaims it in test code. The fixed run requires zero
outstanding allocations on every tested success/error path. A new missing-map
case checks the existing early free, guarding against a double-free.
LeakSanitizer is enabled for the fixed run on non-Darwin hosts; on this Mac,
leak scanning is disabled because it is unsupported. Explicit allocation
tracking, AddressSanitizer and fail-fast UBSan remain enabled. This is not a
whole-firmware leak audit.

The prior 12 topology tests, 15 MCC tests and CPU bounds/negative-control
harness also pass. The full firmware and test executables are distinct:
only the host test executables were run.

## Exact T6032/J575d board-DT handoff

The board harness compiles the actual J575d DTS from the pinned Linux
`asahi` commit `77cb8f24c2381a8abb7272d7bbdec548d6426a8a`. Its
[source manifest](inventory/t6032-board-dt-sources-2026-09-26.json) records
the 19-file include closure, commit-addressed URLs and SHA-256 checksums.
This is a pinned source test, not a claim about current upstream status.

```sh
# Explicit network preparation, needed only when the source closure is absent:
PYTHONDONTWRITEBYTECODE=1 uv run --no-project --python 3.13 scripts/test-m1n1-board-handoff.py --fetch
# The test itself is offline; the pinned m1n1 source must also be prepared:
PYTHONDONTWRITEBYTECODE=1 uv run --no-project --offline --python 3.13 scripts/test-m1n1-board-handoff.py
```

Prerequisites are clang, dtc (tested with 1.8.1), and the m1n1 sources above.
The run reports six existing DTS structural warnings in `simple_bus_reg`
and `unit_address_vs_reg`; it is not a warning-free DT compilation.

The 32 CPU ordinals and decoded affinities agree with the sanitized live
host inventory: two dies, each with 4E+6P+6P cores. Linux DT P-core `reg`
values additionally carry bit 16 (`0x10000`); the adapter checks that marker
separately from the ADT die/cluster/core fields. Global DT clusters 3–5
correspond to die 1's local clusters 0–2. This cross-check is **not** a
measurement of the CPUs' runtime MPIDR registers.

| Board fixture | Result |
| --- | --- |
| All 32 CPUs alive | 32 CPUs, six clusters retained |
| CPU 24 dead | 31 CPUs, six clusters retained |
| Die-1 cluster 5 dead | 26 CPUs, five clusters retained |
| Mock CPU 7 MPIDR mismatch | Rejected; temporary allocation released |

All four scenarios pass with zero outstanding tracked allocations under
AddressSanitizer and fail-fast UBSan. The harness checks exact surviving
CPU-map phandles, removed CPU nodes, release addresses and reservation
counts. The board has the `apple,t8122-aic3` fallback compatible but no AIC
affinity list, so AIC-list pruning coverage comes from the synthetic suite,
not this board fixture. SMP IDs/liveness and execution level remain mocked;
neither AIC operation nor native CPU release has been validated.

## Secondary-start prerequisite guards

The separate [startup regression](m1n1-t6032-startup.md#offline-startup-regression)
compares original, `0003`, `0003` plus `0004`, and the subsequent `0005` startup implementations,
with mocked RVBAR, allocation failures, EL3 state, release writes and a
non-returning fatal handler. The full default firmware build includes all
seven patches; the handoff-only harnesses still apply just the two patches
relevant to their extracted function. Post-release timeout now terminates
the calling path before shared reset-state reuse; legacy pre-release skip policy
is unchanged, while `0007` rejects T6032 continuation. No timeout reclamation or T6032 start-offset selection is
included, and native reset behavior remains unvalidated. The additional
[mask helper](m1n1-t6032-mask-contract.md) qualifies the captured T6032
metadata without opening its normal startup dispatch.
The separate [whole-inventory preflight](m1n1-t6032-inventory-preflight.md)
checks all CPU metadata before the boot CPU's RVBAR path; it does not resolve
the native-entry gates. The subsequent [caller-status patch](m1n1-t6032-start-status.md)
propagates T6032 rejection without enabling dispatch or rolling back caller preludes.

# Offline m1n1 CPU-capacity build

2026-09-26: both the unmodified m1n1 baseline and the local 32-CPU patch
compile and link successfully on the M3 Ultra host. This is a **build result,
not a native boot result**. No artifact was installed or executed.

Source: `4184923ffb2dff079b384d6a32cc02142aa14572`; patch:
[`0001-expand-cpu-capacity-and-fix-bounds.patch`](../patches/m1n1/0001-expand-cpu-capacity-and-fix-bounds.patch).
The [build record](inventory/m1n1-cpu-build-2026-09-26.json) records artifact
hashes and scratch locations. The recipe builds the default firmware configuration, not every optional
feature combination. It does not introduce T6032 startup dispatch.

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
fresh scratch tree per run, applies the patch only to the patched copy,
sets a local version tag and passes `--offline --locked` to Cargo. Logs and
artifacts are retained on failure or success. There is no install/boot step.
The source archive stays unmodified. This is a repeatable build recipe, not
a claim of byte-for-byte reproducibility across machines or scratch paths.
It is not a fully isolated, content-pinned toolchain: the script checks the
source archive and Rust version but trusts the prepared tools, extracted
target sysroot and Cargo cache. Preparation digests must be checked manually;
they do not authenticate subsequent changes to extracted files. The build
record also identifies the patch digest used for the recorded patched build.

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

Both builds emit ARM64 ELF images, a Mach-O arm64e image and a raw binary.
Both have the same two compiler warnings: the pre-existing variable-sized
union in `dcp_iboot.c`, and an unused Rust `crate::println` import. No new
compiler warning was observed with the capacity patch.

The CPU handoff tests below are separate host-side tests using libfdt
and mocked SMP state; none execute the firmware. Hardware CPU-start,
execution-level, MCC and frequency-control prerequisites remain open, as
do recovery and native boot validation.

## Full CPU handoff regression

```sh
PYTHONDONTWRITEBYTECODE=1 uv run --no-project --python 3.13 scripts/test-m1n1-cpu-handoff.py
```

This compiles the entire extracted `dt_set_cpus()` from the checksum-checked
pinned `kboot.c`, after applying the capacity patch, with the source tree's
real libfdt. Firmware/SMP operations are mocked. AddressSanitizer and UBSan
are enabled with fail-fast undefined-behavior checking.

Six scenarios pass:

| Input | Expected result |
| --- | --- |
| 32 CPUs; boot CPU ordinal 5 | 32 nodes retained, 31 secondary release addresses and stack reservations |
| 32 CPUs; secondary CPU 20 dead | 31 nodes retained; CPU 20 removed from AIC affinities and CPU map |
| 33 CPUs | Error before indexing beyond CPU capacity |
| DT/SMP MPIDR mismatch | Error with temporary allocation released |
| Missing CPU `reg` | Error with temporary allocation released |
| 24 CPUs | Success; 23 secondary release addresses and stack reservations |

The harness checks exact surviving AIC/CPU-map phandle membership, not just
counts, and checks release addresses including the boot-CPU exception.
Linux FDT values use big-endian cells. The synthetic MPIDRs split CPUs into
two groups representing dies; they are not measured M3 Ultra MPIDRs. Its
two-group CPU map is a functional fixture, not the board's actual six-cluster
device tree. Exact board-DT integration and EL3-mode testing remain separate.

**Known finding, not fixed here:** the pinned function fails to free
`pruned_phandles` when it successfully processes an existing CPU map.
The harness explicitly expects and reports one outstanding allocation in
each such success case (128 bytes at `MAX_CPUS=32`). Error paths in the
tested cases release it. Leak scanning is disabled for this known finding;
the allocator counter makes it visible, while address/UB checks remain
enabled. This is not a claim of a leak-free firmware or sanitizer run.
Keep a cleanup fix separate from the three-line capacity patch.

The prior 12 topology tests, 15 MCC tests and CPU bounds/negative-control
harness also pass. The full firmware and test executables are distinct:
only the host test executables were run.

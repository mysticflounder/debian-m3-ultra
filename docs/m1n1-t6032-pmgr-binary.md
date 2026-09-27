# T6032 PMGR: local kernel-collection evidence

Observed 2026-09-26 local time (2026-09-27 UTC). This is offline analysis of
Apple's installed binary, not native execution of our firmware. No registers,
boot policy, partitions, VM configuration or firmware were changed.

## Provenance

The host is J575d / Mac15,14 / chip `0x6032`, with 32 CPUs on two dies.
The restore `kernelcache.release.mac15j` and active-boot `kernelcache`
under this host's Preboot volume decode to **identical bytes**. Both contain
the same kernel version reported by `uname -v`:

```
Darwin Kernel Version 27.0.0: Tue Aug 11 21:05:42 PDT 2026;
root:xnu-13432.1.9~1/RELEASE_ARM64_T6031
```

Live IOService inspection identifies `AppleT6031PMGR` as the active PMGR
class, matching `pmgr1,t6031`, with bundle
`com.apple.driver.AppleT6031PMGR`. The family name **does not exclude Ultra**.
This is a matching local artifact, not a guessed M3 Max substitute. It does
not prove that the bytes of every running driver were read from live memory.

| Artifact | SHA-256 |
| --- | --- |
| Restore IM4P | `f949b416892967d9224314d703be7d25f6207e603ddf606a65454f94cb9e513e` |
| Active-boot IMG4 | `cdc0726194fce3ac53acb05a3c2557b4dca5c6e47f92bdf06eb1f41730ad52d7` |
| Either decoded collection, 125,992,960 bytes | `a24fefccc060854cecc996b40983499e1319008e4f16c0717a5fef6c4d4828dc` |

These are reproducibility checks, **not signature verification**. Apple
binaries and full disassemblies remain local under `scratch/`; they are not
included in the repository. All addresses below are unslid file VM addresses
for this exact hash and must not be reused blindly for another OS build.
The [bounded evidence manifest](inventory/t6032-pmgr-binary-2026-09-26.json)
records the provenance and validation limits without copying Apple binaries.

## Established offline observations

| Observation | Binary location / trace |
| --- | --- |
| Die stride `0x2000000000` | `AppleT6031PMGR::getDieStride`, `0xfffffe0009f60710`; `getDieOffset`, `0xfffffe0009f6071c`, shifts the checked die index left 37 |
| Separate group 2 offset `0x18000` and group 8 offset `0x88000`, both map 0 | `AppleT6031PMGR::initRegGroups`, calls at `0xfffffe0009f5a3e0` and `0xfffffe0009f5a414` |
| Group table uses 24-byte records at `this+0x5d48` | `ApplePMGR::initRegGroup`, `0xfffffe0009b7c9ec`; group 8 enable/map/offset fields are `this+0x5e10/14/18` |
| CPU/misc-core configuration reads group 8 | `ApplePMGR::configMiscCores`, `0xfffffe0009b95554` |
| Virtual write calls receive group offset `+4`, then `+8+4*cluster`, with a die argument | `configMiscCores`, call sites `0xfffffe0009b957ac` and `0xfffffe0009b95860`, in the mode-2 path; this does not by itself establish hardware semantics |
| `acc-clusters` is consumed with an eight-byte record stride | `ApplePMGR::initDriver`, length division at `0xfffffe0009b7ce4c` |
| CPU masks use physical-ID/topology metadata | `getCorePhysID` call at `0xfffffe0009b95624`; eight-byte `acc-cores` scan at `0xfffffe0009b95634`–`0xfffffe0009b95674` matches bytes 6/7, followed by metadata-dependent shifts at `0xfffffe0009b956e8` and `0xfffffe0009b95714` |

Unlike merely dividing the observed property length, the consumer now
establishes that the captured 48-byte `acc-clusters` property supplies six
eight-byte records. This does **not** assign a complete meaning to all eight
bytes. The separate `clusters` property is also consumed; it is not the
`acc-clusters` table. The physical-ID scan uses **`acc-cores`**, not
`acc-clusters`: `initDriver` stores their pointers at structure-relative
offsets `+0x20` and `+0x30` respectively, and the scan reads `+0x20`.
Matching record sizes alone would have misidentified this table.

The allowlisted live `/arm-io/pmgr/die-stride` value was eight bytes
`0000000020000000` (little-endian `0x2000000000`). Apple's superclass reads
this DT override and stores it at `this+0x6320`; absent an override it calls
the virtual stride getter. `ApplePMGR::initRegMap` (`0xfffffe0009b7c724`)
uses that stride to derive subsequent dies' physical mappings from die 0.
`AppleT6031PMGR::initRegMaps` (`0xfffffe0009f59d44`) initializes map 0 using
provider register index 0. The final generic write path uses the selected
map's virtual base plus the requested register offset.

## What this does not yet establish

- The full CPU-release mask contract. Apple's implementation uses topology
  fields rather than visibly computing `4*cluster+core`. We have not yet
  proved equivalence or a bug in m1n1's formula. Bit overlap alone does not
  prove a bug: the first register could control shared resources.
- Which metadata/mode branches execute for each of our 32 CPUs. A static
  path is not a runtime trace or proof that macOS runtime sequencing is
  sufficient during early boot.
- Safe native entry state, RVBAR/reset sequencing, required barriers or
  recovery readiness. No secondary was released by our code.
- MCC register semantics or six-cluster frequency initialization.

T6032 dispatch therefore **remains disabled**. Next: finish decoding the
per-core/cluster mapping and derive all 32 expected masks in a host-side
model, with explicit failure on inconsistent metadata, before proposing
firmware writes. Then handle the independent early-boot/recovery gates.

Follow-up: the [32-CPU mask comparison](m1n1-t6032-cpu-masks.md) now joins
all captured `acc-cores` records to the CPU inventory and demonstrates
12 differences from the legacy formula. Remaining gates are explicit there.

## Reproduction tooling

`scripts/inspect-local-kernelcache.py` accepts only bounded local files.
`decode` unwraps IM4P or IMG4 and uses macOS libcompression for unencrypted
LZFSE. `view` creates an **inspection-only, non-loadable** fileset view:
the embedded header is copied to offset zero, while original offsets and
VM addresses are retained. Output must be a new file under project
`scratch/`; existing files are never overwritten. This is not a general
Mach-O verifier, decryptor, installer or kernel-service client.

```sh
PYTHONDONTWRITEBYTECODE=1 UV_CACHE_DIR="$PWD/scratch/uv-cache" \
  uv run --no-project --offline --python 3.13 scripts/test-local-kernelcache.py
# Supply a readable local kernel collection; choose new output names.
python3 scripts/inspect-local-kernelcache.py decode "$KERNEL_COLLECTION" \
  scratch/kernelcache-decoded.macho
python3 scripts/inspect-local-kernelcache.py view scratch/kernelcache-decoded.macho \
  scratch/pmgr-inspection-only.macho --entry com.apple.driver.AppleT6031PMGR
nm -C scratch/pmgr-inspection-only.macho > scratch/pmgr-symbols.txt
xcrun llvm-objdump --macho --disassemble scratch/pmgr-inspection-only.macho \
  > scratch/pmgr-disassembly.txt
```

The reusable tool reproduced both the earlier decoded collection and the
earlier subclass view byte-for-byte. The latter hashes to
`b244d44a1a54cfd501cef21a711ae038231c21614580d0382db4afdb73ac3a9d`.
Synthetic tests require no proprietary fixtures. macOS `llvm-objdump`
ignored address-range flags in Mach-O mode during this investigation;
redirect full output to scratch and inspect bounded sections instead.

Independent review confirmed outer chained-fixup format 8
(`DYLD_CHAINED_PTR_64_KERNEL_CACHE`). This alone does not resolve a particular
virtual call: each vtable word's chain membership, cache level and target
must also be checked. No unresolved vtable inference is a hardware gate
cleared by this document. Review also prompted regular-file-only input and
complete load-command bounds checks; the test suite covers both.

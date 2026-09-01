# debian-m3

Test rig for Debian on Apple M3. Host is a Mac Studio (Mac15,14, M3 Ultra,
`t6032`/`j575d`).

The active workstream is completing and validating QEMU's Apple Silicon
`-cpu host` passthrough model. See the
[QEMU Apple host-CPU passthrough plan](docs/qemu-apple-host-cpu-passthrough.md).
The [m1n1 T6032 plan](docs/m1n1-t6032-bringup.md) is retained as a deferred
bare-metal roadmap.

## What this proves and what it cannot prove

| Stage | Tool | Proves |
|---|---|---|
| Build | `debian:unstable` arm64 container | The Asahi patch stack builds under Debian, and the M3 device trees compile |
| Boot | QEMU `virt` + HVF | The Debian `linux-asahi` kernel boots and the userland runs |
| CPU model | Host/guest feature probes | Which HVF-exposed architectural CPU features actually reach the guest |
| Hardware | — | Nothing. QEMU has no Apple M-series machine model. |

This host cannot run Asahi natively: the installer has no entry for chip `0x6032`
or board `j575dap`. Only M3 / M3 Pro / M3 Max MacBooks and iMacs are supported,
and they need macOS 14.8.3 firmware.

## Scripts

### `scripts/container-setup.sh`
Runs inside a `debian:unstable` arm64 container. Adds the Debian Bananas archive,
installs the build dependencies of `linux-asahi`, and fetches the source.

```bash
docker volume create m3build
docker run --name m3setup --platform linux/arm64 \
  -v m3build:/build -v "$PWD/scripts:/scripts:ro" \
  -w /build debian:unstable bash /scripts/container-setup.sh
docker commit m3setup m3build:deps && docker rm m3setup
```

Environment: `SUITE` (default `unstable-bananas`), `SRC` (default `linux-asahi`),
`BUILD_DIR` (default `/build`).

Use `SUITE=trixie-bananas` with a `debian:trixie` base for the Trixie kernel.
Sid is needed for the sid kernel because the build depends on `gcc-15-for-host`.

### Device tree check

```bash
docker run --rm --platform linux/arm64 -v m3build:/build \
  -w /build/linux-asahi-7.1.10-1 m3build:deps \
  bash -c 'make ARCH=arm64 defconfig >/dev/null && make ARCH=arm64 -j24 dtbs'
```

### `scripts/make-rootfs.sh`
Runs inside a **privileged** container. Builds a minimal Debian sid arm64 rootfs,
installs the prebuilt `linux-image-asahi` package, generates the initramfs, and
exports `Image-*`, `initrd.img-*` and a populated `rootfs.ext4`.

```bash
docker run --rm --privileged --platform linux/arm64 \
  -v m3build:/build -v "$PWD/scripts:/scripts:ro" \
  m3build:deps bash /scripts/make-rootfs.sh
```

Environment: `R` (rootfs dir), `OUT`, `IMG_SIZE` (default `6G`), `SUITE` (default `sid`).

It needs `--privileged` because it mounts `/proc`, `/sys` and `/dev` into the chroot
so that `update-initramfs` works.

Copy the results to `out/` with `cp --sparse=always` — the 6 GB image holds under 1 GB.

### `scripts/boot-qemu.sh`
Boots the exported kernel in QEMU with HVF.

```bash
./scripts/boot-qemu.sh          # interactive, Ctrl-A X to quit
./scripts/boot-qemu.sh --auto   # runs a probe, writes out/boot.log, powers off
```

Environment: `QEMU`, `SMP` (default 8), `MEM` (default `8G`).
Login is `root` / `root`, with autologin on `ttyAMA0`.

### CPU passthrough evidence

`scripts/cpu-probe-host.sh` compiles and runs a read-only
Hypervisor.framework collector. It creates a vCPU configuration object but no
VM or vCPU, and writes the resulting fingerprint to
`out/cpu-probe-host.json`:

```bash
./scripts/cpu-probe-host.sh
```

`scripts/cpu-probe-vm.sh` boots the existing builder image with `-cpu host`
and `-snapshot`, attaches `scripts/` as a read-only vvfat disk, compiles the
Linux arm64 collector in the guest, pins it to every configured vCPU, and
writes a self-describing fingerprint to
`out/cpu-probe-guest.json`:

```bash
./scripts/cpu-probe-vm.sh
SMP=32 ./scripts/cpu-probe-vm.sh
```

The guest manifest includes per-vCPU registers and sysfs identification,
online/present/possible masks, `/proc/cpuinfo`, kernel feature messages, exact
QEMU arguments, input hashes, and consistency checks.

Run the required vCPU-count matrix sequentially and produce the raw host/guest
gap report with:

```bash
./scripts/cpu-probe-matrix.sh
./scripts/cpu-probe-compare.sh
```

Outputs are under `out/cpu-matrix/`. The measured interpretation is in the
[M3 Ultra Phase 3 results](docs/qemu-m3-ultra-phase3-results.md).
The probe scripts reject output paths outside the project `out/` tree and
refuse symlinked output targets.

`scripts/el1-probe-vm.sh` is the raw EL1 follow-up. It boots the same Debian
builder as a disposable QEMU/HVF guest, builds and loads a short-lived kernel
module there, and records `MPIDR_EL1`, `CLIDR_EL1`, and the ID registers Linux
sanitizes from EL0. It is a QEMU-only evidence tool; it does not support or
attempt bare-metal boot:

```bash
./scripts/el1-probe-vm.sh
SMP=32 ./scripts/el1-probe-vm.sh
./scripts/el1-probe-matrix.sh
./scripts/el1-probe-compare.sh out/el1-probe-smp8.XXXXXX/evidence.json
```

The matrix runner collects 1, 8, 16, 24, and 32 vCPUs sequentially and runs
the host/raw-EL1 comparison for every result. EL1 manifests and comparisons
are written under `out/el1-probe-*`. The base rootfs is
opened through an explicit disposable qcow2 overlay, while the build disk and
source share are read-only; the runner also refuses a concurrent VM using the
builder image. The only writes are project output files and the temporary
overlay used by the guest. No firmware, NVRAM, boot policy, raw physical disk,
or host system volume is passed through or intentionally modified; no host
privilege is used.

Current QEMU deliberately exposes a homogeneous synthetic Apple MIDR
(`0x610f0000`) instead of physical P/E-core identities. The probes measure the
architectural feature contract separately from that known identity policy.

### `scripts/make-builder-vm.sh`
Runs inside a **privileged** container. Builds a self-contained builder VM:
`vmroot.ext4` (Debian sid + the asahi kernel + every `linux-asahi` build dependency
+ a systemd unit that builds at boot and powers off) and `build.ext4` (a pristine
source tree on its own disk). The VM then needs no network and no Docker.

Environment: `ROOT_SIZE` (14G), `BUILD_SIZE` (60G), `JOBS` (8),
`PROFILES` (default `pkg.linux.nokerneldbginfo pkg.linux.notools nodoc`).

Drop `pkg.linux.nokerneldbginfo` for a faithful rebuild of what Debian ships.
It costs the DWARF, the BTF step and a 1 GB debug package.

### `scripts/build-vm.sh`
```bash
./scripts/build-vm.sh           # run the build -> out/vmbuild.log, out/BUILD_RC
./scripts/build-vm.sh --log     # follow a running build's console
./scripts/build-vm.sh --peek    # shell on a throwaway copy, safe during a build
./scripts/build-vm.sh --shell   # shell on the real disks, build unit masked
```

Environment: `SMP` (8), `MEM` (32G), `QEMU`, `LOG`.

QEMU write-locks each disk image, so only one VM may use them at a time. The
script checks for a running build and tells you what to do instead of letting
QEMU print a lock error. `--peek` uses `-snapshot`, so writes are discarded — but
a filesystem being written by another VM can read back stale or inconsistent.

### `scripts/bench.c` and `scripts/bench-vm.sh`
A matched host/guest microbenchmark: integer throughput and memory bandwidth,
same source, same compiler family, so guest numbers can be compared with host
numbers directly. It answers the question that decides this project — whether a
VM runs native binaries close enough to full speed.

On the host:

```bash
gcc-16 -O2 -pthread -o /tmp/bench scripts/bench.c
/tmp/bench 1
/tmp/bench 8
```

In the guest, put the source on the build disk first, then:

```bash
./scripts/bench-vm.sh
```

Or run it by hand from a VM shell, where `bench.c` sits on `/dev/vdb`:

```sh
mkdir -p /build && mount /dev/vdb /build && cd /build
gcc -O2 -pthread -o /tmp/bench bench.c && /tmp/bench 1 && /tmp/bench 8
```

Measured host baseline (Mac Studio M3 Ultra, macOS 26.6.2, GCC 16):

| threads | int Gops | mem GiB/s |
|---|---|---|
| 1 | 1.78 | 29.25 |
| 8 | 12.92 | 29.00 |

The benchmark deliberately avoids disk and network, which are the two paths
that are *not* native under QEMU. Measure those separately.

**Warning.** Do not write to a disk image while a VM has it open. QEMU's lock
lives on the macOS side and a Linux container mounting the same file cannot see
it. Two writers will corrupt the filesystem.

## Contributing upstream

A goal of this project is to get work merged upstream. Two projects, two models:

| Target | Project | Model |
|---|---|---|
| `T6032` bring-up — the actual gap | m1n1 | GitHub, takes pull requests |
| Device trees, drivers | Linux | **Email patches, not pull requests** |

`MAINTAINERS`, `ARM/APPLE MACHINE SUPPORT`:

```
M:  Sven Peter <sven@kernel.org>
M:  Janne Grunau <j@jannau.net>
L:  asahi@lists.linux.dev
L:  linux-arm-kernel@lists.infradead.org (moderated for non-subscribers)
T:  git https://github.com/AsahiLinux/linux.git
```

Rules that apply to every patch: author against a clean mainline or
`asahi-soc/for-next` tree, never against the Debian source package, which
carries Debian's own patches; one logical change per patch; a `Signed-off-by:`
line under the DCO; `scripts/checkpatch.pl --strict` clean; recipients from
`scripts/get_maintainer.pl`; `b4` to send and track a series.

Maintainers require patches to be tested on the hardware. Nothing
`t6032`-specific is submittable from a machine that cannot boot it.

Hardware-free contributions that *are* possible: device tree schema fixes via
`make ARCH=arm64 CHECK_DTBS=y`, checkpatch cleanups, build fixes, and
documentation. Note that `dtschema` is not packaged in Debian sid — there is no
`python3-dtschema` — so install it with `pip` in a virtualenv.

## Notes

- Do not build on a bind mount from `/Users`. APFS is case-insensitive and the kernel
  tree has files that differ only in case (`xt_mark.h` and `xt_MARK.h`). Use a Docker volume.
- Debian arm64 `vmlinuz` is already an uncompressed `Image`, so `vfkit` accepts it.
- Docker Desktop had 8.3 GB of RAM here. Raise it before a full package build.

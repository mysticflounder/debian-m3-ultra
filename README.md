# debian-m3

Test rig for Debian on Apple M3. Host is a Mac Studio (Mac15,14, M3 Ultra, `t6032`/`j575d`).

## What this proves and what it cannot prove

| Stage | Tool | Proves |
|---|---|---|
| Build | `debian:unstable` arm64 container | The Asahi patch stack builds under Debian, and the M3 device trees compile |
| Boot | QEMU `virt` + HVF | The Debian `linux-asahi` kernel boots and the userland runs |
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

## Notes

- Do not build on a bind mount from `/Users`. APFS is case-insensitive and the kernel
  tree has files that differ only in case (`xt_mark.h` and `xt_MARK.h`). Use a Docker volume.
- Debian arm64 `vmlinuz` is already an uncompressed `Image`, so `vfkit` accepts it.
- Docker Desktop had 8.3 GB of RAM here. Raise it before a full package build.

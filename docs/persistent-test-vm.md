# Persistent Headless Test VM Plan

## Goal and current status

P0 is a long-lived Debian guest for ordinary development and regression work.
It must keep changes across clean shutdowns and reboots, have outbound network
and DNS access, accept SSH from the host, and mount an NFSv4 export as a client.
No X server, display device, or graphical console is required.

On 2026-09-02 the launcher created standalone `out/testvm-root.qcow2` from
`out/rootfs.ext4` and completed two clean boots. The writable root,
provisioning, network, SSH, and reboot-persistence gates passed. `nfs-common`
and `mount.nfs4` are installed and the NFS server's TCP port is reachable, but
the mount itself is the sole incomplete P0 acceptance item.

The same day, a standalone clone at `out/testvm-debian-root.qcow2` was migrated
to Debian's stock `linux-image-arm64` package and completed two more clean
boots. This is now the validated generic-kernel profile; the original disk and
Asahi kernel/initramfs remain unchanged as a fallback.

This operational milestone takes priority over further upstream coordination.
If it exposes a QEMU or component bug, a focused fix may be merged into this
project's fork and used immediately; upstream review can proceed independently.

## P0 status

- [x] Create and validate standalone writable `out/testvm-root.qcow2` from the
  known bootable raw rootfs, with no backing or external data file.
- [x] Provision DHCP/DNS, `openssh-server`, and `nfs-common`; rerunning the
  provisioner on boot 2 succeeded.
- [x] Provide a repeatable serial-only launcher with unprivileged user-mode
  networking and loopback-only SSH forwarding.
- [x] Complete two clean boots and verify writable-root state, guest identity,
  SSH identity, DNS, HTTPS, and host-to-guest SSH persist or remain usable.
- [ ] Mount and read the selected read-only NFSv4.0 export, then unmount it
  cleanly. TCP reachability has passed; source-port policy still blocks mount.

## Launcher contract

The launcher entry point is `scripts/test-vm.sh`. Its required core interface
is:

- `scripts/test-vm.sh init` validates the source artifacts and creates
  `out/testvm-root.qcow2` as a standalone image. It must refuse to silently
  overwrite an existing persistent disk.
- `scripts/test-vm.sh run` boots the persistent disk read/write with HVF and
  `-cpu host`, using the exported kernel and initramfs. It uses `-nographic`
  with `console=ttyAMA0`; the serial terminal is the recovery and setup path.
- `scripts/test-vm.sh info` reports the resolved QEMU, kernel, initramfs, disk,
  CPU, memory, networking, and SSH-forward configuration without starting the
  guest.
- `TEST_VM_DISK` selects a qcow2 image directly under `out/`.
  `TEST_VM_KERNEL` and `TEST_VM_INITRD` select a matching external boot pair
  directly under `out/`; they must be set together. These explicit overrides
  allow a cloned disk to be tested without changing `out/KVER` or the default
  Asahi artifacts.
- `TEST_VM_QMP_SOCKET` optionally creates a QEMU Machine Protocol Unix socket
  directly under `out/`. `scripts/test-vm-console.sh` uses this private local
  control channel to verify state and request a clean guest power-down.

`scripts/test-vm-provision.sh` is the guest-side provisioning helper. The
launcher attaches it read-only; it may change the guest root filesystem, but
must not make a host directory writable to the guest.

After `init`, boot once with `run` and provision the guest once from the
read-only scripts partition:

```bash
mkdir -p /mnt/m3-scripts
mount -o ro /dev/vdb1 /mnt/m3-scripts
bash /mnt/m3-scripts/test-vm-provision.sh
```

The helper is idempotent; the second-boot rerun passed. Normal later boots do
not require rerunning it.

SSH is deliberately key-only. On a new image, bootstrap the host public key
through the serial console before relying on the port forward:

```bash
# Copy ~/.ssh/id_ed25519.pub on the host, then run this in the guest console.
install -d -m 0700 /root/.ssh
cat >> /root/.ssh/authorized_keys  # paste the public key, then press Ctrl-D
chmod 0600 /root/.ssh/authorized_keys
chown -R root:root /root/.ssh
```

Test a fresh
`ssh -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519 -p 22022 root@127.0.0.1`
session before detaching from the serial console. The provisioner sets
`PermitRootLogin prohibit-password`, `PasswordAuthentication no`, and
`KbdInteractiveAuthentication no`; rerunning it therefore cannot silently
restore password access.

The default disk is `out/testvm-root.qcow2`. A launcher may expose explicit
environment overrides such as `QEMU`, `SMP`, and `MEM`, but the resolved values
must be visible through `info`. A caller-provided disk path must still be a
regular project image, never an automatically inferred physical device.

## Network and NFS contract

The validated default network is a virtio NIC backed by QEMU's unprivileged
user-mode network stack, with both slirp IPv4 and IPv6 enabled:

```text
-netdev user,id=net0,ipv4=on,ipv6=on,hostfwd=tcp:127.0.0.1:22022-:22
-device virtio-net-pci,netdev=net0
```

This gives the guest a DHCP-configured private address, outbound connectivity,
and host access to SSH at `127.0.0.1:22022`, without TAP setup, root privileges,
bridging, or a vmnet entitlement. The SSH listener must not bind all host
interfaces by default. Lowercase `ssh -p` selects the forwarded port; uppercase
`-P` does not select the port for OpenSSH `ssh`.

The guest received `10.0.2.15` by DHCP. DNS, an HTTPS request returning HTTP/2
200, and host SSH all succeeded. TCP connection to `10.0.0.229:2049` also
succeeded.

The remaining NFS gate uses the read-only NFSv4.0 export
`10.0.0.229:/tank/nfs`. Its mount currently fails with `EPERM`: the server
requires a secure/reserved client source port, while libslirp NAT does not
preserve that reserved source port. Mounting the same export from the host with
`resvport` succeeds, isolating the failure from server reachability and export
availability.

Two possible next paths remain open, without a choice yet:

- narrowly allow non-reserved source ports server-side for this test export;
  or
- build and sign QEMU's `vmnet-bridged` backend and authorize the guest's LAN
  address at the server. `vmnet-shared` remains NAT and does not supply the
  direct LAN identity needed by that alternative.

## Recorded two-boot result

Both boots used the launcher-selected
`out/qemu-fork-pmintenclr-build/qemu-system-aarch64` (QEMU 11.1.50), 8 vCPUs,
8 GiB RAM, direct `Image`/initrd boot, HVF `-cpu host`, a serial-only console,
the persistent qcow2 root, slirp IPv4/IPv6, loopback SSH port 22022, and a
read-only vvfat scripts disk.

On both boots `/dev/vda` was the read/write ext4 root. After clean shutdown and
boot 2, all three persistent identities matched boot 1:

- sentinel: `persistent-test-vm-boot1`;
- machine ID: `d787e1e0488a47cdae92859fc0658024`; and
- ED25519 host-key fingerprint:
  `SHA256:GmLXWdNFQiMX0nTWzPlGjHCK3a4gEIVoovvclbFFc0w`.

The provisioner was safely rerun on boot 2. DHCP `10.0.2.15`, DNS, HTTPS
HTTP/2 200, and host SSH succeeded. NFS package/tool installation and TCP/2049
reachability succeeded; only the actual NFSv4.0 mount remains incomplete.

The launcher did not use QEMU `-snapshot`. Probe and benchmark launchers remain
disposable by design and do not satisfy the persistence gate.

## Stock Debian kernel result

The generic-kernel profile is:

```bash
TEST_VM_DISK=out/testvm-debian-root.qcow2 \
TEST_VM_KERNEL=out/Image-7.1.12+deb14-arm64 \
TEST_VM_INITRD=out/initrd.img-7.1.12+deb14-arm64 \
./scripts/test-vm.sh run
```

The clone contains the matching `linux-image`, `linux-modules`, and `linux-base`
packages for `7.1.12+deb14-arm64`. Its initramfs was regenerated after
installing `e2fsprogs`; it contains `virtio_blk`, ext4, and `fsck.ext4`.
The exported `vmlinuz` is already an uncompressed ARM64 `Image` with 4K pages.

Both stock-kernel boots reached `systemctl is-system-running = running` with
`/dev/vda` mounted read/write as ext4. Boot 2 retained the boot-1 sentinel,
machine ID `d787e1e0488a47cdae92859fc0658024`, and SSH host identity. DHCP assigned
`10.0.2.15`; DNS, HTTPS, and host-to-guest SSH on the loopback forward passed.
`mount.nfs4` remained installed and TCP/2049 remained reachable. The known
libslirp reserved-source-port limitation is unchanged and is not kernel-related.

This confirms that the QEMU `virt` VM does not require an Asahi kernel. QEMU
provides standardized virtual devices; Asahi's Apple SoC and board support is
needed for the separately deferred bare-metal path.

### Reproducing the stock-kernel profile

The migration deliberately works on a standalone clone. With all VMs powered
off, create it without overwriting an existing target:

```bash
test ! -e out/testvm-debian-root.qcow2
test ! -e out/testvm-debian-root.qcow2.tmp
/opt/homebrew/bin/qemu-img convert -p -f qcow2 -O qcow2 \
  out/testvm-root.qcow2 out/testvm-debian-root.qcow2.tmp
mv -n out/testvm-debian-root.qcow2.tmp out/testvm-debian-root.qcow2
/opt/homebrew/bin/qemu-img check out/testvm-debian-root.qcow2
```

Boot that clone once with the existing Asahi artifacts and a separate SSH
forward:

```bash
TEST_VM_DISK=out/testvm-debian-root.qcow2 \
TEST_VM_KERNEL=out/Image-7.1.10+deb14-asahi \
TEST_VM_INITRD=out/initrd.img-7.1.10+deb14-asahi \
SSH_PORT=22023 \
./scripts/test-vm.sh run
```

Inside the clone, install Debian's generic kernel and regenerate its initramfs
with an ext4 checker present:

```bash
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends linux-image-arm64 e2fsprogs
kver="$(basename "$(readlink -f /vmlinuz)")"
kver="${kver#vmlinuz-}"
printf 'VERSION=%s\n' "$kver"
update-initramfs -u -k "$kver"
```

While that bootstrap boot remains running, export the matching pair from the
host. Replace `VERSION` with the value of `kver` printed in the guest:

```bash
test ! -e out/vmlinuz-VERSION
test ! -e out/initrd.img-VERSION
test ! -e out/Image-VERSION
scp -P 22023 root@127.0.0.1:/boot/vmlinuz-VERSION out/vmlinuz-VERSION
scp -P 22023 root@127.0.0.1:/boot/initrd.img-VERSION out/initrd.img-VERSION
file out/vmlinuz-VERSION
cp -p -n out/vmlinuz-VERSION out/Image-VERSION
```

The `file` check must identify an ARM64 boot executable `Image`; do not copy a
compressed kernel under the `Image-` name. Shut the guest down cleanly, check
the qcow2 image again, and then use the generic-kernel launch command above.

### Daily console control

The stock-kernel VM can run independently of the terminal that started it:

```bash
./scripts/test-vm-console.sh start
./scripts/test-vm-console.sh status
./scripts/test-vm-console.sh console
./scripts/test-vm-console.sh stop
```

`connect` is an alias for `console`. The controller starts the existing
launcher inside a detached tmux session, so the launcher's lock and QEMU's
exclusive qcow2 lock remain held for the VM's complete lifetime. It creates a
Unix QMP socket at `out/.testvm-debian-qmp.sock`; `stop` sends QEMU's
`system_powerdown` request over QMP and waits for a guest-originated `SHUTDOWN`
event before asking QEMU itself to exit. If `stop` is interrupted after that
event, running `stop` again completes the held QEMU exit. The controller does
not fall back to killing QEMU if shutdown fails.

From outside tmux, leave the console with `Ctrl-B d`. From an existing tmux
client, the controller switches to the VM session; use `Ctrl-B L` to return to
the previous session. Either action leaves the VM running. `Ctrl-A X` remains
QEMU's immediate-exit sequence and should be reserved for recovery because it
does not perform an orderly guest shutdown.

## Safety boundary

This VM is QEMU `virt` plus virtual devices. It does not emulate or boot an
Apple machine and must not receive:

- an IPSW, Apple firmware bundle, UEFI firmware, or writable NVRAM;
- m1n1, an Apple boot object, boot-policy state, or installer metadata;
- a host block device, raw physical disk, internal SSD partition, system
  volume, or arbitrary device passthrough; or
- a writable host directory merely to transfer the provisioning helper.

Direct kernel/initramfs boot, a project-owned qcow2 disk, a read-only helper
attachment, the emulated virtio devices, and user-mode networking are the whole
machine boundary. `init` must fail closed rather than replace an existing disk,
and `run` must fail clearly if required project artifacts are absent.

## Later work

- P1 continues M3 Ultra CPU-model correctness and fork maintenance using the
  already captured feature, PMU, and performance evidence. Upstream QEMU email
  review is desirable but non-blocking for this VM.
- P2 repeats the CPU contract independently on M5 Max; it must not be treated as
  evidence for M3 Ultra or as a prerequisite for the P0 VM.
- Native `t6032`/m1n1 work remains deferred and retains its separate
  no-firmware/no-physical-device safety gate.

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
interfaces by default.

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

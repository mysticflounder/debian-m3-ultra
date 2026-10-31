# Persistent Headless Test VM Plan

## Goal and current status

P0 is a long-lived Debian guest for ordinary development and regression work.
It must keep changes across clean shutdowns and reboots, have outbound network
and DNS access, accept SSH from the host, and mount an NFSv4 export as a client.
No X server, display device, or graphical console is required.

On 2026-09-02 the launcher created standalone `out/testvm-root.qcow2` from
`out/rootfs.ext4` and completed two clean boots. The writable root,
provisioning, network, SSH, and reboot-persistence gates passed. On 2026-09-03
a second virtio NIC backed by `vmnet-bridged` gave the guest a LAN address, and
the NFS mount/read/hash/unmount gate passed. P0 is complete.

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
- [x] Provide a repeatable serial-only launcher with a bridged LAN/NFS NIC and
  a separate user-mode NIC for loopback-only management SSH.
- [x] Complete two clean boots and verify writable-root state, guest identity,
  SSH identity, DNS, HTTPS, and host-to-guest SSH persist or remain usable.
- [x] Mount and read the selected read-only NFSv4.0 export, then unmount it
  cleanly through the bridged NIC.

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
- `VMNET_IFNAME` selects the physical bridge interface and defaults to `en0`.
  With the default `VMNET_USE_SUDO=1`, startup authorizes vmnet creation with
  `sudo`, passes `-run-with user=UID:GID`, and transfers the QMP socket back to
  the invoking user. QEMU opens its fixed startup resources while privileged,
  then long-running guest execution and disk I/O occur as the invoking user.
  The console controller requests authorization; before a non-interactive
  direct `scripts/test-vm.sh run`, authorize once with `sudo -v`.

Recreate the vmnet-enabled fork build with:

```bash
./scripts/build-qemu-vmnet.sh
```

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

The validated network has two virtio NICs with fixed MAC addresses:

```text
-netdev user,id=mgmt,ipv4=on,ipv6=on,hostfwd=tcp:127.0.0.1:22022-:22
-device virtio-net-pci,netdev=mgmt,mac=52:54:00:12:34:56
-netdev vmnet-bridged,id=lan,ifname=en0
-device virtio-net-pci,netdev=lan,mac=52:54:00:12:34:57
```

The first NIC remains a stable management path: private DHCP, outbound access,
and host SSH at `127.0.0.1:22022`. The second NIC is bridged to the physical LAN
for NFS and other protocols that require an independent LAN identity. The SSH
forward remains loopback-only. Lowercase `ssh -p` selects its port; uppercase
`-P` does not select the port for OpenSSH `ssh`.

The management NIC received `10.0.2.15`; the bridged NIC received
`10.0.0.98/24`. The route to `10.0.0.229` uses the bridged NIC directly. DNS,
HTTPS, host SSH, and TCP connection to NFS port 2049 all succeed.

The NFS gate uses the read-only NFSv4.0 export `10.0.0.229:/tank/nfs`. It failed
with `EPERM` over libslirp because the server requires a secure/reserved client
source port and NAT did not preserve it. The separate QEMU build at
`out/qemu-fork-vmnet-build/qemu-system-aarch64` enables `vmnet.framework`; QEMU
creates the bridge during a short root window and then drops to the invoking
UID/GID. No server policy change was needed.

Run the fail-closed acceptance gate with:

```bash
./scripts/test-vm-nfs.sh
```

It runs inside a private guest mount namespace, creates a one-run mount
directory, and requests NFSv4.0 read-only with `resvport` and bounded retry
behavior. It verifies the resulting source/type/options, reads and hashes
`pdz.html` under deadlines, and unmounts anything the run mounted on both
success and later validation failure. SSH must already have the VM host key in
`known_hosts`; the script will not accept a new host key automatically.

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
HTTP/2 200, and host SSH succeeded. The later bridged-NIC acceptance run
mounted the NFSv4.0 export, read and hashed `pdz.html`, and unmounted cleanly.

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
`mount.nfs4` remained installed and TCP/2049 remained reachable. Bridging the
second NIC resolved libslirp's reserved-source-port limitation without a
kernel or server-policy change.

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
attachment, emulated virtio devices, loopback-only management NAT, and one
vmnet bridge are the whole machine boundary. QEMU's short root startup opens
only those fixed resources and creates vmnet; it drops to the invoking user
before guest execution. `init` must fail closed rather than replace an existing
disk, and `run` must fail clearly if required project artifacts are absent.

## Separate portable UEFI image (2026-10-12 local)

`out/debian-portable.qcow2` is a new standalone GPT disk, built from an
independent copy of the stopped stock-kernel VM. The original images were
not modified. Unlike the direct-kernel P0 profile above, this separately
authorized profile uses QEMU's AArch64 EDK2 firmware and a **file-backed**
private UEFI variable store, not Mac firmware or host NVRAM.

The image has a 1,999,634,432-byte FAT32 ESP and a 119,999,037,440-byte
ext4 root partition. Its virtual disk size is 122,010,000,384 bytes; qcow2
allocation is roughly 1.66 GB after validation. It contains Debian forky/sid,
GRUB 2.14-4 and defaults to the existing generic `7.1.12+deb14-arm64` kernel.
The older Asahi kernel remains an alternate entry, not a native-boot claim.

Run it with `./scripts/portable-vm.sh run`; inspect the offline configuration
with `./scripts/portable-vm.sh info`. Bridge setup may require `sudo -v`.
Connect using `ssh -p 22025 -o UserKnownHostsFile=out/portable-known-hosts
root@127.0.0.1` (one command). Your existing authorized public key is retained;
password authentication is disabled. The image has a fresh machine ID and
SSH host keys. Shut down with `systemctl poweroff` inside the guest.

The launcher uses 4 vCPUs, 4 GB RAM, HVF, unique NIC MAC addresses, bridged
`en0`, and a loopback-only management forward. It does not pass a host kernel
or initrd. `PORTABLE_VM_SERIAL_LOG=unique-name.log` records the console under
`out/`; otherwise the console stays on the terminal. The image and variable
store are personal VM state; do not publish them or start simultaneous clones
with the same identities/MAC addresses.

Two cold UEFI/GRUB boots passed root/ESP mounts, key-only SSH, DNS, HTTPS,
saved-file persistence, stable machine/SSH identity and clean shutdown.
Direct bridged SSH also passed. Final qcow2 check reported no errors. Receipts
are `out/portable-build.log`, `out/portable-acceptance-boot{1,2}.txt`, and
`out/portable-boot{1,2}.log`. The image was left powered off.

`scripts/prepare-portable-root-guest.sh` builds only inside the designated
temporary helper, with a blank serial/size-checked image disk; it is not a
physical-partition installer. `scripts/check-portable-root-guest.sh` provides
the record/verify acceptance checks. No physical partitions were created.
Transferring the individual filesystems, Apple boot-stub provisioning, native
drivers and physical M3 Ultra boot validation remain separate work.

## M5 Max working VM (2026-10-22)

The MacBook's retained `out/m5-vm/debian-arm64.qcow2` contains Debian forky/sid
and matches the retained generic `7.1.13+deb14-arm64` kernel/initrd. Its qcow2
header was dirty with lazy reference counts enabled, and the initial read-only
check reported 2,392 errors. An independent APFS copy was created at
`out/m5-working/debian-arm64.qcow2`. QEMU's reference-count repair fixed 1,196
inconsistencies on that copy; subsequent offline checks reported zero errors.
The retained original's SHA-256 was verified unchanged. QEMU documents this
repair behavior under [qemu-img check and lazy reference counts](https://www.qemu.org/docs/master/tools/qemu-img.html).

The working VM uses Homebrew QEMU 11.1.1, HVF, four vCPUs, 4 GB RAM and a
120 GiB standalone writable disk. The host currently runs macOS 27.0.1
(26A434). It boots the generic kernel directly; the separately prepared M3
UEFI image is not present on this MacBook. Networking uses QEMU user networking
with management SSH bound to `127.0.0.1:22026`.

```bash
./scripts/m5-vm.sh start     # detached; waits for SSH readiness
./scripts/m5-vm.sh ssh       # root, using the existing authorized host key
./scripts/m5-vm.sh status
./scripts/m5-vm.sh console   # press Enter; Ctrl-C disconnects
./scripts/m5-vm.sh stop      # clean guest poweroff
```

`run` provides a foreground console instead of a detached VM. `info` prints
the configuration. `SMP`, `MEM`, `M5_VM_SSH_PORT`, `QEMU` and `QEMU_IMG` can
override launch defaults; use the same port setting for subsequent commands.
The launcher checks disk integrity before starting and refuses concurrent
disk use through QEMU's disk and PID-file locks. Serial output appends to
`out/m5-working/console.log`.

Acceptance passed key-authenticated SSH, disabled password/keyboard-interactive
authentication, four online CPUs, writable root, DNS, outbound HTTPS, serial
command execution, a clean shutdown/cold start and an in-process guest reboot.
The saved marker, machine ID and SSH host-key fingerprint survived the cold
boot. No failed systemd services were reported. The launcher also passed clean
stop/start and repeated-start checks. The VM was left running. The existing
guest VNC service remains on guest loopback port 5901; desktop access was not
tested. Bridged LAN/NFS and the full M5 CPU-feature contract remain unqualified.

Receipts are under `out/m5-working/`: `image-repair.json`, `image-check*.json`,
`original-image.sha256`, `acceptance-boot{1,2}.txt`, `reboot-acceptance.txt` and
`console.log`. The tracked [M5 VM inventory](inventory/m5-vm-2026-10-22.json)
records the configuration and acceptance scope.

### M5 package and NFS setup (2026-10-31)

The M5 VM has Vim, unattended upgrades and `ferm-nftables`; nano is removed.
APT update and upgrade completed, and an unattended-upgrade dry run accepted
the Debian Sid, Bananas and mysticflounder origins. The signed mysticflounder
Sid repository currently has an empty ARM64 index. A narrowly pinned Trixie
fallback permits only `ferm-nftables`: version `2.9~1785110799` declares
`Architecture: all` and passed install, parse, nftables apply and flush tests
in a disposable ARM64 VM. The working VM has the package installed but its
firewall service is not enabled. The rootfs and builder provisioning paths
install these defaults and configure the signed repository.

The guest's `/opt/nfs` is configured as a systemd automount for the Mac's
`10.0.0.229:/tank/nfs` export. NFS over QEMU user networking reached the
server but the mount was rejected. A LAN bridge requires macOS administrator
authorization; run `./scripts/m5-vm-enable-nfs.sh` in a terminal to authorize
vmnet, restart the VM with a bridged NIC and verify the mount. The helper
enables the bridge for future starts only after the mount passes. This bridge
and mount have not yet been validated on this host.

The launcher loads its kernel and initrd from `out/m5-vm`, outside the guest
disk. APT can install newer guest kernels, but it does not update those host
files automatically. On 2026-10-31 the guest had `7.2.14+deb14-arm64`
installed while the running and launcher-selected kernel was
`7.1.13+deb14-arm64`; switching the boot files requires a separate verified
update.

## Later work

- P1 continues M3 Ultra CPU-model correctness and fork maintenance using the
  already captured feature, PMU, and performance evidence. Upstream QEMU email
  review is desirable but non-blocking for this VM.
- P2 repeats the CPU contract independently on M5 Max; it must not be treated as
  evidence for M3 Ultra or as a prerequisite for the P0 VM.
- Native `t6032`/m1n1 work remains deferred and retains its separate
  no-firmware/no-physical-device safety gate.

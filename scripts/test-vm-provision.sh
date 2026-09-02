#!/bin/bash
# Idempotently prepare the persistent QEMU test VM for headless network use.
# Run as root inside the guest from the read-only scripts disk.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "test-vm-provision: run this script as root" >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
BUILD_CHROOT="${TEST_VM_BUILD_CHROOT:-0}"

case "$BUILD_CHROOT" in
    0|1) ;;
    *)
        echo "test-vm-provision: TEST_VM_BUILD_CHROOT must be 0 or 1" >&2
        exit 2
        ;;
esac

systemd_is_running() {
    [ -d /run/systemd/system ] && [ "$(cat /proc/1/comm 2>/dev/null || true)" = "systemd" ]
}

dns_resolves() {
    timeout 10 getent ahosts deb.debian.org >/dev/null 2>&1
}

echo "==> configure systemd-networkd DHCP"
install -d -m 0755 /etc/systemd/network
cat > /etc/systemd/network/20-qemu-wired.network <<'EOF'
[Match]
Name=en* eth*

[Network]
DHCP=yes
IPv6AcceptRA=yes

[DHCPv4]
UseDNS=yes
EOF

systemctl enable systemd-networkd.service systemd-networkd-wait-online.service
if systemd_is_running; then
    systemctl restart systemd-networkd.service
fi

# QEMU user networking provides IPv6 and IPv4 DNS proxies.  Prefer the IPv6
# proxy because it also works when macOS has only IPv6 upstream resolvers;
# retain the IPv4 proxy for hosts with IPv4-only DNS.  These bootstrap package
# installation before systemd-resolved is present/running.
if [ "$BUILD_CHROOT" -eq 0 ] && ! dns_resolves; then
    echo "==> bootstrap DNS through QEMU user networking"
    rm -f /etc/resolv.conf
    printf 'nameserver fec0::3\nnameserver 10.0.2.3\noptions timeout:2 attempts:2\n' \
        > /etc/resolv.conf
fi

if [ "$BUILD_CHROOT" -eq 0 ] && systemd_is_running; then
    dns_ready=0
    for _ in $(seq 1 30); do
        if dns_resolves; then
            dns_ready=1
            break
        fi
        sleep 1
    done
    [ "$dns_ready" -eq 1 ] || {
        echo "test-vm-provision: DHCP or DNS did not become ready" >&2
        exit 1
    }
fi

echo "==> install headless network, SSH, and NFS client packages"
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    iproute2 \
    iputils-ping \
    netcat-openbsd \
    netbase \
    nfs-common \
    openssh-server \
    systemd-resolved

echo "==> configure persistent DNS and SSH"
systemctl enable systemd-resolved.service ssh.service
ln -sfn ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# The host forwarding rule is bound to 127.0.0.1.  Password login is enabled
# for this local test appliance so the root/root image credentials remain
# usable until the operator installs an SSH public key.
install -d -m 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/90-m3-test-vm.conf <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
EOF

ssh-keygen -A
if systemd_is_running; then
    systemctl restart systemd-resolved.service
    systemctl restart systemd-networkd.service
    systemctl restart ssh.service
fi

echo "==> provisioning complete"
echo "    SSH is enabled; nfs-common and minimal diagnostic tools are installed."

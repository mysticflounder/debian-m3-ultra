#!/bin/bash
# Configure the Mac's NFS export as an on-demand mount in the guest.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run as root" >&2; exit 1; }
mkdir -p /opt/nfs
cat > /etc/systemd/system/opt-nfs.mount <<'EOF'
[Unit]
Description=Mac NFS share
Wants=network-online.target
After=network-online.target

[Mount]
What=10.0.0.229:/tank/nfs
Where=/opt/nfs
Type=nfs
Options=vers=4.0,rw,resvport,_netdev
TimeoutSec=20
EOF
cat > /etc/systemd/system/opt-nfs.automount <<'EOF'
[Unit]
Description=Automount Mac NFS share

[Automount]
Where=/opt/nfs
TimeoutIdleSec=600

[Install]
WantedBy=multi-user.target
EOF
systemd-analyze verify /etc/systemd/system/opt-nfs.mount /etc/systemd/system/opt-nfs.automount
systemctl daemon-reload
systemctl enable --now opt-nfs.automount

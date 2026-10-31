#!/bin/bash
# Enable a LAN bridge and verify the Mac's NFS export in the M5 VM.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
VM="$HERE/scripts/m5-vm.sh"
MARKER="$HERE/out/m5-working/bridge-enabled"

[ -t 0 ] || { echo "Run this command in a terminal to authorize vmnet." >&2; exit 1; }
sudo -v
"$VM" ssh bash -s < "$HERE/scripts/configure-m5-nfs-guest.sh"
"$VM" stop
if ! M5_VM_BRIDGE=1 "$VM" start; then
    echo "Bridged startup failed; restarting the VM without a bridge." >&2
    M5_VM_BRIDGE=0 "$VM" start || true
    exit 1
fi
if ! "$VM" ssh 'timeout 30 ls /opt/nfs >/dev/null && findmnt -T /opt/nfs -t nfs,nfs4'; then
    echo "The bridged VM started, but the NFS export did not mount." >&2
    exit 1
fi
touch "$MARKER"
echo "NFS is mounted at /opt/nfs. Future starts will use the LAN bridge."

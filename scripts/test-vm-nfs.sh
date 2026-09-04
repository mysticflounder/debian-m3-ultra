#!/bin/bash
# Run the persistent VM's read-only NFSv4 acceptance gate over SSH.
set -euo pipefail

SSH_BIN="${SSH_BIN:-/usr/bin/ssh}"
SSH_IDENTITY="${SSH_IDENTITY:-$HOME/.ssh/id_ed25519}"
SSH_PORT_VALUE="${SSH_PORT:-22022}"

fail() {
    echo "test-vm-nfs: $*" >&2
    exit 1
}

[ -x "$SSH_BIN" ] || fail "ssh is not executable: $SSH_BIN"
[ -r "$SSH_IDENTITY" ] || fail "SSH identity is not readable: $SSH_IDENTITY"
case "$SSH_PORT_VALUE" in
    ""|*[!0-9]*) fail "SSH_PORT must be an integer from 1 through 65535" ;;
esac
[ "$SSH_PORT_VALUE" -ge 1 ] && [ "$SSH_PORT_VALUE" -le 65535 ] ||
    fail "SSH_PORT must be an integer from 1 through 65535"

"$SSH_BIN" \
    -o BatchMode=yes \
    -o ConnectionAttempts=1 \
    -o ConnectTimeout=10 \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes \
    -i "$SSH_IDENTITY" \
    -p "$SSH_PORT_VALUE" \
    root@127.0.0.1 'exec unshare --mount --propagation private bash -s' <<'GUEST'
set -euo pipefail

source_path="10.0.0.229:/tank/nfs"
mount_dir=""
probe_relative="pdz.html"
mount_attempted=0

fail() {
    echo "test-vm-nfs: $*" >&2
    exit 1
}

cleanup() {
    local status=$?
    local cleanup_failed=0
    local mount_status
    local mounted_source=""
    local source_is_expected=0

    trap - EXIT HUP INT TERM
    set +e
    if [ -n "$mount_dir" ] && [ -d "$mount_dir" ]; then
        mountpoint -q "$mount_dir"
        mount_status=$?
        if [ "$mount_status" -eq 0 ]; then
            mounted_source="$(findmnt -n -o SOURCE --target "$mount_dir" 2>/dev/null)"
            case "$mounted_source" in
                "$source_path"|"[10.0.0.229]:/tank/nfs") source_is_expected=1 ;;
                *) source_is_expected=0 ;;
            esac
            if [ "$mount_attempted" -eq 1 ] && [ "$source_is_expected" -eq 1 ]; then
                if ! timeout --kill-after=5s 10s umount "$mount_dir"; then
                    echo "test-vm-nfs: failed to unmount owned NFS mount: $mount_dir" >&2
                    cleanup_failed=1
                else
                    mountpoint -q "$mount_dir"
                    mount_status=$?
                    if [ "$mount_status" -eq 0 ]; then
                        echo "test-vm-nfs: owned NFS mount remains active: $mount_dir" >&2
                        cleanup_failed=1
                    elif [ "$mount_status" -ne 32 ]; then
                        echo "test-vm-nfs: could not verify cleanup unmount: $mount_dir" >&2
                        cleanup_failed=1
                    fi
                fi
            else
                echo "test-vm-nfs: refusing to unmount an unexpected mount at $mount_dir: $mounted_source" >&2
                cleanup_failed=1
            fi
        elif [ "$mount_status" -ne 32 ]; then
            echo "test-vm-nfs: could not determine cleanup mount state: $mount_dir" >&2
            cleanup_failed=1
        fi
        rmdir "$mount_dir" 2>/dev/null || true
    fi
    if [ "$cleanup_failed" -ne 0 ]; then
        exit 1
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[ "$(id -u)" -eq 0 ] || fail "guest command must run as root"
for command_name in awk findmnt mktemp mount mountpoint sha256sum timeout umount wc; do
    command -v "$command_name" >/dev/null 2>&1 ||
        fail "guest command not found: $command_name"
done

mount_dir="$(mktemp -d /run/test-vm-nfs.XXXXXX)" ||
    fail "could not create a private mount directory"
set +e
mountpoint -q "$mount_dir"
mount_status=$?
set -e
case "$mount_status" in
    32) ;;
    0) fail "new private directory is unexpectedly a mount point: $mount_dir" ;;
    *) fail "could not determine initial mount state: $mount_dir" ;;
esac

echo "==> mounting $source_path read-only over NFSv4.0"
mount_attempted=1
if ! timeout --kill-after=5s 20s mount -t nfs4 \
    -o ro,resvport,soft,timeo=50,retrans=2,vers=4.0,proto=tcp \
    "$source_path" "$mount_dir"; then
    fail "NFS mount failed"
fi

mount_source="$(findmnt -n -o SOURCE --target "$mount_dir")"
mount_fstype="$(findmnt -n -o FSTYPE --target "$mount_dir")"
mount_options="$(findmnt -n -o OPTIONS --target "$mount_dir")"
case "$mount_source" in
    "$source_path"|"[10.0.0.229]:/tank/nfs") ;;
    *) fail "unexpected NFS source: $mount_source" ;;
esac
case "$mount_fstype" in
    nfs|nfs4) ;;
    *) fail "unexpected filesystem type: $mount_fstype" ;;
esac
# Linux accepts resvport above but does not expose that implicit transport
# choice in findmnt.  The server's secure-port policy is the effective check.
for required_option in ro soft timeo=50 retrans=2 vers=4.0 proto=tcp; do
    case ",$mount_options," in
        *,"$required_option",*) ;;
        *) fail "NFS mount lacks $required_option: $mount_options" ;;
    esac
done

probe_path="$mount_dir/$probe_relative"
[ ! -L "$probe_path" ] && [ -f "$probe_path" ] ||
    fail "expected probe file is unavailable: $probe_relative"
probe_size="$(timeout --kill-after=5s 20s wc -c "$probe_path" | awk '{print $1}')" ||
    fail "timed out reading probe size: $probe_relative"
probe_sha256="$(timeout --kill-after=5s 20s sha256sum "$probe_path" | awk '{print $1}')" ||
    fail "timed out hashing probe file: $probe_relative"
echo "read: $probe_relative bytes=$probe_size sha256=$probe_sha256"

timeout --kill-after=5s 10s umount "$mount_dir" || fail "NFS unmount failed"
set +e
mountpoint -q "$mount_dir"
mount_status=$?
set -e
case "$mount_status" in
    32) mount_attempted=0 ;;
    0) fail "mount remains active after unmount" ;;
    *) fail "could not verify NFS unmount" ;;
esac
echo "NFS_TEST=pass"
GUEST

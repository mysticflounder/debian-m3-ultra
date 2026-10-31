#!/bin/bash
# Configure the signed mysticflounder APT repository inside a guest.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run as root" >&2; exit 1; }
command -v curl >/dev/null
command -v gpg >/dev/null

# Debian development snapshots can report forky in os-release even though
# their configured APT suite is sid. The repository publishes sid, not forky.
if grep -q '/sid$' /etc/debian_version; then
    CODENAME=sid
else
    . /etc/os-release
    CODENAME="${VERSION_CODENAME:-}"
fi
case "$CODENAME" in
    bullseye|bookworm|trixie|sid|focal|jammy|noble|oracular) ;;
    *) echo "Unsupported mysticflounder repository codename: $CODENAME" >&2; exit 1 ;;
esac

TASK_DIR="$(mktemp -d)"
trap 'rm -rf "$TASK_DIR"' EXIT
curl -fsSL https://debrepo.mysticflounder.com/gpg/repo-signing-key.gpg > "$TASK_DIR/key.asc"
gpg --batch --yes --dearmor -o "$TASK_DIR/key.gpg" "$TASK_DIR/key.asc"
install -d /usr/share/keyrings /etc/apt/sources.list.d
install -m 0644 "$TASK_DIR/key.gpg" /usr/share/keyrings/mysticflounder.gpg
printf 'deb [signed-by=/usr/share/keyrings/mysticflounder.gpg] https://debrepo.mysticflounder.com %s main\n' "$CODENAME" > /etc/apt/sources.list.d/mysticflounder.list
if [ "$CODENAME" = sid ]; then
    # The repository currently publishes ferm-nftables for trixie only.
    # Permit that package without mixing the rest of the trixie repository
    # into a sid VM.
    install -d /etc/apt/preferences.d
    printf 'deb [signed-by=/usr/share/keyrings/mysticflounder.gpg] https://debrepo.mysticflounder.com trixie main\n' > /etc/apt/sources.list.d/mysticflounder-ferm-fallback.list
    cat > /etc/apt/preferences.d/mysticflounder-ferm-fallback <<'EOF'
Package: ferm-nftables
Pin: release o=mysticflounder,n=trixie
Pin-Priority: 500

Package: *
Pin: release o=mysticflounder,n=trixie
Pin-Priority: -1
EOF
fi
echo "Configured mysticflounder APT repository for $CODENAME"

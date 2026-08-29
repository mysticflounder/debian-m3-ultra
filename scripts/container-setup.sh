#!/bin/bash
# Runs INSIDE a debian:unstable arm64 container.
# Adds the Debian Bananas archive, installs build deps, fetches linux-asahi source.
set -euo pipefail

SUITE="${SUITE:-unstable-bananas}"
SRC="${SRC:-linux-asahi}"
BUILD_DIR="${BUILD_DIR:-/build}"

echo "==> apt bootstrap"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends ca-certificates curl >/dev/null

echo "==> add bananas archive ($SUITE)"
install -d /etc/apt/keyrings
curl -fsSL -o /etc/apt/keyrings/bananas-archive-keyring.gpg \
  https://bananas-archive.debian.net/bananas-archive/bananas-archive-keyring.gpg

cat > /etc/apt/sources.list.d/bananas.sources <<EOF
Types: deb deb-src
URIs: https://bananas-archive.debian.net/bananas-archive
Suites: $SUITE
Components: main
Signed-By: /etc/apt/keyrings/bananas-archive-keyring.gpg
EOF

printf 'Package: *\nPin: release a=%s\nPin-Priority: 1050\n' "$SUITE" \
  > /etc/apt/preferences.d/bananas.pref

# The base image ships deb-only sources; source packages need deb-src too.
if [ -f /etc/apt/sources.list.d/debian.sources ]; then
    sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources
fi

apt-get update -qq
echo "==> linux-asahi versions available"
apt-cache policy "$SRC" || true
apt-cache showsrc "$SRC" 2>/dev/null | grep -m1 '^Version:' || true

echo "==> install build dependencies"
apt-get install -y --no-install-recommends \
    build-essential fakeroot devscripts quilt dpkg-dev >/dev/null
apt-get build-dep -y "$SRC"

echo "==> fetch source into $BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
apt-get source "$SRC"

echo "==> done"
ls -d "$BUILD_DIR"/${SRC}-* 2>/dev/null || ls "$BUILD_DIR"

#!/bin/bash
# Compile and run the read-only Hypervisor.framework host CPU collector.
#
#   ./scripts/cpu-probe-host.sh
#
# Environment: CC, QEMU, BIN, JSON_OUT, HOST_CPU_NAME (fallback override).
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/out"
CC="${CC:-clang}"
QEMU="${QEMU:-/opt/homebrew/bin/qemu-system-aarch64}"
BIN="${BIN:-$OUT/hvf-host-cpu}"
JSON_OUT="${JSON_OUT:-$OUT/cpu-probe-host.json}"
RAW="$OUT/.cpu-probe-host-raw.$$"
FINAL="$OUT/.cpu-probe-host-final.$$"

cleanup() {
    rm -f "$RAW" "$FINAL"
}
trap cleanup EXIT

mkdir -p "$OUT"

"$CC" -std=c11 -Wall -Wextra -Wpedantic -Werror -O2 \
    "$HERE/scripts/hvf-host-cpu.c" \
    -framework Hypervisor \
    -o "$BIN"

PROBE_STATUS=0
"$BIN" > "$RAW" || PROBE_STATUS=$?

MACOS_VERSION="$(sw_vers -productVersion)"
MACOS_BUILD="$(sw_vers -buildVersion)"
HOST_CPU="${HOST_CPU_NAME:-}"
if [ -z "$HOST_CPU" ] &&
   ! HOST_CPU="$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"; then
    HOST_CPU="$(uname -m)"
fi
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
QEMU_VERSION="$($QEMU --version | head -1)"

jq \
    --arg macos_version "$MACOS_VERSION" \
    --arg macos_build "$MACOS_BUILD" \
    --arg host_cpu "$HOST_CPU" \
    --arg sdk_version "$SDK_VERSION" \
    --arg qemu_version "$QEMU_VERSION" \
    '. + {
        host: {
            cpu: $host_cpu,
            macos_version: $macos_version,
            macos_build: $macos_build,
            sdk_version: $sdk_version,
            qemu_version: $qemu_version
        }
    }' \
    "$RAW" > "$FINAL"

if ! jq -e '
    type == "object" and
    .schema_version == 1 and
    (.config | type == "object") and
    (.host | type == "object") and
    (.feature_registers | type == "array") and
    (.ccsidr_el1 | type == "array")
' "$FINAL" >/dev/null; then
    echo "host probe did not produce the expected JSON schema" >&2
    exit 1
fi

mv "$FINAL" "$JSON_OUT"
echo "host CPU fingerprint: $JSON_OUT"

if [ "$PROBE_STATUS" -ne 0 ]; then
    echo "one or more HVF queries failed; preserved all results in $JSON_OUT" >&2
    exit "$PROBE_STATUS"
fi

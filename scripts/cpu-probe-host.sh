#!/bin/bash
# Compile and run the read-only Hypervisor.framework host CPU collector.
#
#   ./scripts/cpu-probe-host.sh
#
# Environment: CC, QEMU, BIN, JSON_OUT, HOST_CPU_NAME (fallback override).
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
OUT="$HERE/out"
CC="${CC:-clang}"
QEMU="${QEMU:-/opt/homebrew/bin/qemu-system-aarch64}"
BIN_INPUT="${BIN:-$OUT/hvf-host-cpu}"
JSON_OUT_INPUT="${JSON_OUT:-$OUT/cpu-probe-host.json}"

if [ -L "$OUT" ]; then
    echo "refusing symlinked output root: $OUT" >&2
    exit 1
fi
mkdir -p "$OUT"
OUT_REAL="$(cd "$OUT" && pwd -P)"

resolve_safe_output() {
    local input candidate parent parent_real link_count

    input="$1"
    case "$input" in
        /*) candidate="$input" ;;
        *)  candidate="$HERE/$input" ;;
    esac
    case "$candidate/" in
        *"/../"*|*"/./"*|*"//"*)
            echo "output path contains an unsafe component: $input" >&2
            return 1
            ;;
    esac
    case "$candidate" in
        "$OUT"/*) ;;
        *)
            echo "output path must stay under $OUT: $input" >&2
            return 1
            ;;
    esac
    parent="${candidate%/*}"
    if [ ! -d "$parent" ]; then
        echo "output directory does not exist: $parent" >&2
        return 1
    fi
    parent_real="$(cd "$parent" && pwd -P)"
    case "$parent_real" in
        "$OUT_REAL"|"$OUT_REAL"/*) ;;
        *)
            echo "output directory resolves outside $OUT: $parent" >&2
            return 1
            ;;
    esac
    if [ -L "$candidate" ] || { [ -e "$candidate" ] && [ ! -f "$candidate" ]; }; then
        echo "refusing non-regular or symlinked output: $candidate" >&2
        return 1
    fi
    if [ -e "$candidate" ]; then
        link_count="$(stat -f '%l' "$candidate")"
        if [ "$link_count" -ne 1 ]; then
            echo "refusing multiply linked output: $candidate" >&2
            return 1
        fi
    fi
    printf '%s\n' "$candidate"
}

BIN="$(resolve_safe_output "$BIN_INPUT")"
JSON_OUT="$(resolve_safe_output "$JSON_OUT_INPUT")"
if [ "$BIN" = "$JSON_OUT" ]; then
    echo "BIN and JSON_OUT must be different files" >&2
    exit 1
fi

RAW="$(mktemp "$OUT/.cpu-probe-host-raw.XXXXXX")"
FINAL="$(mktemp "$OUT/.cpu-probe-host-final.XXXXXX")"

cleanup() {
    rm -f "$RAW" "$FINAL"
}
trap cleanup EXIT

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

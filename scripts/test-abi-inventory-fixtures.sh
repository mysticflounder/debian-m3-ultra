#!/bin/bash
# Source-only fixtures for extract-abi-inventory.sh.  Never launches a VM.
set -euo pipefail
umask 077

HERE="$(cd "$(/usr/bin/dirname "$0")/.." && pwd -P)"
EXTRACTOR="$HERE/scripts/extract-abi-inventory.sh"
[ -f "$EXTRACTOR" ] && [ ! -L "$EXTRACTOR" ] || exit 1

/bin/mkdir -p "$HERE/scratch"
fixture_dir="$(/usr/bin/mktemp -d "$HERE/scratch/abi-inventory-fixtures.XXXXXX")"
source_dir="$fixture_dir/source"
/bin/mkdir -m 700 "$source_dir"

NAMES=(Makefile ptrace.c syscall-abi.c syscall-abi-asm.S syscall-abi.h tpidr2.c hwcap.c kselftest.h lib.mk)
tests=0

pass_case() { tests=$((tests + 1)); }

write_sources() {
    printf '%s\n' 'obj-y += syscall-abi.o' > "$source_dir/Makefile"
    printf '%s\n' 'int ptrace_fixture(void) { return 0; }' > "$source_dir/ptrace.c"
    printf '%s\n' 'long syscall_abi_fixture(void) { return 1; }' > "$source_dir/syscall-abi.c"
    printf '%s\n' '.text' '/* syscall ABI assembly fixture */' > "$source_dir/syscall-abi-asm.S"
    printf '%s\n' '#define SYSCALL_ABI_FIXTURE 1' > "$source_dir/syscall-abi.h"
    printf '%s\n' 'int tpidr2_fixture(void) { return 2; }' > "$source_dir/tpidr2.c"
    printf '%s\n' 'int hwcap_fixture(void) { return 3; }' > "$source_dir/hwcap.c"
    printf '%s\n' '#define KSFT_TAP_LEVEL 0' > "$source_dir/kselftest.h"
    printf '%s\n' 'obj-y := $(patsubst %,.o,$(src-y))' > "$source_dir/lib.mk"
}

file_sha256() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

file_bytes() {
    /usr/bin/stat -f '%z' "$1"
}

append_block() {
    local log=$1 name=$2 file=$3 sha bytes
    sha="$(file_sha256 "$file")"
    bytes="$(file_bytes "$file")"
    [ "$#" -lt 4 ] || [ -z "${4:-}" ] || sha=$4
    [ "$#" -lt 5 ] || [ -z "${5:-}" ] || bytes=$5
    printf 'M3_ABI_FILE_BEGIN name=%s sha256=%s bytes=%s\n' "$name" "$sha" "$bytes" >> "$log"
    /usr/bin/base64 -i "$file" >> "$log"
    printf 'M3_ABI_FILE_END name=%s\n' "$name" >> "$log"
}

build_valid_log() {
    local log=$1 name
    : > "$log"
    for name in "${NAMES[@]}"; do
        append_block "$log" "$name" "$source_dir/$name"
    done
}

expect_valid() {
    local label=$1 log=$2 output first dest
    output="$(/bin/bash "$EXTRACTOR" "$log")"
    first=${output%%$'\n'*}
    dest=${output#*$'\n'}
    [ "$first" = "ABI inventory verified: files=9 bytes=$total_bytes" ] || {
        echo "unexpected extractor output for $label: $output" >&2
        exit 1
    }
    case "$dest" in
        "$HERE"/scratch/abi-sources.*) ;;
        *) echo "unexpected extraction directory for $label: $dest" >&2; exit 1 ;;
    esac
    [ -d "$dest" ] && [ ! -L "$dest" ] || exit 1
    pass_case
}

expect_rejected() {
    local label=$1 log=$2
    if /bin/bash "$EXTRACTOR" "$log" >/dev/null 2>&1; then
        echo "accepted rejected fixture: $label" >&2
        exit 1
    fi
    pass_case
}

# Import the real host marker validator without entering abi_main.  The
# source-only import creates only private repository fixtures/definitions;
# disable the inherited EXIT and signal traps before continuing.
ABI_INVENTORY_SOURCE_ONLY=1 source "$HERE/scripts/abi-inventory-vm.sh"
trap - EXIT INT TERM HUP
AWK=/usr/bin/awk
MARKER_NAMES=("${NAMES[@]}")

write_marker_log() {
    local log=$1 eol=$2 count=${3:-9} name index
    : > "$log"
    for ((index = 0; index < count; index++)); do
        name="${MARKER_NAMES[$index]}"
        printf 'M3_ABI_FILE_BEGIN name=%s sha256=%064d bytes=1%s' "$name" 0 "$eol" >> "$log"
        printf 'M3_ABI_FILE_END name=%s%s' "$name" "$eol" >> "$log"
    done
}

expect_markers_valid() {
    local label=$1 log=$2
    SERIAL_LOG="$log"
    if ! abi_validate_inventory_markers; then
        echo "rejected valid marker fixture: $label" >&2
        exit 1
    fi
    pass_case
}

expect_markers_rejected() {
    local label=$1 log=$2
    SERIAL_LOG="$log"
    if abi_validate_inventory_markers; then
        echo "accepted rejected marker fixture: $label" >&2
        exit 1
    fi
    pass_case
}

write_sources
total_bytes=0
for name in "${NAMES[@]}"; do
    total_bytes=$((total_bytes + $(file_bytes "$source_dir/$name")))
done

valid="$fixture_dir/valid.log"
build_valid_log "$valid"
expect_valid valid "$valid"

duplicate="$fixture_dir/duplicate.log"
build_valid_log "$duplicate"
append_block "$duplicate" Makefile "$source_dir/Makefile"
expect_rejected duplicate "$duplicate"

missing="$fixture_dir/missing.log"
: > "$missing"
for name in "${NAMES[@]:0:8}"; do
    append_block "$missing" "$name" "$source_dir/$name"
done
expect_rejected missing "$missing"

traversal="$fixture_dir/traversal.log"
: > "$traversal"
append_block "$traversal" '../escape' "$source_dir/Makefile"
expect_rejected traversal "$traversal"

wronghash="$fixture_dir/wronghash.log"
: > "$wronghash"
for name in "${NAMES[@]}"; do
    if [ "$name" = Makefile ]; then
        append_block "$wronghash" "$name" "$source_dir/$name" \
            0000000000000000000000000000000000000000000000000000000000000000
    else
        append_block "$wronghash" "$name" "$source_dir/$name"
    fi
done
expect_rejected wronghash "$wronghash"

wrongsize="$fixture_dir/wrongsize.log"
: > "$wrongsize"
for name in "${NAMES[@]}"; do
    if [ "$name" = Makefile ]; then
        append_block "$wrongsize" "$name" "$source_dir/$name" "" 1
    else
        append_block "$wrongsize" "$name" "$source_dir/$name"
    fi
done
expect_rejected wrongsize "$wrongsize"

badbase64="$fixture_dir/badbase64.log"
: > "$badbase64"
for name in "${NAMES[@]:0:8}"; do
    append_block "$badbase64" "$name" "$source_dir/$name"
done
printf 'M3_ABI_FILE_BEGIN name=lib.mk sha256=%s bytes=%s\n' \
    "$(file_sha256 "$source_dir/lib.mk")" "$(file_bytes "$source_dir/lib.mk")" >> "$badbase64"
printf '%s\n' 'not-base64!' >> "$badbase64"
printf '%s\n' 'M3_ABI_FILE_END name=lib.mk' >> "$badbase64"
expect_rejected badbase64 "$badbase64"

incomplete="$fixture_dir/incomplete-block.log"
: > "$incomplete"
for name in "${NAMES[@]:0:8}"; do
    append_block "$incomplete" "$name" "$source_dir/$name"
done
name=lib.mk
printf 'M3_ABI_FILE_BEGIN name=%s sha256=%s bytes=%s\n' "$name" \
    "$(file_sha256 "$source_dir/$name")" "$(file_bytes "$source_dir/$name")" >> "$incomplete"
/usr/bin/base64 -i "$source_dir/$name" >> "$incomplete"
expect_rejected incomplete-block "$incomplete"

malformed="$fixture_dir/malformed-marker.log"
: > "$malformed"
printf 'M3_ABI_FILE_BEGIN sha256=%s name=Makefile bytes=%s\n' \
    "$(file_sha256 "$source_dir/Makefile")" "$(file_bytes "$source_dir/Makefile")" >> "$malformed"
/usr/bin/base64 -i "$source_dir/Makefile" >> "$malformed"
printf '%s\n' 'M3_ABI_FILE_END name=Makefile' >> "$malformed"
expect_rejected malformed-marker "$malformed"

oversize="$fixture_dir/oversize.log"
: > "$oversize"
printf '%s\n' 'M3_ABI_FILE_BEGIN name=Makefile sha256=0000000000000000000000000000000000000000000000000000000000000000 bytes=131073' >> "$oversize"
printf '%s\n' 'YQ==' 'M3_ABI_FILE_END name=Makefile' >> "$oversize"
expect_rejected oversize "$oversize"

control="$fixture_dir/control-contamination.log"
printf '%s\n' 'M3_ABI_FILE_PROGRESS phase=1' > "$control"
for name in "${NAMES[@]}"; do
    append_block "$control" "$name" "$source_dir/$name"
done
expect_rejected control-contamination "$control"

marker_crlf="$fixture_dir/markers-crlf.log"
write_marker_log "$marker_crlf" $'\r\n'
expect_markers_valid crlf "$marker_crlf"

marker_lf="$fixture_dir/markers-lf.log"
write_marker_log "$marker_lf" $'\n'
expect_markers_valid lf "$marker_lf"

marker_duplicate="$fixture_dir/markers-duplicate.log"
write_marker_log "$marker_duplicate" $'\n'
printf 'M3_ABI_FILE_BEGIN name=Makefile sha256=%064d bytes=1\n' 0 >> "$marker_duplicate"
expect_markers_rejected duplicate-marker "$marker_duplicate"

marker_missing="$fixture_dir/markers-missing.log"
write_marker_log "$marker_missing" $'\n' 8
expect_markers_rejected missing-marker "$marker_missing"

/bin/bash -n "$HERE/scripts/test-abi-inventory-fixtures.sh"
echo "ABI inventory fixtures passed: $tests cases; no VM launched"
echo "fixture artifacts: $fixture_dir"

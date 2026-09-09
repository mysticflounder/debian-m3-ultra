#!/bin/bash
# Source-only fixtures for the current-fork EL1 parser and validator.
# Never launches QEMU.
set -euo pipefail
umask 077

HERE="$(cd "$(/usr/bin/dirname "$0")/.." && pwd -P)"
RUNNER="$HERE/scripts/el1-fork-vm.sh"
[ -f "$RUNNER" ] && [ ! -L "$RUNNER" ] || exit 1
PARSER="$HERE/scripts/el1-fork-parser.sh"
[ -f "$PARSER" ] && [ ! -L "$PARSER" ] || exit 1

/bin/mkdir -p "$HERE/scratch"
fixture_dir="$(/usr/bin/mktemp -d "$HERE/scratch/el1-fork-fixtures.XXXXXX")"
EL1_FORK_SOURCE_ONLY=1 source "$RUNNER"
trap - EXIT INT TERM HUP
JQ=/usr/bin/jq

tests=0
expect_valid() {
    local label=$1 markers=$2 output
    output="$fixture_dir/$label.json"
    parse_probe_json 1 "$markers" "$output"
    validate_probe_json 1 "$output"
    tests=$((tests + 1))
}

expect_parse_rejected() {
    local label=$1 markers=$2 output
    output="$fixture_dir/$label.json"
    if parse_probe_json 1 "$markers" "$output" >/dev/null 2>&1; then
        echo "accepted malformed marker fixture: $label" >&2
        exit 1
    fi
    tests=$((tests + 1))
}

expect_validation_rejected() {
    local label=$1 markers=$2 output
    output="$fixture_dir/$label.json"
    parse_probe_json 1 "$markers" "$output" || {
        echo "parser rejected validator fixture: $label" >&2
        exit 1
    }
    if validate_probe_json 1 "$output" >/dev/null 2>&1; then
        echo "accepted invalid evidence fixture: $label" >&2
        exit 1
    fi
    tests=$((tests + 1))
}

expect_count_valid() {
    local label=$1 value=$2
    parse_counts "$value" || { echo "rejected valid count fixture: $label" >&2; exit 1; }
    tests=$((tests + 1))
}

expect_count_rejected() {
    local label=$1 value=$2
    if parse_counts "$value"; then
        echo "accepted invalid count fixture: $label" >&2
        exit 1
    fi
    tests=$((tests + 1))
}

expect_boundary_rejected() {
    local label=$1 token=$2 serial=$3 output="$fixture_dir/$1.markers"
    SERIAL_LOG="$serial"
    if el1_extract_markers "$token" "$output"; then
        echo "accepted invalid token boundary fixture: $label" >&2
        exit 1
    fi
    tests=$((tests + 1))
}

write_valid() {
    local file=$1
    {
        printf '%s\n' 'EL1_PROBE_START schema_version=2 online_cpu_count=1'
        printf '%s\n' 'EL1_PROBE_CPU cpu=0 observed_cpu=0 status=read'
        printf '%s\n' 'EL1_PROBE_REG cpu=0 name=MPIDR_EL1 status=read value=0x0000000080000000'
        printf '%s\n' 'EL1_PROBE_REG cpu=0 name=CLIDR_EL1 status=read value=0x0000000081000023'
        printf '%s\n' 'EL1_PROBE_REG cpu=0 name=CTR_EL0 status=read value=0x000000009444c004'
        printf '%s\n' 'EL1_PROBE_REG cpu=0 name=DCZID_EL0 status=read value=0x0000000000000004'
        printf '%s\n' 'EL1_PROBE_REG cpu=0 name=ID_AA64PFR0_EL1 status=read value=0x1101000010110011'
        printf '%s\n' 'EL1_PROBE_REG cpu=0 name=ID_AA64PFR1_EL1 status=read value=0x0000000100000001'
        printf '%s\n' 'EL1_PROBE_REG cpu=0 name=ID_AA64DFR0_EL1 status=read value=0x0000000010305106'
        printf '%s\n' 'EL1_PROBE_REG cpu=0 name=ID_AA64DFR1_EL1 status=read value=0x0000000000000000'
        printf '%s\n' 'EL1_PROBE_REG cpu=0 name=ID_AA64ISAR0_EL1 status=read value=0x0221100110212120'
        printf '%s\n' 'EL1_PROBE_REG cpu=0 name=ID_AA64ISAR1_EL1 status=read value=0x0010111110211402'
        printf '%s\n' 'EL1_PROBE_REG cpu=0 name=ID_AA64MMFR0_EL1 status=read value=0x000010000f100002'
        printf '%s\n' 'EL1_PROBE_REG cpu=0 name=ID_AA64MMFR1_EL1 status=read value=0x0000100011312000'
        printf '%s\n' 'EL1_PROBE_REG cpu=0 name=ID_AA64MMFR2_EL1 status=read value=0x1001001102001011'
        printf '%s\n' 'EL1_PROBE_REG cpu=0 name=ID_AA64SMFR0_EL1 status=not_read value=0x0000000000000000'
        printf '%s\n' 'EL1_PROBE_REG cpu=0 name=ID_AA64ZFR0_EL1 status=not_read value=0x0000000000000000'
        printf '%s\n' 'EL1_PROBE_CACHE_SELECTOR cpu=0 before=0x0000000000000000 after=0x0000000000000000 restored=yes'
        printf '%s\n' 'EL1_PROBE_CACHE cpu=0 level=1 ctype=3 cache_type=data_or_unified ind=0 selector=0 status=read value=0x00000000700fe03a'
        printf '%s\n' 'EL1_PROBE_CACHE cpu=0 level=1 ctype=3 cache_type=instruction ind=1 selector=1 status=read value=0x00000000203fe01a'
        printf '%s\n' 'EL1_PROBE_CACHE cpu=0 level=2 ctype=4 cache_type=data_or_unified ind=0 selector=2 status=read value=0x0000000070ffe07b'
        printf '%s\n' 'EL1_PROBE_END sampled_cpu_count=1 status=ok'
    } > "$file"
}

valid="$fixture_dir/valid.log"
write_valid "$valid"
expect_valid valid "$valid"

# The two absent SVE/SME registers are legitimate not_read rows, not zeros.
expect_valid not-read "$valid"

bad_start="$fixture_dir/bad-start.log"
sed 's/schema_version=2/schema_version=x/' "$valid" > "$bad_start"
expect_parse_rejected bad-start "$bad_start"

bad_register="$fixture_dir/bad-register.log"
sed 's/status=read value=0x0000000080000000/status=bogus value=0x0000000080000000/' "$valid" > "$bad_register"
expect_parse_rejected bad-register "$bad_register"

duplicate_cpu="$fixture_dir/duplicate-cpu.log"
{ sed -n '1,2p' "$valid"; sed -n '2p' "$valid" | sed 's/EL1_PROBE_CPU/EL1_PROBE_CPU/'; sed -n '3,$p' "$valid"; } > "$duplicate_cpu"
expect_validation_rejected duplicate-cpu "$duplicate_cpu"

missing_cpu="$fixture_dir/missing-cpu.log"
sed '/^EL1_PROBE_CPU /d' "$valid" > "$missing_cpu"
expect_validation_rejected missing-cpu "$missing_cpu"

duplicate_register="$fixture_dir/duplicate-register.log"
{ sed -n '1,3p' "$valid"; sed -n '3p' "$valid"; sed -n '4,$p' "$valid"; } > "$duplicate_register"
expect_validation_rejected duplicate-register "$duplicate_register"

missing_register="$fixture_dir/missing-register.log"
sed '/name=ID_AA64MMFR2_EL1 /d' "$valid" > "$missing_register"
expect_validation_rejected missing-register "$missing_register"

duplicate_selector="$fixture_dir/duplicate-selector.log"
{ sed -n '/^EL1_PROBE_CACHE_SELECTOR /p' "$valid"; sed -n '/^EL1_PROBE_CACHE_SELECTOR /p' "$valid"; sed -n '/^EL1_PROBE_CACHE /p' "$valid"; sed -n '/^EL1_PROBE_START /p;/^EL1_PROBE_CPU /p;/^EL1_PROBE_REG /p;/^EL1_PROBE_END /p' "$valid"; } > "$duplicate_selector"
expect_parse_rejected duplicate-selector "$duplicate_selector"

missing_selector="$fixture_dir/missing-selector.log"
sed '/^EL1_PROBE_CACHE_SELECTOR /d' "$valid" > "$missing_selector"
expect_parse_rejected missing-selector "$missing_selector"

selector_not_restored="$fixture_dir/selector-not-restored.log"
sed 's/restored=yes/restored=no/' "$valid" > "$selector_not_restored"
expect_validation_rejected selector-not-restored "$selector_not_restored"

mismatched_cpu="$fixture_dir/mismatched-cpu.log"
sed 's/observed_cpu=0/observed_cpu=1/' "$valid" > "$mismatched_cpu"
expect_validation_rejected mismatched-cpu "$mismatched_cpu"

bad_cache="$fixture_dir/bad-cache.log"
sed 's/ctype=3 cache_type/ctype=x cache_type/' "$valid" > "$bad_cache"
expect_parse_rejected bad-cache "$bad_cache"

unknown_marker="$fixture_dir/unknown-marker.log"
{ sed -n '1p' "$valid"; printf '%s\n' 'EL1_PROBE_UNKNOWN payload=ignored'; sed -n '2,$p' "$valid"; } > "$unknown_marker"
expect_parse_rejected unknown-marker "$unknown_marker"

expect_count_valid canonical-counts '1 8 16 24 32'
expect_count_rejected duplicate-counts '1 8 8'
expect_count_rejected unsupported-count '2'
expect_count_rejected newline-count $'1\n8'
expect_count_rejected empty-count ''

token=fixture-token
boundary_valid="$fixture_dir/boundary-valid.log"
{
    printf 'noise before\nEL1_FORK_BEGIN token=%s\n' "$token"
    printf '%s\n' 'EL1_PROBE_START schema_version=2 online_cpu_count=1'
    printf 'EL1_FORK_END token=%s\nnoise after\n' "$token"
} > "$boundary_valid"
SERIAL_LOG="$boundary_valid"
el1_extract_markers "$token" "$fixture_dir/boundary-valid.markers"
[ "$(/bin/cat "$fixture_dir/boundary-valid.markers")" = 'EL1_PROBE_START schema_version=2 online_cpu_count=1' ] || {
    echo 'valid token boundary extraction changed payload' >&2
    exit 1
}
tests=$((tests + 1))

wrong_end="$fixture_dir/boundary-wrong-end.log"
{
    printf 'EL1_FORK_BEGIN token=%s\n' "$token"
    printf '%s\n' 'EL1_PROBE_START schema_version=2 online_cpu_count=1'
    printf 'EL1_FORK_END token=other\n'
} > "$wrong_end"
expect_boundary_rejected wrong-end "$token" "$wrong_end"

nested_begin="$fixture_dir/boundary-nested-begin.log"
{
    printf 'EL1_FORK_BEGIN token=%s\nEL1_FORK_BEGIN token=%s\n' "$token" "$token"
    printf 'EL1_FORK_END token=%s\n' "$token"
} > "$nested_begin"
expect_boundary_rejected nested-begin "$token" "$nested_begin"

partial_probe="$fixture_dir/partial-probe.log"
{
    printf 'EL1_FORK_BEGIN token=%s\n' "$token"
    printf 'EL1_PROBE_REG cpu=0 name=CTR_EL0 status=read value=0x000000009444c00'
    printf 'EL1_FORK_END token=%s\n' "$token"
} > "$partial_probe"
expect_boundary_rejected partial-probe "$token" "$partial_probe"

# Existing historical schema-2 evidence must remain consumable by the shared
# host comparator; this is read-only evidence and does not launch a guest.
historical_host="$HERE/out/cpu-matrix/host.json"
historical_el1="$HERE/out/el1-probe-smp1.DbP3LL/evidence.json"
if [ -f "$historical_host" ] && [ -f "$historical_el1" ]; then
    comparison_dir="$HERE/out/el1-fork-fixture-results.$RANDOM"
    /bin/mkdir -m 700 "$comparison_dir"
    HOST_JSON="$historical_host" REPORT_JSON="$comparison_dir/host-comparison.json" \
        /bin/bash "$HERE/scripts/el1-probe-compare.sh" "$historical_el1" >/dev/null
    "$JQ" -e '.schema_version == 2 and .summary.differences_requiring_investigation == 0 and .summary.qemu_patch_candidate == false' \
        "$comparison_dir/host-comparison.json" >/dev/null
    tests=$((tests + 1))
fi

# Regression fixture for the launch wrapper: extract the exact quoted shell
# body from the runner, then execute it against a stub. This proves it writes
# its own shell PID and execs the stub, never writing positional arguments into
# the QEMU path.
wrapper_body="$(/usr/bin/sed -n "s#.* /bin/sh -c '\(.*\)' el1-fork-qemu.*#\1#p" "$RUNNER" | /usr/bin/head -n 1)"
[ -n "$wrapper_body" ] || { echo 'could not extract launch wrapper body' >&2; exit 1; }
if /usr/bin/grep -Eq 'printf [^;]*"\$1" > "\$2"' <<< "$wrapper_body"; then
    echo 'launch wrapper still writes positional argument into QEMU path' >&2
    exit 1
fi
stub="$fixture_dir/qemu-stub"
stub_args="$fixture_dir/stub.args"
pid_file="$fixture_dir/qemu.pid"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" > "%s"\n' "$stub_args" > "$stub"
/bin/chmod 700 "$stub"
/bin/sh -c "$wrapper_body" el1-fork-qemu "$pid_file" "$stub" alpha beta
pid="$(/bin/cat "$pid_file")"
case "$pid" in ''|*[!0-9]*) echo 'launch wrapper pid is not numeric' >&2; exit 1;; esac
[ "$(/bin/cat "$stub_args")" = 'alpha beta' ] || { echo 'launch wrapper did not exec stub arguments' >&2; exit 1; }
tests=$((tests + 1))

/bin/bash -n "$RUNNER" "$0"
echo "EL1 fork fixtures passed: $tests cases; parser, fail-closed markers, not_read rows, and launch-wrapper ownership checks passed"
echo "fixture artifacts: $fixture_dir"

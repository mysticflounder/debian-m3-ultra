#!/bin/bash
# Run the matched benchmark on the macOS host and retain validated JSON evidence.
set -euo pipefail

BENCH_HOST_THREAD_COUNTS=${THREAD_COUNTS-1,8,16,24,32}
BENCH_HOST_WARMUPS=${WARMUPS-1}
BENCH_HOST_REPETITIONS=${REPETITIONS-7}

export LC_ALL=C
export LANG=C
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 077

# Start the actual run with only the three supported inputs and controlled basics.
# The explicit scrub also protects the fixed /usr/bin/env used for the re-exec.
unset BASH_ENV ENV CDPATH GLOBIGNORE \
    DYLD_FRAMEWORK_PATH DYLD_FALLBACK_FRAMEWORK_PATH \
    DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH DYLD_INSERT_LIBRARIES \
    DYLD_IMAGE_SUFFIX DYLD_ROOT_PATH DYLD_VERSIONED_FRAMEWORK_PATH \
    DYLD_VERSIONED_LIBRARY_PATH DYLD_FORCE_FLAT_NAMESPACE \
    DYLD_PRINT_TO_FILE DYLD_SHARED_REGION \
    LD_PRELOAD LD_LIBRARY_PATH \
    PERL5LIB PERLLIB PERL5OPT PERL5DB PERLIO PERL_UNICODE \
    CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH \
    LIBRARY_PATH COMPILER_PATH GCC_EXEC_PREFIX GCC_SPECS \
    GCC_COMPARE_DEBUG GCC_COMPARE_DEBUG_OPT GCC_COLORS \
    COLLECT_GCC_OPTIONS COLLECT_LTO_WRAPPER \
    DEPENDENCIES_OUTPUT SUNPRO_DEPENDENCIES \
    CFLAGS CPPFLAGS CXXFLAGS OBJCFLAGS ASFLAGS LDFLAGS \
    MACOSX_DEPLOYMENT_TARGET SDKROOT SOURCE_DATE_EPOCH TMPDIR

if [[ ${BENCH_HOST_CLEAN_ENV-} != 1 ]]; then
    exec /usr/bin/env -i \
        BENCH_HOST_CLEAN_ENV=1 \
        LC_ALL=C \
        LANG=C \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        THREAD_COUNTS="$BENCH_HOST_THREAD_COUNTS" \
        WARMUPS="$BENCH_HOST_WARMUPS" \
        REPETITIONS="$BENCH_HOST_REPETITIONS" \
        /bin/bash "$0" "$@"
fi
unset BENCH_HOST_CLEAN_ENV BENCH_HOST_THREAD_COUNTS BENCH_HOST_WARMUPS \
    BENCH_HOST_REPETITIONS

readonly GCC=/opt/homebrew/bin/gcc-16
readonly JQ=/usr/bin/jq
readonly SHASUM=/usr/bin/shasum
readonly SYSCTL=/usr/sbin/sysctl
readonly SW_VERS=/usr/bin/sw_vers
readonly DATE=/bin/date
readonly DIRNAME=/usr/bin/dirname
readonly MKDIR=/bin/mkdir
readonly MKTEMP=/usr/bin/mktemp
readonly CHMOD=/bin/chmod
readonly MV=/bin/mv
readonly RM=/bin/rm
readonly RMDIR=/bin/rmdir

readonly MAX_WARMUPS=10
readonly MAX_REPETITIONS=100
readonly MAX_THREAD_COUNTS=64

die()
{
    printf 'bench-host: %s\n' "$*" >&2
    exit 1
}

hash_file()
{
    local path="$1"
    local output
    local digest

    if ! output="$("$SHASUM" -a 256 "$path")"; then
        return 1
    fi
    digest=${output%% *}
    if [[ ! $digest =~ ^[0123456789abcdefABCDEF]{64}$ ]]; then
        return 1
    fi
    printf '%s\n' "$digest"
}

normalize_uint()
{
    local destination="$1"
    local label="$2"
    local raw="$3"
    local minimum="$4"
    local maximum="$5"
    local value

    [[ $raw =~ ^[0-9]+$ ]] || die "$label must be a decimal integer"
    ((${#raw} <= 3)) || die "$label is outside $minimum..$maximum"
    value=$((10#$raw))
    ((value >= minimum && value <= maximum)) ||
        die "$label is outside $minimum..$maximum"
    printf -v "$destination" '%d' "$value"
}

validate_load_value()
{
    [[ $1 =~ ^[0-9]+([.][0-9]+)?$ ]] ||
        die "sysctl returned a malformed load average"
}

validate_sample()
{
    local sample="$1"
    local expected_threads="$2"
    local expected_sample_id="$3"

    [[ $sample != *$'\n'* ]] || return 1
    printf '%s\n' "$sample" | "$JQ" -s -e \
        --argjson expected_threads "$expected_threads" \
        --arg expected_sample_id "$expected_sample_id" '
        def absolute: if . < 0 then -. else . end;
        def nearly_equal($left; $right):
          (($left - $right) | absolute) <=
            (1e-7 * (($right | absolute) + 1));
        def positive_finite: type == "number" and isfinite and . > 0;
        length == 1 and (.[0] |
        type == "object" and
        (keys == [
          "checksum",
          "int_gops",
          "int_iterations_per_thread",
          "int_operations_per_iteration",
          "int_process_cpu_seconds",
          "int_process_gops_per_cpu_second",
          "int_process_scheduler_residency",
          "int_seconds",
          "int_worker_cpu_seconds",
          "int_worker_gops_per_cpu_second",
          "int_worker_scheduler_residency",
          "memory_bytes",
          "memory_gib_s",
          "memory_passes",
          "memory_process_cpu_seconds",
          "memory_process_gib_per_cpu_second",
          "memory_process_scheduler_residency",
          "memory_seconds",
          "sample_id",
          "threads",
          "timing_version"
        ]) and
        .timing_version == 2 and
        .sample_id == $expected_sample_id and
        (.sample_id | test("^[A-Za-z0-9_.:-]{1,64}$")) and
        (.checksum | type == "string") and
        .threads == $expected_threads and
        .int_iterations_per_thread == 400000000 and
        .int_operations_per_iteration == 4 and
        .memory_bytes == 268435456 and
        .memory_passes == 8 and
        (.int_seconds | positive_finite) and
        (.int_gops | positive_finite) and
        (.int_worker_cpu_seconds | positive_finite) and
        (.int_process_cpu_seconds | positive_finite) and
        (.int_worker_scheduler_residency | positive_finite) and
        (.int_process_scheduler_residency | positive_finite) and
        (.int_worker_gops_per_cpu_second | positive_finite) and
        (.int_process_gops_per_cpu_second | positive_finite) and
        (.memory_seconds | positive_finite) and
        (.memory_gib_s | positive_finite) and
        (.memory_process_cpu_seconds | positive_finite) and
        (.memory_process_scheduler_residency | positive_finite) and
        (.memory_process_gib_per_cpu_second | positive_finite) and
        .int_worker_cpu_seconds <= (.int_process_cpu_seconds + 0.001) and
        .int_worker_scheduler_residency <= 1.01 and
        .int_process_scheduler_residency <= 1.05 and
        .memory_process_scheduler_residency <= 1.05 and
        nearly_equal(.int_gops;
          (400000000 * $expected_threads * 4 / .int_seconds / 1e9)) and
        nearly_equal(.int_worker_scheduler_residency;
          (.int_worker_cpu_seconds / (.int_seconds * $expected_threads))) and
        nearly_equal(.int_process_scheduler_residency;
          (.int_process_cpu_seconds / (.int_seconds * $expected_threads))) and
        nearly_equal(.int_worker_gops_per_cpu_second;
          (400000000 * $expected_threads * 4 /
            .int_worker_cpu_seconds / 1e9)) and
        nearly_equal(.int_process_gops_per_cpu_second;
          (400000000 * $expected_threads * 4 /
            .int_process_cpu_seconds / 1e9)) and
        nearly_equal(.memory_gib_s;
          (268435456 * 8 / .memory_seconds / 1073741824)) and
        nearly_equal(.memory_process_scheduler_residency;
          (.memory_process_cpu_seconds / .memory_seconds)) and
        nearly_equal(.memory_process_gib_per_cpu_second;
          (268435456 * 8 / .memory_process_cpu_seconds / 1073741824)) and
        (.checksum | test("^[0-9a-f]{16}$")))
        ' >/dev/null
}

validate_timing_markers()
{
    local expected_count="$1"
    local line
    local sample_id=''
    local state=0
    local completed=0
    local begin_pattern='^BENCH_WORK_BEGIN[[:space:]]sample_id=([A-Za-z0-9_.:-]+)[[:space:]]workload=integer$'

    while IFS= read -r line || [[ -n $line ]]; do
        case "$state" in
            0)
                [[ $line =~ $begin_pattern ]] || return 1
                sample_id=${BASH_REMATCH[1]}
                ((completed < ${#ALL_SAMPLE_IDS[@]})) || return 1
                [[ $sample_id == "${ALL_SAMPLE_IDS[$completed]}" ]] || return 1
                state=1
                ;;
            1)
                [[ $line == "BENCH_WORK_END sample_id=$sample_id workload=integer status=ok" ]] ||
                    return 1
                state=2
                ;;
            2)
                [[ $line == "BENCH_WORK_BEGIN sample_id=$sample_id workload=memory" ]] ||
                    return 1
                state=3
                ;;
            3)
                [[ $line == "BENCH_WORK_END sample_id=$sample_id workload=memory status=ok" ]] ||
                    return 1
                ((++completed))
                state=0
                ;;
        esac
    done < "$TIMING_MARKERS"

    ((state == 0 && completed == expected_count &&
      completed == ${#ALL_SAMPLE_IDS[@]}))
}

RUN_DIR=''
OUT_DIR=''
BENCHMARK=''
SAMPLES_NDJSON=''
TIMING_MARKERS=''
EVIDENCE_TMP=''

cleanup()
{
    local status="$?"
    local candidate

    trap - EXIT
    if ((status != 0)) && [[ -n $RUN_DIR && -n $OUT_DIR &&
        $RUN_DIR == "$OUT_DIR"/benchmark-host.?????? &&
        -d $RUN_DIR && ! -L $RUN_DIR ]]; then
        for candidate in "$BENCHMARK" "$SAMPLES_NDJSON" "$EVIDENCE_TMP"; do
            case "$candidate" in
                "$RUN_DIR/bench"|"$RUN_DIR/samples.ndjson"|\
                    "$RUN_DIR/.evidence.json.tmp")
                    if [[ -f $candidate && ! -L $candidate ]]; then
                        "$RM" -f -- "$candidate"
                    fi
                    ;;
            esac
        done
        if [[ ${TMPDIR:-} == "$RUN_DIR/tmp" && -d $TMPDIR && ! -L $TMPDIR ]]; then
            "$RMDIR" -- "$TMPDIR" 2>/dev/null || true
        fi
    fi
    exit "$status"
}

trap cleanup EXIT

(($# == 0)) || die "this runner takes no command-line arguments"

THREAD_COUNTS=${THREAD_COUNTS-1,8,16,24,32}
WARMUPS=${WARMUPS-1}
REPETITIONS=${REPETITIONS-7}

normalize_uint WARMUPS_VALUE WARMUPS "$WARMUPS" 0 "$MAX_WARMUPS"
normalize_uint REPETITIONS_VALUE REPETITIONS "$REPETITIONS" 1 \
    "$MAX_REPETITIONS"

[[ ${#THREAD_COUNTS} -le 256 ]] || die "THREAD_COUNTS is too long"
[[ $THREAD_COUNTS =~ ^[0-9]+(,[0-9]+)*$ ]] ||
    die "THREAD_COUNTS must be a comma-separated decimal list"
IFS=, read -r -a THREADS <<< "$THREAD_COUNTS"
((${#THREADS[@]} >= 1 && ${#THREADS[@]} <= MAX_THREAD_COUNTS)) ||
    die "THREAD_COUNTS must contain 1..$MAX_THREAD_COUNTS entries"

for tool in "$GCC" "$JQ" "$SHASUM" "$SYSCTL" "$SW_VERS" "$DATE" \
    "$DIRNAME" "$MKDIR" "$MKTEMP" "$CHMOD" "$MV" "$RM" "$RMDIR"; do
    [[ -x $tool ]] || die "required executable is unavailable: $tool"
done

if ! LOGICAL_CPU_COUNT="$("$SYSCTL" -n hw.logicalcpu)"; then
    die "cannot query hw.logicalcpu"
fi
if ! PHYSICAL_CPU_COUNT="$("$SYSCTL" -n hw.physicalcpu)"; then
    die "cannot query hw.physicalcpu"
fi
normalize_uint LOGICAL_CPU_COUNT_VALUE hw.logicalcpu "$LOGICAL_CPU_COUNT" 1 64
normalize_uint PHYSICAL_CPU_COUNT_VALUE hw.physicalcpu "$PHYSICAL_CPU_COUNT" 1 64
((PHYSICAL_CPU_COUNT_VALUE <= LOGICAL_CPU_COUNT_VALUE)) ||
    die "physical CPU count exceeds logical CPU count"

NORMALIZED_THREADS=()
for raw_thread in "${THREADS[@]}"; do
    normalize_uint thread_value THREAD_COUNTS "$raw_thread" 1 64
    ((thread_value <= LOGICAL_CPU_COUNT_VALUE)) ||
        die "thread count $thread_value exceeds hw.logicalcpu=$LOGICAL_CPU_COUNT_VALUE"
    if ((${#NORMALIZED_THREADS[@]} > 0)); then
        for existing_thread in "${NORMALIZED_THREADS[@]}"; do
            ((thread_value != existing_thread)) ||
                die "THREAD_COUNTS contains duplicate $thread_value"
        done
    fi
    NORMALIZED_THREADS+=("$thread_value")
done
THREADS=("${NORMALIZED_THREADS[@]}")

if ! SCRIPT_DIR="$(CDPATH= cd -P -- "$("$DIRNAME" -- "$0")" && pwd)"; then
    die "cannot resolve the script directory"
fi
if ! REPOSITORY_DIR="$(CDPATH= cd -P -- "$SCRIPT_DIR/.." && pwd)"; then
    die "cannot resolve the repository directory"
fi
SOURCE="$SCRIPT_DIR/bench.c"
[[ -f $SOURCE && ! -L $SOURCE ]] ||
    die "benchmark source must be a regular, non-symlink file: $SOURCE"

OUT_REQUESTED="$REPOSITORY_DIR/out"
[[ ! -L $OUT_REQUESTED ]] || die "refusing a symlinked out directory"
"$MKDIR" -p -- "$OUT_REQUESTED"
if ! OUT_DIR="$(CDPATH= cd -P -- "$OUT_REQUESTED" && pwd)"; then
    die "cannot resolve the output directory"
fi
[[ $OUT_DIR == "$REPOSITORY_DIR/out" ]] ||
    die "output directory did not resolve to the repository out directory"
if ! RUN_DIR="$("$MKTEMP" -d "$OUT_DIR/benchmark-host.XXXXXX")"; then
    die "cannot create a fresh benchmark evidence directory"
fi
"$CHMOD" 700 "$RUN_DIR"
[[ $RUN_DIR == "$OUT_DIR"/benchmark-host.* ]] ||
    die "unexpected evidence directory path"
TMPDIR="$RUN_DIR/tmp"
"$MKDIR" -- "$TMPDIR"
"$CHMOD" 700 "$TMPDIR"
export TMPDIR

if ! GCC_VERSION_OUTPUT="$("$GCC" --version)"; then
    die "cannot query compiler version"
fi
GCC_VERSION=${GCC_VERSION_OUTPUT%%$'\n'*}
if ! GCC_NUMERIC_VERSION="$("$GCC" -dumpfullversion)"; then
    die "cannot query numeric compiler version"
fi
[[ $GCC_NUMERIC_VERSION == 16.* ]] ||
    die "pinned gcc-16 reported unexpected version $GCC_NUMERIC_VERSION"
if ! JQ_VERSION="$("$JQ" --version)"; then
    die "cannot query jq version"
fi
if ! SHASUM_VERSION_OUTPUT="$("$SHASUM" --version)"; then
    die "cannot query shasum version"
fi
SHASUM_VERSION=${SHASUM_VERSION_OUTPUT%%$'\n'*}

if ! SOURCE_HASH_BEFORE="$(hash_file "$SOURCE")"; then
    die "cannot hash benchmark source"
fi
if ! COMPILER_HASH_BEFORE="$(hash_file "$GCC")"; then
    die "cannot hash compiler"
fi
if ! JQ_HASH_BEFORE="$(hash_file "$JQ")"; then
    die "cannot hash jq"
fi
if ! SHASUM_HASH_BEFORE="$(hash_file "$SHASUM")"; then
    die "cannot hash shasum"
fi

if ! PRODUCT_NAME="$("$SW_VERS" -productName)"; then
    die "cannot query macOS product name"
fi
if ! PRODUCT_VERSION="$("$SW_VERS" -productVersion)"; then
    die "cannot query macOS product version"
fi
if ! BUILD_VERSION="$("$SW_VERS" -buildVersion)"; then
    die "cannot query macOS build version"
fi
if ! CPU_BRAND="$("$SYSCTL" -n machdep.cpu.brand_string)"; then
    die "cannot query CPU brand"
fi
if ! CPU_CLASS="$("$SYSCTL" -n hw.machine)"; then
    die "cannot query CPU class"
fi

BENCHMARK="$RUN_DIR/bench"
COMPILE_ARGV=(
    "$GCC"
    -O2
    -pthread
    -Wall
    -Wextra
    -Werror
    -std=gnu11
    -o
    "$BENCHMARK"
    "$SOURCE"
)
"${COMPILE_ARGV[@]}"
[[ -x $BENCHMARK ]] || die "compiler did not create the benchmark executable"
if ! BINARY_HASH_BEFORE="$(hash_file "$BENCHMARK")"; then
    die "cannot hash compiled benchmark"
fi

if ! PRE_TIMESTAMP="$("$DATE" -u '+%Y-%m-%dT%H:%M:%SZ')"; then
    die "cannot capture pre-run timestamp"
fi
if ! PRE_LOAD_RAW="$("$SYSCTL" -n vm.loadavg)"; then
    die "cannot capture pre-run load averages"
fi
read -r PRE_LOAD_OPEN PRE_LOAD_1 PRE_LOAD_5 PRE_LOAD_15 PRE_LOAD_CLOSE \
    PRE_LOAD_EXTRA <<< "$PRE_LOAD_RAW"
[[ $PRE_LOAD_OPEN == \{ && $PRE_LOAD_CLOSE == \} && -z ${PRE_LOAD_EXTRA:-} ]] ||
    die "sysctl returned malformed pre-run load averages"
validate_load_value "$PRE_LOAD_1"
validate_load_value "$PRE_LOAD_5"
validate_load_value "$PRE_LOAD_15"

SAMPLES_NDJSON="$RUN_DIR/samples.ndjson"
TIMING_MARKERS="$RUN_DIR/timing-markers.log"
: > "$SAMPLES_NDJSON"
: > "$TIMING_MARKERS"
ALL_SAMPLE_IDS=()
for thread_value in "${THREADS[@]}"; do
    for ((run = 1; run <= WARMUPS_VALUE; ++run)); do
        sample_id="t${thread_value}-w${run}"
        ALL_SAMPLE_IDS+=("$sample_id")
        if ! sample="$("$BENCHMARK" --json --timing-v2 "$sample_id" \
            "$thread_value" 2>> "$TIMING_MARKERS")"; then
            die "warmup failed for $thread_value threads"
        fi
        validate_sample "$sample" "$thread_value" "$sample_id" ||
            die "warmup returned invalid JSON for $thread_value threads"
    done
    for ((run = 1; run <= REPETITIONS_VALUE; ++run)); do
        sample_id="t${thread_value}-r${run}"
        ALL_SAMPLE_IDS+=("$sample_id")
        if ! sample="$("$BENCHMARK" --json --timing-v2 "$sample_id" \
            "$thread_value" 2>> "$TIMING_MARKERS")"; then
            die "measured run failed for $thread_value threads"
        fi
        validate_sample "$sample" "$thread_value" "$sample_id" ||
            die "measured run returned invalid JSON for $thread_value threads"
        printf '%s\n' "$sample" >> "$SAMPLES_NDJSON"
    done
done
EXPECTED_INVOCATION_COUNT=$((${#THREADS[@]} *
    (WARMUPS_VALUE + REPETITIONS_VALUE)))
validate_timing_markers "$EXPECTED_INVOCATION_COUNT" ||
    die "benchmark timing marker log is malformed or incomplete"
if ! TIMING_MARKERS_HASH="$(hash_file "$TIMING_MARKERS")"; then
    die "cannot hash benchmark timing markers"
fi

if ! POST_LOAD_RAW="$("$SYSCTL" -n vm.loadavg)"; then
    die "cannot capture post-run load averages"
fi
if ! POST_TIMESTAMP="$("$DATE" -u '+%Y-%m-%dT%H:%M:%SZ')"; then
    die "cannot capture post-run timestamp"
fi
read -r POST_LOAD_OPEN POST_LOAD_1 POST_LOAD_5 POST_LOAD_15 POST_LOAD_CLOSE \
    POST_LOAD_EXTRA <<< "$POST_LOAD_RAW"
[[ $POST_LOAD_OPEN == \{ && $POST_LOAD_CLOSE == \} && -z ${POST_LOAD_EXTRA:-} ]] ||
    die "sysctl returned malformed post-run load averages"
validate_load_value "$POST_LOAD_1"
validate_load_value "$POST_LOAD_5"
validate_load_value "$POST_LOAD_15"

if ! SOURCE_HASH_AFTER="$(hash_file "$SOURCE")"; then
    die "cannot re-hash benchmark source"
fi
if ! COMPILER_HASH_AFTER="$(hash_file "$GCC")"; then
    die "cannot re-hash compiler"
fi
if ! JQ_HASH_AFTER="$(hash_file "$JQ")"; then
    die "cannot re-hash jq"
fi
if ! SHASUM_HASH_AFTER="$(hash_file "$SHASUM")"; then
    die "cannot re-hash shasum"
fi
if ! BINARY_HASH_AFTER="$(hash_file "$BENCHMARK")"; then
    die "cannot re-hash compiled benchmark"
fi
if ! GCC_VERSION_OUTPUT_AFTER="$("$GCC" --version)"; then
    die "cannot re-query compiler version"
fi
GCC_VERSION_AFTER=${GCC_VERSION_OUTPUT_AFTER%%$'\n'*}
if ! GCC_NUMERIC_VERSION_AFTER="$("$GCC" -dumpfullversion)"; then
    die "cannot re-query numeric compiler version"
fi
if ! JQ_VERSION_AFTER="$("$JQ" --version)"; then
    die "cannot re-query jq version"
fi
if ! SHASUM_VERSION_OUTPUT_AFTER="$("$SHASUM" --version)"; then
    die "cannot re-query shasum version"
fi
SHASUM_VERSION_AFTER=${SHASUM_VERSION_OUTPUT_AFTER%%$'\n'*}

[[ $SOURCE_HASH_BEFORE == "$SOURCE_HASH_AFTER" ]] ||
    die "benchmark source changed during the run"
[[ $COMPILER_HASH_BEFORE == "$COMPILER_HASH_AFTER" ]] ||
    die "compiler changed during the run"
[[ $JQ_HASH_BEFORE == "$JQ_HASH_AFTER" ]] || die "jq changed during the run"
[[ $SHASUM_HASH_BEFORE == "$SHASUM_HASH_AFTER" ]] ||
    die "shasum changed during the run"
[[ $BINARY_HASH_BEFORE == "$BINARY_HASH_AFTER" ]] ||
    die "compiled benchmark changed during the run"
[[ $GCC_VERSION == "$GCC_VERSION_AFTER" &&
   $GCC_NUMERIC_VERSION == "$GCC_NUMERIC_VERSION_AFTER" ]] ||
    die "compiler version changed during the run"
[[ $JQ_VERSION == "$JQ_VERSION_AFTER" ]] || die "jq version changed during the run"
[[ $SHASUM_VERSION == "$SHASUM_VERSION_AFTER" ]] ||
    die "shasum version changed during the run"

if ! COMPILE_ARGV_JSON="$("$JQ" -cn --args '$ARGS.positional' -- \
    "${COMPILE_ARGV[@]}")"; then
    die "cannot encode compiler argv"
fi
if ! BENCHMARK_ARGV_JSON="$("$JQ" -cn --args '$ARGS.positional' -- \
    "$BENCHMARK" --json --timing-v2 '<sample_id>' '<threads>')"; then
    die "cannot encode benchmark argv template"
fi
if ! THREADS_JSON="$("$JQ" -cn --args '$ARGS.positional | map(tonumber)' -- \
    "${THREADS[@]}")"; then
    die "cannot encode thread counts"
fi

EVIDENCE_TMP="$RUN_DIR/.evidence.json.tmp"
EVIDENCE="$RUN_DIR/evidence.json"
"$JQ" -n \
    --slurpfile samples "$SAMPLES_NDJSON" \
    --arg product_name "$PRODUCT_NAME" \
    --arg product_version "$PRODUCT_VERSION" \
    --arg build_version "$BUILD_VERSION" \
    --arg cpu_brand "$CPU_BRAND" \
    --arg cpu_class "$CPU_CLASS" \
    --arg source_path "$SOURCE" \
    --arg source_hash "$SOURCE_HASH_BEFORE" \
    --arg compiler_path "$GCC" \
    --arg compiler_version "$GCC_VERSION" \
    --arg compiler_numeric_version "$GCC_NUMERIC_VERSION" \
    --arg compiler_hash "$COMPILER_HASH_BEFORE" \
    --arg jq_path "$JQ" \
    --arg jq_version "$JQ_VERSION" \
    --arg jq_hash "$JQ_HASH_BEFORE" \
    --arg shasum_path "$SHASUM" \
    --arg shasum_version "$SHASUM_VERSION" \
    --arg shasum_hash "$SHASUM_HASH_BEFORE" \
    --arg benchmark_path "$BENCHMARK" \
    --arg benchmark_hash "$BINARY_HASH_BEFORE" \
    --arg timing_markers_path "$TIMING_MARKERS" \
    --arg timing_markers_hash "$TIMING_MARKERS_HASH" \
    --arg pre_timestamp "$PRE_TIMESTAMP" \
    --arg post_timestamp "$POST_TIMESTAMP" \
    --arg source_hash_after "$SOURCE_HASH_AFTER" \
    --arg compiler_hash_after "$COMPILER_HASH_AFTER" \
    --arg jq_hash_after "$JQ_HASH_AFTER" \
    --arg shasum_hash_after "$SHASUM_HASH_AFTER" \
    --arg benchmark_hash_after "$BINARY_HASH_AFTER" \
    --arg compiler_version_after "$GCC_VERSION_AFTER" \
    --arg compiler_numeric_version_after "$GCC_NUMERIC_VERSION_AFTER" \
    --arg jq_version_after "$JQ_VERSION_AFTER" \
    --arg shasum_version_after "$SHASUM_VERSION_AFTER" \
    --argjson logical_cpus "$LOGICAL_CPU_COUNT_VALUE" \
    --argjson physical_cpus "$PHYSICAL_CPU_COUNT_VALUE" \
    --argjson compile_argv "$COMPILE_ARGV_JSON" \
    --argjson benchmark_argv "$BENCHMARK_ARGV_JSON" \
    --argjson thread_counts "$THREADS_JSON" \
    --argjson warmups "$WARMUPS_VALUE" \
    --argjson repetitions "$REPETITIONS_VALUE" \
    --argjson timing_invocation_count "$EXPECTED_INVOCATION_COUNT" \
    --argjson pre_load_1 "$PRE_LOAD_1" \
    --argjson pre_load_5 "$PRE_LOAD_5" \
    --argjson pre_load_15 "$PRE_LOAD_15" \
    --argjson post_load_1 "$POST_LOAD_1" \
    --argjson post_load_5 "$POST_LOAD_5" \
    --argjson post_load_15 "$POST_LOAD_15" '
    def distribution:
      sort as $values
      | ($values | length) as $count
      | {
          count: $count,
          min: $values[0],
          median: (
            if ($count % 2) == 1 then
              $values[(($count / 2) | floor)]
            else
              (($values[($count / 2) - 1] + $values[$count / 2]) / 2)
            end
          ),
          mean: (($values | add) / $count),
          max: $values[-1]
        };
    {
      schema_version: 2,
      role: "host",
      host: {
        operating_system: {
          product_name: $product_name,
          product_version: $product_version,
          build_version: $build_version
        },
        cpu: {
          brand: $cpu_brand,
          class: $cpu_class,
          logical_count: $logical_cpus,
          physical_count: $physical_cpus
        }
      },
      source: {
        path: $source_path,
        sha256: $source_hash
      },
      compiler: {
        path: $compiler_path,
        version: $compiler_version,
        numeric_version: $compiler_numeric_version,
        sha256: $compiler_hash
      },
      tools: {
        jq: {path: $jq_path, version: $jq_version, sha256: $jq_hash},
        shasum: {
          path: $shasum_path,
          version: $shasum_version,
          sha256: $shasum_hash
        }
      },
      compilation: {
        argv: $compile_argv,
        benchmark_path: $benchmark_path,
        benchmark_sha256: $benchmark_hash
      },
      benchmark: {
        argv_template: $benchmark_argv,
        timing: {
          version: 2,
          sample_id_format: "t<threads>-w<warmup-ordinal> or t<threads>-r<repetition-ordinal>",
          integer_worker_cpu_source: "sum of each worker thread CPU clock over its integer loop",
          process_cpu_source: "getrusage(RUSAGE_SELF) user plus system CPU time deltas",
          wall_clock_source: "CLOCK_MONOTONIC",
          derived_formulas: {
            int_worker_scheduler_residency: "int_worker_cpu_seconds / (int_seconds * threads)",
            int_process_scheduler_residency: "int_process_cpu_seconds / (int_seconds * threads)",
            memory_process_scheduler_residency: "memory_process_cpu_seconds / memory_seconds",
            int_worker_gops_per_cpu_second: "integer operations / int_worker_cpu_seconds / 1e9",
            int_process_gops_per_cpu_second: "integer operations / int_process_cpu_seconds / 1e9",
            memory_process_gib_per_cpu_second: "memory bytes times passes / memory_process_cpu_seconds / 2^30"
          },
          marker_log: {
            path: $timing_markers_path,
            sha256: $timing_markers_hash,
            invocation_count: $timing_invocation_count,
            marker_count: ($timing_invocation_count * 4)
          }
        },
        parameters: {
          thread_counts: $thread_counts,
          warmups_per_thread: $warmups,
          repetitions_per_thread: $repetitions,
          int_iterations_per_thread: 400000000,
          int_operations_per_iteration: 4,
          memory_bytes: 268435456,
          memory_passes: 8
        },
        sample_order: "thread_counts order, then repetition order; warmups omitted",
        samples: $samples,
        distributions: (
          $samples
          | group_by(.threads)
          | map({
              threads: .[0].threads,
              int_seconds: (map(.int_seconds) | distribution),
              int_gops: (map(.int_gops) | distribution),
              int_worker_cpu_seconds:
                (map(.int_worker_cpu_seconds) | distribution),
              int_process_cpu_seconds:
                (map(.int_process_cpu_seconds) | distribution),
              int_worker_scheduler_residency:
                (map(.int_worker_scheduler_residency) | distribution),
              int_process_scheduler_residency:
                (map(.int_process_scheduler_residency) | distribution),
              int_worker_gops_per_cpu_second:
                (map(.int_worker_gops_per_cpu_second) | distribution),
              int_process_gops_per_cpu_second:
                (map(.int_process_gops_per_cpu_second) | distribution),
              memory_seconds: (map(.memory_seconds) | distribution),
              memory_gib_s: (map(.memory_gib_s) | distribution),
              memory_process_cpu_seconds:
                (map(.memory_process_cpu_seconds) | distribution),
              memory_process_scheduler_residency:
                (map(.memory_process_scheduler_residency) | distribution),
              memory_process_gib_per_cpu_second:
                (map(.memory_process_gib_per_cpu_second) | distribution)
            })
        )
      },
      thermal_load_notes: {
        note: "Load averages are context only; no affinity or thermal-state assumptions were made.",
        pre: {
          timestamp_utc: $pre_timestamp,
          load_average: {
            one_minute: $pre_load_1,
            five_minutes: $pre_load_5,
            fifteen_minutes: $pre_load_15
          }
        },
        post: {
          timestamp_utc: $post_timestamp,
          load_average: {
            one_minute: $post_load_1,
            five_minutes: $post_load_5,
            fifteen_minutes: $post_load_15
          }
        }
      },
      integrity: {
        source_sha256: {before: $source_hash, after: $source_hash_after},
        compiler_sha256: {before: $compiler_hash, after: $compiler_hash_after},
        jq_sha256: {before: $jq_hash, after: $jq_hash_after},
        shasum_sha256: {before: $shasum_hash, after: $shasum_hash_after},
        benchmark_sha256: {before: $benchmark_hash, after: $benchmark_hash_after},
        versions: {
          compiler: {
            before: $compiler_version,
            after: $compiler_version_after,
            numeric_before: $compiler_numeric_version,
            numeric_after: $compiler_numeric_version_after
          },
          jq: {before: $jq_version, after: $jq_version_after},
          shasum: {before: $shasum_version, after: $shasum_version_after}
        },
        all_protected_hashes_match: true
      }
    }
    ' > "$EVIDENCE_TMP"

EXPECTED_SAMPLE_COUNT=$((${#THREADS[@]} * REPETITIONS_VALUE))
"$JQ" -e \
    --argjson expected_sample_count "$EXPECTED_SAMPLE_COUNT" \
    --argjson thread_counts "$THREADS_JSON" \
    --argjson expected_warmups "$WARMUPS_VALUE" \
    --argjson expected_repetitions "$REPETITIONS_VALUE" '
    def absolute: if . < 0 then -. else . end;
    def nearly_equal($left; $right):
      (($left - $right) | absolute) <=
        (1e-7 * (($right | absolute) + 1));
    def positive_finite: type == "number" and isfinite and . > 0;
    def distribution:
      sort as $values
      | ($values | length) as $count
      | {
          count: $count,
          min: $values[0],
          median: (
            if ($count % 2) == 1 then
              $values[(($count / 2) | floor)]
            else
              (($values[($count / 2) - 1] + $values[$count / 2]) / 2)
            end
          ),
          mean: (($values | add) / $count),
          max: $values[-1]
        };
    def valid_sample:
      (keys == [
        "checksum",
        "int_gops",
        "int_iterations_per_thread",
        "int_operations_per_iteration",
        "int_process_cpu_seconds",
        "int_process_gops_per_cpu_second",
        "int_process_scheduler_residency",
        "int_seconds",
        "int_worker_cpu_seconds",
        "int_worker_gops_per_cpu_second",
        "int_worker_scheduler_residency",
        "memory_bytes",
        "memory_gib_s",
        "memory_passes",
        "memory_process_cpu_seconds",
        "memory_process_gib_per_cpu_second",
        "memory_process_scheduler_residency",
        "memory_seconds",
        "sample_id",
        "threads",
        "timing_version"
      ]) and
      .timing_version == 2 and
      (.sample_id | test("^[A-Za-z0-9_.:-]{1,64}$")) and
      .int_iterations_per_thread == 400000000 and
      .int_operations_per_iteration == 4 and
      .memory_bytes == 268435456 and .memory_passes == 8 and
      ([.int_seconds, .int_gops, .int_worker_cpu_seconds,
        .int_process_cpu_seconds, .int_worker_scheduler_residency,
        .int_process_scheduler_residency,
        .int_worker_gops_per_cpu_second,
        .int_process_gops_per_cpu_second, .memory_seconds, .memory_gib_s,
        .memory_process_cpu_seconds, .memory_process_scheduler_residency,
        .memory_process_gib_per_cpu_second]
        | all(.[]; positive_finite)) and
      .int_worker_cpu_seconds <= (.int_process_cpu_seconds + 0.001) and
      .int_worker_scheduler_residency <= 1.01 and
      .int_process_scheduler_residency <= 1.05 and
      .memory_process_scheduler_residency <= 1.05 and
      nearly_equal(.int_gops;
        (400000000 * .threads * 4 / .int_seconds / 1e9)) and
      nearly_equal(.int_worker_scheduler_residency;
        (.int_worker_cpu_seconds / (.int_seconds * .threads))) and
      nearly_equal(.int_process_scheduler_residency;
        (.int_process_cpu_seconds / (.int_seconds * .threads))) and
      nearly_equal(.int_worker_gops_per_cpu_second;
        (400000000 * .threads * 4 / .int_worker_cpu_seconds / 1e9)) and
      nearly_equal(.int_process_gops_per_cpu_second;
        (400000000 * .threads * 4 / .int_process_cpu_seconds / 1e9)) and
      nearly_equal(.memory_gib_s;
        (268435456 * 8 / .memory_seconds / 1073741824)) and
      nearly_equal(.memory_process_scheduler_residency;
        (.memory_process_cpu_seconds / .memory_seconds)) and
      nearly_equal(.memory_process_gib_per_cpu_second;
        (268435456 * 8 / .memory_process_cpu_seconds / 1073741824)) and
      (.checksum | type == "string" and test("^[0-9a-f]{16}$"));
    (keys == [
      "benchmark", "compilation", "compiler", "host", "integrity",
      "role", "schema_version", "source", "thermal_load_notes", "tools"
    ]) and
    .schema_version == 2 and .role == "host" and
    (.benchmark | keys == [
      "argv_template", "distributions", "parameters", "sample_order",
      "samples", "timing"
    ]) and
    .benchmark.timing.version == 2 and
    (.benchmark.timing | keys == [
      "derived_formulas", "integer_worker_cpu_source", "marker_log",
      "process_cpu_source", "sample_id_format", "version",
      "wall_clock_source"
    ]) and
    (.benchmark.timing.marker_log | keys == [
      "invocation_count", "marker_count", "path", "sha256"
    ]) and
    .benchmark.timing.marker_log.invocation_count ==
      (($thread_counts | length) * ($expected_warmups + $expected_repetitions)) and
    .benchmark.timing.marker_log.marker_count ==
      (.benchmark.timing.marker_log.invocation_count * 4) and
    (.benchmark.timing.marker_log.sha256 |
      test("^[0-9a-fA-F]{64}$")) and
    .benchmark.argv_template == [
      .compilation.benchmark_path, "--json", "--timing-v2",
      "<sample_id>", "<threads>"
    ] and
    .benchmark.parameters.thread_counts == $thread_counts and
    .benchmark.parameters.warmups_per_thread == $expected_warmups and
    .benchmark.parameters.repetitions_per_thread == $expected_repetitions and
    (.benchmark.samples | length) == $expected_sample_count and
    [.benchmark.samples[].threads] ==
      [$thread_counts[] as $thread |
        range(1; $expected_repetitions + 1) | $thread] and
    [.benchmark.samples[].sample_id] ==
      [$thread_counts[] as $thread |
        range(1; $expected_repetitions + 1) |
        "t\($thread)-r\(.)"] and
    all(.benchmark.samples[]; valid_sample) and
    .benchmark.distributions == (
      .benchmark.samples
      | group_by(.threads)
      | map({
          threads: .[0].threads,
          int_seconds: (map(.int_seconds) | distribution),
          int_gops: (map(.int_gops) | distribution),
          int_worker_cpu_seconds:
            (map(.int_worker_cpu_seconds) | distribution),
          int_process_cpu_seconds:
            (map(.int_process_cpu_seconds) | distribution),
          int_worker_scheduler_residency:
            (map(.int_worker_scheduler_residency) | distribution),
          int_process_scheduler_residency:
            (map(.int_process_scheduler_residency) | distribution),
          int_worker_gops_per_cpu_second:
            (map(.int_worker_gops_per_cpu_second) | distribution),
          int_process_gops_per_cpu_second:
            (map(.int_process_gops_per_cpu_second) | distribution),
          memory_seconds: (map(.memory_seconds) | distribution),
          memory_gib_s: (map(.memory_gib_s) | distribution),
          memory_process_cpu_seconds:
            (map(.memory_process_cpu_seconds) | distribution),
          memory_process_scheduler_residency:
            (map(.memory_process_scheduler_residency) | distribution),
          memory_process_gib_per_cpu_second:
            (map(.memory_process_gib_per_cpu_second) | distribution)
        })
    ) and
    .integrity.all_protected_hashes_match == true and
    .integrity.source_sha256.before == .integrity.source_sha256.after and
    .integrity.compiler_sha256.before == .integrity.compiler_sha256.after and
    .integrity.jq_sha256.before == .integrity.jq_sha256.after and
    .integrity.shasum_sha256.before == .integrity.shasum_sha256.after and
    .integrity.benchmark_sha256.before == .integrity.benchmark_sha256.after
    ' "$EVIDENCE_TMP" >/dev/null
"$CHMOD" 600 "$TIMING_MARKERS"
"$CHMOD" 600 "$EVIDENCE_TMP"
"$MV" "$EVIDENCE_TMP" "$EVIDENCE"

printf '%s\n' "$EVIDENCE"

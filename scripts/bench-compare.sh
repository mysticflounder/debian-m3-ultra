#!/bin/bash
# Validate and descriptively compare one host and five guest benchmark runs.
# Inputs are read only. The sole output is a fresh comparison evidence directory.
set -euo pipefail

export LC_ALL=C
export LANG=C
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 077

readonly JQ=/usr/bin/jq
readonly SHASUM=/usr/bin/shasum
readonly REALPATH=/bin/realpath
readonly DIRNAME=/usr/bin/dirname
readonly MKDIR=/bin/mkdir
readonly MKTEMP=/usr/bin/mktemp
readonly CHMOD=/bin/chmod
readonly MV=/bin/mv
readonly RM=/bin/rm
readonly RMDIR=/bin/rmdir
readonly STAT=/usr/bin/stat

die()
{
    printf 'bench-compare: %s\n' "$*" >&2
    exit 1
}

hash_file()
{
    local path="$1"
    local output
    local digest

    output="$("$SHASUM" -a 256 "$path")" || return 1
    digest=${output%% *}
    [[ $digest =~ ^[0123456789abcdefABCDEF]{64}$ ]] || return 1
    printf '%s\n' "$digest"
}

validate_regular_input()
{
    local path="$1"
    local label="$2"
    local links
    local size

    [[ $path != *$'\n'* && $path != *$'\r'* ]] ||
        die "$label path contains a line break"
    [[ -e $path && ! -L $path && -f $path && -r $path ]] ||
        die "$label must be a readable, non-symlink regular file: $path"
    links="$("$STAT" -f '%l' "$path")" ||
        die "could not inspect $label link count: $path"
    [[ $links =~ ^[0-9]+$ && $links == 1 ]] ||
        die "$label must have exactly one hard link: $path"
    size="$("$STAT" -f '%z' "$path")" ||
        die "could not inspect $label size: $path"
    [[ $size =~ ^[0-9]+$ ]] || die "$label has a malformed size: $path"
    ((size > 0 && size <= 10485760)) ||
        die "$label size is outside 1..10485760 bytes: $path"
}

validate_host()
{
    local path="$1"

    "$JQ" -e '
        def exact_keys($wanted): (keys | sort) == ($wanted | sort);
        def sha256: type == "string" and test("^[0-9a-f]{64}$");
        def positive_finite:
            type == "number" and isfinite and . > 0;
        def absolute: if . < 0 then -. else . end;
        def nearly_equal($left; $right):
            (($left - $right) | absolute) <=
                (1e-12 * (($right | absolute) + 1));
        def stat:
            type == "object" and
            exact_keys(["count", "min", "median", "mean", "max"]) and
            .count == 7 and
            (.min | positive_finite) and
            (.median | positive_finite) and
            (.mean | positive_finite) and
            (.max | positive_finite) and
            .min <= .median and .median <= .max and
            .min <= .mean and .mean <= .max;
        def sample:
            type == "object" and
            exact_keys([
                "threads", "int_iterations_per_thread",
                "int_operations_per_iteration", "int_seconds", "int_gops",
                "memory_bytes", "memory_passes", "memory_seconds",
                "memory_gib_s", "checksum"
            ]) and
            (.threads | type == "number" and floor == . and . > 0) and
            .int_iterations_per_thread == 400000000 and
            .int_operations_per_iteration == 4 and
            .memory_bytes == 268435456 and .memory_passes == 8 and
            (.int_seconds | positive_finite) and
            (.int_gops | positive_finite) and
            (.memory_seconds | positive_finite) and
            (.memory_gib_s | positive_finite) and
            (.checksum | type == "string" and test("^[0-9a-f]{16}$"));
        def distribution_matches($samples; $metrics):
            . as $distribution |
            ($samples | map(select(.threads == $distribution.threads))) as $rows |
            ($rows | length) == 7 and
            all($metrics[];
                . as $metric |
                ($rows | map(.[$metric])) as $values |
                ($values | sort) as $sorted |
                ($distribution[$metric] | stat) and
                $distribution[$metric].count == ($values | length) and
                $distribution[$metric].min == $sorted[0] and
                $distribution[$metric].median == $sorted[3] and
                nearly_equal($distribution[$metric].mean; ($values | add / length)) and
                $distribution[$metric].max == $sorted[6]);
        def unchanged_pair:
            type == "object" and
            (.before | sha256) and (.after | sha256) and .before == .after;
        def unchanged_version:
            type == "object" and .before == .after;

        . as $root |
        type == "object" and
        exact_keys([
            "schema_version", "role", "host", "source", "compiler", "tools",
            "compilation", "benchmark", "thermal_load_notes", "integrity"
        ]) and
        .schema_version == 1 and .role == "host" and
        (.source | exact_keys(["path", "sha256"])) and
        (.source.path | type == "string" and length > 0) and
        (.source.sha256 | sha256) and
        (.compiler | exact_keys(["path", "version", "numeric_version", "sha256"])) and
        .compiler.path == "/opt/homebrew/bin/gcc-16" and
        .compiler.numeric_version == "16.1.0" and
        (.compiler.version | type == "string" and test("GCC 16[.]1[.]0"; "i")) and
        (.compiler.sha256 | sha256) and
        (.compilation | exact_keys(["argv", "benchmark_path", "benchmark_sha256"])) and
        (.compilation.benchmark_sha256 | sha256) and
        (.compilation.argv | type == "array" and length == 10) and
        .compilation.argv[0] == .compiler.path and
        .compilation.argv[1:7] ==
            ["-O2", "-pthread", "-Wall", "-Wextra", "-Werror", "-std=gnu11"] and
        .compilation.argv[7] == "-o" and
        .compilation.argv[8] == .compilation.benchmark_path and
        .compilation.argv[9] == .source.path and
        (.benchmark | exact_keys([
            "argv_template", "parameters", "sample_order", "samples", "distributions"
        ])) and
        (.benchmark.parameters | exact_keys([
            "thread_counts", "warmups_per_thread", "repetitions_per_thread",
            "int_iterations_per_thread", "int_operations_per_iteration",
            "memory_bytes", "memory_passes"
        ])) and
        .benchmark.parameters.thread_counts == [1, 8, 16, 24, 32] and
        .benchmark.parameters.warmups_per_thread == 1 and
        .benchmark.parameters.repetitions_per_thread == 7 and
        .benchmark.parameters.int_iterations_per_thread == 400000000 and
        .benchmark.parameters.int_operations_per_iteration == 4 and
        .benchmark.parameters.memory_bytes == 268435456 and
        .benchmark.parameters.memory_passes == 8 and
        .benchmark.argv_template ==
            [.compilation.benchmark_path, "--json", "<threads>"] and
        .benchmark.sample_order ==
            "thread_counts order, then repetition order; warmups omitted" and
        (.benchmark.samples | type == "array" and length == 35) and
        all(.benchmark.samples[]; sample) and
        ([.benchmark.samples[].threads] ==
            ([1, 8, 16, 24, 32] as $threads |
             [range(0; 35) | $threads[(. / 7 | floor)]])) and
        all(.benchmark.samples | group_by(.threads)[];
            length == 7 and (map(.checksum) | unique | length) == 1) and
        (.benchmark.distributions | type == "array" and length == 5) and
        [.benchmark.distributions[].threads] == [1, 8, 16, 24, 32] and
        all(.benchmark.distributions[];
            exact_keys(["threads", "int_gops", "memory_gib_s"]) and
            distribution_matches($root.benchmark.samples; ["int_gops", "memory_gib_s"])) and
        (.tools | exact_keys(["jq", "shasum"])) and
        (.tools.jq | exact_keys(["path", "version", "sha256"])) and
        (.tools.shasum | exact_keys(["path", "version", "sha256"])) and
        (.tools.jq.sha256 | sha256) and (.tools.shasum.sha256 | sha256) and
        (.integrity | exact_keys([
            "source_sha256", "compiler_sha256", "jq_sha256", "shasum_sha256",
            "benchmark_sha256", "versions", "all_protected_hashes_match"
        ])) and
        .integrity.all_protected_hashes_match == true and
        (.integrity.source_sha256 | unchanged_pair) and
        (.integrity.compiler_sha256 | unchanged_pair) and
        (.integrity.jq_sha256 | unchanged_pair) and
        (.integrity.shasum_sha256 | unchanged_pair) and
        (.integrity.benchmark_sha256 | unchanged_pair) and
        .integrity.source_sha256.before == .source.sha256 and
        .integrity.compiler_sha256.before == .compiler.sha256 and
        .integrity.jq_sha256.before == .tools.jq.sha256 and
        .integrity.shasum_sha256.before == .tools.shasum.sha256 and
        .integrity.benchmark_sha256.before == .compilation.benchmark_sha256 and
        (.integrity.versions | exact_keys(["compiler", "jq", "shasum"])) and
        (.integrity.versions.compiler |
            exact_keys(["before", "after", "numeric_before", "numeric_after"]) and
            unchanged_version) and
        .integrity.versions.compiler.numeric_before == .compiler.numeric_version and
        .integrity.versions.compiler.numeric_before ==
            .integrity.versions.compiler.numeric_after and
        (.integrity.versions.jq |
            exact_keys(["before", "after"]) and unchanged_version) and
        (.integrity.versions.shasum |
            exact_keys(["before", "after"]) and unchanged_version)
    ' "$path" >/dev/null || die "host evidence failed strict validation: $path"
}

validate_guest()
{
    local path="$1"
    local expected_smp="$2"

    "$JQ" -e --argjson expected_smp "$expected_smp" '
        def exact_keys($wanted): (keys | sort) == ($wanted | sort);
        def sha256: type == "string" and test("^[0-9a-f]{64}$");
        def positive_finite:
            type == "number" and isfinite and . > 0;
        def absolute: if . < 0 then -. else . end;
        def nearly_equal($left; $right):
            (($left - $right) | absolute) <=
                (1e-12 * (($right | absolute) + 1));
        def stat:
            type == "object" and
            exact_keys(["count", "min", "median", "mean", "max"]) and
            .count == 7 and
            (.min | positive_finite) and
            (.median | positive_finite) and
            (.mean | positive_finite) and
            (.max | positive_finite) and
            .min <= .median and .median <= .max and
            .min <= .mean and .mean <= .max;
        def sample:
            type == "object" and
            exact_keys([
                "threads", "int_iterations_per_thread",
                "int_operations_per_iteration", "int_seconds", "int_gops",
                "memory_bytes", "memory_passes", "memory_seconds",
                "memory_gib_s", "checksum"
            ]) and
            (.threads | type == "number" and floor == . and . > 0) and
            .int_iterations_per_thread == 400000000 and
            .int_operations_per_iteration == 4 and
            .memory_bytes == 268435456 and .memory_passes == 8 and
            (.int_seconds | positive_finite) and
            (.int_gops | positive_finite) and
            (.memory_seconds | positive_finite) and
            (.memory_gib_s | positive_finite) and
            (.checksum | type == "string" and test("^[0-9a-f]{16}$"));
        def distribution_matches($samples; $metrics):
            . as $distribution |
            ($samples | map(select(.threads == $distribution.threads))) as $rows |
            ($rows | length) == 7 and
            all($metrics[];
                . as $metric |
                ($rows | map(.[$metric])) as $values |
                ($values | sort) as $sorted |
                ($distribution[$metric] | stat) and
                $distribution[$metric].count == ($values | length) and
                $distribution[$metric].min == $sorted[0] and
                $distribution[$metric].median == $sorted[3] and
                nearly_equal($distribution[$metric].mean; ($values | add / length)) and
                $distribution[$metric].max == $sorted[6]);
        def input_hashes_unchanged:
            type == "object" and
            (.sha256_before | sha256) and (.sha256_after | sha256) and
            .sha256_before == .sha256_after;
        def run_hashes_unchanged:
            type == "object" and
            (.sha256_before | sha256) and (.sha256_after | sha256) and
            .sha256_before == .sha256_after;
        def expected_threads:
            if $expected_smp == 1 then [1] else [1, $expected_smp] end;

        . as $root |
        type == "object" and
        exact_keys([
            "schema_version", "role", "metadata", "samples", "distributions",
            "benchmark", "inputs", "run", "safety"
        ]) and
        .schema_version == 1 and .role == "guest" and
        (.benchmark | exact_keys([
            "smp", "memory", "thread_counts", "warmups", "repetitions",
            "sample_order", "int_iterations_per_thread",
            "int_operations_per_iteration", "memory_bytes", "memory_passes",
            "compile_flags", "compile_argv", "argv_template"
        ])) and
        .benchmark.smp == $expected_smp and
        .benchmark.memory == "8G" and
        .benchmark.thread_counts == expected_threads and
        .benchmark.warmups == 1 and .benchmark.repetitions == 7 and
        .benchmark.int_iterations_per_thread == 400000000 and
        .benchmark.int_operations_per_iteration == 4 and
        .benchmark.memory_bytes == 268435456 and .benchmark.memory_passes == 8 and
        .benchmark.compile_flags ==
            ["-O2", "-pthread", "-Wall", "-Wextra", "-Werror", "-std=gnu11"] and
        (.benchmark.compile_argv | type == "array" and length == 10) and
        .benchmark.compile_argv[0] == .metadata.compiler_path and
        .benchmark.compile_argv[1:7] == .benchmark.compile_flags and
        .benchmark.compile_argv[7:10] == ["bench.c", "-o", "bench"] and
        .benchmark.argv_template == ["./bench", "--json", "<threads>"] and
        .benchmark.sample_order ==
            "thread_counts order, then repetition order; warmups omitted" and
        (.metadata | exact_keys([
            "compiler_path", "compiler_family", "compiler_version",
            "compiler_version_line", "kernel_release", "online_cpu_count",
            "cpu_implementer", "cpu_part", "tso_present"
        ])) and
        .metadata.compiler_path == "/usr/bin/gcc" and
        .metadata.compiler_family == "gcc" and
        .metadata.compiler_version == "16.2.0" and
        (.metadata.compiler_version_line |
            type == "string" and test("gcc .*16[.]2[.]0"; "i")) and
        .metadata.online_cpu_count == $expected_smp and
        (.samples | type == "array" and
            length == ((expected_threads | length) * 7)) and
        all(.samples[]; sample) and
        ([.samples[].threads] ==
            (expected_threads as $threads |
             [range(0; (($threads | length) * 7)) |
                $threads[(. / 7 | floor)]])) and
        all(.samples | group_by(.threads)[];
            length == 7 and (map(.checksum) | unique | length) == 1) and
        (.distributions | type == "array" and
            length == (expected_threads | length)) and
        [.distributions[].threads] == expected_threads and
        all(.distributions[];
            exact_keys([
                "threads", "int_seconds", "int_gops",
                "memory_seconds", "memory_gib_s"
            ]) and
            distribution_matches($root.samples; [
                "int_seconds", "int_gops", "memory_seconds", "memory_gib_s"
            ])) and
        (.inputs | exact_keys([
            "kernel_version", "kernel", "initrd", "rootfs", "benchmark_source"
        ])) and
        (.inputs.kernel_version |
            exact_keys(["path", "sha256_before", "sha256_after"]) and
            input_hashes_unchanged) and
        all([.inputs.kernel, .inputs.initrd, .inputs.rootfs][];
            exact_keys(["path", "size", "sha256_before", "sha256_after"]) and
            (.size | type == "number" and floor == . and . > 0) and
            input_hashes_unchanged) and
        (.inputs.benchmark_source |
            exact_keys([
                "path", "sha256_before", "sha256_after",
                "staged_copy_sha256_before", "staged_copy_sha256_after"
            ]) and
            input_hashes_unchanged and
            (.staged_copy_sha256_before | sha256) and
            (.staged_copy_sha256_after | sha256) and
            .staged_copy_sha256_before == .staged_copy_sha256_after and
            .sha256_before == .staged_copy_sha256_before) and
        (.run | exact_keys([
            "qemu", "qemu_img", "timeout", "lsof", "parser", "jq", "realpath"
        ])) and
        (.run.qemu |
            exact_keys(["path", "version", "argv", "sha256_before", "sha256_after"]) and
            (.argv | type == "array" and length > 0) and
            (.argv | index("-no-user-config") != null) and
            (.argv | index("-nodefaults") != null) and
            (.argv | index("-no-reboot") != null) and
            (.argv as $argv |
                ($argv | index("-M")) as $machine_index |
                ($argv | index("-accel")) as $accel_index |
                ($argv | index("-cpu")) as $cpu_index |
                ($argv | index("-smp")) as $smp_index |
                ($argv | index("-m")) as $memory_index |
                ($argv | index("-nic")) as $nic_index |
                ($argv | index("-display")) as $display_index |
                ($argv | index("-monitor")) as $monitor_index |
                $machine_index != null and $argv[$machine_index + 1] == "virt,highmem=on" and
                $accel_index != null and $argv[$accel_index + 1] == "hvf,kernel-irqchip=on" and
                $cpu_index != null and $argv[$cpu_index + 1] == "host" and
                $smp_index != null and
                    $argv[$smp_index + 1] ==
                        ("\($expected_smp),sockets=1,cores=\($expected_smp),threads=1") and
                $memory_index != null and $argv[$memory_index + 1] == "8G" and
                $nic_index != null and $argv[$nic_index + 1] == "none" and
                $display_index != null and $argv[$display_index + 1] == "none" and
                $monitor_index != null and $argv[$monitor_index + 1] == "none" and
                ([ $argv[] | select(type == "string" and
                    test("^if=virtio,file=.*[,]format=qcow2,cache=none$")) ] | length) == 1 and
                ([ $argv[] | select(type == "string" and
                    test("^if=virtio,file=fat:ro:.*[,]format=raw,readonly=on$")) ] | length) == 1) and
            run_hashes_unchanged) and
        all([.run.qemu_img, .run.jq][];
            exact_keys(["path", "version", "sha256_before", "sha256_after"]) and
            run_hashes_unchanged) and
        (.run.timeout |
            exact_keys(["path", "seconds", "sha256_before", "sha256_after"]) and
            .seconds == 1800 and run_hashes_unchanged) and
        all([.run.lsof, .run.parser, .run.realpath][];
            exact_keys(["path", "sha256_before", "sha256_after"]) and
            run_hashes_unchanged) and
        (.safety | exact_keys([
            "host_privilege_required", "explicit_disposable_overlay",
            "root_backing_read_only", "root_backing_opened_via_overlay",
            "source_drive_read_only", "source_block_read_only_proved_in_guest",
            "source_mount_read_only_proved_in_guest",
            "warmup_boundaries_validated_in_guest", "qemu_child_pid_captured",
            "qemu_child_pid_parent_verified", "qemu_wrapper_never_signaled",
            "cleanup_wait_requires_wrapper_not_running_or_stopped",
            "qemu_child_absence_required_before_artifact_cleanup",
            "uncertain_process_state_retains_artifacts_and_lock",
            "build_drive_attached", "network_disabled", "monitor_disabled",
            "display_disabled", "firmware_or_pflash_attached",
            "host_devices_attached", "implicit_disks_disabled",
            "protected_inputs_unchanged", "protected_tools_unchanged",
            "staged_source_unchanged", "overlay_removed_after_shutdown",
            "source_staging_removed_after_shutdown",
            "serial_fifo_removed_after_shutdown"
        ])) and
        .safety.host_privilege_required == false and
        .safety.explicit_disposable_overlay == true and
        .safety.root_backing_read_only == true and
        .safety.root_backing_opened_via_overlay == true and
        .safety.source_drive_read_only == true and
        .safety.source_block_read_only_proved_in_guest == true and
        .safety.source_mount_read_only_proved_in_guest == true and
        .safety.warmup_boundaries_validated_in_guest == true and
        .safety.qemu_child_pid_captured == true and
        .safety.qemu_child_pid_parent_verified == true and
        .safety.qemu_wrapper_never_signaled == true and
        .safety.cleanup_wait_requires_wrapper_not_running_or_stopped == true and
        .safety.qemu_child_absence_required_before_artifact_cleanup == true and
        .safety.uncertain_process_state_retains_artifacts_and_lock == true and
        .safety.build_drive_attached == false and
        .safety.network_disabled == true and .safety.monitor_disabled == true and
        .safety.display_disabled == true and
        .safety.firmware_or_pflash_attached == false and
        .safety.host_devices_attached == false and
        .safety.implicit_disks_disabled == true and
        .safety.protected_inputs_unchanged == true and
        .safety.protected_tools_unchanged == true and
        .safety.staged_source_unchanged == true and
        .safety.overlay_removed_after_shutdown == true and
        .safety.source_staging_removed_after_shutdown == true and
        .safety.serial_fifo_removed_after_shutdown == true
    ' "$path" >/dev/null ||
        die "guest SMP $expected_smp evidence failed strict validation: $path"
}

validate_cross_contract()
{
    local host="$1"
    local guest1="$2"
    local guest8="$3"
    local guest16="$4"
    local guest24="$5"
    local guest32="$6"

    "$JQ" -e \
        --slurpfile host "$host" \
        --slurpfile guest1 "$guest1" \
        --slurpfile guest8 "$guest8" \
        --slurpfile guest16 "$guest16" \
        --slurpfile guest24 "$guest24" \
        --slurpfile guest32 "$guest32" '
        def host_constants:
            {
                int_iterations_per_thread:
                    .benchmark.parameters.int_iterations_per_thread,
                int_operations_per_iteration:
                    .benchmark.parameters.int_operations_per_iteration,
                memory_bytes: .benchmark.parameters.memory_bytes,
                memory_passes: .benchmark.parameters.memory_passes
            };
        def guest_constants:
            {
                int_iterations_per_thread: .benchmark.int_iterations_per_thread,
                int_operations_per_iteration: .benchmark.int_operations_per_iteration,
                memory_bytes: .benchmark.memory_bytes,
                memory_passes: .benchmark.memory_passes
            };

        $host[0] as $h |
        [$guest1[0], $guest8[0], $guest16[0], $guest24[0], $guest32[0]] as $guests |
        ($h | host_constants) as $constants |
        $h.compiler.numeric_version == "16.1.0" and
        all($guests[]; .metadata.compiler_family == "gcc") and
        all($guests[]; .metadata.compiler_version == "16.2.0") and
        all($guests[]; (. | guest_constants) == $constants) and
        all($guests[];
            .benchmark.compile_flags == $h.compilation.argv[1:7]) and
        all($guests[];
            .inputs.benchmark_source.sha256_before == $h.source.sha256) and
        all($guests[];
            .inputs.benchmark_source.path == $h.source.path) and
        all($guests[];
            .inputs.kernel_version.sha256_before ==
                $guests[0].inputs.kernel_version.sha256_before and
            .inputs.kernel.sha256_before == $guests[0].inputs.kernel.sha256_before and
            .inputs.initrd.sha256_before == $guests[0].inputs.initrd.sha256_before and
            .inputs.rootfs.sha256_before == $guests[0].inputs.rootfs.sha256_before) and
        all($guests[];
            . as $guest |
            all($guest.samples[];
                . as $sample |
                (($h.benchmark.samples |
                    map(select(.threads == $sample.threads) | .checksum) |
                    unique) == [$sample.checksum])))
    ' -n >/dev/null || die "evidence files do not share the required benchmark contract"
}

readonly EXPECTED_SMPS=(1 8 16 24 32)
readonly MAX_INPUT_BYTES=10485760

(($# == 6)) ||
    die "usage: $0 HOST_EVIDENCE GUEST_SMP1 GUEST_SMP8 GUEST_SMP16 GUEST_SMP24 GUEST_SMP32"

for tool in "$JQ" "$SHASUM" "$REALPATH"; do
    [[ -e $tool && ! -L $tool && -f $tool && -x $tool ]] ||
        die "required pinned tool is not a non-symlink executable: $tool"
done

JQ_SHA256_BEFORE="$(hash_file "$JQ")" || die "could not hash $JQ"
SHASUM_SHA256_BEFORE="$(hash_file "$SHASUM")" || die "could not hash $SHASUM"
REALPATH_SHA256_BEFORE="$(hash_file "$REALPATH")" || die "could not hash $REALPATH"

SCRIPT_PARENT="$("$DIRNAME" "$0")" || die "could not locate script directory"
REPO_ROOT="$(cd "$SCRIPT_PARENT/.." && pwd -P)" || die "could not locate repository root"
REPO_ROOT="$("$REALPATH" "$REPO_ROOT")" || die "could not canonicalize repository root"
OUT_ROOT="$REPO_ROOT/out"
[[ -e $OUT_ROOT && ! -L $OUT_ROOT && -d $OUT_ROOT ]] ||
    die "output root must already be a non-symlink directory: $OUT_ROOT"

INPUT_ARGUMENTS=("$@")
INPUT_PATHS=()
INPUT_SHA256_BEFORE=()
for ((i = 0; i < 6; i++)); do
    if ((i == 0)); then
        label="host evidence"
    else
        label="guest SMP ${EXPECTED_SMPS[$((i - 1))]} evidence"
    fi
    validate_regular_input "${INPUT_ARGUMENTS[$i]}" "$label"
    canonical="$("$REALPATH" "${INPUT_ARGUMENTS[$i]}")" ||
        die "could not canonicalize $label"
    [[ $canonical != *$'\n'* && $canonical != *$'\r'* ]] ||
        die "$label canonical path contains a line break"
    validate_regular_input "$canonical" "$label"
    INPUT_PATHS[$i]="$canonical"
    INPUT_SHA256_BEFORE[$i]="$(hash_file "$canonical")" ||
        die "could not hash $label: $canonical"
done

for ((i = 0; i < 6; i++)); do
    for ((j = i + 1; j < 6; j++)); do
        [[ ${INPUT_PATHS[$i]} != "${INPUT_PATHS[$j]}" ]] ||
            die "input evidence paths must be distinct: ${INPUT_PATHS[$i]}"
    done
done

validate_host "${INPUT_PATHS[0]}"
for ((i = 0; i < 5; i++)); do
    validate_guest "${INPUT_PATHS[$((i + 1))]}" "${EXPECTED_SMPS[$i]}"
done
validate_cross_contract \
    "${INPUT_PATHS[0]}" "${INPUT_PATHS[1]}" "${INPUT_PATHS[2]}" \
    "${INPUT_PATHS[3]}" "${INPUT_PATHS[4]}" "${INPUT_PATHS[5]}"

RUN_DIR=''
EVIDENCE_TMP=''
COMMITTED=false

cleanup()
{
    local status="$?"

    trap - EXIT
    if ((status != 0)) && [[ $COMMITTED == false ]]; then
        if [[ -n $EVIDENCE_TMP && -n $RUN_DIR &&
            $EVIDENCE_TMP == "$RUN_DIR"/.evidence.json.?????? &&
            -f $EVIDENCE_TMP && ! -L $EVIDENCE_TMP ]]; then
            "$RM" -f -- "$EVIDENCE_TMP"
        fi
        if [[ -n $RUN_DIR && $RUN_DIR == "$OUT_ROOT"/benchmark-comparison.?????? &&
            -d $RUN_DIR && ! -L $RUN_DIR ]]; then
            "$RMDIR" -- "$RUN_DIR" 2>/dev/null || true
        fi
    fi
    exit "$status"
}
trap cleanup EXIT

RUN_DIR="$("$MKTEMP" -d "$OUT_ROOT/benchmark-comparison.XXXXXX")" ||
    die "could not create comparison output directory"
[[ $RUN_DIR == "$OUT_ROOT"/benchmark-comparison.?????? &&
    -d $RUN_DIR && ! -L $RUN_DIR ]] ||
    die "mktemp returned an unsafe output directory"
"$CHMOD" 700 "$RUN_DIR" || die "could not set output directory permissions"
EVIDENCE_TMP="$("$MKTEMP" "$RUN_DIR/.evidence.json.XXXXXX")" ||
    die "could not create temporary comparison evidence"
[[ $EVIDENCE_TMP == "$RUN_DIR"/.evidence.json.?????? &&
    -f $EVIDENCE_TMP && ! -L $EVIDENCE_TMP ]] ||
    die "mktemp returned an unsafe evidence path"

"$JQ" -n \
    --slurpfile host "${INPUT_PATHS[0]}" \
    --slurpfile guest1 "${INPUT_PATHS[1]}" \
    --slurpfile guest8 "${INPUT_PATHS[2]}" \
    --slurpfile guest16 "${INPUT_PATHS[3]}" \
    --slurpfile guest24 "${INPUT_PATHS[4]}" \
    --slurpfile guest32 "${INPUT_PATHS[5]}" \
    --arg host_path "${INPUT_PATHS[0]}" \
    --arg guest1_path "${INPUT_PATHS[1]}" \
    --arg guest8_path "${INPUT_PATHS[2]}" \
    --arg guest16_path "${INPUT_PATHS[3]}" \
    --arg guest24_path "${INPUT_PATHS[4]}" \
    --arg guest32_path "${INPUT_PATHS[5]}" \
    --arg host_sha256 "${INPUT_SHA256_BEFORE[0]}" \
    --arg guest1_sha256 "${INPUT_SHA256_BEFORE[1]}" \
    --arg guest8_sha256 "${INPUT_SHA256_BEFORE[2]}" \
    --arg guest16_sha256 "${INPUT_SHA256_BEFORE[3]}" \
    --arg guest24_sha256 "${INPUT_SHA256_BEFORE[4]}" \
    --arg guest32_sha256 "${INPUT_SHA256_BEFORE[5]}" \
    --arg jq_path "$JQ" \
    --arg shasum_path "$SHASUM" \
    --arg realpath_path "$REALPATH" \
    --arg jq_sha256 "$JQ_SHA256_BEFORE" \
    --arg shasum_sha256 "$SHASUM_SHA256_BEFORE" \
    --arg realpath_sha256 "$REALPATH_SHA256_BEFORE" '
    def metric($host_distribution; $guest_distribution; $name):
        ($host_distribution[$name].median) as $host_median |
        ($guest_distribution[$name].median) as $guest_median |
        ($guest_median / $host_median) as $ratio |
        {
            host_median: $host_median,
            guest_median: $guest_median,
            guest_to_host_ratio: $ratio,
            delta_percent: (($ratio - 1) * 100)
        };
    def comparison_row($host; $guest; $distribution):
        ($host.benchmark.distributions[] |
            select(.threads == $distribution.threads)) as $host_distribution |
        {
            guest_smp: $guest.benchmark.smp,
            threads: $distribution.threads,
            row_kind:
                (if $distribution.threads == 1 and $guest.benchmark.smp == 1
                 then "single_thread_and_full_utilization"
                 elif $distribution.threads == 1
                 then "single_thread_at_smp"
                 else "full_utilization"
                 end),
            int_gops: metric($host_distribution; $distribution; "int_gops"),
            memory_gib_s:
                metric($host_distribution; $distribution; "memory_gib_s")
        };
    def evidence_input($path; $sha256; $role; $smp):
        {
            path: $path,
            sha256_before: $sha256,
            sha256_after: $sha256,
            role: $role
        } + (if $smp == null then {} else {smp: $smp} end);

    $host[0] as $h |
    [$guest1[0], $guest8[0], $guest16[0], $guest24[0], $guest32[0]] as $guests |
    [
        evidence_input($guest1_path; $guest1_sha256; "guest"; 1),
        evidence_input($guest8_path; $guest8_sha256; "guest"; 8),
        evidence_input($guest16_path; $guest16_sha256; "guest"; 16),
        evidence_input($guest24_path; $guest24_sha256; "guest"; 24),
        evidence_input($guest32_path; $guest32_sha256; "guest"; 32)
    ] as $guest_inputs |
    {
        schema_version: 1,
        result: "descriptive_only",
        input_evidence: {
            host: evidence_input($host_path; $host_sha256; "host"; null),
            guests: $guest_inputs
        },
        generator_tools: {
            jq: {
                path: $jq_path,
                sha256_before: $jq_sha256,
                sha256_after: $jq_sha256
            },
            shasum: {
                path: $shasum_path,
                sha256_before: $shasum_sha256,
                sha256_after: $shasum_sha256
            },
            realpath: {
                path: $realpath_path,
                sha256_before: $realpath_sha256,
                sha256_after: $realpath_sha256
            }
        },
        benchmark_contract: {
            host_thread_counts: [1, 8, 16, 24, 32],
            guest_smp_order: [1, 8, 16, 24, 32],
            guest_thread_counts: [[1], [1, 8], [1, 16], [1, 24], [1, 32]],
            warmups: 1,
            repetitions: 7,
            source_sha256: $h.source.sha256,
            constants: {
                int_iterations_per_thread:
                    $h.benchmark.parameters.int_iterations_per_thread,
                int_operations_per_iteration:
                    $h.benchmark.parameters.int_operations_per_iteration,
                memory_bytes: $h.benchmark.parameters.memory_bytes,
                memory_passes: $h.benchmark.parameters.memory_passes
            },
            compile_flags: $h.compilation.argv[1:7],
            compiler: {
                family: "GCC",
                host_version: "16.1.0",
                guest_version: "16.2.0",
                versions_equal: false,
                version_difference_allowed: true
            }
        },
        comparisons:
            [$guests[] as $guest |
             $guest.distributions[] as $distribution |
             comparison_row($h; $guest; $distribution)],
        method_notes: [
            "Ratios are descriptive; no hard gate is applied because a numerical threshold has not been agreed.",
            "Compiler patch versions differ: host GCC 16.1.0 and guest GCC 16.2.0.",
            "Host CPU affinity and thermal control were absent.",
            "Host load during guest runs was not captured.",
            "The memory workload is single-threaded regardless of the requested thread count.",
            "The suite currently covers integer and memory workloads only."
        ]
    }
' >"$EVIDENCE_TMP" || die "could not generate comparison evidence"
"$CHMOD" 600 "$EVIDENCE_TMP" || die "could not set evidence permissions"

"$JQ" -e '
    def exact_keys($wanted): (keys | sort) == ($wanted | sort);
    def sha256: type == "string" and test("^[0-9a-f]{64}$");
    def positive_finite: type == "number" and isfinite and . > 0;
    def evidence_hashes:
        (.sha256_before | sha256) and (.sha256_after | sha256) and
        .sha256_before == .sha256_after;
    def metric:
        type == "object" and
        exact_keys([
            "host_median", "guest_median", "guest_to_host_ratio", "delta_percent"
        ]) and
        (.host_median | positive_finite) and
        (.guest_median | positive_finite) and
        (.guest_to_host_ratio | positive_finite) and
        (.delta_percent | type == "number" and isfinite) and
        ((.guest_to_host_ratio - (.guest_median / .host_median)) < 1e-12) and
        ((.guest_to_host_ratio - (.guest_median / .host_median)) > -1e-12) and
        ((.delta_percent - ((.guest_to_host_ratio - 1) * 100)) < 1e-10) and
        ((.delta_percent - ((.guest_to_host_ratio - 1) * 100)) > -1e-10);

    type == "object" and
    exact_keys([
        "schema_version", "result", "input_evidence", "generator_tools",
        "benchmark_contract", "comparisons", "method_notes"
    ]) and
    .schema_version == 1 and
    .result == "descriptive_only" and
    (.input_evidence | exact_keys(["host", "guests"])) and
    (.input_evidence.host |
        exact_keys(["path", "sha256_before", "sha256_after", "role"]) and
        .role == "host" and (.path | type == "string" and startswith("/")) and
        evidence_hashes) and
    (.input_evidence.guests | type == "array" and length == 5) and
    all(.input_evidence.guests[];
        exact_keys(["path", "sha256_before", "sha256_after", "role", "smp"]) and
        .role == "guest" and (.path | type == "string" and startswith("/")) and
        evidence_hashes) and
    (.input_evidence.guests | map(.smp)) == [1, 8, 16, 24, 32] and
    ([.input_evidence.host.path] + [.input_evidence.guests[].path] |
        unique | length) == 6 and
    (.generator_tools | exact_keys(["jq", "shasum", "realpath"])) and
    all(.generator_tools[];
        exact_keys(["path", "sha256_before", "sha256_after"]) and
        (.path | type == "string" and startswith("/")) and evidence_hashes) and
    (.benchmark_contract | exact_keys([
        "host_thread_counts", "guest_smp_order", "guest_thread_counts",
        "warmups", "repetitions", "source_sha256", "constants",
        "compile_flags", "compiler"
    ])) and
    .benchmark_contract.host_thread_counts == [1, 8, 16, 24, 32] and
    .benchmark_contract.guest_smp_order == [1, 8, 16, 24, 32] and
    .benchmark_contract.guest_thread_counts ==
        [[1], [1, 8], [1, 16], [1, 24], [1, 32]] and
    .benchmark_contract.warmups == 1 and
    .benchmark_contract.repetitions == 7 and
    (.benchmark_contract.source_sha256 | sha256) and
    (.benchmark_contract.constants | exact_keys([
        "int_iterations_per_thread", "int_operations_per_iteration",
        "memory_bytes", "memory_passes"
    ])) and
    .benchmark_contract.constants == {
        int_iterations_per_thread: 400000000,
        int_operations_per_iteration: 4,
        memory_bytes: 268435456,
        memory_passes: 8
    } and
    .benchmark_contract.compile_flags ==
        ["-O2", "-pthread", "-Wall", "-Wextra", "-Werror", "-std=gnu11"] and
    (.benchmark_contract.compiler | exact_keys([
        "family", "host_version", "guest_version", "versions_equal",
        "version_difference_allowed"
    ])) and
    .benchmark_contract.compiler == {
        family: "GCC",
        host_version: "16.1.0",
        guest_version: "16.2.0",
        versions_equal: false,
        version_difference_allowed: true
    } and
    (.comparisons | length) == 9 and
    (.comparisons | map([.guest_smp, .threads])) ==
        [[1, 1], [8, 1], [8, 8], [16, 1], [16, 16],
         [24, 1], [24, 24], [32, 1], [32, 32]] and
    ([.comparisons[] | select(.threads == 1)] | length) == 5 and
    ([.comparisons[] | select(.threads == .guest_smp)] | length) == 5 and
    all(.comparisons[];
        exact_keys(["guest_smp", "threads", "row_kind", "int_gops", "memory_gib_s"]) and
        .row_kind ==
            (if .threads == 1 and .guest_smp == 1
             then "single_thread_and_full_utilization"
             elif .threads == 1 then "single_thread_at_smp"
             else "full_utilization" end) and
        (.int_gops | metric) and (.memory_gib_s | metric)) and
    (.method_notes | type == "array" and length == 6) and
    all(.method_notes[]; type == "string" and length > 0) and
    (tostring |
        test("machine[-_ ]?id|boot[-_ ]?id|host[-_ ]?name|serial[-_ ]?(number|id)|(^|[^a-z])(pass|fail)([^a-z]|$)"; "i") |
        not)
' "$EVIDENCE_TMP" >/dev/null || die "generated comparison evidence failed validation"

for ((i = 0; i < 6; i++)); do
    after="$(hash_file "${INPUT_PATHS[$i]}")" ||
        die "could not rehash input evidence: ${INPUT_PATHS[$i]}"
    [[ $after == "${INPUT_SHA256_BEFORE[$i]}" ]] ||
        die "input evidence changed during comparison: ${INPUT_PATHS[$i]}"
done
JQ_SHA256_AFTER="$(hash_file "$JQ")" || die "could not rehash $JQ"
SHASUM_SHA256_AFTER="$(hash_file "$SHASUM")" || die "could not rehash $SHASUM"
REALPATH_SHA256_AFTER="$(hash_file "$REALPATH")" || die "could not rehash $REALPATH"
[[ $JQ_SHA256_AFTER == "$JQ_SHA256_BEFORE" ]] || die "$JQ changed during comparison"
[[ $SHASUM_SHA256_AFTER == "$SHASUM_SHA256_BEFORE" ]] ||
    die "$SHASUM changed during comparison"
[[ $REALPATH_SHA256_AFTER == "$REALPATH_SHA256_BEFORE" ]] ||
    die "$REALPATH changed during comparison"

EVIDENCE_PATH="$RUN_DIR/evidence.json"
"$MV" -- "$EVIDENCE_TMP" "$EVIDENCE_PATH" ||
    die "could not atomically install comparison evidence"
EVIDENCE_TMP=''
COMMITTED=true
printf '%s\n' "$EVIDENCE_PATH"

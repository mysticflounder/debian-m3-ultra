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

validate_single_json_document()
{
    local path="$1"
    local label="$2"

    "$JQ" -s -e 'length == 1' "$path" >/dev/null ||
        die "$label must contain exactly one top-level JSON document: $path"
}

validate_host()
{
    local path="$1"

    "$JQ" -e '
        def exact_keys($wanted): (keys | sort) == ($wanted | sort);
        def sha256: type == "string" and test("^[0-9a-f]{64}$");
        def positive_finite:
            type == "number" and isfinite and . > 0;
        def absolute_nonempty_path:
            type == "string" and length > 1 and startswith("/");
        def absolute: if . < 0 then -. else . end;
        def nearly_equal($left; $right):
            (($left - $right) | absolute) <=
                (1e-12 * (($right | absolute) + 1));
        def timing_nearly_equal($left; $right):
            (($left - $right) | absolute) <=
                (1e-7 * (($right | absolute) + 1));
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
        def sample_v1:
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
        def sample_v2:
            type == "object" and
            exact_keys([
                "checksum", "int_gops", "int_iterations_per_thread",
                "int_operations_per_iteration", "int_process_cpu_seconds",
                "int_process_gops_per_cpu_second",
                "int_process_scheduler_residency", "int_seconds",
                "int_worker_cpu_seconds", "int_worker_gops_per_cpu_second",
                "int_worker_scheduler_residency", "memory_bytes",
                "memory_gib_s", "memory_passes",
                "memory_process_cpu_seconds",
                "memory_process_gib_per_cpu_second",
                "memory_process_scheduler_residency", "memory_seconds",
                "sample_id", "threads", "timing_version"
            ]) and
            .timing_version == 2 and
            (.sample_id | type == "string" and
                test("^[A-Za-z0-9_.:-]{1,64}$")) and
            (.threads | type == "number" and floor == . and . > 0) and
            .int_iterations_per_thread == 400000000 and
            .int_operations_per_iteration == 4 and
            .memory_bytes == 268435456 and .memory_passes == 8 and
            all([
                .int_seconds, .int_gops, .int_worker_cpu_seconds,
                .int_process_cpu_seconds, .int_worker_scheduler_residency,
                .int_process_scheduler_residency,
                .int_worker_gops_per_cpu_second,
                .int_process_gops_per_cpu_second, .memory_seconds,
                .memory_gib_s, .memory_process_cpu_seconds,
                .memory_process_scheduler_residency,
                .memory_process_gib_per_cpu_second
            ][]; positive_finite) and
            .int_worker_cpu_seconds <= (.int_process_cpu_seconds + 0.001) and
            .int_worker_scheduler_residency <= 1.01 and
            .int_process_scheduler_residency <= 1.05 and
            .memory_process_scheduler_residency <= 1.05 and
            timing_nearly_equal(.int_gops;
                (400000000 * .threads * 4 / .int_seconds / 1e9)) and
            timing_nearly_equal(.int_worker_scheduler_residency;
                (.int_worker_cpu_seconds / (.int_seconds * .threads))) and
            timing_nearly_equal(.int_process_scheduler_residency;
                (.int_process_cpu_seconds / (.int_seconds * .threads))) and
            timing_nearly_equal(.int_worker_gops_per_cpu_second;
                (400000000 * .threads * 4 /
                    .int_worker_cpu_seconds / 1e9)) and
            timing_nearly_equal(.int_process_gops_per_cpu_second;
                (400000000 * .threads * 4 /
                    .int_process_cpu_seconds / 1e9)) and
            timing_nearly_equal(.memory_gib_s;
                (268435456 * 8 / .memory_seconds / 1073741824)) and
            timing_nearly_equal(.memory_process_scheduler_residency;
                (.memory_process_cpu_seconds / .memory_seconds)) and
            timing_nearly_equal(.memory_process_gib_per_cpu_second;
                (268435456 * 8 /
                    .memory_process_cpu_seconds / 1073741824)) and
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
        (.schema_version == 1 or .schema_version == 2) and .role == "host" and
        (.source | exact_keys(["path", "sha256"])) and
        (.source.path | absolute_nonempty_path) and
        (.source.sha256 | sha256) and
        (.compiler | exact_keys(["path", "version", "numeric_version", "sha256"])) and
        .compiler.path == "/opt/homebrew/bin/gcc-16" and
        .compiler.numeric_version == "16.1.0" and
        (.compiler.version | type == "string" and test("GCC 16[.]1[.]0"; "i")) and
        (.compiler.sha256 | sha256) and
        (.compilation | exact_keys(["argv", "benchmark_path", "benchmark_sha256"])) and
        (.compilation.benchmark_path | absolute_nonempty_path) and
        (.compilation.benchmark_sha256 | sha256) and
        (.compilation.argv | type == "array" and length == 10) and
        .compilation.argv[0] == .compiler.path and
        .compilation.argv[1:7] ==
            ["-O2", "-pthread", "-Wall", "-Wextra", "-Werror", "-std=gnu11"] and
        .compilation.argv[7] == "-o" and
        .compilation.argv[8] == .compilation.benchmark_path and
        .compilation.argv[9] == .source.path and
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
        .benchmark.sample_order ==
            "thread_counts order, then repetition order; warmups omitted" and
        (.benchmark.samples | type == "array" and length == 35) and
        ([.benchmark.samples[].threads] ==
            ([1, 8, 16, 24, 32] as $threads |
             [range(0; 35) | $threads[(. / 7 | floor)]])) and
        all(.benchmark.samples | group_by(.threads)[];
            length == 7 and (map(.checksum) | unique | length) == 1) and
        (.benchmark.distributions | type == "array" and length == 5) and
        [.benchmark.distributions[].threads] == [1, 8, 16, 24, 32] and
        (if .schema_version == 1 then
            (.benchmark | exact_keys([
                "argv_template", "parameters", "sample_order", "samples",
                "distributions"
            ])) and
            .benchmark.argv_template ==
                [.compilation.benchmark_path, "--json", "<threads>"] and
            all(.benchmark.samples[]; sample_v1) and
            all(.benchmark.distributions[];
                exact_keys(["threads", "int_gops", "memory_gib_s"]) and
                distribution_matches($root.benchmark.samples;
                    ["int_gops", "memory_gib_s"]))
        else
            (.benchmark | exact_keys([
                "argv_template", "parameters", "sample_order", "samples",
                "distributions", "timing"
            ])) and
            .benchmark.argv_template == [
                .compilation.benchmark_path, "--json", "--timing-v2",
                "<sample_id>", "<threads>"
            ] and
            (.benchmark.timing | exact_keys([
                "version", "sample_id_format", "integer_worker_cpu_source",
                "process_cpu_source", "wall_clock_source",
                "derived_formulas", "marker_log"
            ])) and
            .benchmark.timing.version == 2 and
            .benchmark.timing.sample_id_format ==
                "t<threads>-w<warmup-ordinal> or t<threads>-r<repetition-ordinal>" and
            .benchmark.timing.integer_worker_cpu_source ==
                "sum of each worker thread CPU clock over its integer loop" and
            .benchmark.timing.process_cpu_source ==
                "getrusage(RUSAGE_SELF) user plus system CPU time deltas" and
            .benchmark.timing.wall_clock_source == "CLOCK_MONOTONIC" and
            .benchmark.timing.derived_formulas == {
                int_worker_scheduler_residency:
                    "int_worker_cpu_seconds / (int_seconds * threads)",
                int_process_scheduler_residency:
                    "int_process_cpu_seconds / (int_seconds * threads)",
                memory_process_scheduler_residency:
                    "memory_process_cpu_seconds / memory_seconds",
                int_worker_gops_per_cpu_second:
                    "integer operations / int_worker_cpu_seconds / 1e9",
                int_process_gops_per_cpu_second:
                    "integer operations / int_process_cpu_seconds / 1e9",
                memory_process_gib_per_cpu_second:
                    "memory bytes times passes / memory_process_cpu_seconds / 2^30"
            } and
            (.benchmark.timing.marker_log | exact_keys([
                "path", "sha256", "invocation_count", "marker_count"
            ])) and
            (.benchmark.timing.marker_log.path |
                type == "string" and startswith("/")) and
            (.benchmark.timing.marker_log.sha256 | sha256) and
            .benchmark.timing.marker_log.invocation_count == 40 and
            .benchmark.timing.marker_log.marker_count == 160 and
            all(.benchmark.samples[]; sample_v2) and
            [.benchmark.samples[].sample_id] ==
                [[1, 8, 16, 24, 32][] as $threads | range(1; 8) |
                    "t\($threads)-r\(.)"] and
            all(.benchmark.distributions[];
                exact_keys([
                    "threads", "int_seconds", "int_gops",
                    "int_worker_cpu_seconds", "int_process_cpu_seconds",
                    "int_worker_scheduler_residency",
                    "int_process_scheduler_residency",
                    "int_worker_gops_per_cpu_second",
                    "int_process_gops_per_cpu_second", "memory_seconds",
                    "memory_gib_s", "memory_process_cpu_seconds",
                    "memory_process_scheduler_residency",
                    "memory_process_gib_per_cpu_second"
                ]) and
                distribution_matches($root.benchmark.samples; [
                    "int_seconds", "int_gops", "int_worker_cpu_seconds",
                    "int_process_cpu_seconds",
                    "int_worker_scheduler_residency",
                    "int_process_scheduler_residency",
                    "int_worker_gops_per_cpu_second",
                    "int_process_gops_per_cpu_second", "memory_seconds",
                    "memory_gib_s", "memory_process_cpu_seconds",
                    "memory_process_scheduler_residency",
                    "memory_process_gib_per_cpu_second"
                ]))
        end) and
        (.tools | exact_keys(["jq", "shasum"])) and
        (.tools.jq | exact_keys(["path", "version", "sha256"])) and
        (.tools.shasum | exact_keys(["path", "version", "sha256"])) and
        (.tools.jq.path | absolute_nonempty_path) and
        (.tools.shasum.path | absolute_nonempty_path) and
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

validate_guest_v1()
{
    local path="$1"
    local expected_smp="$2"

    "$JQ" -e --argjson expected_smp "$expected_smp" '
        def exact_keys($wanted): (keys | sort) == ($wanted | sort);
        def sha256: type == "string" and test("^[0-9a-f]{64}$");
        def positive_finite:
            type == "number" and isfinite and . > 0;
        def absolute_nonempty_path:
            type == "string" and length > 1 and startswith("/");
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
            (.path | absolute_nonempty_path) and
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
            (.path | absolute_nonempty_path) and
            run_hashes_unchanged) and
        (.run.timeout |
            exact_keys(["path", "seconds", "sha256_before", "sha256_after"]) and
            (.path | absolute_nonempty_path) and
            .seconds == 1800 and run_hashes_unchanged) and
        all([.run.lsof, .run.parser, .run.realpath][];
            exact_keys(["path", "sha256_before", "sha256_after"]) and
            (.path | absolute_nonempty_path) and
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

validate_guest_v2()
{
    local path="$1"
    local expected_smp="$2"

    "$JQ" -e --argjson expected_smp "$expected_smp" '
        def exact_keys($wanted): (keys | sort) == ($wanted | sort);
        def sha256: type == "string" and test("^[0-9a-f]{64}$");
        def positive_finite: type == "number" and isfinite and . > 0;
        def nonnegative_finite: type == "number" and isfinite and . >= 0;
        def absolute_nonempty_path:
            type == "string" and length > 1 and startswith("/");
        def absolute: if . < 0 then -. else . end;
        def timing_nearly_equal($left; $right):
            (($left - $right) | absolute) <=
                (1e-7 * (($right | absolute) + 1));
        def stat:
            type == "object" and
            exact_keys(["count", "min", "median", "mean", "max"]) and
            .count == 7 and
            all([.min, .median, .mean, .max][]; positive_finite) and
            .min <= .median and .median <= .max and
            .min <= .mean and .mean <= .max;
        def expected_threads:
            if $expected_smp == 1 then [1] else [1, $expected_smp] end;
        def sample_v2:
            type == "object" and
            exact_keys([
                "checksum", "int_gops", "int_iterations_per_thread",
                "int_operations_per_iteration", "int_process_cpu_seconds",
                "int_process_gops_per_cpu_second",
                "int_process_scheduler_residency", "int_seconds",
                "int_worker_cpu_seconds", "int_worker_gops_per_cpu_second",
                "int_worker_scheduler_residency", "memory_bytes",
                "memory_gib_s", "memory_passes",
                "memory_process_cpu_seconds",
                "memory_process_gib_per_cpu_second",
                "memory_process_scheduler_residency", "memory_seconds",
                "sample_id", "threads", "timing_version"
            ]) and
            .timing_version == 2 and
            (.sample_id | test("^[A-Za-z0-9_.:-]{1,64}$")) and
            (.threads | type == "number" and floor == . and . > 0) and
            .int_iterations_per_thread == 400000000 and
            .int_operations_per_iteration == 4 and
            .memory_bytes == 268435456 and .memory_passes == 8 and
            all([
                .int_seconds, .int_gops, .int_worker_cpu_seconds,
                .int_process_cpu_seconds, .int_worker_scheduler_residency,
                .int_process_scheduler_residency,
                .int_worker_gops_per_cpu_second,
                .int_process_gops_per_cpu_second, .memory_seconds,
                .memory_gib_s, .memory_process_cpu_seconds,
                .memory_process_scheduler_residency,
                .memory_process_gib_per_cpu_second
            ][]; positive_finite) and
            .int_worker_cpu_seconds <= (.int_process_cpu_seconds + 0.001) and
            .int_worker_scheduler_residency <= 1.01 and
            .int_process_scheduler_residency <= 1.05 and
            .memory_process_scheduler_residency <= 1.05 and
            timing_nearly_equal(.int_gops;
                (400000000 * .threads * 4 / .int_seconds / 1e9)) and
            timing_nearly_equal(.int_worker_scheduler_residency;
                (.int_worker_cpu_seconds / (.int_seconds * .threads))) and
            timing_nearly_equal(.int_process_scheduler_residency;
                (.int_process_cpu_seconds / (.int_seconds * .threads))) and
            timing_nearly_equal(.int_worker_gops_per_cpu_second;
                (400000000 * .threads * 4 /
                    .int_worker_cpu_seconds / 1e9)) and
            timing_nearly_equal(.int_process_gops_per_cpu_second;
                (400000000 * .threads * 4 /
                    .int_process_cpu_seconds / 1e9)) and
            timing_nearly_equal(.memory_gib_s;
                (268435456 * 8 / .memory_seconds / 1073741824)) and
            timing_nearly_equal(.memory_process_scheduler_residency;
                (.memory_process_cpu_seconds / .memory_seconds)) and
            timing_nearly_equal(.memory_process_gib_per_cpu_second;
                (268435456 * 8 /
                    .memory_process_cpu_seconds / 1073741824)) and
            (.checksum | type == "string" and test("^[0-9a-f]{16}$"));
        def distribution_matches($samples; $metrics):
            . as $distribution |
            ($samples | map(select(.threads == $distribution.threads))) as $rows |
            all($metrics[];
                . as $metric |
                ($rows | map(.[$metric])) as $values |
                ($values | sort) as $sorted |
                ($distribution[$metric] | stat) and
                $distribution[$metric].min == $sorted[0] and
                $distribution[$metric].median == $sorted[3] and
                (($distribution[$metric].mean - ($values | add / length)) |
                    absolute) < 1e-12 and
                $distribution[$metric].max == $sorted[6]);
        def expected_observations:
            [expected_threads[] as $threads |
             ((range(1; 2) | "t\($threads)-w\(.)"),
              (range(1; 8) | "t\($threads)-r\(.)")) as $sample_id |
             {sample_id: $sample_id, workload: "integer"},
             {sample_id: $sample_id, workload: "memory"}];

        . as $root |
        type == "object" and
        exact_keys([
            "benchmark", "cpu_accounting", "distributions", "inputs",
            "metadata", "role", "run", "safety", "samples",
            "schema_version"
        ]) and
        .schema_version == 2 and .role == "guest" and
        (.benchmark | exact_keys([
            "smp", "memory", "thread_counts", "warmups", "repetitions",
            "sample_order", "accounting_sample_order",
            "int_iterations_per_thread", "int_operations_per_iteration",
            "memory_bytes", "memory_passes", "compile_flags",
            "compile_argv", "argv_template"
        ])) and
        .benchmark.smp == $expected_smp and .benchmark.memory == "8G" and
        .benchmark.thread_counts == expected_threads and
        .benchmark.warmups == 1 and .benchmark.repetitions == 7 and
        .benchmark.sample_order ==
            "thread_counts order, then repetition order; warmups omitted" and
        .benchmark.accounting_sample_order ==
            "thread_counts order, warmup then measured, each integer then memory" and
        .benchmark.int_iterations_per_thread == 400000000 and
        .benchmark.int_operations_per_iteration == 4 and
        .benchmark.memory_bytes == 268435456 and
        .benchmark.memory_passes == 8 and
        .benchmark.compile_flags ==
            ["-O2", "-pthread", "-Wall", "-Wextra", "-Werror", "-std=gnu11"] and
        .benchmark.compile_argv == [
            "/usr/bin/gcc", "-O2", "-pthread", "-Wall", "-Wextra",
            "-Werror", "-std=gnu11", "bench.c", "-o", "bench"
        ] and
        .benchmark.argv_template == [
            "./bench", "--json", "--timing-v2", "<sample_id>", "<threads>"
        ] and
        (.samples | length) == ((expected_threads | length) * 7) and
        all(.samples[]; sample_v2) and
        [.samples[] | {threads, sample_id}] ==
            [expected_threads[] as $threads | range(1; 8) |
                {threads: $threads, sample_id: "t\($threads)-r\(.)"}] and
        all(.samples | group_by(.threads)[];
            length == 7 and (map(.checksum) | unique | length) == 1) and
        (.distributions | length) == (expected_threads | length) and
        [.distributions[].threads] == expected_threads and
        all(.distributions[];
            exact_keys([
                "threads", "int_seconds", "int_gops",
                "int_worker_cpu_seconds", "int_process_cpu_seconds",
                "int_worker_scheduler_residency",
                "int_process_scheduler_residency",
                "int_worker_gops_per_cpu_second",
                "int_process_gops_per_cpu_second", "memory_seconds",
                "memory_gib_s", "memory_process_cpu_seconds",
                "memory_process_scheduler_residency",
                "memory_process_gib_per_cpu_second"
            ]) and
            distribution_matches($root.samples; [
                "int_seconds", "int_gops", "int_worker_cpu_seconds",
                "int_process_cpu_seconds", "int_worker_scheduler_residency",
                "int_process_scheduler_residency",
                "int_worker_gops_per_cpu_second",
                "int_process_gops_per_cpu_second", "memory_seconds",
                "memory_gib_s", "memory_process_cpu_seconds",
                "memory_process_scheduler_residency",
                "memory_process_gib_per_cpu_second"
            ])) and
        (.cpu_accounting | exact_keys(["observer", "observations"])) and
        (.cpu_accounting.observer | exact_keys([
            "source_path", "source_sha256_before", "source_sha256_after",
            "compiler_path", "compiler_sha256_before",
            "compiler_sha256_after", "tail_path", "tail_sha256_before",
            "tail_sha256_after", "binary_path", "binary_sha256_before",
            "binary_sha256_after"
        ])) and
        all([
            .cpu_accounting.observer.source_sha256_before,
            .cpu_accounting.observer.source_sha256_after,
            .cpu_accounting.observer.compiler_sha256_before,
            .cpu_accounting.observer.compiler_sha256_after,
            .cpu_accounting.observer.tail_sha256_before,
            .cpu_accounting.observer.tail_sha256_after,
            .cpu_accounting.observer.binary_sha256_before,
            .cpu_accounting.observer.binary_sha256_after
        ][]; sha256) and
        .cpu_accounting.observer.source_sha256_before ==
            .cpu_accounting.observer.source_sha256_after and
        .cpu_accounting.observer.compiler_sha256_before ==
            .cpu_accounting.observer.compiler_sha256_after and
        .cpu_accounting.observer.tail_sha256_before ==
            .cpu_accounting.observer.tail_sha256_after and
        .cpu_accounting.observer.binary_sha256_before ==
            .cpu_accounting.observer.binary_sha256_after and
        all([
            .cpu_accounting.observer.source_path,
            .cpu_accounting.observer.compiler_path,
            .cpu_accounting.observer.tail_path,
            .cpu_accounting.observer.binary_path
        ][]; absolute_nonempty_path) and
        ([.cpu_accounting.observations[] | {sample_id, workload}] ==
            expected_observations) and
        all(.cpu_accounting.observations[];
            type == "object" and
            exact_keys([
                "accounting_status", "boundary_source", "host_wall_seconds",
                "qemu_management_cpu_seconds", "qemu_process_cpu_seconds",
                "qemu_vcpu_cpu_seconds", "sample_id",
                "sampling_uncertainty_seconds",
                "counter_skew_clamped_seconds", "vcpu_thread_count",
                "vcpu_thread_set_stable", "workload"
            ]) and
            .accounting_status == "ok" and
            .boundary_source == "serial-marker-receipt" and
            .vcpu_thread_count == $expected_smp and
            .vcpu_thread_set_stable == true and
            (.host_wall_seconds | positive_finite) and
            (.qemu_process_cpu_seconds | nonnegative_finite) and
            (.qemu_vcpu_cpu_seconds | nonnegative_finite) and
            (.qemu_management_cpu_seconds | nonnegative_finite) and
            (.sampling_uncertainty_seconds | nonnegative_finite) and
            (.counter_skew_clamped_seconds | nonnegative_finite) and
            .counter_skew_clamped_seconds <=
                (2 * $expected_smp * .sampling_uncertainty_seconds) and
            .qemu_vcpu_cpu_seconds <=
                ($expected_smp *
                 (1.01 * .host_wall_seconds +
                  2 * .sampling_uncertainty_seconds) + 1e-9) and
            ((.qemu_process_cpu_seconds - .qemu_vcpu_cpu_seconds -
              .qemu_management_cpu_seconds +
              .counter_skew_clamped_seconds) | absolute) < 0.000001) and
        all(.cpu_accounting.observations[] |
            select(.sample_id | test("-r[1-7]$")) |
            select(.workload == "integer");
            .qemu_vcpu_cpu_seconds > 0) and
        (.run | exact_keys([
            "clang", "cpu_observer", "jq", "lsof", "parser", "qemu",
            "qemu_img", "realpath", "tail", "timeout"
        ])) and
        all([.run.clang, .run.tail][];
            exact_keys(["path", "sha256_before", "sha256_after"]) and
            (.path | absolute_nonempty_path) and
            (.sha256_before | sha256) and
            .sha256_before == .sha256_after) and
        (.run.cpu_observer | exact_keys([
            "source_path", "source_sha256_before", "source_sha256_after",
            "binary_path", "binary_sha256_before", "binary_sha256_after"
        ])) and
        (.run.cpu_observer.source_sha256_before | sha256) and
        (.run.cpu_observer.binary_sha256_before | sha256) and
        (.run.cpu_observer.source_path | absolute_nonempty_path) and
        (.run.cpu_observer.binary_path | absolute_nonempty_path) and
        .run.cpu_observer.source_sha256_before ==
            .run.cpu_observer.source_sha256_after and
        .run.cpu_observer.binary_sha256_before ==
            .run.cpu_observer.binary_sha256_after and
        .cpu_accounting.observer.source_path == .run.cpu_observer.source_path and
        .cpu_accounting.observer.source_sha256_before ==
            .run.cpu_observer.source_sha256_before and
        .cpu_accounting.observer.compiler_path == .run.clang.path and
        .cpu_accounting.observer.compiler_sha256_before ==
            .run.clang.sha256_before and
        .cpu_accounting.observer.tail_path == .run.tail.path and
        .cpu_accounting.observer.tail_sha256_before ==
            .run.tail.sha256_before and
        .cpu_accounting.observer.binary_path == .run.cpu_observer.binary_path and
        .cpu_accounting.observer.binary_sha256_before ==
            .run.cpu_observer.binary_sha256_before
    ' "$path" >/dev/null ||
        die "guest SMP $expected_smp schema-2 evidence failed strict validation: $path"

    validate_guest_v1 <("$JQ" '
        {
            schema_version: 1,
            role: .role,
            metadata: .metadata,
            samples: [.samples[] | {
                threads, int_iterations_per_thread,
                int_operations_per_iteration, int_seconds, int_gops,
                memory_bytes, memory_passes, memory_seconds, memory_gib_s,
                checksum
            }],
            distributions: [.distributions[] | {
                threads, int_seconds, int_gops, memory_seconds, memory_gib_s
            }],
            benchmark: (.benchmark |
                del(.accounting_sample_order) |
                .argv_template = ["./bench", "--json", "<threads>"]),
            inputs: .inputs,
            run: (.run | {
                qemu, qemu_img, timeout, lsof, parser, jq, realpath
            }),
            safety: .safety
        }
    ' "$path") "$expected_smp"
}

validate_guest()
{
    local path="$1"
    local expected_smp="$2"
    local schema_version

    schema_version="$("$JQ" -er '
        .schema_version |
        select(type == "number" and (. == 1 or . == 2))
    ' "$path")" ||
        die "guest SMP $expected_smp has an unsupported schema version: $path"
    case "$schema_version" in
        1) validate_guest_v1 "$path" "$expected_smp" ;;
        2) validate_guest_v2 "$path" "$expected_smp" ;;
        *) die "guest SMP $expected_smp has an unsupported schema version: $path" ;;
    esac
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
    validate_single_json_document "$canonical" "$label"
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
    def cpu_sample_row($host; $guest; $guest_sample):
        ($guest_sample.sample_id |
            capture("-r(?<ordinal>[1-7])$").ordinal | tonumber) as $ordinal |
        ($host.benchmark.samples |
            map(select(.threads == $guest_sample.threads and
                       .sample_id == $guest_sample.sample_id))[0]) as $host_sample |
        ($guest.cpu_accounting.observations |
            map(select(.sample_id == $guest_sample.sample_id and
                       .workload == "integer"))[0]) as $observation |
        (400000000 * $guest_sample.threads * 4 / 1e9) as $fixed_work_gop |
        {
            guest_smp: $guest.benchmark.smp,
            threads: $guest_sample.threads,
            sample_ordinal: $ordinal,
            sample_id: $guest_sample.sample_id,
            fixed_integer_work_gop: $fixed_work_gop,
            host_native: {
                worker_cpu_seconds: $host_sample.int_worker_cpu_seconds,
                worker_gops_per_cpu_second:
                    $host_sample.int_worker_gops_per_cpu_second,
                worker_scheduler_residency:
                    $host_sample.int_worker_scheduler_residency
            },
            guest_native: {
                worker_cpu_seconds: $guest_sample.int_worker_cpu_seconds,
                worker_gops_per_cpu_second:
                    $guest_sample.int_worker_gops_per_cpu_second,
                worker_scheduler_residency:
                    $guest_sample.int_worker_scheduler_residency
            },
            guest_qemu: {
                host_wall_seconds: $observation.host_wall_seconds,
                qemu_process_cpu_seconds:
                    $observation.qemu_process_cpu_seconds,
                qemu_vcpu_cpu_seconds: $observation.qemu_vcpu_cpu_seconds,
                qemu_management_cpu_seconds:
                    $observation.qemu_management_cpu_seconds,
                counter_skew_clamped_seconds:
                    $observation.counter_skew_clamped_seconds,
                sampling_uncertainty_seconds:
                    $observation.sampling_uncertainty_seconds,
                vcpu_thread_count: $observation.vcpu_thread_count,
                cpu_conservation_residual_seconds:
                    ($observation.qemu_process_cpu_seconds -
                     $observation.qemu_vcpu_cpu_seconds -
                     $observation.qemu_management_cpu_seconds +
                     $observation.counter_skew_clamped_seconds),
                fixed_work_gops_per_qemu_vcpu_cpu_second:
                    ($fixed_work_gop / $observation.qemu_vcpu_cpu_seconds),
                qemu_vcpu_occupancy:
                    ($observation.qemu_vcpu_cpu_seconds /
                     ($observation.host_wall_seconds *
                      $observation.vcpu_thread_count))
            },
            guest_to_host_worker_cpu_efficiency_ratio:
                ($guest_sample.int_worker_gops_per_cpu_second /
                 $host_sample.int_worker_gops_per_cpu_second),
            guest_to_host_worker_residency_ratio:
                ($guest_sample.int_worker_scheduler_residency /
                 $host_sample.int_worker_scheduler_residency)
        };

    $host[0] as $h |
    [$guest1[0], $guest8[0], $guest16[0], $guest24[0], $guest32[0]] as $guests |
    ($h.schema_version == 2 and
        all($guests[]; .schema_version == 2)) as $cpu_available |
    [
        evidence_input($guest1_path; $guest1_sha256; "guest"; 1),
        evidence_input($guest8_path; $guest8_sha256; "guest"; 8),
        evidence_input($guest16_path; $guest16_sha256; "guest"; 16),
        evidence_input($guest24_path; $guest24_sha256; "guest"; 24),
        evidence_input($guest32_path; $guest32_sha256; "guest"; 32)
    ] as $guest_inputs |
    {
        schema_version: 2,
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
        cpu_accounting: (({
            status: (if $cpu_available then "available" else "unavailable" end),
            input_schema_versions: {
                host: $h.schema_version,
                guests: [$guests[] | {
                    smp: .benchmark.smp,
                    schema_version: .schema_version
                }]
            }
        }) +
        (if $cpu_available then {
            join_contract: {
                host_guest_sample_key: ["threads", "sample_ordinal"],
                sample_id_pattern: "t<threads>-r<sample_ordinal>",
                qemu_observation_key: ["sample_id", "workload"],
                qemu_boundary_source: "serial-marker-receipt",
                workload: "integer"
            },
            sample_comparisons: [
                $guests[] as $guest |
                $guest.samples[] as $guest_sample |
                cpu_sample_row($h; $guest; $guest_sample)
            ]
        } else {
            reason: "CPU accounting requires schema version 2 for the host and all guest inputs."
        } end)),
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
    def nonnegative_finite: type == "number" and isfinite and . >= 0;
    def absolute_nonempty_path:
        type == "string" and length > 1 and startswith("/");
    def absolute: if . < 0 then -. else . end;
    def nearly_equal($left; $right):
        (($left - $right) | absolute) <=
            (1e-12 * (($right | absolute) + 1));
    def timing_nearly_equal($left; $right):
        (($left - $right) | absolute) <=
            (1e-7 * (($right | absolute) + 1));
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
    def native_cpu:
        type == "object" and
        exact_keys([
            "worker_cpu_seconds", "worker_gops_per_cpu_second",
            "worker_scheduler_residency"
        ]) and
        all([.worker_cpu_seconds, .worker_gops_per_cpu_second,
             .worker_scheduler_residency][]; positive_finite) and
        .worker_scheduler_residency <= 1.01;
    def cpu_sample:
        type == "object" and
        exact_keys([
            "guest_smp", "threads", "sample_ordinal", "sample_id",
            "fixed_integer_work_gop", "host_native", "guest_native",
            "guest_qemu", "guest_to_host_worker_cpu_efficiency_ratio",
            "guest_to_host_worker_residency_ratio"
        ]) and
        (.guest_smp | type == "number" and floor == . and . > 0) and
        (.threads | type == "number" and floor == . and . > 0) and
        (.sample_ordinal | type == "number" and floor == . and
            . >= 1 and . <= 7) and
        .sample_id == "t\(.threads)-r\(.sample_ordinal)" and
        (.fixed_integer_work_gop | positive_finite) and
        nearly_equal(.fixed_integer_work_gop; (1.6 * .threads)) and
        (.host_native | native_cpu) and (.guest_native | native_cpu) and
        timing_nearly_equal(.host_native.worker_gops_per_cpu_second;
            (.fixed_integer_work_gop /
             .host_native.worker_cpu_seconds)) and
        timing_nearly_equal(.guest_native.worker_gops_per_cpu_second;
            (.fixed_integer_work_gop /
             .guest_native.worker_cpu_seconds)) and
        (.guest_to_host_worker_cpu_efficiency_ratio | positive_finite) and
        (.guest_to_host_worker_residency_ratio | positive_finite) and
        nearly_equal(.guest_to_host_worker_cpu_efficiency_ratio;
            (.guest_native.worker_gops_per_cpu_second /
             .host_native.worker_gops_per_cpu_second)) and
        nearly_equal(.guest_to_host_worker_residency_ratio;
            (.guest_native.worker_scheduler_residency /
             .host_native.worker_scheduler_residency)) and
        (.guest_qemu | type == "object" and exact_keys([
            "host_wall_seconds", "qemu_process_cpu_seconds",
            "qemu_vcpu_cpu_seconds", "qemu_management_cpu_seconds",
            "counter_skew_clamped_seconds", "sampling_uncertainty_seconds",
            "vcpu_thread_count", "cpu_conservation_residual_seconds",
            "fixed_work_gops_per_qemu_vcpu_cpu_second",
            "qemu_vcpu_occupancy"
        ])) and
        (.guest_qemu.host_wall_seconds | positive_finite) and
        (.guest_qemu.qemu_process_cpu_seconds | nonnegative_finite) and
        (.guest_qemu.qemu_vcpu_cpu_seconds | positive_finite) and
        (.guest_qemu.qemu_management_cpu_seconds | nonnegative_finite) and
        (.guest_qemu.counter_skew_clamped_seconds | nonnegative_finite) and
        (.guest_qemu.sampling_uncertainty_seconds | nonnegative_finite) and
        .guest_qemu.vcpu_thread_count == .guest_smp and
        .guest_qemu.counter_skew_clamped_seconds <=
            (2 * .guest_smp * .guest_qemu.sampling_uncertainty_seconds) and
        .guest_qemu.qemu_vcpu_cpu_seconds <=
            (.guest_smp *
             (1.01 * .guest_qemu.host_wall_seconds +
              2 * .guest_qemu.sampling_uncertainty_seconds) + 1e-9) and
        (.guest_qemu.cpu_conservation_residual_seconds |
            type == "number" and isfinite and absolute < 0.000001) and
        nearly_equal(.guest_qemu.cpu_conservation_residual_seconds;
            (.guest_qemu.qemu_process_cpu_seconds -
             .guest_qemu.qemu_vcpu_cpu_seconds -
             .guest_qemu.qemu_management_cpu_seconds +
             .guest_qemu.counter_skew_clamped_seconds)) and
        (.guest_qemu.fixed_work_gops_per_qemu_vcpu_cpu_second |
            positive_finite) and
        nearly_equal(
            .guest_qemu.fixed_work_gops_per_qemu_vcpu_cpu_second;
            (.fixed_integer_work_gop /
             .guest_qemu.qemu_vcpu_cpu_seconds)) and
        (.guest_qemu.qemu_vcpu_occupancy | positive_finite) and
        nearly_equal(.guest_qemu.qemu_vcpu_occupancy;
            (.guest_qemu.qemu_vcpu_cpu_seconds /
             (.guest_qemu.host_wall_seconds *
              .guest_qemu.vcpu_thread_count)));

    type == "object" and
    exact_keys([
        "schema_version", "result", "input_evidence", "generator_tools",
        "benchmark_contract", "comparisons", "cpu_accounting", "method_notes"
    ]) and
    .schema_version == 2 and
    .result == "descriptive_only" and
    (.input_evidence | exact_keys(["host", "guests"])) and
    (.input_evidence.host |
        exact_keys(["path", "sha256_before", "sha256_after", "role"]) and
        .role == "host" and (.path | absolute_nonempty_path) and
        evidence_hashes) and
    (.input_evidence.guests | type == "array" and length == 5) and
    all(.input_evidence.guests[];
        exact_keys(["path", "sha256_before", "sha256_after", "role", "smp"]) and
        .role == "guest" and (.path | absolute_nonempty_path) and
        evidence_hashes) and
    (.input_evidence.guests | map(.smp)) == [1, 8, 16, 24, 32] and
    ([.input_evidence.host.path] + [.input_evidence.guests[].path] |
        unique | length) == 6 and
    (.generator_tools | exact_keys(["jq", "shasum", "realpath"])) and
    all(.generator_tools[];
        exact_keys(["path", "sha256_before", "sha256_after"]) and
        (.path | absolute_nonempty_path) and evidence_hashes) and
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
    (.cpu_accounting.input_schema_versions |
        exact_keys(["host", "guests"])) and
    (.cpu_accounting.input_schema_versions.host == 1 or
        .cpu_accounting.input_schema_versions.host == 2) and
    (.cpu_accounting.input_schema_versions.guests |
        type == "array" and length == 5) and
    (.cpu_accounting.input_schema_versions.guests | map(.smp)) ==
        [1, 8, 16, 24, 32] and
    all(.cpu_accounting.input_schema_versions.guests[];
        exact_keys(["smp", "schema_version"]) and
        (.schema_version == 1 or .schema_version == 2)) and
    (if (.cpu_accounting.input_schema_versions.host == 2 and
         all(.cpu_accounting.input_schema_versions.guests[];
             .schema_version == 2)) then
        (.cpu_accounting | exact_keys([
            "status", "input_schema_versions", "join_contract",
            "sample_comparisons"
        ])) and
        .cpu_accounting.status == "available" and
        .cpu_accounting.join_contract == {
            host_guest_sample_key: ["threads", "sample_ordinal"],
            sample_id_pattern: "t<threads>-r<sample_ordinal>",
            qemu_observation_key: ["sample_id", "workload"],
            qemu_boundary_source: "serial-marker-receipt",
            workload: "integer"
        } and
        (.cpu_accounting.sample_comparisons | length) == 63 and
        [.cpu_accounting.sample_comparisons[] |
            [.guest_smp, .threads, .sample_ordinal]] ==
            [[[1, 1], [8, 1], [8, 8], [16, 1], [16, 16],
              [24, 1], [24, 24], [32, 1], [32, 32]][] as $pair |
             range(1; 8) | [$pair[0], $pair[1], .]] and
        all(.cpu_accounting.sample_comparisons[]; cpu_sample)
    else
        (.cpu_accounting | exact_keys([
            "status", "reason", "input_schema_versions"
        ])) and
        .cpu_accounting.status == "unavailable" and
        .cpu_accounting.reason ==
            "CPU accounting requires schema version 2 for the host and all guest inputs."
    end) and
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

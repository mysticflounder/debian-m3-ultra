/* Matched host/guest microbenchmark: integer throughput and memory bandwidth.
 * Build: gcc -O2 -pthread -Wall -Wextra -Werror -std=gnu11 -o bench bench.c
 * Run:   ./bench <threads>
 *        ./bench --json <threads>
 *        ./bench --json --timing-v2 <sample_id> <threads>
 * timing-v2 writes flushed BENCH_WORK_BEGIN/END boundaries to stderr.
 */
#define _GNU_SOURCE

#include <errno.h>
#include <inttypes.h>
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

#ifdef __APPLE__
#include <mach/mach.h>
#endif

#define INT_ITERS UINT64_C(400000000)
#define INT_OPS_PER_ITERATION UINT64_C(4)
#define MEM_BYTES UINT64_C(268435456)
#define MEM_PASSES UINT64_C(8)
#define MAX_THREADS 64

struct int_worker_args {
    uint64_t seed;
    uint64_t result;
    int timing_v2;
    int cpu_time_valid;
    double cpu_seconds;
};

static volatile uint64_t g_sink;

static int monotonic_seconds(double *result)
{
    struct timespec timestamp;

    if (clock_gettime(CLOCK_MONOTONIC, &timestamp) != 0) {
        perror("clock_gettime");
        return -1;
    }
    *result = (double)timestamp.tv_sec + (double)timestamp.tv_nsec / 1e9;
    return 0;
}

static int process_cpu_seconds(double *result)
{
    struct rusage usage;

    if (getrusage(RUSAGE_SELF, &usage) != 0) {
        perror("getrusage");
        return -1;
    }
    *result = (double)usage.ru_utime.tv_sec +
        (double)usage.ru_utime.tv_usec / 1e6 +
        (double)usage.ru_stime.tv_sec +
        (double)usage.ru_stime.tv_usec / 1e6;
    return isfinite(*result) && *result >= 0.0 ? 0 : -1;
}

static int thread_cpu_seconds(double *result)
{
#ifdef __APPLE__
    thread_basic_info_data_t information;
    mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
    const mach_port_t thread = mach_thread_self();
    const kern_return_t status = thread_info(
        thread, THREAD_BASIC_INFO, (thread_info_t)&information, &count);

    (void)mach_port_deallocate(mach_task_self(), thread);
    if (status != KERN_SUCCESS) {
        return -1;
    }
    *result = (double)information.user_time.seconds +
        (double)information.user_time.microseconds / 1e6 +
        (double)information.system_time.seconds +
        (double)information.system_time.microseconds / 1e6;
#else
    struct timespec timestamp;

    if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &timestamp) != 0) {
        return -1;
    }
    *result = (double)timestamp.tv_sec + (double)timestamp.tv_nsec / 1e9;
#endif
    return isfinite(*result) && *result >= 0.0 ? 0 : -1;
}

static int valid_sample_id(const char *text)
{
    size_t length;

    if (text == NULL || (length = strlen(text)) == 0 || length > 64) {
        return 0;
    }
    for (size_t i = 0; i < length; ++i) {
        const char value = text[i];

        if (!((value >= 'A' && value <= 'Z') ||
              (value >= 'a' && value <= 'z') ||
              (value >= '0' && value <= '9') || value == '_' ||
              value == '.' || value == ':' || value == '-')) {
            return 0;
        }
    }
    return 1;
}

static int emit_work_marker(const char *event, const char *sample_id,
                            const char *workload, const char *status)
{
    int result;

    if (status == NULL) {
        result = fprintf(stderr, "BENCH_WORK_%s sample_id=%s workload=%s\n",
                         event, sample_id, workload);
    } else {
        result = fprintf(stderr,
                         "BENCH_WORK_%s sample_id=%s workload=%s status=%s\n",
                         event, sample_id, workload, status);
    }
    if (result < 0 || fflush(stderr) != 0) {
        return -1;
    }
    return 0;
}

static int timing_work_failed(int timing_v2, const char *sample_id,
                              const char *workload)
{
    if (timing_v2) {
        (void)emit_work_marker("END", sample_id, workload, "failed");
    }
    return EXIT_FAILURE;
}

/* xorshift64*: each iteration has three XOR/shift operations and one multiply. */
static void *int_work(void *opaque)
{
    struct int_worker_args *args = opaque;
    uint64_t x = args->seed;
    double cpu_start = 0.0;
    double cpu_finish = 0.0;

    args->cpu_time_valid = !args->timing_v2 ||
        thread_cpu_seconds(&cpu_start) == 0;

    for (uint64_t i = 0; i < INT_ITERS; ++i) {
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        x *= UINT64_C(0x2545F4914F6CDD1D);
    }
    args->result = x;
    if (args->timing_v2) {
        if (!args->cpu_time_valid || thread_cpu_seconds(&cpu_finish) != 0 ||
            !isfinite(cpu_finish - cpu_start) || cpu_finish <= cpu_start) {
            args->cpu_time_valid = 0;
        } else {
            args->cpu_seconds = cpu_finish - cpu_start;
        }
    }
    return NULL;
}

static uint64_t mem_work(const uint64_t *buffer)
{
    const size_t count = (size_t)(MEM_BYTES / sizeof(*buffer));
    uint64_t sum = 0;

    for (uint64_t pass = 0; pass < MEM_PASSES; ++pass) {
        /* Prevent the compiler from merging identical read-only passes. */
        __asm__ __volatile__("" : "+r"(sum) : : "memory");
        for (size_t i = 0; i < count; ++i) {
            sum += buffer[i];
        }
    }
    g_sink = sum;
    return sum;
}

static int parse_threads(const char *text, int *threads)
{
    const char *cursor;
    char *end = NULL;
    long value;

    if (text == NULL || *text == '\0') {
        return -1;
    }
    for (cursor = text; *cursor != '\0'; ++cursor) {
        if (*cursor < '0' || *cursor > '9') {
            return -1;
        }
    }
    errno = 0;
    value = strtol(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || value < 1 ||
        value > MAX_THREADS) {
        return -1;
    }
    *threads = (int)value;
    return 0;
}

static int join_workers(pthread_t *workers, size_t count)
{
    int failed = 0;

    for (size_t i = 0; i < count; ++i) {
        const int error = pthread_join(workers[i], NULL);

        if (error != 0) {
            fprintf(stderr, "pthread_join: %s\n", strerror(error));
            failed = 1;
        }
    }
    return failed ? -1 : 0;
}

int main(int argc, char **argv)
{
    int json_output = 0;
    int timing_v2 = 0;
    const char *sample_id = NULL;
    const char *thread_argument = NULL;
    int thread_count;
    pthread_t workers[MAX_THREADS];
    struct int_worker_args worker_args[MAX_THREADS];
    size_t created = 0;
    double start;
    double finish;
    double int_seconds;
    double memory_seconds;
    double process_cpu_start = 0.0;
    double process_cpu_finish = 0.0;
    double int_worker_cpu_seconds = 0.0;
    double int_process_cpu_seconds = 0.0;
    double memory_process_cpu_seconds = 0.0;
    uint64_t *buffer = NULL;
    uint64_t memory_sum;
    uint64_t checksum = UINT64_C(1469598103934665603);

    if (argc == 2) {
        thread_argument = argv[1];
    } else if (argc == 3 && strcmp(argv[1], "--json") == 0) {
        json_output = 1;
        thread_argument = argv[2];
    } else if (argc == 5 && strcmp(argv[1], "--json") == 0 &&
               strcmp(argv[2], "--timing-v2") == 0) {
        json_output = 1;
        timing_v2 = 1;
        sample_id = argv[3];
        thread_argument = argv[4];
    } else {
        fprintf(stderr, "usage: %s [--json] <threads:1-64>\n", argv[0]);
        fprintf(stderr,
                "       %s --json --timing-v2 <sample_id> <threads:1-64>\n",
                argv[0]);
        return EXIT_FAILURE;
    }
    if (timing_v2 && !valid_sample_id(sample_id)) {
        fprintf(stderr, "sample_id must use 1-64 characters from [A-Za-z0-9_.:-]\n");
        return EXIT_FAILURE;
    }
    if (parse_threads(thread_argument, &thread_count) != 0) {
        fprintf(stderr, "threads must be an integer from 1 through 64\n");
        return EXIT_FAILURE;
    }

    for (int i = 0; i < thread_count; ++i) {
        worker_args[i].seed = UINT64_C(0x9E3779B97F4A7C15) ^ (uint64_t)i;
        worker_args[i].result = 0;
        worker_args[i].timing_v2 = timing_v2;
        worker_args[i].cpu_time_valid = !timing_v2;
        worker_args[i].cpu_seconds = 0.0;
    }

    if (timing_v2 &&
        emit_work_marker("BEGIN", sample_id, "integer", NULL) != 0) {
        return EXIT_FAILURE;
    }
    if (timing_v2 && process_cpu_seconds(&process_cpu_start) != 0) {
        return timing_work_failed(timing_v2, sample_id, "integer");
    }
    if (monotonic_seconds(&start) != 0) {
        return timing_work_failed(timing_v2, sample_id, "integer");
    }
    for (int i = 0; i < thread_count; ++i) {
        const int error = pthread_create(&workers[i], NULL, int_work,
                                         &worker_args[i]);

        if (error != 0) {
            fprintf(stderr, "pthread_create: %s\n", strerror(error));
            (void)join_workers(workers, created);
            return timing_work_failed(timing_v2, sample_id, "integer");
        }
        ++created;
    }
    if (join_workers(workers, created) != 0) {
        return timing_work_failed(timing_v2, sample_id, "integer");
    }
    if (monotonic_seconds(&finish) != 0) {
        return timing_work_failed(timing_v2, sample_id, "integer");
    }
    if (timing_v2 && process_cpu_seconds(&process_cpu_finish) != 0) {
        return timing_work_failed(timing_v2, sample_id, "integer");
    }
    int_seconds = finish - start;
    if (!isfinite(int_seconds) || int_seconds <= 0.0) {
        fprintf(stderr, "integer workload duration was not positive\n");
        return timing_work_failed(timing_v2, sample_id, "integer");
    }
    if (timing_v2) {
        int_process_cpu_seconds = process_cpu_finish - process_cpu_start;
        for (int i = 0; i < thread_count; ++i) {
            if (!worker_args[i].cpu_time_valid) {
                fprintf(stderr, "integer worker CPU accounting failed\n");
                return timing_work_failed(timing_v2, sample_id, "integer");
            }
            int_worker_cpu_seconds += worker_args[i].cpu_seconds;
        }
        if (!isfinite(int_process_cpu_seconds) ||
            !isfinite(int_worker_cpu_seconds) ||
            int_process_cpu_seconds <= 0.0 || int_worker_cpu_seconds <= 0.0) {
            fprintf(stderr, "integer CPU duration was not positive\n");
            return timing_work_failed(timing_v2, sample_id, "integer");
        }
        if (emit_work_marker("END", sample_id, "integer", "ok") != 0) {
            return EXIT_FAILURE;
        }
    }

    buffer = malloc((size_t)MEM_BYTES);
    if (buffer == NULL) {
        perror("malloc");
        return EXIT_FAILURE;
    }
    memset(buffer, 1, (size_t)MEM_BYTES);

    if (timing_v2 &&
        emit_work_marker("BEGIN", sample_id, "memory", NULL) != 0) {
        free(buffer);
        return EXIT_FAILURE;
    }
    if (timing_v2 && process_cpu_seconds(&process_cpu_start) != 0) {
        free(buffer);
        return timing_work_failed(timing_v2, sample_id, "memory");
    }
    if (monotonic_seconds(&start) != 0) {
        free(buffer);
        return timing_work_failed(timing_v2, sample_id, "memory");
    }
    memory_sum = mem_work(buffer);
    if (monotonic_seconds(&finish) != 0) {
        free(buffer);
        return timing_work_failed(timing_v2, sample_id, "memory");
    }
    if (timing_v2 && process_cpu_seconds(&process_cpu_finish) != 0) {
        free(buffer);
        return timing_work_failed(timing_v2, sample_id, "memory");
    }
    memory_seconds = finish - start;
    free(buffer);
    if (!isfinite(memory_seconds) || memory_seconds <= 0.0) {
        fprintf(stderr, "memory workload duration was not positive\n");
        return timing_work_failed(timing_v2, sample_id, "memory");
    }
    if (timing_v2) {
        memory_process_cpu_seconds = process_cpu_finish - process_cpu_start;
        if (!isfinite(memory_process_cpu_seconds) ||
            memory_process_cpu_seconds <= 0.0) {
            fprintf(stderr, "memory CPU duration was not positive\n");
            return timing_work_failed(timing_v2, sample_id, "memory");
        }
        if (emit_work_marker("END", sample_id, "memory", "ok") != 0) {
            return EXIT_FAILURE;
        }
    }

    for (int i = 0; i < thread_count; ++i) {
        checksum ^= worker_args[i].result;
        checksum *= UINT64_C(1099511628211);
    }
    checksum ^= memory_sum;
    checksum *= UINT64_C(1099511628211);

    const double int_gops =
        (double)INT_ITERS * (double)thread_count *
        (double)INT_OPS_PER_ITERATION / int_seconds / 1e9;
    const double memory_gib_s =
        (double)MEM_BYTES * (double)MEM_PASSES / memory_seconds /
        (double)(UINT64_C(1) << 30);
    const double int_worker_gops_per_cpu_second = timing_v2 ?
        (double)INT_ITERS * (double)thread_count *
        (double)INT_OPS_PER_ITERATION / int_worker_cpu_seconds / 1e9 : 0.0;
    const double int_process_gops_per_cpu_second = timing_v2 ?
        (double)INT_ITERS * (double)thread_count *
        (double)INT_OPS_PER_ITERATION / int_process_cpu_seconds / 1e9 : 0.0;
    const double memory_process_gib_per_cpu_second = timing_v2 ?
        (double)MEM_BYTES * (double)MEM_PASSES / memory_process_cpu_seconds /
        (double)(UINT64_C(1) << 30) : 0.0;
    const double int_worker_scheduler_residency = timing_v2 ?
        int_worker_cpu_seconds / (int_seconds * (double)thread_count) : 0.0;
    const double int_process_scheduler_residency = timing_v2 ?
        int_process_cpu_seconds / (int_seconds * (double)thread_count) : 0.0;
    const double memory_process_scheduler_residency = timing_v2 ?
        memory_process_cpu_seconds / memory_seconds : 0.0;

    if (!isfinite(int_gops) || int_gops <= 0.0 ||
        !isfinite(memory_gib_s) || memory_gib_s <= 0.0) {
        fprintf(stderr, "workload rate was not finite and positive\n");
        return EXIT_FAILURE;
    }
    if (timing_v2 &&
        (!isfinite(int_worker_gops_per_cpu_second) ||
         !isfinite(int_process_gops_per_cpu_second) ||
         !isfinite(memory_process_gib_per_cpu_second) ||
         !isfinite(int_worker_scheduler_residency) ||
         !isfinite(int_process_scheduler_residency) ||
         !isfinite(memory_process_scheduler_residency) ||
         int_worker_gops_per_cpu_second <= 0.0 ||
         int_process_gops_per_cpu_second <= 0.0 ||
         memory_process_gib_per_cpu_second <= 0.0 ||
         int_worker_scheduler_residency <= 0.0 ||
         int_process_scheduler_residency <= 0.0 ||
         memory_process_scheduler_residency <= 0.0)) {
        fprintf(stderr, "CPU-normalized metric was not finite and positive\n");
        return EXIT_FAILURE;
    }

    if (timing_v2) {
        printf("{\"timing_version\":2,\"sample_id\":\"%s\",\"threads\":%d"
               ",\"int_iterations_per_thread\":%" PRIu64
               ",\"int_operations_per_iteration\":%" PRIu64
               ",\"int_seconds\":%.9f,\"int_gops\":%.9f"
               ",\"int_worker_cpu_seconds\":%.9f"
               ",\"int_process_cpu_seconds\":%.9f"
               ",\"int_worker_scheduler_residency\":%.9f"
               ",\"int_process_scheduler_residency\":%.9f"
               ",\"int_worker_gops_per_cpu_second\":%.9f"
               ",\"int_process_gops_per_cpu_second\":%.9f"
               ",\"memory_bytes\":%" PRIu64 ",\"memory_passes\":%" PRIu64
               ",\"memory_seconds\":%.9f,\"memory_gib_s\":%.9f"
               ",\"memory_process_cpu_seconds\":%.9f"
               ",\"memory_process_scheduler_residency\":%.9f"
               ",\"memory_process_gib_per_cpu_second\":%.9f"
               ",\"checksum\":\"%016" PRIx64 "\"}\n",
               sample_id, thread_count, INT_ITERS, INT_OPS_PER_ITERATION,
               int_seconds, int_gops, int_worker_cpu_seconds,
               int_process_cpu_seconds, int_worker_scheduler_residency,
               int_process_scheduler_residency,
               int_worker_gops_per_cpu_second,
               int_process_gops_per_cpu_second, MEM_BYTES, MEM_PASSES,
               memory_seconds, memory_gib_s, memory_process_cpu_seconds,
               memory_process_scheduler_residency,
               memory_process_gib_per_cpu_second, checksum);
    } else if (json_output) {
        printf("{\"threads\":%d,\"int_iterations_per_thread\":%" PRIu64
               ",\"int_operations_per_iteration\":%" PRIu64
               ",\"int_seconds\":%.9f,\"int_gops\":%.9f"
               ",\"memory_bytes\":%" PRIu64 ",\"memory_passes\":%" PRIu64
               ",\"memory_seconds\":%.9f,\"memory_gib_s\":%.9f"
               ",\"checksum\":\"%016" PRIx64 "\"}\n",
               thread_count, INT_ITERS, INT_OPS_PER_ITERATION, int_seconds,
               int_gops, MEM_BYTES, MEM_PASSES, memory_seconds, memory_gib_s,
               checksum);
    } else {
        printf("threads=%d int_time=%.3fs int_Gops=%.2f "
               "mem_time=%.3fs mem_GiB_s=%.2f\n",
               thread_count, int_seconds, int_gops, memory_seconds,
               memory_gib_s);
    }

    if (fflush(stdout) != 0 || ferror(stdout)) {
        perror("stdout");
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}

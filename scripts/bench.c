/* Matched host/guest microbenchmark: integer throughput and memory bandwidth.
 * Build: gcc -O2 -pthread -Wall -Wextra -Werror -std=gnu11 -o bench bench.c
 * Run:   ./bench <threads>
 *        ./bench --json <threads>
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
#include <time.h>

#define INT_ITERS UINT64_C(400000000)
#define INT_OPS_PER_ITERATION UINT64_C(4)
#define MEM_BYTES UINT64_C(268435456)
#define MEM_PASSES UINT64_C(8)
#define MAX_THREADS 64

struct int_worker_args {
    uint64_t seed;
    uint64_t result;
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

/* xorshift64*: each iteration has three XOR/shift operations and one multiply. */
static void *int_work(void *opaque)
{
    struct int_worker_args *args = opaque;
    uint64_t x = args->seed;

    for (uint64_t i = 0; i < INT_ITERS; ++i) {
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        x *= UINT64_C(0x2545F4914F6CDD1D);
    }
    args->result = x;
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
    const char *thread_argument = NULL;
    int thread_count;
    pthread_t workers[MAX_THREADS];
    struct int_worker_args worker_args[MAX_THREADS];
    size_t created = 0;
    double start;
    double finish;
    double int_seconds;
    double memory_seconds;
    uint64_t *buffer = NULL;
    uint64_t memory_sum;
    uint64_t checksum = UINT64_C(1469598103934665603);

    if (argc == 2) {
        thread_argument = argv[1];
    } else if (argc == 3 && strcmp(argv[1], "--json") == 0) {
        json_output = 1;
        thread_argument = argv[2];
    } else {
        fprintf(stderr, "usage: %s [--json] <threads:1-64>\n", argv[0]);
        return EXIT_FAILURE;
    }
    if (parse_threads(thread_argument, &thread_count) != 0) {
        fprintf(stderr, "threads must be an integer from 1 through 64\n");
        return EXIT_FAILURE;
    }

    for (int i = 0; i < thread_count; ++i) {
        worker_args[i].seed = UINT64_C(0x9E3779B97F4A7C15) ^ (uint64_t)i;
        worker_args[i].result = 0;
    }

    if (monotonic_seconds(&start) != 0) {
        return EXIT_FAILURE;
    }
    for (int i = 0; i < thread_count; ++i) {
        const int error = pthread_create(&workers[i], NULL, int_work,
                                         &worker_args[i]);

        if (error != 0) {
            fprintf(stderr, "pthread_create: %s\n", strerror(error));
            (void)join_workers(workers, created);
            return EXIT_FAILURE;
        }
        ++created;
    }
    if (join_workers(workers, created) != 0) {
        return EXIT_FAILURE;
    }
    if (monotonic_seconds(&finish) != 0) {
        return EXIT_FAILURE;
    }
    int_seconds = finish - start;
    if (!isfinite(int_seconds) || int_seconds <= 0.0) {
        fprintf(stderr, "integer workload duration was not positive\n");
        return EXIT_FAILURE;
    }

    buffer = malloc((size_t)MEM_BYTES);
    if (buffer == NULL) {
        perror("malloc");
        return EXIT_FAILURE;
    }
    memset(buffer, 1, (size_t)MEM_BYTES);

    if (monotonic_seconds(&start) != 0) {
        free(buffer);
        return EXIT_FAILURE;
    }
    memory_sum = mem_work(buffer);
    if (monotonic_seconds(&finish) != 0) {
        free(buffer);
        return EXIT_FAILURE;
    }
    memory_seconds = finish - start;
    free(buffer);
    if (!isfinite(memory_seconds) || memory_seconds <= 0.0) {
        fprintf(stderr, "memory workload duration was not positive\n");
        return EXIT_FAILURE;
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

    if (!isfinite(int_gops) || int_gops <= 0.0 ||
        !isfinite(memory_gib_s) || memory_gib_s <= 0.0) {
        fprintf(stderr, "workload rate was not finite and positive\n");
        return EXIT_FAILURE;
    }

    if (json_output) {
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

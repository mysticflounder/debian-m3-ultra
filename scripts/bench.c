/* Matched host/guest microbenchmark: integer throughput and memory bandwidth.
 * Build:  gcc -O2 -pthread -o bench bench.c
 * Run:    ./bench <threads>
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <pthread.h>
#include <time.h>

#define INT_ITERS 400000000ULL
#define MEM_BYTES (256ULL << 20)

volatile uint64_t g_sink;

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

/* xorshift64* — data-dependent, so it cannot be vectorised away */
static void *int_work(void *arg) {
    uint64_t x = 0x9E3779B97F4A7C15ULL ^ (uint64_t)(uintptr_t)arg;
    for (uint64_t i = 0; i < INT_ITERS; i++) {
        x ^= x >> 12; x ^= x << 25; x ^= x >> 27;
        x *= 0x2545F4914F6CDD1DULL;
    }
    *(volatile uint64_t *)arg = x;
    return NULL;
}

static void *mem_work(void *arg) {
    uint64_t *buf = ((uint64_t **)arg)[0];
    size_t n = MEM_BYTES / sizeof(uint64_t);
    uint64_t s = 0;
    for (int rep = 0; rep < 8; rep++)
        for (size_t i = 0; i < n; i++) s += buf[i];
    g_sink = s;
    return NULL;
}

int main(int argc, char **argv) {
    int nt = argc > 1 ? atoi(argv[1]) : 1;
    if (nt < 1) nt = 1;

    pthread_t th[64];
    uint64_t sink[64];
    if (nt > 64) nt = 64;

    double t0 = now();
    for (int i = 0; i < nt; i++) {
        sink[i] = i;
        pthread_create(&th[i], NULL, int_work, &sink[i]);
    }
    for (int i = 0; i < nt; i++) pthread_join(th[i], NULL);
    double dt_int = now() - t0;

    uint64_t *buf = malloc(MEM_BYTES);
    if (!buf) { perror("malloc"); return 1; }
    memset(buf, 1, MEM_BYTES);
    void *marg[2] = { buf, NULL };
    t0 = now();
    mem_work(marg);
    double dt_mem = now() - t0;

    double gops = (double)INT_ITERS * nt * 4.0 / dt_int / 1e9;
    double gbs  = (double)MEM_BYTES * 8.0 / dt_mem / (1 << 30);

    printf("threads=%d int_time=%.3fs int_Gops=%.2f mem_time=%.3fs mem_GiB_s=%.2f\n",
           nt, dt_int, gops, dt_mem, gbs);
    free(buf);
    return 0;
}

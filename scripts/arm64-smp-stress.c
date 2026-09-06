#define _GNU_SOURCE
/*
 * Bounded same-process SMP memory/coherence witness.  This is intended to
 * run in the Linux guest: it uses one pthread per online logical CPU and no
 * host-specific interfaces.
 */
#include <errno.h>
#include <inttypes.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <unistd.h>

#define MAX_CPUS 32
#define PASSES 8
#define SHARD_BYTES (16U * 1024U * 1024U)
#define TOTAL_CAP_BYTES (512U * 1024U * 1024U)
#define SHARD_WORDS (SHARD_BYTES / sizeof(uint64_t))
#define CHECKSUM_STRIDE_WORDS 4096U
#define ATOMIC_INCREMENTS_PER_PASS 10000U

struct worker_result {
    uint64_t checksum;
    uint64_t passes;
    uint64_t bytes;
    uint64_t wrong;
};

struct shared {
    int cpus;
    const char *token;
    pthread_barrier_t ready;
    pthread_barrier_t phase;
    pthread_mutex_t lock;
    pthread_cond_t go_cond;
    int go;
    uint64_t *buffer;
    _Atomic uint64_t atomic_operations;
    struct worker_result results[MAX_CPUS];
};

struct worker_arg {
    struct shared *shared;
    int cpu;
};

static void fail_now(const char *reason)
{
    printf("M3_STRESS_FAIL reason=%s\n", reason);
    fflush(stdout);
    _exit(1);
}

static uint64_t mix64(uint64_t value)
{
    value ^= value >> 30;
    value *= UINT64_C(0xbf58476d1ce4e5b9);
    value ^= value >> 27;
    value *= UINT64_C(0x94d049bb133111eb);
    return value ^ (value >> 31);
}

/* The address, owning CPU, and pass all affect the value written. */
static uint64_t word_pattern(int cpu, unsigned pass, size_t word)
{
    uint64_t address = (uint64_t)cpu * (uint64_t)SHARD_WORDS + word;
    uint64_t value = address + UINT64_C(0x9e3779b97f4a7c15) * (pass + 1U);
    value ^= UINT64_C(0xd1b54a32d192ed03) * ((uint64_t)cpu + 1U);
    return mix64(value);
}

static uint64_t checksum_step(uint64_t state, uint64_t value)
{
    state ^= value + UINT64_C(0x9e3779b97f4a7c15) + (state << 6) + (state >> 2);
    return mix64(state);
}

/* Recompute the expected digest from the pattern, without reading memory.
 * This is not an independent implementation of the pattern algorithm. */
static uint64_t reference_checksum(int cpu)
{
    uint64_t state = UINT64_C(0x123456789abcdef0) ^
                     (UINT64_C(0x517cc1b727220a95) * ((uint64_t)cpu + 1U));
    for (unsigned pass = 0; pass < PASSES; ++pass)
        for (size_t word = 0; word < SHARD_WORDS; word += CHECKSUM_STRIDE_WORDS)
            state = checksum_step(state, ~word_pattern(cpu, pass, word));
    return state;
}

static int affinity_is_cpu(int cpu)
{
    cpu_set_t set;
    CPU_ZERO(&set);
    if (sched_getaffinity(0, sizeof set, &set) != 0)
        return 0;
    return CPU_COUNT(&set) == 1 && CPU_ISSET(cpu, &set) && sched_getcpu() == cpu;
}

static void require_affinity(const struct worker_arg *arg)
{
    if (!affinity_is_cpu(arg->cpu))
        fail_now("cpu-affinity");
}

static void require_barrier(pthread_barrier_t *barrier)
{
    int status = pthread_barrier_wait(barrier);
    if (status != 0 && status != PTHREAD_BARRIER_SERIAL_THREAD)
        fail_now("barrier");
}

static void *worker(void *opaque)
{
    struct worker_arg *arg = opaque;
    struct shared *shared = arg->shared;
    cpu_set_t set;

    CPU_ZERO(&set);
    CPU_SET(arg->cpu, &set);
    if (pthread_setaffinity_np(pthread_self(), sizeof set, &set) != 0 ||
        !affinity_is_cpu(arg->cpu))
        fail_now("cpu-affinity");
    require_barrier(&shared->ready);

    if (pthread_mutex_lock(&shared->lock) != 0)
        fail_now("mutex-lock");
    while (!shared->go) {
        if (pthread_cond_wait(&shared->go_cond, &shared->lock) != 0)
            fail_now("cond-wait");
    }
    uint64_t *buffer = shared->buffer;
    if (pthread_mutex_unlock(&shared->lock) != 0)
        fail_now("mutex-unlock");
    if (!buffer)
        fail_now("missing-buffer");

    const int neighbor = (arg->cpu + 1) % shared->cpus;
    uint64_t checksum = UINT64_C(0x123456789abcdef0) ^
                        (UINT64_C(0x517cc1b727220a95) * ((uint64_t)arg->cpu + 1U));
    uint64_t wrong = 0;

    for (unsigned pass = 0; pass < PASSES; ++pass) {
        require_affinity(arg);
        require_barrier(&shared->phase);

        uint64_t *own = buffer + (size_t)arg->cpu * SHARD_WORDS;
        for (size_t word = 0; word < SHARD_WORDS; ++word)
            *(volatile uint64_t *)&own[word] = word_pattern(arg->cpu, pass, word);
        require_affinity(arg);
        require_barrier(&shared->phase);

        /* Every worker reads a different worker's just-filled shard. */
        const volatile uint64_t *other =
            (const volatile uint64_t *)(buffer + (size_t)neighbor * SHARD_WORDS);
        require_affinity(arg);
        for (size_t word = 0; word < SHARD_WORDS; ++word)
            if (other[word] != word_pattern(neighbor, pass, word))
                ++wrong, fail_now("neighbor-corruption");
        require_affinity(arg);
        require_barrier(&shared->phase);

        require_affinity(arg);
        for (size_t word = 0; word < SHARD_WORDS; ++word)
            if (*(volatile uint64_t *)&own[word] != word_pattern(arg->cpu, pass, word))
                ++wrong, fail_now("private-corruption");
        require_affinity(arg);
        require_barrier(&shared->phase);

        require_affinity(arg);
        for (size_t word = 0; word < SHARD_WORDS; ++word)
            *(volatile uint64_t *)&own[word] = ~word_pattern(arg->cpu, pass, word);
        require_affinity(arg);
        require_barrier(&shared->phase);

        require_affinity(arg);
        for (size_t word = 0; word < SHARD_WORDS; ++word) {
            uint64_t value = *(volatile uint64_t *)&own[word];
            if (value != ~word_pattern(arg->cpu, pass, word))
                ++wrong, fail_now("invert-corruption");
            if (word % CHECKSUM_STRIDE_WORDS == 0)
                checksum = checksum_step(checksum, value);
        }
        for (size_t word = 0; word < SHARD_WORDS; ++word)
            if (other[word] != ~word_pattern(neighbor, pass, word))
                ++wrong, fail_now("neighbor-invert-corruption");
        require_affinity(arg);
        require_barrier(&shared->phase);

        for (unsigned increment = 0; increment < ATOMIC_INCREMENTS_PER_PASS;
             ++increment)
            (void)atomic_fetch_add_explicit(&shared->atomic_operations, 1,
                                            memory_order_relaxed);
        require_affinity(arg);
        require_barrier(&shared->phase);
    }

    if (checksum != reference_checksum(arg->cpu))
        fail_now("checksum");
    shared->results[arg->cpu] = (struct worker_result){
        .checksum = checksum,
        .passes = PASSES,
        .bytes = SHARD_BYTES,
        .wrong = wrong,
    };
    return NULL;
}

static void boot_id(char output[64])
{
    FILE *file = fopen("/proc/sys/kernel/random/boot_id", "r");
    if (!file || !fgets(output, 64, file) || fclose(file) != 0)
        fail_now("boot-id");
    output[strcspn(output, "\r\n")] = '\0';
    if (strlen(output) != 36)
        fail_now("boot-id-format");
}

static int valid_token(const char *token)
{
    size_t length = strlen(token);
    return length > 0 && length <= 100 &&
           strspn(token,
                 "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-") ==
               length;
}

static int valid_nonce(const char *nonce)
{
    size_t length = strlen(nonce);
    return length >= 16 && length <= 96 &&
           strspn(nonce, "0123456789abcdef") == length;
}

int main(int argc, char **argv)
{
    struct shared shared;
    pthread_t threads[MAX_CPUS];
    struct worker_arg args[MAX_CPUS];
    char initial_boot[64], current_boot[64], line[256], command[32], value[128], extra;
    char *end;
    long cpus;
    pid_t initial_pid;

    setvbuf(stdout, NULL, _IONBF, 0);
    putchar('\n');
    if (argc != 3)
        fail_now("arguments");
    errno = 0;
    cpus = strtol(argv[1], &end, 10);
    if (errno || end == argv[1] || *end || cpus < 1 || cpus > MAX_CPUS)
        fail_now("cpu-count");
    if (!valid_token(argv[2]))
        fail_now("token");
    long online = sysconf(_SC_NPROCESSORS_ONLN);
    if (online != cpus)
        fail_now("online-cpu-count");
    size_t actual_bytes = (size_t)cpus * SHARD_BYTES;
    if (actual_bytes > TOTAL_CAP_BYTES)
        fail_now("memory-cap");
    boot_id(initial_boot);
    initial_pid = getpid();

    memset(&shared, 0, sizeof shared);
    shared.cpus = (int)cpus;
    shared.token = argv[2];
    atomic_init(&shared.atomic_operations, 0);
    if (pthread_barrier_init(&shared.ready, NULL, (unsigned)cpus + 1U) != 0 ||
        pthread_barrier_init(&shared.phase, NULL, (unsigned)cpus) != 0 ||
        pthread_mutex_init(&shared.lock, NULL) != 0 ||
        pthread_cond_init(&shared.go_cond, NULL) != 0)
        fail_now("pthread-init");
    for (int cpu = 0; cpu < cpus; ++cpu) {
        args[cpu] = (struct worker_arg){ .shared = &shared, .cpu = cpu };
        if (pthread_create(&threads[cpu], NULL, worker, &args[cpu]) != 0)
            fail_now("pthread-create");
    }
    require_barrier(&shared.ready);
    printf("M3_STRESS_READY token=%s pid=%ld boot=%s cpus=%ld bytes_per_cpu=%u passes=%u\n",
           argv[2], (long)initial_pid, initial_boot, cpus, SHARD_BYTES, PASSES);

    if (!fgets(line, sizeof line, stdin) ||
        sscanf(line, "%31s %127s %c", command, value, &extra) != 2 ||
        strcmp(command, "GO") != 0 || strcmp(value, argv[2]) != 0)
        fail_now("go-protocol");

    shared.buffer = mmap(NULL, actual_bytes, PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (shared.buffer == MAP_FAILED)
        fail_now("mmap");
    if (pthread_mutex_lock(&shared.lock) != 0)
        fail_now("mutex-lock");
    shared.go = 1;
    int broadcast_status = pthread_cond_broadcast(&shared.go_cond);
    int unlock_status = pthread_mutex_unlock(&shared.lock);
    if (broadcast_status != 0) {
        fail_now("cond-broadcast");
    }
    if (unlock_status != 0)
        fail_now("mutex-unlock");

    for (int cpu = 0; cpu < cpus; ++cpu)
        if (pthread_join(threads[cpu], NULL) != 0)
            fail_now("pthread-join");
    uint64_t expected_operations = (uint64_t)cpus * PASSES *
                                   ATOMIC_INCREMENTS_PER_PASS;
    if (atomic_load_explicit(&shared.atomic_operations, memory_order_relaxed) !=
            expected_operations)
        fail_now("atomic-count");
    for (int cpu = 0; cpu < cpus; ++cpu)
        if (shared.results[cpu].passes != PASSES ||
            shared.results[cpu].bytes != SHARD_BYTES || shared.results[cpu].wrong != 0)
            fail_now("worker-result");

    for (int cpu = 0; cpu < cpus; ++cpu)
        printf("M3_STRESS_CPU token=%s cpu=%d passes=%u bytes=%u\n",
               argv[2], cpu, PASSES, SHARD_BYTES);
    printf("M3_STRESS_DONE token=%s cpus=%ld passes=%u memory_bytes=%zu atomic_count=%" PRIu64
           "\n",
           argv[2], cpus, PASSES, actual_bytes, expected_operations);

    if (munmap(shared.buffer, actual_bytes) != 0)
        fail_now("munmap");
    if (pthread_barrier_destroy(&shared.ready) != 0 ||
        pthread_barrier_destroy(&shared.phase) != 0 ||
        pthread_mutex_destroy(&shared.lock) != 0 ||
        pthread_cond_destroy(&shared.go_cond) != 0)
        fail_now("pthread-destroy");

    if (!fgets(line, sizeof line, stdin) ||
        sscanf(line, "%31s %127s %c", command, value, &extra) != 2 ||
        strcmp(command, "VERIFY") != 0 || !valid_nonce(value))
        fail_now("verify-protocol");
    boot_id(current_boot);
    if (getpid() != initial_pid || strcmp(initial_boot, current_boot) != 0)
        fail_now("identity");
    printf("M3_STRESS_PASS nonce=%s pid=%ld boot=%s cpus=%ld bytes_per_cpu=%u passes=%u\n",
           value, (long)initial_pid, current_boot, cpus, SHARD_BYTES, PASSES);
    if (!fgets(line, sizeof line, stdin) || strcmp(line, "POWEROFF\n") != 0)
        fail_now("poweroff-protocol");
    sync();
    execl("/sbin/poweroff", "poweroff", (char *)NULL);
    fail_now("poweroff");
}

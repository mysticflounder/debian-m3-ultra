#define _GNU_SOURCE
/* Bounded Linux guest idle/wakeup witness.  timerfd sleep is evidence of
 * timed blocking and wakeup; it does not claim that a particular WFI path was
 * observed by the host. */
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/timerfd.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define MAX_CPUS 64
#define CYCLES 3
#define SLEEP_SECONDS 10
#define REFERENCE_CHECKSUM UINT64_C(0xc4fa5bc401b5bac2)

struct cpu_stat {
    uint64_t idle;
};

struct shared {
    int cpus;
    const char *token;
    pthread_barrier_t ready;
    pthread_mutex_t lock;
    pthread_cond_t go_cond;
    int go;
    int failed;
    uint64_t checksum;
    unsigned wakes;
    uint64_t checksums[MAX_CPUS];
    unsigned wake_counts[MAX_CPUS];
};

struct worker_arg {
    struct shared *shared;
    int cpu;
};

static void die(const char *reason)
{
    printf("M3_IDLE_FAIL reason=%s errno=%d\n", reason, errno);
    fflush(stdout);
    _exit(1);
}

static uint64_t mix(uint64_t value)
{
    value ^= value >> 30;
    value *= UINT64_C(0xbf58476d1ce4e5b9);
    value ^= value >> 27;
    value *= UINT64_C(0x94d049bb133111eb);
    return value ^ (value >> 31);
}

static uint64_t work(void)
{
    volatile uint64_t value = UINT64_C(0x123456789abcdef0);
    for (unsigned i = 0; i < 200000; ++i)
        value = mix(value + i + UINT64_C(0x9e3779b97f4a7c15));
    return value;
}

static int read_idle(struct cpu_stat *stats, int cpus)
{
    FILE *file = fopen("/proc/stat", "r");
    char line[256];
    int seen = 0;

    if (!file)
        return -1;
    while (fgets(line, sizeof line, file)) {
        unsigned cpu;
        unsigned long long user, nice, system, idle, iowait, irq, softirq,
            steal;
        int count = sscanf(line, "cpu%u %llu %llu %llu %llu %llu %llu %llu %llu",
                           &cpu, &user, &nice, &system, &idle, &iowait,
                           &irq, &softirq, &steal);
        if (count == 9 && cpu < (unsigned)cpus) {
            (void)iowait;
            stats[cpu].idle = (uint64_t)idle;
            seen++;
        }
    }
    fclose(file);
    return seen == cpus ? 0 : -1;
}

static int affinity_is_cpu(int cpu)
{
    cpu_set_t set;
    CPU_ZERO(&set);
    if (sched_getaffinity(0, sizeof set, &set) != 0)
        return 0;
    return CPU_COUNT(&set) == 1 && CPU_ISSET(cpu, &set) && sched_getcpu() == cpu;
}

static void *worker(void *opaque)
{
    struct worker_arg *arg = opaque;
    struct shared *shared = arg->shared;
    cpu_set_t set;
    int timer = -1;

    CPU_ZERO(&set);
    CPU_SET(arg->cpu, &set);
    if (pthread_setaffinity_np(pthread_self(), sizeof set, &set) != 0 ||
        !affinity_is_cpu(arg->cpu)) {
        pthread_mutex_lock(&shared->lock);
        shared->failed = 1;
        pthread_mutex_unlock(&shared->lock);
    }
    int barrier_status = pthread_barrier_wait(&shared->ready);
    if (barrier_status != 0 && barrier_status != PTHREAD_BARRIER_SERIAL_THREAD)
        die("worker-barrier");
    pthread_mutex_lock(&shared->lock);
    while (!shared->go && !shared->failed)
        pthread_cond_wait(&shared->go_cond, &shared->lock);
    int failed = shared->failed;
    pthread_mutex_unlock(&shared->lock);
    if (failed)
        return NULL;

    timer = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC);
    if (timer < 0)
        goto failed;
    for (int cycle = 0; cycle < CYCLES; ++cycle) {
        struct itimerspec timer_spec = {
            .it_value = { .tv_sec = SLEEP_SECONDS, .tv_nsec = 0 }
        };
        uint64_t expirations;
        struct timespec before, after;
        if (clock_gettime(CLOCK_MONOTONIC, &before) != 0 ||
            timerfd_settime(timer, 0, &timer_spec, NULL) != 0 ||
            read(timer, &expirations, sizeof expirations) != (ssize_t)sizeof expirations ||
            clock_gettime(CLOCK_MONOTONIC, &after) != 0 ||
            expirations != 1 || !affinity_is_cpu(arg->cpu) ||
            after.tv_sec - before.tv_sec < SLEEP_SECONDS ||
            (after.tv_sec - before.tv_sec == SLEEP_SECONDS &&
             after.tv_nsec < before.tv_nsec))
            goto failed;
        uint64_t checksum = work();
        pthread_mutex_lock(&shared->lock);
        if (checksum != REFERENCE_CHECKSUM)
            shared->failed = 1;
        shared->checksum = REFERENCE_CHECKSUM;
        shared->wakes++;
        shared->wake_counts[arg->cpu]++;
        shared->checksums[arg->cpu] = checksum;
        pthread_mutex_unlock(&shared->lock);
    }
    close(timer);
    return NULL;

failed:
    if (timer >= 0)
        close(timer);
    pthread_mutex_lock(&shared->lock);
    shared->failed = 1;
    pthread_mutex_unlock(&shared->lock);
    return NULL;
}

static void boot_id(char output[64])
{
    FILE *file = fopen("/proc/sys/kernel/random/boot_id", "r");
    if (!file || !fgets(output, 64, file) || fclose(file) != 0)
        die("boot-id");
    output[strcspn(output, "\r\n")] = '\0';
    if (strlen(output) != 36)
        die("boot-id-format");
}

static int valid_nonce(const char *nonce)
{
    size_t length = strlen(nonce);
    if (length < 16 || length > 96)
        return 0;
    return strspn(nonce, "0123456789abcdef") == length;
}

int main(int argc, char **argv)
{
    struct shared shared;
    pthread_t threads[MAX_CPUS];
    struct worker_arg args[MAX_CPUS];
    struct cpu_stat before[MAX_CPUS], after[MAX_CPUS];
    char initial_boot[64], current_boot[64], line[256], command[32], value[128], extra;
    char *end;
    long cpus;

    setvbuf(stdout, NULL, _IONBF, 0);
    putchar('\n');
    if (argc != 3)
        die("arguments");
    errno = 0;
    cpus = strtol(argv[1], &end, 10);
    if (errno || end == argv[1] || *end || cpus < 1 || cpus > MAX_CPUS)
        die("cpu-count");
    if (strlen(argv[2]) == 0 || strlen(argv[2]) > 100 ||
        strspn(argv[2], "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-") != strlen(argv[2]))
        die("token");
    if (sysconf(_SC_NPROCESSORS_ONLN) != cpus)
        die("online-cpu-count");
    boot_id(initial_boot);
    memset(&shared, 0, sizeof shared);
    shared.cpus = (int)cpus;
    shared.token = argv[2];
    if (pthread_barrier_init(&shared.ready, NULL, (unsigned)cpus + 1U) != 0 ||
        pthread_mutex_init(&shared.lock, NULL) != 0 ||
        pthread_cond_init(&shared.go_cond, NULL) != 0)
        die("pthread-init");
    for (int cpu = 0; cpu < cpus; ++cpu) {
        args[cpu] = (struct worker_arg){ .shared = &shared, .cpu = cpu };
        if (pthread_create(&threads[cpu], NULL, worker, &args[cpu]) != 0)
            die("pthread-create");
    }
    int barrier_status = pthread_barrier_wait(&shared.ready);
    if (barrier_status != 0 && barrier_status != PTHREAD_BARRIER_SERIAL_THREAD)
        die("main-barrier");
    pthread_mutex_lock(&shared.lock);
    int ready_failed = shared.failed;
    pthread_mutex_unlock(&shared.lock);
    if (ready_failed)
        die("thread-ready");
    printf("M3_IDLE_READY token=%s pid=%ld boot=%s cpus=%ld\n",
           argv[2], (long)getpid(), initial_boot, cpus);
    if (!fgets(line, sizeof line, stdin) ||
        sscanf(line, "%31s %127s %c", command, value, &extra) != 2 ||
        strcmp(command, "GO") != 0 || strcmp(value, argv[2]) != 0)
        die("go-protocol");
    if (read_idle(before, (int)cpus) != 0)
        die("proc-stat-before");
    pthread_mutex_lock(&shared.lock);
    shared.go = 1;
    pthread_cond_broadcast(&shared.go_cond);
    pthread_mutex_unlock(&shared.lock);
    for (int cpu = 0; cpu < cpus; ++cpu)
        if (pthread_join(threads[cpu], NULL) != 0)
            die("pthread-join");
    pthread_mutex_lock(&shared.lock);
    int failed = shared.failed;
    unsigned wakes = shared.wakes;
    pthread_mutex_unlock(&shared.lock);
    if (failed || wakes != (unsigned)(CYCLES * cpus) ||
        shared.checksum != REFERENCE_CHECKSUM ||
        read_idle(after, (int)cpus) != 0)
        die("idle-wakeup");
    printf("M3_IDLE_DONE token=%s cpus=%ld wakes=%u checksum=%016" PRIx64 "\n",
           argv[2], cpus, wakes, shared.checksum);
    for (int cpu = 0; cpu < cpus; ++cpu) {
        if (after[cpu].idle <= before[cpu].idle ||
            shared.wake_counts[cpu] != CYCLES)
            die("proc-stat-decreased");
        printf("M3_IDLE_CPU token=%s cpu=%d wakes=%d checksum=%016" PRIx64
               " idle_ticks_before=%" PRIu64 " idle_ticks_after=%" PRIu64
               " idle_ticks_delta=%" PRIu64 "\n", argv[2], cpu, CYCLES,
               shared.checksums[cpu], before[cpu].idle, after[cpu].idle,
               after[cpu].idle - before[cpu].idle);
    }
    if (!fgets(line, sizeof line, stdin) ||
        sscanf(line, "%31s %127s %c", command, value, &extra) != 2 ||
        strcmp(command, "VERIFY") != 0 || !valid_nonce(value))
        die("verify-protocol");
    boot_id(current_boot);
    if (getpid() <= 0 || strcmp(initial_boot, current_boot) != 0)
        die("identity-changed");
    printf("M3_IDLE_PASS nonce=%s pid=%ld boot=%s cpus=%ld\n",
           value, (long)getpid(), initial_boot, cpus);
    if (!fgets(line, sizeof line, stdin) || strcmp(line, "POWEROFF\n") != 0)
        die("poweroff-protocol");
    sync();
    execl("/sbin/poweroff", "poweroff", (char *)NULL);
    die("poweroff");
}

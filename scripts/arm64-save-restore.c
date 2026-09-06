#define _GNU_SOURCE
/* A same-process RAM, disk, CPU and timer witness. Run only in the guest. */
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <poll.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/timerfd.h>
#include <time.h>
#include <unistd.h>

static volatile unsigned char ram[4 * 1024 * 1024];
static unsigned char disk[4096] __attribute__((aligned(4096)));
static const char *sentinel = "/root/m3-save-restore-sentinel";
static void die(const char *what) {
    printf("M3_SR_FAIL reason=%s errno=%d\n", what, errno);
    exit(1);
}
static unsigned char pattern(size_t i) {
    uint64_t x = i + UINT64_C(0x9e3779b97f4a7c15);
    x = (x ^ (x >> 30)) * UINT64_C(0xbf58476d1ce4e5b9);
    x = (x ^ (x >> 27)) * UINT64_C(0x94d049bb133111eb);
    return (unsigned char)(x ^ (x >> 31));
}
static void write_disk(int mutated) {
    for (size_t i = 0; i < sizeof disk; ++i) disk[i] = pattern(i) ^ (mutated ? 255 : 0);
    int fd = open(sentinel, O_CREAT | O_RDWR | O_DIRECT | O_SYNC, 0600);
    if (fd < 0 || pwrite(fd, disk, sizeof disk, 0) != (ssize_t)sizeof disk || fsync(fd)) die("disk-write");
    if (close(fd)) die("disk-close");
    sync();
}
static void boot_id(char out[64]) {
    FILE *f = fopen("/proc/sys/kernel/random/boot_id", "r");
    if (!f || !fgets(out, 64, f) || fclose(f)) die("boot-id");
    out[strcspn(out, "\r\n")] = 0;
    if (strlen(out) != 36) die("boot-id-format");
}
static uint64_t now_ns(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t)) die("clock");
    return (uint64_t)t.tv_sec * UINT64_C(1000000000) + (uint64_t)t.tv_nsec;
}
static uint64_t work(void) {
    volatile uint64_t x = UINT64_C(0x123456789abcdef);
    for (unsigned i = 0; i < 200000; ++i) x = x * UINT64_C(6364136223846793005) + 1;
    return x;
}
int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    /* Consume any interactive-shell OSC command-start prefix on a blank line. */
    putchar('\n');
    if (argc != 3) die("arguments");
    char *end;
    long cpus = strtol(argv[1], &end, 10);
    if (*end || cpus < 1 || cpus > 64 || sysconf(_SC_NPROCESSORS_ONLN) != cpus) die("cpu-count");
    if (strlen(argv[2]) > 100 || strspn(argv[2], "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-") != strlen(argv[2])) die("token");
    pid_t initial_pid = getpid();
    char initial_boot[64], current_boot[64], line[256], command[32], nonce[128], extra;
    boot_id(initial_boot);
    for (size_t i = 0; i < sizeof ram; ++i) ram[i] = pattern(i);
    write_disk(0);
    uint64_t baseline_clock = now_ns();
    printf("M3_SR_READY token=%s pid=%ld boot=%s cpus=%ld\n", argv[2], (long)initial_pid, initial_boot, cpus);
    int mutated = 0;
    while (fgets(line, sizeof line, stdin)) {
        if (sscanf(line, "%31s %127s %c", command, nonce, &extra) != 2) die("command-format");
        if (!strcmp(command, "MUTATE")) {
            if (mutated || strcmp(nonce, argv[2])) die("mutate-protocol");
            for (size_t i = 0; i < sizeof ram; ++i) ram[i] ^= 255;
            write_disk(1);
            mutated = 1;
            printf("M3_SR_MUTATED token=%s\n", nonce);
        } else if (!strcmp(command, "VERIFY")) {
            if (!strcmp(nonce, argv[2]) || strlen(nonce) < 16 || strspn(nonce, "0123456789abcdef") != strlen(nonce)) die("challenge");
            if (mutated) die("mutated-state-not-restored");
            for (size_t i = 0; i < sizeof ram; ++i) if (ram[i] != pattern(i)) die("ram-not-restored");
            int fd = open(sentinel, O_RDONLY | O_DIRECT);
            if (fd < 0 || pread(fd, disk, sizeof disk, 0) != (ssize_t)sizeof disk || close(fd)) die("disk-read");
            for (size_t i = 0; i < sizeof disk; ++i) if (disk[i] != pattern(i)) die("disk-not-restored");
            boot_id(current_boot);
            if (getpid() != initial_pid || strcmp(initial_boot, current_boot)) die("identity-changed");
            const uint64_t reference = UINT64_C(0xd9ef6e3b3f70baaf);
            if (work() != reference) die("reference-work");
            for (int cpu = 0; cpu < cpus; ++cpu) {
                cpu_set_t mask;
                CPU_ZERO(&mask); CPU_SET(cpu, &mask);
                if (sched_setaffinity(0, sizeof mask, &mask) || sched_getcpu() != cpu) die("cpu-affinity");
                if (work() != reference || sched_getcpu() != cpu) die("cpu-work");
                printf("M3_SR_CPU nonce=%s cpu=%d checksum=%016" PRIx64 "\n", nonce, cpu, reference);
            }
            uint64_t before = now_ns(), expirations;
            int timer = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
            struct itimerspec it = { .it_value = { .tv_sec = 0, .tv_nsec = 100000000 } };
            struct pollfd p = { .fd = timer, .events = POLLIN };
            if (timer < 0 || timerfd_settime(timer, 0, &it, NULL) || poll(&p, 1, 3000) != 1 || !(p.revents & POLLIN) || read(timer, &expirations, sizeof expirations) != (ssize_t)sizeof expirations || expirations != 1) die("timerfd");
            uint64_t after = now_ns();
            if (before < baseline_clock || after <= before || after - before < 100000000 || after - before > UINT64_C(4000000000)) die("monotonic");
            if (close(timer)) die("timer-close");
            printf("M3_SR_PASS nonce=%s token=%s pid=%ld boot=%s cpus=%ld ram=baseline disk=baseline timer=expired monotonic=progress\n", nonce, argv[2], (long)initial_pid, initial_boot, cpus);
            if (!fgets(line, sizeof line, stdin) || strcmp(line, "POWEROFF\n")) die("poweroff-protocol");
            sync();
            execl("/sbin/poweroff", "poweroff", (char *)NULL);
            die("poweroff");
        } else die("unknown-command");
    }
    die("unexpected-eof");
}

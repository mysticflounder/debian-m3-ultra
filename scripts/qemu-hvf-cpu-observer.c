/* Read timing-v2 workload markers and account for a same-user QEMU process.
 *
 * Usage: qemu-hvf-cpu-observer <qemu-pid> <smp>
 * Input: BENCH_WORK_BEGIN sample_id=<id> workload=<integer|memory>
 *        BENCH_WORK_END sample_id=<id> workload=<integer|memory> status=ok
 *
 * One compact JSON object is written for each completed interval.  The
 * observer deliberately treats serial marker receipt as the interval
 * boundary.  Each object records that boundary source and the endpoint
 * sampling uncertainty.  No privileged API is used.
 */
#define _DARWIN_C_SOURCE

#include <errno.h>
#include <inttypes.h>
#include <libproc.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach_time.h>
#include <sys/proc_info.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define LINE_LIMIT 512
#define MAX_SMP 64
#define MAX_THREAD_BYTES (1024U * 1024U)

struct identity {
    uid_t uid;
    uint64_t start_sec;
    uint64_t start_usec;
};

struct vcpu_sample {
    uint64_t tid;
    uint64_t user_ns;
    uint64_t system_ns;
};

struct snapshot {
    uint64_t process_user_ns;
    uint64_t process_system_ns;
    struct vcpu_sample vcpus[MAX_SMP];
    int vcpu_count;
    uint64_t monotonic_ns;
    uint64_t sampling_span_ns;
};

static pid_t target_pid;
static int target_smp;
static struct identity target_identity;
static mach_timebase_info_data_t timebase;

static int absolute_time_to_ns(uint64_t value, uint64_t *result)
{
    __uint128_t scaled;

    if (timebase.denom == 0) {
        return -1;
    }
    scaled = (__uint128_t)value * timebase.numer / timebase.denom;
    if (scaled > UINT64_MAX) {
        return -1;
    }
    *result = (uint64_t)scaled;
    return 0;
}

static int now_ns(uint64_t *result)
{
    struct timespec ts;

    if (clock_gettime(CLOCK_MONOTONIC_RAW, &ts) != 0 || ts.tv_sec < 0 ||
        ts.tv_nsec < 0 || ts.tv_nsec >= 1000000000L) {
        return -1;
    }
    if ((uint64_t)ts.tv_sec > (UINT64_MAX - (uint64_t)ts.tv_nsec) / 1000000000U) {
        return -1;
    }
    *result = (uint64_t)ts.tv_sec * 1000000000U + (uint64_t)ts.tv_nsec;
    return 0;
}

static int read_identity(struct identity *identity)
{
    struct proc_bsdinfo bsd;
    int result;

    memset(&bsd, 0, sizeof(bsd));
    result = proc_pidinfo(target_pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd));
    if (result != (int)sizeof(bsd) || bsd.pbi_pid != (uint32_t)target_pid ||
        bsd.pbi_uid != geteuid()) {
        return -1;
    }
    identity->uid = bsd.pbi_uid;
    identity->start_sec = bsd.pbi_start_tvsec;
    identity->start_usec = bsd.pbi_start_tvusec;
    return 0;
}

static int identity_matches(void)
{
    struct identity current;

    if (read_identity(&current) != 0) {
        return 0;
    }
    return current.uid == target_identity.uid &&
        current.start_sec == target_identity.start_sec &&
        current.start_usec == target_identity.start_usec;
}

static int parse_cpu_name(const char *name, int *index)
{
    const char *cursor = name;
    unsigned long value = 0;

    if (strncmp(cursor, "CPU ", 4) != 0) {
        return -1;
    }
    cursor += 4;
    if (*cursor < '0' || *cursor > '9') {
        return -1;
    }
    while (*cursor >= '0' && *cursor <= '9') {
        value = value * 10U + (unsigned long)(*cursor - '0');
        if (value >= (unsigned long)target_smp) {
            return -1;
        }
        ++cursor;
    }
    if (strcmp(cursor, "/HVF") != 0) {
        return -1;
    }
    *index = (int)value;
    return 0;
}

static int list_threads(uint64_t **ids_out, size_t *count_out)
{
    uint64_t *ids = NULL;
    size_t capacity = 256;
    int bytes;

    while (capacity <= MAX_THREAD_BYTES) {
        ids = realloc(ids, capacity);
        if (ids == NULL) {
            return -1;
        }
        bytes = proc_pidinfo(target_pid, PROC_PIDLISTTHREADS, 0, ids,
                             (int)capacity);
        if (bytes < 0) {
            free(ids);
            return -1;
        }
        if ((size_t)bytes < capacity) {
            if (bytes == 0 || (bytes % PROC_PIDLISTTHREADS_SIZE) != 0) {
                free(ids);
                return -1;
            }
            *ids_out = ids;
            *count_out = (size_t)bytes / PROC_PIDLISTTHREADS_SIZE;
            return 0;
        }
        capacity *= 2;
    }
    free(ids);
    return -1;
}

static int snapshot_threads(struct snapshot *snapshot)
{
    uint64_t *ids = NULL;
    bool found[MAX_SMP] = { false };
    size_t count = 0;

    if (list_threads(&ids, &count) != 0) {
        return -1;
    }
    for (size_t i = 0; i < count; ++i) {
        struct proc_threadinfo info;
        int cpu;
        int bytes;

        memset(&info, 0, sizeof(info));
        /* PROC_PIDLISTTHREADS IDs are accepted by PROC_PIDTHREADINFO here.
         * PROC_PIDTHREADID64INFO returns ESRCH for these IDs on macOS 26.6.2.
         * The pth_* time fields are already nanoseconds. */
        bytes = proc_pidinfo(target_pid, PROC_PIDTHREADINFO, ids[i],
                             &info, sizeof(info));
        if (bytes != (int)sizeof(info)) {
            free(ids);
            return -1;
        }
        if (strncmp(info.pth_name, "CPU ", 4) != 0) {
            continue;
        }
        if (parse_cpu_name(info.pth_name, &cpu) != 0 || found[cpu]) {
            free(ids);
            return -1;
        }
        found[cpu] = true;
        snapshot->vcpus[cpu].tid = ids[i];
        snapshot->vcpus[cpu].user_ns = info.pth_user_time;
        snapshot->vcpus[cpu].system_ns = info.pth_system_time;
    }
    free(ids);
    for (int cpu = 0; cpu < target_smp; ++cpu) {
        if (!found[cpu]) {
            return -1;
        }
    }
    snapshot->vcpu_count = target_smp;
    return 0;
}

static int take_snapshot(struct snapshot *snapshot)
{
    struct proc_taskinfo task;
    uint64_t before_ns;
    uint64_t after_ns;
    int bytes;

    memset(snapshot, 0, sizeof(*snapshot));
    if (now_ns(&before_ns) != 0 || !identity_matches()) {
        return -1;
    }
    memset(&task, 0, sizeof(task));
    bytes = proc_pidinfo(target_pid, PROC_PIDTASKINFO, 0, &task, sizeof(task));
    /* pti_total_* uses Mach absolute-time units on Apple Silicon; convert it
     * before comparing it with proc_threadinfo's nanosecond counters. */
    if (bytes != (int)sizeof(task) ||
        absolute_time_to_ns(task.pti_total_user,
                            &snapshot->process_user_ns) != 0 ||
        absolute_time_to_ns(task.pti_total_system,
                            &snapshot->process_system_ns) != 0 ||
        snapshot_threads(snapshot) != 0 ||
        !identity_matches() || now_ns(&after_ns) != 0 || after_ns < before_ns) {
        return -1;
    }
    snapshot->monotonic_ns = before_ns + (after_ns - before_ns) / 2;
    snapshot->sampling_span_ns = after_ns - before_ns;
    return 0;
}

static int valid_sample_id(const char *text)
{
    size_t length = strlen(text);

    if (length == 0 || length > 64) {
        return 0;
    }
    for (size_t i = 0; i < length; ++i) {
        char c = text[i];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
              (c >= '0' && c <= '9') || c == '_' || c == '.' ||
              c == ':' || c == '-')) {
            return 0;
        }
    }
    return 1;
}

static int parse_marker(const char *line, bool *begin, char *sample_id,
                        char *workload)
{
    int used = 0;
    char status[16];
    int fields;

    fields = sscanf(line, "BENCH_WORK_BEGIN sample_id=%64s workload=%15s%n",
                    sample_id, workload, &used);
    if (fields == 2 && line[used] == '\0') {
        *begin = true;
    } else {
        used = 0;
        fields = sscanf(line,
                        "BENCH_WORK_END sample_id=%64s workload=%15s status=%15s%n",
                        sample_id, workload, status, &used);
        if (fields != 3 || strcmp(status, "ok") != 0 || line[used] != '\0') {
            return -1;
        }
        *begin = false;
    }
    if (!valid_sample_id(sample_id) ||
        (strcmp(workload, "integer") != 0 && strcmp(workload, "memory") != 0)) {
        return -1;
    }
    return 0;
}

static int delta(uint64_t end, uint64_t start, uint64_t *result)
{
    if (end < start) {
        return -1;
    }
    *result = end - start;
    return 0;
}

static int sum_vcpu_delta(const struct snapshot *start, const struct snapshot *end,
                          uint64_t *user, uint64_t *system)
{
    *user = 0;
    *system = 0;
    if (start->vcpu_count != target_smp || end->vcpu_count != target_smp) {
        return -1;
    }
    for (int cpu = 0; cpu < target_smp; ++cpu) {
        uint64_t user_delta;
        uint64_t system_delta;
        if (start->vcpus[cpu].tid != end->vcpus[cpu].tid ||
            delta(end->vcpus[cpu].user_ns, start->vcpus[cpu].user_ns,
                  &user_delta) != 0 ||
            delta(end->vcpus[cpu].system_ns, start->vcpus[cpu].system_ns,
                  &system_delta) != 0 ||
            UINT64_MAX - *user < user_delta ||
            UINT64_MAX - *system < system_delta) {
            return -1;
        }
        *user += user_delta;
        *system += system_delta;
    }
    return 0;
}

static void print_unavailable(const char *sample_id, const char *workload,
                              const char *status, double wall)
{
    printf("{\"sample_id\":\"%s\",\"workload\":\"%s\","
           "\"host_wall_seconds\":%.9f,\"qemu_process_cpu_seconds\":null,"
           "\"qemu_vcpu_cpu_seconds\":null,\"qemu_management_cpu_seconds\":null,"
           "\"vcpu_thread_count\":%d,\"vcpu_thread_set_stable\":false,"
           "\"accounting_status\":\"%s\",\"sampling_uncertainty_seconds\":null,"
           "\"counter_skew_clamped_seconds\":null,"
           "\"boundary_source\":\"serial-marker-receipt\"}\n",
           sample_id, workload, wall, target_smp, status);
    fflush(stdout);
}

static int print_interval(const char *sample_id, const char *workload,
                          const struct snapshot *start,
                          const struct snapshot *end)
{
    uint64_t process_user;
    uint64_t process_system;
    uint64_t vcpu_user;
    uint64_t vcpu_system;
    uint64_t process_total;
    uint64_t vcpu_total;
    uint64_t management_total;
    double wall;
    double uncertainty;
    double counter_skew = 0.0;
    double counter_skew_bound;

    if (delta(end->process_user_ns, start->process_user_ns,
              &process_user) != 0 ||
        delta(end->process_system_ns, start->process_system_ns,
              &process_system) != 0 ||
        sum_vcpu_delta(start, end, &vcpu_user, &vcpu_system) != 0 ||
        UINT64_MAX - process_user < process_system ||
        UINT64_MAX - vcpu_user < vcpu_system) {
        fprintf(stderr, "observer counters decreased or vCPU thread IDs changed\n");
        print_unavailable(sample_id, workload, "negative_or_unstable_delta", 0.0);
        return -1;
    }
    process_total = process_user + process_system;
    vcpu_total = vcpu_user + vcpu_system;
    if (end->monotonic_ns < start->monotonic_ns) {
        print_unavailable(sample_id, workload, "negative_or_unstable_delta", 0.0);
        return -1;
    }
    counter_skew_bound = (double)target_smp *
        (double)(start->sampling_span_ns + end->sampling_span_ns) / 1e9;
    if (process_total < vcpu_total) {
        counter_skew = (double)(vcpu_total - process_total) / 1e9;
        if (counter_skew > counter_skew_bound) {
            fprintf(stderr,
                    "observer process/vCPU skew %.9f exceeds sampling bound %.9f\n",
                    counter_skew, counter_skew_bound);
            print_unavailable(sample_id, workload,
                              "negative_or_unstable_delta", 0.0);
            return -1;
        }
        management_total = 0;
    } else {
        management_total = process_total - vcpu_total;
    }
    wall = (double)(end->monotonic_ns - start->monotonic_ns) / 1e9;
    uncertainty = (double)(start->sampling_span_ns + end->sampling_span_ns) /
        2e9;
    printf("{\"sample_id\":\"%s\",\"workload\":\"%s\","
           "\"host_wall_seconds\":%.9f,\"qemu_process_cpu_seconds\":%.9f,"
           "\"qemu_vcpu_cpu_seconds\":%.9f,\"qemu_management_cpu_seconds\":%.9f,"
           "\"vcpu_thread_count\":%d,\"vcpu_thread_set_stable\":true,"
           "\"accounting_status\":\"ok\",\"sampling_uncertainty_seconds\":%.9f,"
           "\"counter_skew_clamped_seconds\":%.9f,"
           "\"boundary_source\":\"serial-marker-receipt\"}\n",
           sample_id, workload, wall,
           (double)process_total / 1e9, (double)vcpu_total / 1e9,
           (double)management_total / 1e9, target_smp, uncertainty,
           counter_skew);
    fflush(stdout);
    return 0;
}

int main(int argc, char **argv)
{
    char line[LINE_LIMIT];
    char active_id[65] = { 0 };
    char active_workload[16] = { 0 };
    struct snapshot begin_snapshot;
    bool active = false;
    int exit_status = 0;
    long pid_value;
    char *end = NULL;

    if (argc != 3) {
        fprintf(stderr, "usage: %s <qemu-pid> <smp>\n", argv[0]);
        return 2;
    }
    errno = 0;
    pid_value = strtol(argv[1], &end, 10);
    if (errno != 0 || end == argv[1] || *end != '\0' || pid_value <= 0 ||
        pid_value > INT_MAX) {
        return 2;
    }
    target_pid = (pid_t)pid_value;
    errno = 0;
    pid_value = strtol(argv[2], &end, 10);
    if (errno != 0 || end == argv[2] || *end != '\0' || pid_value < 1 ||
        pid_value > MAX_SMP) {
        return 2;
    }
    target_smp = (int)pid_value;
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.denom == 0) {
        fprintf(stderr, "cannot read Mach timebase\n");
        return 2;
    }
    if (read_identity(&target_identity) != 0) {
        fprintf(stderr, "cannot validate same-user QEMU PID/start identity\n");
        return 2;
    }
    setvbuf(stdout, NULL, _IOLBF, 0);
    while (fgets(line, sizeof(line), stdin) != NULL) {
        bool is_begin;
        char sample_id[65];
        char workload[16];

        if (strchr(line, '\n') == NULL) {
            int character;
            bool marker_prefix = strstr(line, "BENCH_WORK_") != NULL;

            while ((character = fgetc(stdin)) != '\n' && character != EOF) {
                continue;
            }
            if (marker_prefix) {
                fprintf(stderr, "observer marker line exceeds limit\n");
                return 2;
            }
            continue;
        }
        line[strcspn(line, "\r\n")] = '\0';
        if (strncmp(line, "BENCH_WORK_", 11) != 0) {
            continue;
        }
        if (parse_marker(line, &is_begin, sample_id, workload) != 0) {
            fprintf(stderr, "malformed or unsupported BENCH_WORK marker\n");
            return 2;
        }
        if (is_begin) {
            if (active || take_snapshot(&begin_snapshot) != 0) {
                fprintf(stderr, "invalid begin boundary or QEMU snapshot\n");
                return 2;
            }
            strcpy(active_id, sample_id);
            strcpy(active_workload, workload);
            active = true;
        } else {
            struct snapshot end_snapshot;
            int interval_status;

            if (!active || strcmp(active_id, sample_id) != 0 ||
                strcmp(active_workload, workload) != 0 ||
                take_snapshot(&end_snapshot) != 0) {
                fprintf(stderr, "invalid end boundary or QEMU snapshot\n");
                return 2;
            }
            interval_status = print_interval(sample_id, workload,
                                              &begin_snapshot, &end_snapshot);
            active = false;
            if (interval_status != 0) {
                exit_status = 2;
            }
        }
    }
    if (ferror(stdin) || active) {
        fprintf(stderr, "observer input ended before a complete interval\n");
        return 2;
    }
    return exit_status;
}

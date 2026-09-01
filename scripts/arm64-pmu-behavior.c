/* Read-only Linux/arm64 userspace PMU behavior collector.
 *
 * Build in the guest with:
 *   gcc -O2 -Wall -Wextra -Werror -std=gnu11 \
 *       -o arm64-pmu-behavior arm64-pmu-behavior.c
 *
 * The process changes only its own scheduling affinity, restores it before
 * emitting JSON, and never changes perf or kernel policy.
 */

#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L

#include <dirent.h>
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <linux/perf_event.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

#if !defined(__linux__) || !defined(__aarch64__)
#error "arm64-pmu-behavior.c must be built for Linux/aarch64"
#endif

#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define MAX_TEXT 16384
#define MAX_CPUS 4096

struct operation {
    const char *status;
    int error_number;
};

struct text_result {
    const char *status;
    int error_number;
    char *value;
};

struct read_result {
    struct operation operation;
    uint64_t count;
    uint64_t time_enabled;
    uint64_t time_running;
};

struct event_definition {
    const char *name;
    uint64_t config;
};

struct event_result {
    const struct event_definition *definition;
    const char *status;
    const char *reason;
    struct operation open;
    struct operation reset;
    struct operation enable;
    struct read_result before;
    struct read_result after;
    struct operation disable;
    struct operation close;
    uint64_t count_delta;
    uint64_t time_enabled_delta;
    uint64_t time_running_delta;
    struct operation verify_affinity;
    int affinity_correct;
};

struct cpu_result {
    int cpu;
    struct operation pin;
    struct operation verify_before;
    int observed_before;
    struct event_result events[9];
    struct operation verify_after;
    int observed_after;
    int affinity_correct;
};

struct affinity_state {
    cpu_set_t *original;
    size_t set_size;
    struct operation get_original;
    struct operation restore;
    struct operation verify_restored;
    int restored_exactly;
};

static const struct event_definition event_definitions[] = {
    { "cycles", PERF_COUNT_HW_CPU_CYCLES },
    { "instructions", PERF_COUNT_HW_INSTRUCTIONS },
    { "branch_instructions", PERF_COUNT_HW_BRANCH_INSTRUCTIONS },
    { "cache_references", PERF_COUNT_HW_CACHE_REFERENCES },
    { "cache_misses", PERF_COUNT_HW_CACHE_MISSES },
    { "bus_cycles", PERF_COUNT_HW_BUS_CYCLES },
    { "stalled_frontend", PERF_COUNT_HW_STALLED_CYCLES_FRONTEND },
    { "stalled_backend", PERF_COUNT_HW_STALLED_CYCLES_BACKEND },
    { "ref_cpu_cycles", PERF_COUNT_HW_REF_CPU_CYCLES },
};

static volatile uint64_t workload_data[256];
static volatile uint64_t workload_sink;

static void *checked_realloc(void *pointer, size_t size)
{
    void *result = realloc(pointer, size);

    if (result == NULL && size != 0) {
        fputs("arm64-pmu-behavior: out of memory\n", stderr);
        exit(EXIT_FAILURE);
    }
    return result;
}

static char *checked_strdup(const char *text)
{
    char *result = strdup(text);

    if (result == NULL) {
        fputs("arm64-pmu-behavior: out of memory\n", stderr);
        exit(EXIT_FAILURE);
    }
    return result;
}

static struct operation not_attempted(void)
{
    struct operation result = { "not_attempted", 0 };
    return result;
}

static struct operation success(void)
{
    struct operation result = { "success", 0 };
    return result;
}

static struct operation failure(int error_number)
{
    struct operation result = { "error", error_number };
    return result;
}

static void json_string(const char *text)
{
    const unsigned char *cursor = (const unsigned char *)text;

    putchar('"');
    while (*cursor != '\0') {
        switch (*cursor) {
        case '"': fputs("\\\"", stdout); break;
        case '\\': fputs("\\\\", stdout); break;
        case '\b': fputs("\\b", stdout); break;
        case '\f': fputs("\\f", stdout); break;
        case '\n': fputs("\\n", stdout); break;
        case '\r': fputs("\\r", stdout); break;
        case '\t': fputs("\\t", stdout); break;
        default:
            if (*cursor < 0x20)
                printf("\\u%04x", *cursor);
            else
                putchar(*cursor);
        }
        ++cursor;
    }
    putchar('"');
}

static struct text_result read_text_file(const char *path)
{
    struct text_result result = { "error", 0, NULL };
    FILE *stream;
    char *buffer;
    size_t used;

    errno = 0;
    stream = fopen(path, "re");
    if (stream == NULL) {
        result.error_number = errno;
        result.status = errno == ENOENT ? "missing" : "error";
        return result;
    }
    buffer = checked_realloc(NULL, MAX_TEXT + 1);
    used = fread(buffer, 1, MAX_TEXT, stream);
    if (ferror(stream)) {
        result.error_number = errno != 0 ? errno : EIO;
        free(buffer);
        fclose(stream);
        return result;
    }
    if (used == MAX_TEXT && fgetc(stream) != EOF) {
        result.error_number = EOVERFLOW;
        free(buffer);
        fclose(stream);
        return result;
    }
    if (fclose(stream) != 0) {
        result.error_number = errno;
        free(buffer);
        return result;
    }
    buffer[used] = '\0';
    while (used > 0 && (buffer[used - 1] == '\n' ||
                        buffer[used - 1] == '\r' ||
                        buffer[used - 1] == ' ' || buffer[used - 1] == '\t'))
        buffer[--used] = '\0';
    result.status = "success";
    result.value = buffer;
    return result;
}

static void free_text_result(struct text_result *result)
{
    free(result->value);
    result->value = NULL;
}

static int compare_ints(const void *left, const void *right)
{
    int a = *(const int *)left;
    int b = *(const int *)right;
    return (a > b) - (a < b);
}

static int parse_online_cpus(const char *text, int **ids_out,
                             size_t *count_out, int *max_id_out)
{
    const char *cursor = text;
    int *ids = NULL;
    size_t count = 0;

    while (*cursor != '\0') {
        char *end;
        long first;
        long last;
        long id;

        errno = 0;
        first = strtol(cursor, &end, 10);
        if (errno != 0 || end == cursor || first < 0 || first > INT_MAX)
            goto invalid;
        cursor = end;
        last = first;
        if (*cursor == '-') {
            cursor++;
            errno = 0;
            last = strtol(cursor, &end, 10);
            if (errno != 0 || end == cursor || last < first || last > INT_MAX)
                goto invalid;
            cursor = end;
        }
        if ((unsigned long)(last - first + 1) > MAX_CPUS - count)
            goto invalid;
        for (id = first; id <= last; ++id) {
            ids = checked_realloc(ids, (count + 1) * sizeof(*ids));
            ids[count++] = (int)id;
        }
        if (*cursor == '\0')
            break;
        if (*cursor != ',')
            goto invalid;
        cursor++;
        if (*cursor == '\0')
            goto invalid;
    }
    if (count == 0)
        goto invalid;
    qsort(ids, count, sizeof(*ids), compare_ints);
    for (size_t index = 1; index < count; ++index) {
        if (ids[index] == ids[index - 1])
            goto invalid;
    }
    *ids_out = ids;
    *count_out = count;
    *max_id_out = ids[count - 1];
    return 0;

invalid:
    free(ids);
    return -1;
}

static void collect_original_affinity(struct affinity_state *state, int max_id)
{
    long configured = sysconf(_SC_NPROCESSORS_CONF);
    size_t bit_count = (size_t)(max_id + 1);

    memset(state, 0, sizeof(*state));
    state->get_original = not_attempted();
    state->restore = not_attempted();
    state->verify_restored = not_attempted();
    if (configured > 0 && (size_t)configured > bit_count)
        bit_count = (size_t)configured;
    if (bit_count < 64)
        bit_count = 64;
    while (bit_count <= 1048576) {
        state->set_size = CPU_ALLOC_SIZE(bit_count);
        state->original = CPU_ALLOC(bit_count);
        if (state->original == NULL) {
            state->get_original = failure(ENOMEM);
            return;
        }
        CPU_ZERO_S(state->set_size, state->original);
        errno = 0;
        if (sched_getaffinity(0, state->set_size, state->original) == 0) {
            state->get_original = success();
            return;
        }
        if (errno != EINVAL) {
            state->get_original = failure(errno);
            return;
        }
        CPU_FREE(state->original);
        state->original = NULL;
        bit_count *= 2;
    }
    state->get_original = failure(EOVERFLOW);
}

static struct operation verify_single_cpu(int expected, size_t set_size,
                                          int *observed)
{
    cpu_set_t *current = CPU_ALLOC(set_size * 8);
    struct operation result;

    *observed = -1;
    if (current == NULL)
        return failure(ENOMEM);
    CPU_ZERO_S(set_size, current);
    errno = 0;
    if (sched_getaffinity(0, set_size, current) != 0) {
        result = failure(errno);
    } else {
        errno = 0;
        *observed = sched_getcpu();
        if (*observed < 0)
            result = failure(errno != 0 ? errno : EIO);
        else if (CPU_COUNT_S(set_size, current) != 1 ||
                 !CPU_ISSET_S(expected, set_size, current) ||
                 *observed != expected)
            result = failure(EUCLEAN);
        else
            result = success();
    }
    CPU_FREE(current);
    return result;
}

__attribute__((noinline)) static void bounded_workload(unsigned int seed)
{
    uint64_t accumulator = seed + 1;

    for (unsigned int iteration = 0; iteration < 250000; ++iteration) {
        unsigned int slot = (iteration + seed) & 255U;
        uint64_t value = workload_data[slot];

        value += accumulator ^ ((uint64_t)iteration << (iteration & 7U));
        if ((value & 7U) == (iteration & 7U))
            accumulator += value ^ 0x9e3779b97f4a7c15ULL;
        else
            accumulator = (accumulator << 5) ^ (accumulator >> 3) ^ value;
        workload_data[slot] = value + accumulator;
    }
    workload_sink = accumulator;
}

static struct read_result read_counter(int fd)
{
    struct {
        uint64_t value;
        uint64_t time_enabled;
        uint64_t time_running;
    } payload;
    struct read_result result;
    ssize_t bytes;

    memset(&result, 0, sizeof(result));
    errno = 0;
    do {
        bytes = read(fd, &payload, sizeof(payload));
    } while (bytes < 0 && errno == EINTR);
    if (bytes != (ssize_t)sizeof(payload)) {
        result.operation = failure(bytes < 0 ? errno : EMSGSIZE);
        return result;
    }
    result.operation = success();
    result.count = payload.value;
    result.time_enabled = payload.time_enabled;
    result.time_running = payload.time_running;
    return result;
}

static int unavailable_errno(int error_number)
{
    return error_number == EACCES || error_number == EPERM ||
           error_number == EINVAL || error_number == ENODEV ||
           error_number == ENOENT || error_number == ENOSYS ||
           error_number == EOPNOTSUPP;
}

static const char *unavailable_reason(int error_number)
{
    if (error_number == EACCES || error_number == EPERM)
        return "permission_denied";
    return "unsupported";
}

static void initialize_event(struct event_result *result,
                             const struct event_definition *definition)
{
    memset(result, 0, sizeof(*result));
    result->definition = definition;
    result->status = "not_run";
    result->reason = "cpu_pin_failed";
    result->open = not_attempted();
    result->reset = not_attempted();
    result->enable = not_attempted();
    result->before.operation = not_attempted();
    result->after.operation = not_attempted();
    result->disable = not_attempted();
    result->close = not_attempted();
    result->verify_affinity = not_attempted();
}

static void collect_event(struct event_result *result, int cpu,
                          size_t set_size, unsigned int seed)
{
    struct perf_event_attr attr;
    int fd;
    int enabled = 0;
    int observed;

    memset(&attr, 0, sizeof(attr));
    attr.type = PERF_TYPE_HARDWARE;
    attr.size = sizeof(attr);
    attr.config = result->definition->config;
    attr.disabled = 1;
    attr.inherit = 0;
    attr.pinned = 1;
    attr.exclude_kernel = 1;
    attr.exclude_hv = 1;
    attr.exclude_idle = 1;
    attr.read_format = PERF_FORMAT_TOTAL_TIME_ENABLED |
                       PERF_FORMAT_TOTAL_TIME_RUNNING;

    errno = 0;
    fd = (int)syscall(__NR_perf_event_open, &attr, 0, -1, -1, 0);
    if (fd < 0) {
        result->open = failure(errno);
        if (unavailable_errno(errno)) {
            result->open.status = "unavailable";
            result->status = "unavailable";
            result->reason = unavailable_reason(errno);
        } else {
            result->status = "error";
            result->reason = "open_failed";
        }
        return;
    }
    result->open = success();
    result->reason = "operation_failed";

    errno = 0;
    if (ioctl(fd, PERF_EVENT_IOC_RESET, 0) != 0) {
        result->reset = failure(errno);
        goto finish;
    }
    result->reset = success();
    errno = 0;
    if (ioctl(fd, PERF_EVENT_IOC_ENABLE, 0) != 0) {
        result->enable = failure(errno);
        goto finish;
    }
    result->enable = success();
    enabled = 1;
    result->before = read_counter(fd);
    if (strcmp(result->before.operation.status, "success") != 0)
        goto finish;
    bounded_workload(seed);
    result->after = read_counter(fd);
    if (strcmp(result->after.operation.status, "success") != 0)
        goto finish;

finish:
    if (enabled) {
        errno = 0;
        if (ioctl(fd, PERF_EVENT_IOC_DISABLE, 0) == 0)
            result->disable = success();
        else
            result->disable = failure(errno);
    }
    errno = 0;
    if (close(fd) == 0)
        result->close = success();
    else
        result->close = failure(errno);

    result->verify_affinity = verify_single_cpu(cpu, set_size, &observed);
    result->affinity_correct =
        strcmp(result->verify_affinity.status, "success") == 0;
    if (strcmp(result->before.operation.status, "success") == 0 &&
        strcmp(result->after.operation.status, "success") == 0 &&
        result->after.count >= result->before.count &&
        result->after.time_enabled >= result->before.time_enabled &&
        result->after.time_running >= result->before.time_running) {
        result->count_delta = result->after.count - result->before.count;
        result->time_enabled_delta = result->after.time_enabled -
                                     result->before.time_enabled;
        result->time_running_delta = result->after.time_running -
                                     result->before.time_running;
    }
    if (strcmp(result->reset.status, "success") == 0 &&
        strcmp(result->enable.status, "success") == 0 &&
        strcmp(result->before.operation.status, "success") == 0 &&
        strcmp(result->after.operation.status, "success") == 0 &&
        strcmp(result->disable.status, "success") == 0 &&
        strcmp(result->close.status, "success") == 0 &&
        result->after.count >= result->before.count &&
        result->count_delta > 0 &&
        result->time_enabled_delta > 0 &&
        result->time_running_delta > 0 &&
        result->time_running_delta <= result->time_enabled_delta &&
        result->before.time_running <= result->before.time_enabled &&
        result->after.time_running > 0 &&
        result->after.time_running <= result->after.time_enabled &&
        result->affinity_correct) {
        result->status = "pass";
        result->reason = "measured_positive_delta";
    } else {
        result->status = "fail";
        result->reason = "measurement_contract_failed";
    }
}

static struct text_result find_armv8_pmu_source(void)
{
    const char *root = "/sys/bus/event_source/devices";
    struct text_result result = { "missing", ENOENT, NULL };
    DIR *directory;
    struct dirent *entry;
    char *best = NULL;

    errno = 0;
    directory = opendir(root);
    if (directory == NULL) {
        result.status = errno == ENOENT ? "missing" : "error";
        result.error_number = errno;
        return result;
    }
    errno = 0;
    while ((entry = readdir(directory)) != NULL) {
        if (strncmp(entry->d_name, "armv8_pmuv3", 11) != 0)
            continue;
        if (best == NULL || strcmp(entry->d_name, best) < 0) {
            free(best);
            best = checked_strdup(entry->d_name);
        }
    }
    if (errno != 0) {
        result.status = "error";
        result.error_number = errno;
        free(best);
    } else if (best != NULL) {
        size_t length = strlen(root) + strlen(best) + 2;
        result.value = checked_realloc(NULL, length);
        snprintf(result.value, length, "%s/%s", root, best);
        result.status = "success";
        result.error_number = 0;
        free(best);
    }
    if (closedir(directory) != 0 && strcmp(result.status, "success") != 0) {
        result.status = "error";
        result.error_number = errno;
    }
    return result;
}

static struct text_result read_source_attribute(const struct text_result *source,
                                                const char *name)
{
    char path[PATH_MAX];

    if (strcmp(source->status, "success") != 0) {
        struct text_result result = { "missing", ENOENT, NULL };
        return result;
    }
    if (snprintf(path, sizeof(path), "%s/%s", source->value, name) >=
        (int)sizeof(path)) {
        struct text_result result = { "error", ENAMETOOLONG, NULL };
        return result;
    }
    return read_text_file(path);
}

static void print_operation(const struct operation *operation)
{
    fputs("{\"status\":", stdout);
    json_string(operation->status);
    printf(",\"errno\":%d}", operation->error_number);
}

static void print_text_result(const struct text_result *result)
{
    fputs("{\"status\":", stdout);
    json_string(result->status);
    printf(",\"errno\":%d,\"value\":", result->error_number);
    if (result->value != NULL)
        json_string(result->value);
    else
        fputs("null", stdout);
    putchar('}');
}

static void print_read_result(const struct read_result *result)
{
    fputs("{\"status\":", stdout);
    json_string(result->operation.status);
    printf(",\"errno\":%d,\"count\":\"%" PRIu64
           "\",\"time_enabled\":\"%" PRIu64
           "\",\"time_running\":\"%" PRIu64 "\"}",
           result->operation.error_number, result->count,
           result->time_enabled, result->time_running);
}

static void print_event(const struct event_result *event)
{
    fputs("{\"status\":", stdout);
    json_string(event->status);
    fputs(",\"reason\":", stdout);
    json_string(event->reason);
    printf(",\"type\":%u,\"config\":\"%" PRIu64 "\",\"open\":",
           (unsigned int)PERF_TYPE_HARDWARE, event->definition->config);
    print_operation(&event->open);
    fputs(",\"reset\":", stdout);
    print_operation(&event->reset);
    fputs(",\"enable\":", stdout);
    print_operation(&event->enable);
    fputs(",\"read_before\":", stdout);
    print_read_result(&event->before);
    fputs(",\"read_after\":", stdout);
    print_read_result(&event->after);
    fputs(",\"disable\":", stdout);
    print_operation(&event->disable);
    fputs(",\"close\":", stdout);
    print_operation(&event->close);
    fputs(",\"verify_affinity\":", stdout);
    print_operation(&event->verify_affinity);
    printf(",\"count_delta\":\"%" PRIu64
           "\",\"time_enabled_delta\":\"%" PRIu64
           "\",\"time_running_delta\":\"%" PRIu64
           "\",\"affinity_correct\":%s}",
           event->count_delta, event->time_enabled_delta,
           event->time_running_delta,
           event->affinity_correct ? "true" : "false");
}

static void print_cpu(const struct cpu_result *cpu)
{
    printf("{\"cpu\":%d,\"pin\":", cpu->cpu);
    print_operation(&cpu->pin);
    fputs(",\"verify_before\":", stdout);
    print_operation(&cpu->verify_before);
    printf(",\"observed_before\":%d,\"events\":{", cpu->observed_before);
    for (size_t index = 0; index < ARRAY_SIZE(event_definitions); ++index) {
        if (index != 0)
            putchar(',');
        json_string(event_definitions[index].name);
        putchar(':');
        print_event(&cpu->events[index]);
    }
    fputs("},\"verify_after\":", stdout);
    print_operation(&cpu->verify_after);
    printf(",\"observed_after\":%d,\"affinity_correct\":%s}",
           cpu->observed_after, cpu->affinity_correct ? "true" : "false");
}

int main(void)
{
    const char *online_path = "/sys/devices/system/cpu/online";
    struct text_result online_before = read_text_file(online_path);
    struct text_result online_after;
    struct text_result paranoid = read_text_file("/proc/sys/kernel/perf_event_paranoid");
    struct text_result pmu_source = find_armv8_pmu_source();
    struct text_result pmu_type = read_source_attribute(&pmu_source, "type");
    struct text_result pmu_cpumask = read_source_attribute(&pmu_source, "cpumask");
    struct text_result pmu_nr_counters =
        read_source_attribute(&pmu_source, "caps/nr_counters");
    struct affinity_state affinity;
    struct cpu_result *cpus = NULL;
    int *cpu_ids = NULL;
    size_t cpu_count = 0;
    int max_cpu = 0;
    int parse_errno = 0;
    int cycles_pass_all = 1;

    memset(&affinity, 0, sizeof(affinity));
    affinity.get_original = not_attempted();
    affinity.restore = not_attempted();
    affinity.verify_restored = not_attempted();
    if (strcmp(online_before.status, "success") != 0 ||
        parse_online_cpus(online_before.value, &cpu_ids, &cpu_count,
                          &max_cpu) != 0) {
        parse_errno = strcmp(online_before.status, "success") == 0 ? EINVAL :
                      online_before.error_number;
    } else {
        collect_original_affinity(&affinity, max_cpu);
    }

    if (strcmp(affinity.get_original.status, "success") == 0) {
        cpus = checked_realloc(NULL, cpu_count * sizeof(*cpus));
        memset(cpus, 0, cpu_count * sizeof(*cpus));
        for (size_t index = 0; index < cpu_count; ++index) {
            struct cpu_result *cpu = &cpus[index];
            cpu_set_t *single = CPU_ALLOC(affinity.set_size * 8);

            cpu->cpu = cpu_ids[index];
            cpu->pin = not_attempted();
            cpu->verify_before = not_attempted();
            cpu->verify_after = not_attempted();
            cpu->observed_before = -1;
            cpu->observed_after = -1;
            for (size_t event = 0; event < ARRAY_SIZE(event_definitions); ++event)
                initialize_event(&cpu->events[event], &event_definitions[event]);
            if (single == NULL) {
                cpu->pin = failure(ENOMEM);
            } else {
                CPU_ZERO_S(affinity.set_size, single);
                CPU_SET_S(cpu->cpu, affinity.set_size, single);
                errno = 0;
                if (sched_setaffinity(0, affinity.set_size, single) == 0)
                    cpu->pin = success();
                else
                    cpu->pin = failure(errno);
                CPU_FREE(single);
            }
            if (strcmp(cpu->pin.status, "success") == 0) {
                cpu->verify_before = verify_single_cpu(
                    cpu->cpu, affinity.set_size, &cpu->observed_before);
                if (strcmp(cpu->verify_before.status, "success") == 0) {
                    for (size_t event = 0;
                         event < ARRAY_SIZE(event_definitions); ++event) {
                        collect_event(&cpu->events[event], cpu->cpu,
                                      affinity.set_size,
                                      (unsigned int)(cpu->cpu * 17 + event));
                    }
                }
                cpu->verify_after = verify_single_cpu(
                    cpu->cpu, affinity.set_size, &cpu->observed_after);
            }
            cpu->affinity_correct =
                strcmp(cpu->verify_before.status, "success") == 0 &&
                strcmp(cpu->verify_after.status, "success") == 0;
            if (strcmp(cpu->events[0].status, "pass") != 0)
                cycles_pass_all = 0;
        }

        affinity.restore = not_attempted();
        errno = 0;
        if (sched_setaffinity(0, affinity.set_size, affinity.original) == 0)
            affinity.restore = success();
        else
            affinity.restore = failure(errno);
        if (strcmp(affinity.restore.status, "success") == 0) {
            cpu_set_t *restored = CPU_ALLOC(affinity.set_size * 8);
            if (restored == NULL) {
                affinity.verify_restored = failure(ENOMEM);
            } else {
                CPU_ZERO_S(affinity.set_size, restored);
                errno = 0;
                if (sched_getaffinity(0, affinity.set_size, restored) == 0) {
                    affinity.verify_restored = success();
                    affinity.restored_exactly =
                        CPU_EQUAL_S(affinity.set_size, affinity.original,
                                    restored);
                } else {
                    affinity.verify_restored = failure(errno);
                }
                CPU_FREE(restored);
            }
        }
    } else {
        cycles_pass_all = 0;
    }

    online_after = read_text_file(online_path);
    puts("=== PMU PROBE JSON START ===");
    fputs("{\"schema_version\":1,\"read_only\":true,", stdout);
    printf("\"guest_euid\":%lu,", (unsigned long)geteuid());
    fputs("\"perf_event_paranoid\":", stdout);
    print_text_result(&paranoid);
    fputs(",\"armv8_pmu_sysfs\":{\"source\":", stdout);
    print_text_result(&pmu_source);
    fputs(",\"type\":", stdout);
    print_text_result(&pmu_type);
    fputs(",\"cpumask\":", stdout);
    print_text_result(&pmu_cpumask);
    fputs(",\"nr_counters\":", stdout);
    print_text_result(&pmu_nr_counters);
    fputs("},\"affinity\":{\"online_before\":", stdout);
    print_text_result(&online_before);
    printf(",\"parse_errno\":%d,\"online_cpu_ids\":[", parse_errno);
    for (size_t index = 0; index < cpu_count; ++index)
        printf(index == 0 ? "%d" : ",%d", cpu_ids[index]);
    fputs("],\"get_original\":", stdout);
    print_operation(&affinity.get_original);
    fputs(",\"original_cpu_ids\":[", stdout);
    if (affinity.original != NULL &&
        strcmp(affinity.get_original.status, "success") == 0) {
        int first = 1;
        for (size_t cpu = 0; cpu < affinity.set_size * 8; ++cpu) {
            if (!CPU_ISSET_S(cpu, affinity.set_size, affinity.original))
                continue;
            printf(first ? "%zu" : ",%zu", cpu);
            first = 0;
        }
    }
    putchar(']');
    fputs(",\"restore\":", stdout);
    print_operation(&affinity.restore);
    fputs(",\"verify_restored\":", stdout);
    print_operation(&affinity.verify_restored);
    printf(",\"restored_exactly\":%s,\"online_after\":",
           affinity.restored_exactly ? "true" : "false");
    print_text_result(&online_after);
    fputs(",\"online_mask_stable\":", stdout);
    if (online_before.value != NULL && online_after.value != NULL)
        fputs(strcmp(online_before.value, online_after.value) == 0 ?
              "true}" : "false}", stdout);
    else
        fputs("null}", stdout);
    fputs(",\"cpus\":[", stdout);
    for (size_t index = 0; index < cpu_count; ++index) {
        if (index != 0)
            putchar(',');
        print_cpu(&cpus[index]);
    }
    printf("],\"required_cycles_pass_all\":%s}",
           cycles_pass_all ? "true" : "false");
    putchar('\n');
    puts("=== PMU PROBE JSON END ===");

    free_text_result(&online_before);
    free_text_result(&online_after);
    free_text_result(&paranoid);
    free_text_result(&pmu_source);
    free_text_result(&pmu_type);
    free_text_result(&pmu_cpumask);
    free_text_result(&pmu_nr_counters);
    free(cpu_ids);
    free(cpus);
    if (affinity.original != NULL)
        CPU_FREE(affinity.original);
    return cycles_pass_all && affinity.restored_exactly ? EXIT_SUCCESS : 2;
}

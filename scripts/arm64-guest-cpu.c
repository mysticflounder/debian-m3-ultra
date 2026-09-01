/* Read-only Linux/arm64 guest CPU evidence collector.
 *
 * The collector needs no privileges, executes no commands, and writes only
 * JSON to stdout. It temporarily changes only its own scheduling affinity
 * and signal disposition, restoring both before emitting the result.
 *
 * Guest build:
 *   gcc -O2 -Wall -Wextra -Werror -std=gnu11 \
 *       -o arm64-guest-cpu arm64-guest-cpu.c
 */

#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L

#include <asm/hwcap.h>
#include <dirent.h>
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <sched.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/auxv.h>
#include <unistd.h>

#if !defined(__linux__) || !defined(__aarch64__)
#error "arm64-guest-cpu.c must be built for Linux/aarch64"
#endif

#ifndef AT_HWCAP
#define AT_HWCAP 16
#endif

#ifndef AT_HWCAP2
#define AT_HWCAP2 26
#endif

#ifndef HWCAP_CPUID
#define HWCAP_CPUID (1UL << 11)
#endif

#define ARRAY_SIZE(array) (sizeof(array) / sizeof((array)[0]))

typedef void (*register_reader)(uint64_t *value);

struct register_probe {
    const char *name;
    register_reader read;
};

enum text_status {
    TEXT_AVAILABLE,
    TEXT_MISSING,
    TEXT_PERMISSION_DENIED,
    TEXT_ERROR,
};

struct text_result {
    enum text_status status;
    int error_number;
    char *value;
};

enum register_status {
    REGISTER_AVAILABLE,
    REGISTER_TRAPPED,
    REGISTER_NOT_PROBED,
    REGISTER_ERROR,
};

struct register_result {
    enum register_status status;
    int error_number;
    const char *reason;
    uint64_t value;
};

struct named_file_result {
    char *name;
    struct text_result contents;
};

struct identification_result {
    enum text_status status;
    int error_number;
    int listing_error;
    struct named_file_result *files;
    size_t file_count;
};

struct operation_result {
    int attempted;
    int succeeded;
    int error_number;
};

struct cpu_result {
    int requested_cpu;
    struct operation_result pin;
    struct operation_result observe;
    int observed_cpu;
    struct register_result registers[20];
    struct identification_result identification;
};

struct affinity_result {
    struct operation_result enumeration;
    struct operation_result restore;
    cpu_set_t *original;
    size_t set_size;
    int bit_count;
    int *cpu_ids;
    size_t cpu_count;
};

struct auxv_result {
    int available;
    int error_number;
    unsigned long value;
};

static sigjmp_buf sigill_jmp;
static volatile sig_atomic_t probe_active;

static void handle_sigill(int signo)
{
    if (probe_active) {
        probe_active = 0;
        siglongjmp(sigill_jmp, 1);
    }
    _exit(128 + signo);
}

/* Architectural encodings avoid depending on aliases for newer registers. */
#define DEFINE_REGISTER_READER(function_name, encoding)                 \
    static void function_name(uint64_t *value)                          \
    {                                                                   \
        uint64_t result;                                                \
        __asm__ volatile("mrs %0, " encoding : "=r"(result));           \
        *value = result;                                                \
    }

DEFINE_REGISTER_READER(read_midr_el1,        "S3_0_C0_C0_0")
DEFINE_REGISTER_READER(read_mpidr_el1,       "S3_0_C0_C0_5")
DEFINE_REGISTER_READER(read_ctr_el0,         "S3_3_C0_C0_1")
DEFINE_REGISTER_READER(read_clidr_el1,       "S3_1_C0_C0_1")
DEFINE_REGISTER_READER(read_dczid_el0,       "S3_3_C0_C0_7")
DEFINE_REGISTER_READER(read_id_aa64pfr0,     "S3_0_C0_C4_0")
DEFINE_REGISTER_READER(read_id_aa64pfr1,     "S3_0_C0_C4_1")
DEFINE_REGISTER_READER(read_id_aa64pfr2,     "S3_0_C0_C4_2")
DEFINE_REGISTER_READER(read_id_aa64dfr0,     "S3_0_C0_C5_0")
DEFINE_REGISTER_READER(read_id_aa64dfr1,     "S3_0_C0_C5_1")
DEFINE_REGISTER_READER(read_id_aa64isar0,    "S3_0_C0_C6_0")
DEFINE_REGISTER_READER(read_id_aa64isar1,    "S3_0_C0_C6_1")
DEFINE_REGISTER_READER(read_id_aa64isar2,    "S3_0_C0_C6_2")
DEFINE_REGISTER_READER(read_id_aa64mmfr0,    "S3_0_C0_C7_0")
DEFINE_REGISTER_READER(read_id_aa64mmfr1,    "S3_0_C0_C7_1")
DEFINE_REGISTER_READER(read_id_aa64mmfr2,    "S3_0_C0_C7_2")
DEFINE_REGISTER_READER(read_id_aa64mmfr3,    "S3_0_C0_C7_3")
DEFINE_REGISTER_READER(read_id_aa64mmfr4,    "S3_0_C0_C7_4")
DEFINE_REGISTER_READER(read_id_aa64zfr0,     "S3_0_C0_C4_4")
DEFINE_REGISTER_READER(read_id_aa64smfr0,    "S3_0_C0_C4_5")

static const struct register_probe register_probes[] = {
    { "MIDR_EL1", read_midr_el1 },
    { "MPIDR_EL1", read_mpidr_el1 },
    { "CTR_EL0", read_ctr_el0 },
    { "CLIDR_EL1", read_clidr_el1 },
    { "DCZID_EL0", read_dczid_el0 },
    { "ID_AA64PFR0_EL1", read_id_aa64pfr0 },
    { "ID_AA64PFR1_EL1", read_id_aa64pfr1 },
    { "ID_AA64PFR2_EL1", read_id_aa64pfr2 },
    { "ID_AA64DFR0_EL1", read_id_aa64dfr0 },
    { "ID_AA64DFR1_EL1", read_id_aa64dfr1 },
    { "ID_AA64ISAR0_EL1", read_id_aa64isar0 },
    { "ID_AA64ISAR1_EL1", read_id_aa64isar1 },
    { "ID_AA64ISAR2_EL1", read_id_aa64isar2 },
    { "ID_AA64MMFR0_EL1", read_id_aa64mmfr0 },
    { "ID_AA64MMFR1_EL1", read_id_aa64mmfr1 },
    { "ID_AA64MMFR2_EL1", read_id_aa64mmfr2 },
    { "ID_AA64MMFR3_EL1", read_id_aa64mmfr3 },
    { "ID_AA64MMFR4_EL1", read_id_aa64mmfr4 },
    { "ID_AA64ZFR0_EL1", read_id_aa64zfr0 },
    { "ID_AA64SMFR0_EL1", read_id_aa64smfr0 },
};

_Static_assert(ARRAY_SIZE(register_probes) ==
               ARRAY_SIZE(((struct cpu_result *)0)->registers),
               "register result array must match register probe table");

static void *checked_realloc(void *pointer, size_t size)
{
    void *result = realloc(pointer, size == 0 ? 1 : size);

    if (result == NULL) {
        fputs("arm64-guest-cpu: out of memory\n", stderr);
        exit(EXIT_FAILURE);
    }
    return result;
}

static char *checked_strdup(const char *string)
{
    char *result = strdup(string);

    if (result == NULL) {
        fputs("arm64-guest-cpu: out of memory\n", stderr);
        exit(EXIT_FAILURE);
    }
    return result;
}

static void print_json_string(const char *string)
{
    const unsigned char *cursor = (const unsigned char *)string;

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
            if (*cursor < 0x20 || *cursor >= 0x7f)
                printf("\\u%04x", (unsigned int)*cursor);
            else
                putchar((int)*cursor);
            break;
        }
        ++cursor;
    }
    putchar('"');
}

static enum text_status status_for_errno(int error_number)
{
    if (error_number == ENOENT || error_number == ENOTDIR)
        return TEXT_MISSING;
    if (error_number == EACCES || error_number == EPERM)
        return TEXT_PERMISSION_DENIED;
    return TEXT_ERROR;
}

static struct text_result read_text_file(const char *path)
{
    struct text_result result = { TEXT_ERROR, 0, NULL };
    FILE *stream;
    char *buffer = NULL;
    size_t capacity = 0;
    size_t length = 0;

    errno = 0;
    stream = fopen(path, "rb");
    if (stream == NULL) {
        result.error_number = errno;
        result.status = status_for_errno(errno);
        return result;
    }
    for (;;) {
        size_t amount;

        if (capacity - length < 4097) {
            if (capacity > SIZE_MAX - 4096) {
                result.error_number = EOVERFLOW;
                break;
            }
            capacity += 4096;
            buffer = checked_realloc(buffer, capacity);
        }
        errno = 0;
        amount = fread(buffer + length, 1, capacity - length - 1, stream);
        length += amount;
        if (amount == 0) {
            if (ferror(stream))
                result.error_number = errno != 0 ? errno : EIO;
            else
                result.status = TEXT_AVAILABLE;
            break;
        }
    }
    if (fclose(stream) != 0 && result.status == TEXT_AVAILABLE) {
        result.status = TEXT_ERROR;
        result.error_number = errno != 0 ? errno : EIO;
    }
    if (result.status == TEXT_AVAILABLE) {
        buffer[length] = '\0';
        result.value = buffer;
    } else {
        free(buffer);
    }
    return result;
}

static int compare_strings(const void *left, const void *right)
{
    const char *const *left_string = left;
    const char *const *right_string = right;

    return strcmp(*left_string, *right_string);
}

static void collect_identification(int cpu,
                                   struct identification_result *result)
{
    char directory_path[PATH_MAX];
    DIR *directory;
    char **names = NULL;
    size_t name_count = 0;
    size_t index;

    memset(result, 0, sizeof(*result));
    if (snprintf(directory_path, sizeof(directory_path),
                 "/sys/devices/system/cpu/cpu%d/regs/identification", cpu) >=
        (int)sizeof(directory_path)) {
        result->status = TEXT_ERROR;
        result->error_number = ENAMETOOLONG;
        return;
    }
    errno = 0;
    directory = opendir(directory_path);
    if (directory == NULL) {
        result->status = status_for_errno(errno);
        result->error_number = errno;
        return;
    }
    result->status = TEXT_AVAILABLE;
    for (;;) {
        struct dirent *entry;

        errno = 0;
        entry = readdir(directory);
        if (entry == NULL) {
            if (errno != 0)
                result->listing_error = errno;
            break;
        }
        if (strcmp(entry->d_name, ".") == 0 ||
            strcmp(entry->d_name, "..") == 0)
            continue;
        names = checked_realloc(names, (name_count + 1) * sizeof(*names));
        names[name_count++] = checked_strdup(entry->d_name);
    }
    if (closedir(directory) != 0 && result->listing_error == 0)
        result->listing_error = errno != 0 ? errno : EIO;

    if (name_count > 1)
        qsort(names, name_count, sizeof(*names), compare_strings);
    result->files = checked_realloc(NULL, name_count * sizeof(*result->files));
    result->file_count = name_count;
    for (index = 0; index < name_count; ++index) {
        size_t path_length = strlen(directory_path) + strlen(names[index]) + 2;
        char *path = checked_realloc(NULL, path_length);

        (void)snprintf(path, path_length, "%s/%s", directory_path,
                       names[index]);
        result->files[index].name = names[index];
        result->files[index].contents = read_text_file(path);
        free(path);
    }
    free(names);
}

static int guarded_read(register_reader read, uint64_t *value)
{
    if (sigsetjmp(sigill_jmp, 1) != 0)
        return 0;
    probe_active = 1;
    read(value);
    probe_active = 0;
    return 1;
}

static void collect_registers(struct cpu_result *cpu, int handler_available,
                              int handler_error)
{
    size_t index;

    for (index = 0; index < ARRAY_SIZE(register_probes); ++index) {
        struct register_result *result = &cpu->registers[index];

        if (!cpu->pin.succeeded) {
            result->status = REGISTER_NOT_PROBED;
            result->error_number = cpu->pin.error_number;
            result->reason = "pin_failed";
        } else if (!cpu->observe.succeeded) {
            result->status = REGISTER_NOT_PROBED;
            result->error_number = cpu->observe.error_number;
            result->reason = "sched_getcpu_failed";
        } else if (cpu->observed_cpu != cpu->requested_cpu) {
            result->status = REGISTER_NOT_PROBED;
            result->reason = "pin_mismatch";
        } else if (!handler_available) {
            result->status = REGISTER_ERROR;
            result->error_number = handler_error;
            result->reason = "sigill_handler_error";
        } else if (guarded_read(register_probes[index].read, &result->value)) {
            result->status = REGISTER_AVAILABLE;
        } else {
            result->status = REGISTER_TRAPPED;
            result->reason = "sigill";
        }
    }
}

static struct auxv_result collect_auxv(unsigned long type)
{
    struct auxv_result result;

    errno = 0;
    result.value = getauxval(type);
    result.error_number = errno;
    result.available = errno != ENOENT;
    return result;
}

static struct affinity_result collect_affinity(void)
{
    struct affinity_result result;
    long configured = sysconf(_SC_NPROCESSORS_CONF);
    int bit_count = configured > 0 && configured <= 1048576 ?
                    (int)configured : 128;

    memset(&result, 0, sizeof(result));
    result.enumeration.attempted = 1;
    while (bit_count <= 1048576) {
        cpu_set_t *set;
        size_t set_size = CPU_ALLOC_SIZE(bit_count);
        int saved_errno;

        set = CPU_ALLOC(bit_count);
        if (set == NULL) {
            result.enumeration.error_number = ENOMEM;
            return result;
        }
        CPU_ZERO_S(set_size, set);
        errno = 0;
        if (sched_getaffinity(0, set_size, set) == 0) {
            int cpu;

            result.enumeration.succeeded = 1;
            result.original = set;
            result.set_size = set_size;
            result.bit_count = bit_count;
            for (cpu = 0; cpu < bit_count; ++cpu) {
                if (CPU_ISSET_S(cpu, set_size, set))
                    ++result.cpu_count;
            }
            result.cpu_ids = checked_realloc(
                NULL, result.cpu_count * sizeof(*result.cpu_ids));
            result.cpu_count = 0;
            for (cpu = 0; cpu < bit_count; ++cpu) {
                if (CPU_ISSET_S(cpu, set_size, set))
                    result.cpu_ids[result.cpu_count++] = cpu;
            }
            return result;
        }
        saved_errno = errno;
        CPU_FREE(set);
        if (saved_errno != EINVAL || bit_count == 1048576) {
            result.enumeration.error_number = saved_errno;
            return result;
        }
        bit_count = bit_count > 1048576 / 2 ? 1048576 : bit_count * 2;
    }
    result.enumeration.error_number = EOVERFLOW;
    return result;
}

static void collect_cpu(struct cpu_result *result, int cpu,
                        const struct affinity_result *affinity,
                        int handler_available, int handler_error)
{
    cpu_set_t *single = CPU_ALLOC(affinity->bit_count);

    memset(result, 0, sizeof(*result));
    result->requested_cpu = cpu;
    result->observed_cpu = -1;
    result->pin.attempted = 1;
    if (single == NULL) {
        result->pin.error_number = ENOMEM;
    } else {
        CPU_ZERO_S(affinity->set_size, single);
        CPU_SET_S(cpu, affinity->set_size, single);
        errno = 0;
        if (sched_setaffinity(0, affinity->set_size, single) == 0)
            result->pin.succeeded = 1;
        else
            result->pin.error_number = errno;
        CPU_FREE(single);
    }
    result->observe.attempted = 1;
    errno = 0;
    result->observed_cpu = sched_getcpu();
    if (result->observed_cpu >= 0)
        result->observe.succeeded = 1;
    else
        result->observe.error_number = errno != 0 ? errno : EIO;

    collect_registers(result, handler_available, handler_error);
    collect_identification(cpu, &result->identification);
}

static const char *text_status_name(enum text_status status)
{
    switch (status) {
    case TEXT_AVAILABLE: return "available";
    case TEXT_MISSING: return "missing";
    case TEXT_PERMISSION_DENIED: return "permission_denied";
    case TEXT_ERROR: return "error";
    }
    return "error";
}

static void print_operation(const struct operation_result *result)
{
    const char *status = result->succeeded ? "available" :
                         result->attempted ? "error" : "not_attempted";

    printf("{\"status\": \"%s\", \"errno\": ", status);
    if (result->succeeded || !result->attempted)
        fputs("null}", stdout);
    else
        printf("%d}", result->error_number);
}

static void print_text_result(const struct text_result *result)
{
    fputs("{\"status\": ", stdout);
    print_json_string(text_status_name(result->status));
    fputs(", \"value\": ", stdout);
    if (result->status == TEXT_AVAILABLE)
        print_json_string(result->value);
    else
        fputs("null", stdout);
    fputs(", \"errno\": ", stdout);
    if (result->status == TEXT_AVAILABLE)
        fputs("null}", stdout);
    else
        printf("%d}", result->error_number);
}

static void print_auxv_result(const char *name,
                              const struct auxv_result *result, int comma)
{
    fputs("    ", stdout);
    print_json_string(name);
    fputs(": {\"status\": ", stdout);
    print_json_string(result->available ? "available" : "missing");
    fputs(", \"value\": ", stdout);
    if (result->available)
        printf("\"0x%016" PRIx64 "\"", (uint64_t)result->value);
    else
        fputs("null", stdout);
    fputs(", \"errno\": ", stdout);
    if (result->available)
        fputs("null}", stdout);
    else
        printf("%d}", result->error_number);
    fputs(comma ? ",\n" : "\n", stdout);
}

static void print_register_result(size_t index,
                                  const struct register_result *result,
                                  int comma)
{
    const char *status;

    switch (result->status) {
    case REGISTER_AVAILABLE: status = "available"; break;
    case REGISTER_TRAPPED: status = "unavailable"; break;
    case REGISTER_NOT_PROBED: status = "not_probed"; break;
    case REGISTER_ERROR: status = "error"; break;
    default: status = "error"; break;
    }
    fputs("        ", stdout);
    print_json_string(register_probes[index].name);
    fputs(": {\"status\": ", stdout);
    print_json_string(status);
    fputs(", \"value\": ", stdout);
    if (result->status == REGISTER_AVAILABLE)
        printf("\"0x%016" PRIx64 "\"", result->value);
    else
        fputs("null", stdout);
    fputs(", \"errno\": ", stdout);
    if (result->error_number != 0)
        printf("%d", result->error_number);
    else
        fputs("null", stdout);
    fputs(", \"reason\": ", stdout);
    if (result->reason != NULL)
        print_json_string(result->reason);
    else
        fputs("null", stdout);
    putchar('}');
    fputs(comma ? ",\n" : "\n", stdout);
}

static void print_identification(const struct identification_result *result)
{
    size_t index;

    fputs("{\"status\": ", stdout);
    print_json_string(text_status_name(result->status));
    fputs(", \"errno\": ", stdout);
    if (result->status == TEXT_AVAILABLE)
        fputs("null", stdout);
    else
        printf("%d", result->error_number);
    fputs(", \"listing_errno\": ", stdout);
    if (result->listing_error == 0)
        fputs("null", stdout);
    else
        printf("%d", result->listing_error);
    fputs(", \"files\": {", stdout);
    if (result->file_count != 0)
        putchar('\n');
    for (index = 0; index < result->file_count; ++index) {
        fputs("        ", stdout);
        print_json_string(result->files[index].name);
        fputs(": ", stdout);
        print_text_result(&result->files[index].contents);
        fputs(index + 1 < result->file_count ? ",\n" : "\n", stdout);
    }
    if (result->file_count != 0)
        fputs("      ", stdout);
    fputs("}}", stdout);
}

static void print_cpu(const struct cpu_result *cpu, int comma)
{
    size_t index;
    const char *validation_status;

    if (!cpu->pin.succeeded)
        validation_status = "pin_failed";
    else if (!cpu->observe.succeeded)
        validation_status = "observation_error";
    else if (cpu->observed_cpu != cpu->requested_cpu)
        validation_status = "mismatch";
    else
        validation_status = "match";

    printf("    {\"requested_cpu\": %d, \"pin\": ", cpu->requested_cpu);
    print_operation(&cpu->pin);
    fputs(", \"observed_cpu\": {\"status\": ", stdout);
    print_json_string(cpu->observe.succeeded ? "available" : "error");
    fputs(", \"value\": ", stdout);
    if (cpu->observe.succeeded)
        printf("%d", cpu->observed_cpu);
    else
        fputs("null", stdout);
    fputs(", \"errno\": ", stdout);
    if (cpu->observe.succeeded)
        fputs("null}", stdout);
    else
        printf("%d}", cpu->observe.error_number);
    fputs(", \"pin_validation\": {\"status\": ", stdout);
    print_json_string(validation_status);
    fputs(", \"matches\": ", stdout);
    if (cpu->pin.succeeded && cpu->observe.succeeded)
        fputs(cpu->observed_cpu == cpu->requested_cpu ? "true}" : "false}",
              stdout);
    else
        fputs("null}", stdout);
    fputs(",\n      \"registers\": {\n", stdout);
    for (index = 0; index < ARRAY_SIZE(register_probes); ++index)
        print_register_result(index, &cpu->registers[index],
                              index + 1 < ARRAY_SIZE(register_probes));
    fputs("      },\n      \"sysfs_identification\": ", stdout);
    print_identification(&cpu->identification);
    fputs(comma ? "},\n" : "}\n", stdout);
}

static void free_text_result(struct text_result *result)
{
    free(result->value);
}

static void free_cpu_results(struct cpu_result *cpus, size_t cpu_count)
{
    size_t cpu_index;

    for (cpu_index = 0; cpu_index < cpu_count; ++cpu_index) {
        size_t file_index;

        for (file_index = 0;
             file_index < cpus[cpu_index].identification.file_count;
             ++file_index) {
            free(cpus[cpu_index].identification.files[file_index].name);
            free_text_result(
                &cpus[cpu_index].identification.files[file_index].contents);
        }
        free(cpus[cpu_index].identification.files);
    }
    free(cpus);
}

int main(void)
{
    static const char *const system_paths[] = {
        "/sys/devices/system/cpu/online",
        "/sys/devices/system/cpu/present",
        "/sys/devices/system/cpu/possible",
        "/proc/cpuinfo",
        "/proc/version",
        "/proc/cmdline",
        "/etc/os-release",
    };
    struct text_result system_files[ARRAY_SIZE(system_paths)];
    struct text_result online_mask_after;
    struct auxv_result hwcap = collect_auxv(AT_HWCAP);
    struct auxv_result hwcap2 = collect_auxv(AT_HWCAP2);
    struct sigaction action;
    struct sigaction previous_action;
    struct operation_result signal_install = { 1, 0, 0 };
    struct operation_result signal_restore = { 0, 0, 0 };
    struct affinity_result affinity;
    struct cpu_result *cpus = NULL;
    size_t index;
    int exit_status = EXIT_SUCCESS;

    memset(&action, 0, sizeof(action));
    action.sa_handler = handle_sigill;
    sigemptyset(&action.sa_mask);
    errno = 0;
    if (sigaction(SIGILL, &action, &previous_action) == 0)
        signal_install.succeeded = 1;
    else
        signal_install.error_number = errno;

    for (index = 0; index < ARRAY_SIZE(system_paths); ++index)
        system_files[index] = read_text_file(system_paths[index]);

    affinity = collect_affinity();
    if (affinity.enumeration.succeeded) {
        cpus = checked_realloc(NULL, affinity.cpu_count * sizeof(*cpus));
        for (index = 0; index < affinity.cpu_count; ++index)
            collect_cpu(&cpus[index], affinity.cpu_ids[index], &affinity,
                        signal_install.succeeded,
                        signal_install.error_number);

        affinity.restore.attempted = 1;
        errno = 0;
        if (sched_setaffinity(0, affinity.set_size, affinity.original) == 0)
            affinity.restore.succeeded = 1;
        else
            affinity.restore.error_number = errno;
    }
    online_mask_after = read_text_file("/sys/devices/system/cpu/online");

    if (signal_install.succeeded) {
        signal_restore.attempted = 1;
        errno = 0;
        if (sigaction(SIGILL, &previous_action, NULL) == 0)
            signal_restore.succeeded = 1;
        else
            signal_restore.error_number = errno;
    }

    fputs("{\n  \"schema_version\": 2,\n  \"read_only\": true,\n", stdout);
    fputs("  \"auxv\": {\n", stdout);
    print_auxv_result("AT_HWCAP", &hwcap, 1);
    print_auxv_result("AT_HWCAP2", &hwcap2, 1);
    fputs("    \"HWCAP_CPUID\": ", stdout);
    fputs(hwcap.available && (hwcap.value & HWCAP_CPUID) != 0 ?
          "true,\n" : "false,\n", stdout);
    fputs("    \"HWCAP_CPUID_status\": ", stdout);
    print_json_string(hwcap.available ? "available" : "missing");
    putchar('\n');
    fputs("  },\n  \"collector_state\": {\n    \"sigill_install\": ", stdout);
    print_operation(&signal_install);
    fputs(",\n    \"sigill_restore\": ", stdout);
    print_operation(&signal_restore);
    fputs("\n  },\n  \"affinity\": {\n    \"enumeration\": ", stdout);
    print_operation(&affinity.enumeration);
    fputs(",\n    \"cpus\": [", stdout);
    for (index = 0; index < affinity.cpu_count; ++index)
        printf(index == 0 ? "%d" : ", %d", affinity.cpu_ids[index]);
    fputs("],\n    \"restore\": ", stdout);
    print_operation(&affinity.restore);
    fputs(",\n    \"online_mask_after_collection\": ", stdout);
    print_text_result(&online_mask_after);
    fputs(",\n    \"online_mask_stability\": {\"status\": ", stdout);
    if (system_files[0].status == TEXT_AVAILABLE &&
        online_mask_after.status == TEXT_AVAILABLE) {
        print_json_string("available");
        fputs(", \"matches\": ", stdout);
        fputs(strcmp(system_files[0].value, online_mask_after.value) == 0 ?
              "true}" : "false}", stdout);
    } else {
        print_json_string("unavailable");
        fputs(", \"matches\": null}", stdout);
    }
    fputs("\n  },\n  \"system_files\": {\n", stdout);
    for (index = 0; index < ARRAY_SIZE(system_paths); ++index) {
        fputs("    ", stdout);
        print_json_string(system_paths[index]);
        fputs(": ", stdout);
        print_text_result(&system_files[index]);
        fputs(index + 1 < ARRAY_SIZE(system_paths) ? ",\n" : "\n", stdout);
    }
    fputs("  },\n  \"cpus\": [", stdout);
    if (affinity.cpu_count != 0)
        putchar('\n');
    for (index = 0; index < affinity.cpu_count; ++index)
        print_cpu(&cpus[index], index + 1 < affinity.cpu_count);
    fputs(affinity.cpu_count != 0 ? "  ]\n}\n" : "]\n}\n", stdout);

    if (!affinity.enumeration.succeeded || !affinity.restore.succeeded ||
        !signal_install.succeeded || !signal_restore.succeeded)
        exit_status = EXIT_FAILURE;
    for (index = 0; index < affinity.cpu_count; ++index) {
        if (!cpus[index].pin.succeeded || !cpus[index].observe.succeeded ||
            cpus[index].observed_cpu != cpus[index].requested_cpu)
            exit_status = EXIT_FAILURE;
    }
    if (ferror(stdout))
        exit_status = EXIT_FAILURE;

    for (index = 0; index < ARRAY_SIZE(system_paths); ++index)
        free_text_result(&system_files[index]);
    free_text_result(&online_mask_after);
    free_cpu_results(cpus, affinity.cpu_count);
    free(affinity.cpu_ids);
    if (affinity.original != NULL)
        CPU_FREE(affinity.original);
    return exit_status;
}

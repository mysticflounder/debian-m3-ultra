/* Read-only Linux/arm64 guest CPU feature probe.
 *
 * Guest build:
 *   cc -std=c11 -O2 -Wall -Wextra -Wpedantic \
 *      -o arm64-guest-cpu arm64-guest-cpu.c
 * Guest run (no root privileges required):
 *   ./arm64-guest-cpu
 *
 * This is intended to help validate QEMU/HVF "-cpu host" passthrough.  A
 * register which the guest kernel or virtual CPU does not expose is reported
 * as unavailable; a trapped MRS instruction never terminates the probe.
 */

#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <inttypes.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <asm/hwcap.h>
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

/* Linux arm64 UAPI: arch/arm64/include/uapi/asm/hwcap.h. */
#ifndef HWCAP_CPUID
#define HWCAP_CPUID (1UL << 11)
#endif

typedef void (*register_reader)(uint64_t *value);

struct register_probe {
    const char *name;
    register_reader read;
};

static sigjmp_buf sigill_jmp;
static volatile sig_atomic_t probe_active;

static void handle_sigill(int signo)
{
    if (probe_active) {
        probe_active = 0;
        siglongjmp(sigill_jmp, 1);
    }

    /* There should be no unguarded MRS while our temporary handler is set. */
    _exit(128 + signo);
}

/*
 * Generic architectural encodings keep the source buildable with assemblers
 * which do not yet know aliases for newer feature ID registers.
 */
#define DEFINE_REGISTER_READER(function_name, encoding)                 \
    static void function_name(uint64_t *value)                          \
    {                                                                   \
        uint64_t result;                                                \
        __asm__ volatile("mrs %0, " encoding : "=r"(result));           \
        *value = result;                                                \
    }

DEFINE_REGISTER_READER(read_midr_el1,       "S3_0_C0_C0_0")
DEFINE_REGISTER_READER(read_mpidr_el1,      "S3_0_C0_C0_5")
DEFINE_REGISTER_READER(read_ctr_el0,        "S3_3_C0_C0_1")
DEFINE_REGISTER_READER(read_clidr_el1,      "S3_1_C0_C0_1")
DEFINE_REGISTER_READER(read_dczid_el0,      "S3_3_C0_C0_7")
DEFINE_REGISTER_READER(read_id_aa64pfr0,    "S3_0_C0_C4_0")
DEFINE_REGISTER_READER(read_id_aa64pfr1,    "S3_0_C0_C4_1")
DEFINE_REGISTER_READER(read_id_aa64pfr2,    "S3_0_C0_C4_2")
DEFINE_REGISTER_READER(read_id_aa64dfr0,    "S3_0_C0_C5_0")
DEFINE_REGISTER_READER(read_id_aa64dfr1,    "S3_0_C0_C5_1")
DEFINE_REGISTER_READER(read_id_aa64isar0,   "S3_0_C0_C6_0")
DEFINE_REGISTER_READER(read_id_aa64isar1,   "S3_0_C0_C6_1")
DEFINE_REGISTER_READER(read_id_aa64isar2,   "S3_0_C0_C6_2")
DEFINE_REGISTER_READER(read_id_aa64mmfr0,   "S3_0_C0_C7_0")
DEFINE_REGISTER_READER(read_id_aa64mmfr1,   "S3_0_C0_C7_1")
DEFINE_REGISTER_READER(read_id_aa64mmfr2,   "S3_0_C0_C7_2")
DEFINE_REGISTER_READER(read_id_aa64mmfr3,   "S3_0_C0_C7_3")
DEFINE_REGISTER_READER(read_id_aa64mmfr4,   "S3_0_C0_C7_4")
DEFINE_REGISTER_READER(read_id_aa64zfr0,    "S3_0_C0_C4_4")
DEFINE_REGISTER_READER(read_id_aa64smfr0,   "S3_0_C0_C4_5")

static const struct register_probe registers[] = {
    { "MIDR_EL1",        read_midr_el1 },
    { "MPIDR_EL1",       read_mpidr_el1 },
    { "CTR_EL0",         read_ctr_el0 },
    { "CLIDR_EL1",       read_clidr_el1 },
    { "DCZID_EL0",       read_dczid_el0 },
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

static void print_json_string(const char *string)
{
    const unsigned char *cursor = (const unsigned char *)string;

    putchar('"');
    while (*cursor != '\0') {
        switch (*cursor) {
        case '"':
            fputs("\\\"", stdout);
            break;
        case '\\':
            fputs("\\\\", stdout);
            break;
        case '\b':
            fputs("\\b", stdout);
            break;
        case '\f':
            fputs("\\f", stdout);
            break;
        case '\n':
            fputs("\\n", stdout);
            break;
        case '\r':
            fputs("\\r", stdout);
            break;
        case '\t':
            fputs("\\t", stdout);
            break;
        default:
            if (*cursor < 0x20)
                printf("\\u%04x", (unsigned int)*cursor);
            else
                putchar((int)*cursor);
            break;
        }
        ++cursor;
    }
    putchar('"');
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

static void print_auxv_value(const char *name, unsigned long type, int comma)
{
    unsigned long value;
    int saved_errno;

    errno = 0;
    value = getauxval(type);
    saved_errno = errno;

    fputs("    ", stdout);
    print_json_string(name);
    fputs(": {\"status\": ", stdout);
    if (saved_errno == ENOENT) {
        fputs("\"unavailable\", \"value\": null}", stdout);
    } else {
        printf("\"available\", \"value\": \"0x%016" PRIx64 "\"}",
               (uint64_t)value);
    }
    fputs(comma ? ",\n" : "\n", stdout);
}

static void print_hwcap_cpuid(void)
{
    unsigned long hwcap;
    int present;

    errno = 0;
    hwcap = getauxval(AT_HWCAP);
    present = errno != ENOENT && (hwcap & HWCAP_CPUID) != 0;

    fputs("    \"HWCAP_CPUID\": ", stdout);
    fputs(present ? "true\n" : "false\n", stdout);
}

static void print_register(const struct register_probe *probe, int comma,
                           int handler_available)
{
    uint64_t value = 0;
    int available = handler_available && guarded_read(probe->read, &value);

    fputs("    ", stdout);
    print_json_string(probe->name);
    fputs(": {\"status\": ", stdout);
    if (available) {
        printf("\"available\", \"value\": \"0x%016" PRIx64 "\"}",
               value);
    } else {
        fputs("\"unavailable\", \"value\": null}", stdout);
    }
    fputs(comma ? ",\n" : "\n", stdout);
}

int main(void)
{
    struct sigaction action;
    struct sigaction previous_action;
    int handler_available;
    size_t index;

    action.sa_handler = handle_sigill;
    sigemptyset(&action.sa_mask);
    action.sa_flags = 0;
    handler_available = sigaction(SIGILL, &action, &previous_action) == 0;

    fputs("{\n  \"schema_version\": 1,\n  \"auxv\": {\n", stdout);
    print_auxv_value("AT_HWCAP", AT_HWCAP, 1);
    print_auxv_value("AT_HWCAP2", AT_HWCAP2, 1);
    print_hwcap_cpuid();
    fputs("  },\n  \"registers\": {\n", stdout);

    for (index = 0; index < sizeof(registers) / sizeof(registers[0]); ++index)
        print_register(&registers[index],
                       index + 1 < sizeof(registers) / sizeof(registers[0]),
                       handler_available);

    fputs("  }\n}\n", stdout);

    if (handler_available && sigaction(SIGILL, &previous_action, NULL) != 0)
        return EXIT_FAILURE;
    if (ferror(stdout))
        return EXIT_FAILURE;
    return EXIT_SUCCESS;
}

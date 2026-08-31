/*
 * Read the arm64 host CPU view exported by Hypervisor.framework.
 *
 * This creates only a vCPU configuration object.  It does not
 * create a VM or vCPU, and it does not change host or hypervisor state.
 *
 * Build and use on Apple Silicon macOS:
 *
 *   clang -std=c11 -Wall -Wextra -Wpedantic -O2 \
 *       scripts/hvf-host-cpu.c -framework Hypervisor \
 *       -o scripts/hvf-host-cpu
 *   ./scripts/hvf-host-cpu | jq .
 */

#include <Availability.h>
#include <Hypervisor/Hypervisor.h>

#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

#ifndef __arm64__
#error "hvf-host-cpu must be built for Apple Silicon (arm64)"
#endif

#if defined(__MAC_OS_X_VERSION_MAX_ALLOWED) &&                         \
    __MAC_OS_X_VERSION_MAX_ALLOWED >= 150200
#define HAVE_HV_15_2_FEATURE_REGS 1
#else
#define HAVE_HV_15_2_FEATURE_REGS 0
#endif

struct feature_reg_desc {
    const char *name;
    hv_feature_reg_t reg;
};

struct cache_type_desc {
    const char *name;
    hv_cache_type_t type;
};

/* Keep this order stable: it is part of the output schema. */
static const struct feature_reg_desc feature_regs[] = {
    { "ID_AA64PFR0_EL1", HV_FEATURE_REG_ID_AA64PFR0_EL1 },
    { "ID_AA64PFR1_EL1", HV_FEATURE_REG_ID_AA64PFR1_EL1 },
    { "ID_AA64DFR0_EL1", HV_FEATURE_REG_ID_AA64DFR0_EL1 },
    { "ID_AA64DFR1_EL1", HV_FEATURE_REG_ID_AA64DFR1_EL1 },
    { "ID_AA64ISAR0_EL1", HV_FEATURE_REG_ID_AA64ISAR0_EL1 },
    { "ID_AA64ISAR1_EL1", HV_FEATURE_REG_ID_AA64ISAR1_EL1 },
    { "ID_AA64MMFR0_EL1", HV_FEATURE_REG_ID_AA64MMFR0_EL1 },
    { "ID_AA64MMFR1_EL1", HV_FEATURE_REG_ID_AA64MMFR1_EL1 },
    { "ID_AA64MMFR2_EL1", HV_FEATURE_REG_ID_AA64MMFR2_EL1 },
    { "CTR_EL0", HV_FEATURE_REG_CTR_EL0 },
    { "CLIDR_EL1", HV_FEATURE_REG_CLIDR_EL1 },
    { "DCZID_EL0", HV_FEATURE_REG_DCZID_EL0 },
};

static const struct cache_type_desc cache_types[] = {
    { "data_or_unified", HV_CACHE_TYPE_DATA },
    { "instruction", HV_CACHE_TYPE_INSTRUCTION },
};

static const char *
hv_error_name(hv_return_t result)
{
    switch (result) {
    case HV_SUCCESS:
        return "HV_SUCCESS";
    case HV_ERROR:
        return "HV_ERROR";
    case HV_BUSY:
        return "HV_BUSY";
    case HV_BAD_ARGUMENT:
        return "HV_BAD_ARGUMENT";
    case HV_ILLEGAL_GUEST_STATE:
        return "HV_ILLEGAL_GUEST_STATE";
    case HV_NO_RESOURCES:
        return "HV_NO_RESOURCES";
    case HV_NO_DEVICE:
        return "HV_NO_DEVICE";
    case HV_DENIED:
        return "HV_DENIED";
    case HV_EXISTS:
        return "HV_EXISTS";
    case HV_UNSUPPORTED:
        return "HV_UNSUPPORTED";
    default:
        return "HV_UNKNOWN_ERROR";
    }
}

static void
print_hv_error(hv_return_t result)
{
    printf("\"error\":{\"name\":\"%s\",\"code\":\"0x%08" PRIx32
           "\"}", hv_error_name(result), (uint32_t)result);
}

static const char *
hv_query_status(hv_return_t result)
{
    return result == HV_UNSUPPORTED ? "unavailable" : "error";
}

static bool
print_feature_register(hv_vcpu_config_t config,
                       const struct feature_reg_desc *desc)
{
    uint64_t value;
    hv_return_t result =
        hv_vcpu_config_get_feature_reg(config, desc->reg, &value);

    printf("    {\"name\":\"%s\",", desc->name);
    if (result == HV_SUCCESS) {
        printf("\"status\":\"ok\",\"value\":\"0x%016" PRIx64 "\"}",
               value);
        return true;
    }

    printf("\"status\":\"%s\",", hv_query_status(result));
    print_hv_error(result);
    putchar('}');
    return false;
}

#if HAVE_HV_15_2_FEATURE_REGS
static bool print_macos_15_2_feature_registers(hv_vcpu_config_t config)
    API_AVAILABLE(macos(15.2));

static bool
print_macos_15_2_feature_registers(hv_vcpu_config_t config)
{
    static const struct feature_reg_desc feature_regs_15_2[] = {
        { "ID_AA64SMFR0_EL1", HV_FEATURE_REG_ID_AA64SMFR0_EL1 },
        { "ID_AA64ZFR0_EL1", HV_FEATURE_REG_ID_AA64ZFR0_EL1 },
    };
    bool all_ok = true;

    for (size_t i = 0;
         i < sizeof(feature_regs_15_2) / sizeof(feature_regs_15_2[0]); i++) {
        all_ok = print_feature_register(config, &feature_regs_15_2[i]) && all_ok;
        puts(i + 1 ==
                     sizeof(feature_regs_15_2) / sizeof(feature_regs_15_2[0])
                 ? ""
                 : ",");
    }
    return all_ok;
}

static void
print_macos_15_2_unavailable(void)
{
    puts("    {\"name\":\"ID_AA64SMFR0_EL1\","
         "\"status\":\"unavailable\","
         "\"error\":{\"name\":\"MACOS_VERSION_TOO_OLD\","
         "\"requires\":\"macOS 15.2\"}},");
    puts("    {\"name\":\"ID_AA64ZFR0_EL1\","
         "\"status\":\"unavailable\","
         "\"error\":{\"name\":\"MACOS_VERSION_TOO_OLD\","
         "\"requires\":\"macOS 15.2\"}}");
}
#endif

static bool
print_feature_registers(hv_vcpu_config_t config)
{
    bool all_ok = true;

    puts("  \"feature_registers\":[");
    for (size_t i = 0; i < sizeof(feature_regs) / sizeof(feature_regs[0]);
         i++) {
        const struct feature_reg_desc *desc = &feature_regs[i];

        all_ok = print_feature_register(config, desc) && all_ok;
        /* A current (15.2+) SDK contributes two more items below. */
        puts(i + 1 == sizeof(feature_regs) / sizeof(feature_regs[0]) &&
                     !HAVE_HV_15_2_FEATURE_REGS
                 ? ""
                 : ",");
    }
#if HAVE_HV_15_2_FEATURE_REGS
    if (__builtin_available(macOS 15.2, *)) {
        all_ok = print_macos_15_2_feature_registers(config) && all_ok;
    } else {
        print_macos_15_2_unavailable();
        all_ok = false;
    }
#endif
    puts("  ],");
    return all_ok;
}

static bool
print_cache_registers(hv_vcpu_config_t config)
{
    bool all_ok = true;

    puts("  \"ccsidr_el1\":[");
    for (size_t i = 0; i < sizeof(cache_types) / sizeof(cache_types[0]); i++) {
        const struct cache_type_desc *desc = &cache_types[i];
        uint64_t values[8];
        hv_return_t result = hv_vcpu_config_get_ccsidr_el1_sys_reg_values(
            config, desc->type, values);

        printf("    {\"cache_type\":\"%s\",", desc->name);
        if (result == HV_SUCCESS) {
            printf("\"status\":\"ok\",\"values\":[");
            for (size_t level = 0; level < sizeof(values) / sizeof(values[0]);
                 level++) {
                printf("%s\"0x%016" PRIx64 "\"", level == 0 ? "" : ",",
                       values[level]);
            }
            printf("]}");
        } else {
            printf("\"status\":\"%s\",", hv_query_status(result));
            print_hv_error(result);
            putchar('}');
            all_ok = false;
        }
        puts(i + 1 == sizeof(cache_types) / sizeof(cache_types[0]) ? "" :
                                                                    ",");
    }
    puts("  ]");
    return all_ok;
}

int
main(void)
{
    hv_vcpu_config_t config = hv_vcpu_config_create();
    bool all_ok;

    if (config == NULL) {
        puts("{\"schema_version\":1,\"config\":{\"status\":\"error\","
             "\"error\":{\"name\":\"HV_VCPU_CONFIG_CREATE_FAILED\"}},"
             "\"feature_registers\":[],\"ccsidr_el1\":[]}");
        return 1;
    }

    puts("{");
    puts("  \"schema_version\":1,");
    puts("  \"config\":{\"status\":\"ok\"},");
    all_ok = print_feature_registers(config);
    all_ok = print_cache_registers(config) && all_ok;
    puts("}");

    os_release(config);
    return all_ok ? 0 : 1;
}

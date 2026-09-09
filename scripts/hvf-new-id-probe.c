/* SPDX-License-Identifier: MIT
 * Query newer architectural IDs using the public HVF vCPU-read entry point.
 * The four candidate encodings are NOT named/supported SDK enum promises.
 * Creates one temporary VM/vCPU; never maps memory, runs guest instructions,
 * sets registers, opens disks, or accesses physical devices.
 */
#include <Hypervisor/Hypervisor.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>

#ifndef __arm64__
#error "This diagnostic requires arm64 macOS"
#endif

#define SYSENC(op0, op1, crn, crm, op2) \
    (((op0) << 14) | ((op1) << 11) | ((crn) << 7) | ((crm) << 3) | (op2))
_Static_assert(SYSENC(3, 0, 0, 4, 0) == HV_SYS_REG_ID_AA64PFR0_EL1,
               "HVF system-register encoding differs from the expected layout");
_Static_assert(SYSENC(3, 0, 0, 7, 2) == HV_SYS_REG_ID_AA64MMFR2_EL1,
               "HVF system-register encoding differs from the expected layout");

struct descriptor {
    const char *name;
    hv_sys_reg_t reg;
    bool named;
    hv_feature_reg_t feature;
};

static const struct descriptor registers[] = {
    {"ID_AA64PFR0_EL1", HV_SYS_REG_ID_AA64PFR0_EL1, true, HV_FEATURE_REG_ID_AA64PFR0_EL1},
    {"ID_AA64PFR1_EL1", HV_SYS_REG_ID_AA64PFR1_EL1, true, HV_FEATURE_REG_ID_AA64PFR1_EL1},
    {"ID_AA64ISAR0_EL1", HV_SYS_REG_ID_AA64ISAR0_EL1, true, HV_FEATURE_REG_ID_AA64ISAR0_EL1},
    {"ID_AA64ISAR1_EL1", HV_SYS_REG_ID_AA64ISAR1_EL1, true, HV_FEATURE_REG_ID_AA64ISAR1_EL1},
    {"ID_AA64MMFR0_EL1", HV_SYS_REG_ID_AA64MMFR0_EL1, true, HV_FEATURE_REG_ID_AA64MMFR0_EL1},
    {"ID_AA64MMFR1_EL1", HV_SYS_REG_ID_AA64MMFR1_EL1, true, HV_FEATURE_REG_ID_AA64MMFR1_EL1},
    {"ID_AA64MMFR2_EL1", HV_SYS_REG_ID_AA64MMFR2_EL1, true, HV_FEATURE_REG_ID_AA64MMFR2_EL1},
    {"ID_AA64PFR2_EL1", (hv_sys_reg_t)SYSENC(3, 0, 0, 4, 2), false, 0},
    {"ID_AA64ISAR2_EL1", (hv_sys_reg_t)SYSENC(3, 0, 0, 6, 2), false, 0},
    {"ID_AA64MMFR3_EL1", (hv_sys_reg_t)SYSENC(3, 0, 0, 7, 3), false, 0},
    {"ID_AA64MMFR4_EL1", (hv_sys_reg_t)SYSENC(3, 0, 0, 7, 4), false, 0},
};

struct result {
    bool attempted;
    hv_return_t code;
    uint64_t value;
};

static void print_result(struct result r)
{
    if (!r.attempted) {
        printf("{\"status\":\"not_attempted\",\"code\":null,\"value\":null}");
        return;
    }
    const char *status = r.code == HV_SUCCESS ? "ok" :
        (r.code == HV_UNSUPPORTED || r.code == HV_BAD_ARGUMENT) ? "api_rejected" : "error";
    printf("{\"status\":\"%s\",\"code\":\"0x%08" PRIx32 "\",\"value\":",
           status, (uint32_t)r.code);
    if (r.code == HV_SUCCESS) {
        printf("\"0x%016" PRIx64 "\"}", r.value);
    } else {
        printf("null}");
    }
}

static void print_operation(bool attempted, hv_return_t code)
{
    if (!attempted) {
        printf("{\"status\":\"not_attempted\",\"code\":null}");
    } else {
        printf("{\"status\":\"%s\",\"code\":\"0x%08" PRIx32 "\"}",
               code == HV_SUCCESS ? "ok" : "error", (uint32_t)code);
    }
}

int main(void)
{
    if (geteuid() == 0 || getuid() == 0) {
        fputs("Refusing to run this diagnostic as host root.\n", stderr);
        return 2;
    }
    hv_vcpu_config_t config = hv_vcpu_config_create();
    if (!config) {
        fputs("Could not create vCPU configuration.\n", stderr);
        return 1;
    }
    enum { COUNT = sizeof(registers) / sizeof(registers[0]) };
    struct result config_results[COUNT] = {0};
    struct result vcpu_results[COUNT] = {0};
    bool controls_ok = true;
    for (size_t i = 0; i < COUNT; ++i) {
        if (registers[i].named) {
            config_results[i].attempted = true;
            config_results[i].code = hv_vcpu_config_get_feature_reg(
                config, registers[i].feature, &config_results[i].value);
            controls_ok &= config_results[i].code == HV_SUCCESS;
        }
    }
    hv_return_t vm_create = hv_vm_create(NULL);
    bool vm_created = vm_create == HV_SUCCESS;
    hv_return_t vcpu_create = HV_ERROR, vcpu_destroy = HV_ERROR, vm_destroy = HV_ERROR;
    bool vcpu_created = false;
    hv_vcpu_t vcpu = 0;
    hv_vcpu_exit_t *exit_info = NULL;
    if (vm_created) {
        vcpu_create = hv_vcpu_create(&vcpu, &exit_info, config);
        vcpu_created = vcpu_create == HV_SUCCESS;
        if (vcpu_created) {
            for (size_t i = 0; i < COUNT; ++i) {
                vcpu_results[i].attempted = true;
                vcpu_results[i].code = hv_vcpu_get_sys_reg(
                    vcpu, registers[i].reg, &vcpu_results[i].value);
                if (registers[i].named) {
                    controls_ok &= vcpu_results[i].code == HV_SUCCESS;
                }
            }
            vcpu_destroy = hv_vcpu_destroy(vcpu);
        }
        vm_destroy = hv_vm_destroy();
    }
    os_release(config);
    bool clean = vm_created && vcpu_created &&
        vcpu_destroy == HV_SUCCESS && vm_destroy == HV_SUCCESS;
    printf("{\"schema_version\":1,\"mode\":\"never_run_vcpu_read_api\","
           "\"guest_execution\":false,\"guest_memory_mapped\":false,"
           "\"register_writes\":false,\"disk_images_opened\":false,"
           "\"host_uid\":%" PRIu32 ",\"lifecycle\":{\"vm_create\":", (uint32_t)getuid());
    print_operation(true, vm_create);
    printf(",\"vcpu_create\":"); print_operation(vm_created, vcpu_create);
    printf(",\"vcpu_destroy\":"); print_operation(vcpu_created, vcpu_destroy);
    printf(",\"vm_destroy\":"); print_operation(vm_created, vm_destroy);
    printf("},\"controls_ok\":%s,\"cleanup_ok\":%s,\"registers\":[",
           controls_ok && vcpu_created ? "true" : "false", clean ? "true" : "false");
    for (size_t i = 0; i < COUNT; ++i) {
        printf("%s{\"name\":\"%s\",\"encoding\":\"0x%04x\",\"named_in_sdk\":%s,\"config\":",
               i ? "," : "", registers[i].name, (unsigned)registers[i].reg,
               registers[i].named ? "true" : "false");
        print_result(config_results[i]);
        printf(",\"vcpu\":"); print_result(vcpu_results[i]);
        printf("}");
    }
    printf("]}\n");
    return clean && controls_ok ? 0 : 1;
}

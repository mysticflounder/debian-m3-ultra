/* SPDX-License-Identifier: MIT
 * No-VM mocks for hvf-new-id-probe.c.  The test compiles the probe with
 * lifecycle/read calls renamed to these functions; Hypervisor configuration
 * reads remain the real, VM-free API calls.
 */
#include <Hypervisor/Hypervisor.h>
#include <stdlib.h>
#include <string.h>

static const char *mode(void)
{
    const char *value = getenv("HVF_FIXTURE_MODE");
    return value ? value : "control";
}

hv_return_t mock_hv_vm_create(hv_vm_config_t config)
{
    (void)config;
    return strcmp(mode(), "vm-create-failure") == 0 ? HV_ERROR : HV_SUCCESS;
}

hv_return_t mock_hv_vm_destroy(void)
{
    return HV_SUCCESS;
}

hv_return_t mock_hv_vcpu_create(hv_vcpu_t *vcpu, hv_vcpu_exit_t **exit,
                                hv_vcpu_config_t config)
{
    (void)config;
    if (strcmp(mode(), "vcpu-create-failure") == 0)
        return HV_ERROR;
    *vcpu = 1;
    *exit = NULL;
    return HV_SUCCESS;
}

hv_return_t mock_hv_vcpu_destroy(hv_vcpu_t vcpu)
{
    (void)vcpu;
    return strcmp(mode(), "destroy-failure") == 0 ? HV_ERROR : HV_SUCCESS;
}

hv_return_t mock_hv_vcpu_get_sys_reg(hv_vcpu_t vcpu, hv_sys_reg_t reg,
                                     uint64_t *value)
{
    (void)vcpu;
    if (strcmp(mode(), "control-failure") == 0 &&
        reg == HV_SYS_REG_ID_AA64PFR0_EL1)
        return HV_ERROR;

    /* The four unnamed IDs in hvf-new-id-probe.c. */
    switch ((unsigned)reg) {
    case 0xc022: /* ID_AA64PFR2_EL1 */
        if (strcmp(mode(), "target-zero") == 0) {
            *value = 0;
            return HV_SUCCESS;
        }
        return HV_BAD_ARGUMENT;
    case 0xc032: /* ID_AA64ISAR2_EL1 */
        return HV_UNSUPPORTED;
    case 0xc03b: /* ID_AA64MMFR3_EL1 */
        return HV_BAD_ARGUMENT;
    case 0xc03c: /* ID_AA64MMFR4_EL1 */
        return HV_UNSUPPORTED;
    default:
        *value = 0x123456789abcdef0ULL;
        return HV_SUCCESS;
    }
}

int hvf_new_id_probe_main(void);

int main(void)
{
    return hvf_new_id_probe_main();
}

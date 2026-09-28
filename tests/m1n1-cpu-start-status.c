/* Host-only caller/status tests appended to the shared preflight mock template. */

typedef int64_t s64;
#define P_SMP_START_SECONDARIES 0x500
#define P_HV_INIT 0xc00
#define S_OK 0
#define S_BADSTATE (-2)

typedef struct { u64 opcode; s64 status; u64 retval; } ProxyReply;

static int hv_result;
static unsigned hv_calls, payload_downstream, hv_downstream;
static unsigned pcie_shutdown_count, display_shutdown_count, usb_restore_count;

static void reset_status(void)
{
    hv_result = 0;
    hv_calls = payload_downstream = hv_downstream = 0;
    pcie_shutdown_count = display_shutdown_count = usb_restore_count = 0;
    status_path_failure = 0;
}

static void pcie_shutdown(void) { pcie_shutdown_count++; }
static int display_shutdown(int mode) { (void)mode; display_shutdown_count++; return 0; }
static void usb_hpm_restore_irqs(int mode) { (void)mode; usb_restore_count++; }
int hv_init(void) { hv_calls++; return hv_result; }

static int payload_gate(void)
{
    /* INSERT_PAYLOAD_GUARD */
    payload_downstream++;
    return 0;
}

static int hv_gate(void)
{
    /* The real HV prelude is intentionally before the propagated status check. */
    pcie_shutdown();
    display_shutdown(0);
    usb_hpm_restore_irqs(0);
    /* INSERT_HV_GUARD */
    hv_downstream++;
    return 0;
}

static void proxy_gate(u64 opcode, ProxyReply *reply)
{
    switch (opcode) {
    /* INSERT_PROXY_SMP_CASE */
    /* INSERT_PROXY_HV_CASE */
    default:
        break;
    }
}

static int expect_reject(bool legacy)
{
    reset_fixture();
    reset_status();
    if (legacy) {
        chip_id = T6031;
        mock_child_count = 0;
    } else {
        /* Duplicate cpu-id is rejected by the T6032 preflight before writes. */
        encode_u32(mock_id[1], 0);
        mark_sentinels();
    }
    return smp_start_secondaries();
}

int main(void)
{
#ifdef TEST_MMU_SMP_GUARD
    /* 0016 must reject both entry points before ADT/MMIO/allocation effects. */
    mock_mmu_smp_start_allowed = false;
    reset_fixture(); reset_status(); mark_sentinels();
    if (smp_start_secondaries() != -1 || !no_hardware_effects() ||
        !sentinels_intact() || adt_path_reads || adt_property_reads) return 40;
    reset_fixture(); reset_status(); mark_sentinels();
    if (smp_start_cpu(1, 0, 0, 0, 0, 0) || !no_hardware_effects() ||
        !sentinels_intact() || adt_path_reads || adt_property_reads) return 41;
    mock_mmu_smp_start_allowed = true;
    puts("SMP shared gate: both entry points reject before startup side effects");
#endif
    if (expect_reject(false) != -1 || !no_hardware_effects() || !sentinels_intact()) return 1;
    if (expect_reject(true) != 0) return 2;

    /* Every pre-release metadata lookup failure is fatal only for T6032. */
    for (unsigned failure = 1; failure <= 4; failure++) {
        reset_fixture();
        reset_status();
        status_path_failure = failure;
        mark_sentinels();
        if (smp_start_secondaries() != -1 || !no_hardware_effects() || !sentinels_intact())
            return 14 + (int)failure;
        reset_fixture();
        reset_status();
        status_path_failure = failure;
        chip_id = T6031;
        mock_child_count = 0;
        if (smp_start_secondaries() != 0) return 20 + (int)failure;
    }

    /* A valid inventory still reaches the existing closed T6032 dispatch. */
    reset_fixture();
    reset_status();
    if (smp_start_secondaries() != -1 || memalign_count || !no_hardware_effects()) return 3;

    reset_fixture();
    reset_status();
    if (payload_gate() != -1 || payload_downstream) return 4;
    reset_fixture();
    reset_status();
    chip_id = T6031;
    mock_child_count = 0;
    if (payload_gate() != 0 || payload_downstream != 1) return 5;

    reset_fixture();
    reset_status();
    if (hv_gate() != -1 || hv_downstream ||
        pcie_shutdown_count != 1 || display_shutdown_count != 1 || usb_restore_count != 1)
        return 6;
    reset_fixture();
    reset_status();
    chip_id = T6031;
    mock_child_count = 0;
    if (hv_gate() != 0 || hv_downstream != 1) return 7;

    reset_fixture();
    reset_status();
    encode_u32(mock_id[1], 0);
    ProxyReply reply = {.opcode = P_SMP_START_SECONDARIES, .status = S_OK, .retval = 0};
    proxy_gate(P_SMP_START_SECONDARIES, &reply);
    if (reply.status != S_BADSTATE) return 8;

    reset_fixture();
    reset_status();
    chip_id = T6031;
    mock_child_count = 0;
    reply = (ProxyReply){.opcode = P_SMP_START_SECONDARIES, .status = S_OK, .retval = 0x1111};
    proxy_gate(P_SMP_START_SECONDARIES, &reply);
    if (reply.status != S_OK || reply.retval != 0x1111) return 22;

    reset_status();
    reply = (ProxyReply){.opcode = P_HV_INIT, .status = S_OK, .retval = 0};
    hv_result = -1;
    proxy_gate(P_HV_INIT, &reply);
    if (reply.status != S_BADSTATE || hv_calls != 1) return 9;

    reset_status();
    reply = (ProxyReply){.opcode = P_HV_INIT, .status = S_OK, .retval = 0x2222};
    proxy_gate(P_HV_INIT, &reply);
    if (reply.status != S_OK || reply.retval != 0x2222 || hv_calls != 1) return 23;

    /* The bool leaf contract is checked directly at the pre-release bounds guard. */
    reset_fixture();
    reset_status();
    if (smp_start_cpu(MAX_CPUS, 0, 0, 0, 0, 0)) return 10;
    if (!no_hardware_effects()) return 11;
    reset_fixture();
    reset_status();
    if (smp_start_cpu(1, 0, 0, 0, 0, 0)) return 12;
    if (memalign_count != 1 || write32_count || write64_count || sysop_count || cache_count)
        return 13;

    reset_fixture();
    reset_status();
    spin_table[1].flag = 1;
    if (!smp_start_cpu(1, 0, 0, 0, 0, 0) || !no_hardware_effects() || memalign_count)
        return 30;
    reset_fixture();
    reset_status();
    mock_pfr0 = 0x100;
    if (smp_start_cpu(MAX_EL3_CPUS, 0, 0, 0, 0, 0) || !no_hardware_effects() || memalign_count)
        return 31;

    puts("T6032 SMP status source harness passed: legacy 0, T6032 -1, leaf bool, payload/HV gates, proxy S_BADSTATE");
    puts("Final T6032 all-secondary-flag gate is source-checked but unreachable while dispatch remains closed");
    return 0;
}

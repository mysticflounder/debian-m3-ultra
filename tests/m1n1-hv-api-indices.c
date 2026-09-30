#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;
/* INSERT_SOURCE_DEFINES */
#define CNTFRQ_EL0 1
#define AFSR1_EL2 2
#define BIT(n) (1ULL << (n))

static bool hv_started_cpus[MAX_CPUS];
static bool hv_should_exit[MAX_CPUS];
static u64 hv_cpus_in_guest;
static int hv_pinned_cpu;
static int hv_want_cpu;
static int hv_wdt_cpu;
static bool hv_wdt_active;
static bool hv_wdt_enabled;
static u64 hv_wdt_timeout;
static u64 hv_wdt_breadcrumbs[MAX_CPUS];
static int hv_secondary_info;
static int current_cpu;
static int print_calls;
static int smp_call_count;
static int smp_wait_count;
static int mmu_setup_count;
static int console_flush_count;
static int wdt_pet_count;
static int rendezvous_count;
static u64 last_smp_cpu;
static u64 last_smp_args[4];
static void *smp_call_funcs[3];
static u64 smp_call_cpus[3];
static u64 smp_call_args[3][4];
static u64 mock_wait_result = 0xfeedface;
static int mock_mrs_value = 100;

static void firmware_printf(const char *format, ...)
{
    (void)format;
    print_calls++;
}
#define printf firmware_printf

static int smp_id(void) { return current_cpu; }
static void iodev_console_flush(void) { console_flush_count++; }
static void mmu_secondary_setup(void) { mmu_setup_count++; }
static void hv_init_secondary(void) {}
static void hv_enter_secondary(void) {}
static void hv_wdt_main(void) {}
static void hv_rendezvous(void) { rendezvous_count++; }
static void hv_wdt_pet(void) { wdt_pet_count++; }
static u64 mrs(u64 reg) { (void)reg; return (u64)mock_mrs_value; }
static void msr(u64 reg, u64 value) { (void)reg; (void)value; }

static void smp_call4(int cpu, void *func, u64 arg0, u64 arg1, u64 arg2, u64 arg3)
{
    if (smp_call_count < 3) {
        smp_call_funcs[smp_call_count] = func;
        smp_call_cpus[smp_call_count] = (u64)cpu;
        smp_call_args[smp_call_count][0] = arg0;
        smp_call_args[smp_call_count][1] = arg1;
        smp_call_args[smp_call_count][2] = arg2;
        smp_call_args[smp_call_count][3] = arg3;
    }
    smp_call_count++;
    last_smp_cpu = (u64)cpu;
    last_smp_args[0] = arg0;
    last_smp_args[1] = arg1;
    last_smp_args[2] = arg2;
    last_smp_args[3] = arg3;
}
static u64 smp_wait(int cpu) { (void)cpu; smp_wait_count++; return mock_wait_result; }

/* Actual helper bodies extracted from the pinned source. */
/* INSERT_HELPERS */

typedef struct { u64 args[6]; } ProxyRequest;
typedef struct { int status; u64 retval; } ProxyReply;

/* INSERT_PROXY_OPS */

static void proxy_dispatch(u64 opcode, ProxyRequest *request, ProxyReply *reply)
{
    switch (opcode) {
        /* INSERT_PROXY_CASES */
        default:
            break;
    }
}

static void reset_fixture(void)
{
    memset(hv_started_cpus, 0, sizeof(hv_started_cpus));
    memset(hv_should_exit, 0, sizeof(hv_should_exit));
    memset(hv_wdt_breadcrumbs, 0, sizeof(hv_wdt_breadcrumbs));
    hv_cpus_in_guest = 0;
    hv_pinned_cpu = -1;
    hv_want_cpu = -1;
    hv_wdt_cpu = -1;
    hv_wdt_active = false;
    hv_wdt_enabled = false;
    hv_wdt_timeout = 0;
    current_cpu = 0;
    print_calls = 0;
    smp_call_count = 0;
    smp_wait_count = 0;
    mmu_setup_count = 0;
    console_flush_count = 0;
    wdt_pet_count = 0;
    rendezvous_count = 0;
    last_smp_cpu = 0;
    memset(last_smp_args, 0, sizeof(last_smp_args));
    memset(smp_call_funcs, 0, sizeof(smp_call_funcs));
    memset(smp_call_cpus, 0, sizeof(smp_call_cpus));
    memset(smp_call_args, 0, sizeof(smp_call_args));
    mock_wait_result = 0xfeedface;
    mock_mrs_value = 100;
}

struct fixture_state {
    bool started[MAX_CPUS];
    bool should_exit[MAX_CPUS];
    u64 cpus_in_guest;
    int pinned_cpu;
    int want_cpu;
    int wdt_cpu;
    bool wdt_active;
    bool wdt_enabled;
    u64 wdt_timeout;
    u64 wdt_breadcrumbs[MAX_CPUS];
    int print_calls;
    int smp_call_count;
    int smp_wait_count;
    int mmu_setup_count;
    int console_flush_count;
    int wdt_pet_count;
    int rendezvous_count;
    u64 last_smp_cpu;
    u64 last_smp_args[4];
    void *smp_call_funcs[3];
    u64 smp_call_cpus[3];
    u64 smp_call_args[3][4];
};

static void save_state(struct fixture_state *state)
{
    memset(state, 0, sizeof(*state));
    memcpy(state->started, hv_started_cpus, sizeof(state->started));
    memcpy(state->should_exit, hv_should_exit, sizeof(state->should_exit));
    state->cpus_in_guest = hv_cpus_in_guest;
    state->pinned_cpu = hv_pinned_cpu;
    state->want_cpu = hv_want_cpu;
    state->wdt_cpu = hv_wdt_cpu;
    state->wdt_active = hv_wdt_active;
    state->wdt_enabled = hv_wdt_enabled;
    state->wdt_timeout = hv_wdt_timeout;
    memcpy(state->wdt_breadcrumbs, hv_wdt_breadcrumbs, sizeof(state->wdt_breadcrumbs));
    state->print_calls = print_calls;
    state->smp_call_count = smp_call_count;
    state->smp_wait_count = smp_wait_count;
    state->mmu_setup_count = mmu_setup_count;
    state->console_flush_count = console_flush_count;
    state->wdt_pet_count = wdt_pet_count;
    state->rendezvous_count = rendezvous_count;
    state->last_smp_cpu = last_smp_cpu;
    memcpy(state->last_smp_args, last_smp_args, sizeof(state->last_smp_args));
    memcpy(state->smp_call_funcs, smp_call_funcs, sizeof(state->smp_call_funcs));
    memcpy(state->smp_call_cpus, smp_call_cpus, sizeof(state->smp_call_cpus));
    memcpy(state->smp_call_args, smp_call_args, sizeof(state->smp_call_args));
}

static bool same_state(const struct fixture_state *a, const struct fixture_state *b)
{
    return memcmp(a, b, sizeof(*a)) == 0;
}

static int invalid_ordinary(int cpu)
{
    struct fixture_state before, after;

    reset_fixture();
    save_state(&before);
    mmu_init_secondary(cpu);
    save_state(&after);
    if (!same_state(&before, &after)) return 1;

    reset_fixture();
    save_state(&before);
    hv_start_secondary(cpu, (void *)0x1111, last_smp_args);
    save_state(&after);
    if (!same_state(&before, &after)) return 2;

    reset_fixture();
    save_state(&before);
    hv_wdt_start(cpu);
    save_state(&after);
    if (!same_state(&before, &after)) return 3;

    reset_fixture();
    save_state(&before);
    if (hv_switch_cpu(cpu)) return 4;
    save_state(&after);
    after.print_calls = before.print_calls;
    if (!same_state(&before, &after) || print_calls != 1) return 4;
    return 0;
}

static int valid_ordinary(int cpu)
{
    u64 regs[4] = {UINT64_C(0x11), UINT64_C(0x22), UINT64_C(0x33), UINT64_C(0x44)};
    void *entry = (void *)0x1111;

    reset_fixture();
    mmu_init_secondary(cpu);
    if (smp_call_count != 1 || smp_wait_count != 1 || last_smp_cpu != (u64)cpu ||
        smp_call_funcs[0] != (void *)mmu_secondary_setup || smp_call_cpus[0] != (u64)cpu ||
        smp_call_args[0][0] || smp_call_args[0][1] || smp_call_args[0][2] ||
        smp_call_args[0][3])
        return 1;

    reset_fixture();
    hv_start_secondary(cpu, entry, regs);
    if (!hv_started_cpus[cpu] || !(hv_cpus_in_guest & BIT(cpu)) || smp_call_count != 3 ||
        smp_wait_count != 2 || console_flush_count != 4 ||
        smp_call_funcs[0] != (void *)mmu_secondary_setup ||
        smp_call_funcs[1] != (void *)hv_init_secondary ||
        smp_call_funcs[2] != (void *)hv_enter_secondary ||
        smp_call_cpus[0] != (u64)cpu || smp_call_cpus[1] != (u64)cpu ||
        smp_call_cpus[2] != (u64)cpu ||
        smp_call_args[0][0] || smp_call_args[0][1] || smp_call_args[0][2] ||
        smp_call_args[0][3] || smp_call_args[1][0] != (u64)&hv_secondary_info ||
        smp_call_args[1][1] || smp_call_args[1][2] || smp_call_args[1][3] ||
        smp_call_args[2][0] != (u64)entry || smp_call_args[2][1] != (u64)regs ||
        smp_call_args[2][2] || smp_call_args[2][3])
        return 2;

    reset_fixture();
    hv_wdt_start(cpu);
    if (!hv_wdt_active || !hv_wdt_enabled || hv_wdt_cpu != cpu || wdt_pet_count != 1 ||
        hv_wdt_timeout != (u64)mock_mrs_value * WDT_TIMEOUT || smp_call_count != 1 ||
        smp_call_funcs[0] != (void *)hv_wdt_main || smp_call_cpus[0] != (u64)cpu ||
        smp_call_args[0][0] || smp_call_args[0][1] || smp_call_args[0][2] ||
        smp_call_args[0][3])
        return 3;
    hv_wdt_start((cpu + 1) % MAX_CPUS);
    if (hv_wdt_cpu != cpu || smp_call_count != 1) return 4;
    reset_fixture();
    hv_started_cpus[cpu] = true;
    if (!hv_switch_cpu(cpu) || hv_want_cpu != cpu || rendezvous_count != 1) return 5;
    return 0;
}

static int pin_case(int cpu)
{
    reset_fixture();
    hv_pinned_cpu = 7;
    hv_pin_cpu(cpu);
    if (cpu == -1 || (cpu >= 0 && cpu < MAX_CPUS)) {
        if (hv_pinned_cpu != cpu) return 1;
    } else if (hv_pinned_cpu != 7) {
        return 2;
    }
    return 0;
}

static int exit_case(int requested, int running)
{
    reset_fixture();
    current_cpu = running;
    hv_exit_cpu(requested);
    int resolved = requested == -1 ? running : requested;
    if (resolved < 0 || resolved >= MAX_CPUS) {
        if (print_calls || memcmp(hv_should_exit, (bool[MAX_CPUS]){0}, sizeof(hv_should_exit)))
            return 1;
        return 0;
    }
    if (!hv_should_exit[resolved] || print_calls != 1) return 3;
    return 0;
}

static int proxy_case(u64 opcode, u64 raw, int running)
{
    ProxyRequest request = {0};
    ProxyReply reply = {.status = 0, .retval = 0};
    struct fixture_state before;
    void *entry = (void *)0x2222;
    request.args[0] = raw;
    request.args[1] = (u64)entry;
    request.args[2] = UINT64_C(0x51);
    request.args[3] = UINT64_C(0x52);
    request.args[4] = UINT64_C(0x53);
    request.args[5] = UINT64_C(0x54);
    reset_fixture();
    current_cpu = running;
    hv_pinned_cpu = 7;
    if (opcode == P_HV_SWITCH_CPU) {
        if (raw < MAX_CPUS) {
            hv_started_cpus[raw] = true;
        } else {
            hv_started_cpus[0] = true;
            hv_started_cpus[MAX_CPUS - 1] = true;
        }
    }
    save_state(&before);
    proxy_dispatch(opcode, &request, &reply);
    bool sentinel = opcode == P_HV_PIN_CPU || opcode == P_HV_EXIT_CPU;
    bool accepted = raw < MAX_CPUS || (sentinel && raw == UINT64_MAX);
    if (!accepted) {
        struct fixture_state after;
        save_state(&after);
        if (reply.status || reply.retval || !same_state(&before, &after))
            return 1;
        return 0;
    }

    if (opcode == P_MMU_INIT_SECONDARY) {
        if (smp_call_count != 1 || smp_wait_count != 1 || smp_call_cpus[0] != raw ||
            smp_call_funcs[0] != (void *)mmu_secondary_setup ||
            smp_call_args[0][0] || smp_call_args[0][1] || smp_call_args[0][2] ||
            smp_call_args[0][3]) return 2;
    }
    if (opcode == P_HV_WDT_START) {
        if (!hv_wdt_active || !hv_wdt_enabled || hv_wdt_cpu != (int)raw ||
            hv_wdt_timeout != (u64)mock_mrs_value * WDT_TIMEOUT || wdt_pet_count != 1 ||
            smp_call_funcs[0] != (void *)hv_wdt_main || smp_call_cpus[0] != raw ||
            smp_call_args[0][0] || smp_call_args[0][1] || smp_call_args[0][2] ||
            smp_call_args[0][3]) return 3;
    }
    if (opcode == P_HV_START_SECONDARY) {
        if (!hv_started_cpus[raw] || !(hv_cpus_in_guest & BIT(raw)) || smp_call_count != 3 ||
            smp_wait_count != 2 || console_flush_count != 4 ||
            smp_call_funcs[0] != (void *)mmu_secondary_setup ||
            smp_call_funcs[1] != (void *)hv_init_secondary ||
            smp_call_funcs[2] != (void *)hv_enter_secondary ||
            smp_call_cpus[0] != raw || smp_call_cpus[1] != raw || smp_call_cpus[2] != raw ||
            smp_call_args[0][0] || smp_call_args[0][1] || smp_call_args[0][2] ||
            smp_call_args[0][3] || smp_call_args[1][0] != (u64)&hv_secondary_info ||
            smp_call_args[1][1] || smp_call_args[1][2] || smp_call_args[1][3] ||
            smp_call_args[2][0] != (u64)entry ||
            smp_call_args[2][1] != (u64)&request.args[2] || smp_call_args[2][2] ||
            smp_call_args[2][3]) return 4;
    }
    if (opcode == P_HV_SWITCH_CPU &&
        (reply.retval != 1 || hv_want_cpu != (int)raw || rendezvous_count != 1)) return 5;
    if (opcode == P_HV_PIN_CPU &&
        hv_pinned_cpu != (raw == UINT64_MAX ? -1 : (int)raw)) return 6;
    if (opcode == P_HV_EXIT_CPU) {
        int resolved = raw == UINT64_MAX ? running : (int)raw;
        if (resolved < 0 || resolved >= MAX_CPUS || !hv_should_exit[resolved] || print_calls != 1)
            return 7;
    }
    return 0;
}

int main(void)
{
#ifdef NEGATIVE_HV_EXIT
    return exit_case(INT_MIN, 0);
#else
    const int invalid[] = {INT_MIN, -2, -1, MAX_CPUS, INT_MAX};
    for (unsigned i = 0; i < sizeof(invalid) / sizeof(invalid[0]); i++) {
        if (invalid_ordinary(invalid[i])) return 10 + (int)i;
        if (invalid[i] != -1 && pin_case(invalid[i])) return 20 + (int)i;
        if (invalid[i] != -1 && exit_case(invalid[i], 0)) return 30 + (int)i;
    }
    if (valid_ordinary(0) || valid_ordinary(31)) return 40;
    if (pin_case(-1) || pin_case(0) || pin_case(31)) return 41;
    if (exit_case(-1, 0) || exit_case(-1, 31) || exit_case(-1, -1) ||
        exit_case(0, 0) || exit_case(31, 0) || exit_case(0, -1) ||
        exit_case(31, MAX_CPUS) || exit_case(-1, -2) || exit_case(-1, MAX_CPUS)) return 42;

    const u64 ordinary[] = {P_MMU_INIT_SECONDARY, P_HV_WDT_START,
                            P_HV_START_SECONDARY, P_HV_SWITCH_CPU};
    const u64 sentinels[] = {P_HV_PIN_CPU, P_HV_EXIT_CPU};
    const u64 invalid_raw[] = {32, UINT64_C(0x80000000), UINT64_C(0x100000000),
                               UINT64_C(0x10000001f), UINT64_C(0xffffffff), UINT64_MAX};
    for (unsigned i = 0; i < sizeof(ordinary) / sizeof(ordinary[0]); i++) {
        if (proxy_case(ordinary[i], 0, 0) || proxy_case(ordinary[i], 31, 31)) return 50 + (int)i;
        for (unsigned j = 0; j < sizeof(invalid_raw) / sizeof(invalid_raw[0]); j++)
            if (proxy_case(ordinary[i], invalid_raw[j], 0)) return 60 + (int)i;
    }
    for (unsigned i = 0; i < sizeof(sentinels) / sizeof(sentinels[0]); i++) {
        if (proxy_case(sentinels[i], 0, 0) || proxy_case(sentinels[i], 31, 31) ||
            proxy_case(sentinels[i], UINT64_MAX, 31)) return 70 + (int)i;
        for (unsigned j = 0; j < sizeof(invalid_raw) / sizeof(invalid_raw[0]) - 1; j++)
            if (proxy_case(sentinels[i], invalid_raw[j], 0)) return 80 + (int)i;
    }
    puts("MMU/HV API index and proxy sentinel regression passed");
    return 0;
#endif
}

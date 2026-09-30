#include <limits.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;

#define MAX_CPUS 32
#define MAX_EL3_CPUS 4
#define SECONDARY_STACK_SIZE 0x10000
#define DUMMY_STACK_SIZE 0x1000
#define PMGR_DIE_OFFSET 0x2000000000ULL
#define AIC_IPI_SEND 1
#define AIC_IPI_SEND_CPU(cpu) (cpu)
#define SYS_IMP_APL_IPI_RR_GLOBAL_EL1 2
#define RVBAR_ADDR 0x0000fffffffff000ULL

struct spin_table {
    u64 mpidr;
    u64 flag;
    u64 target;
    u64 args[4];
    u64 retval;
};

static struct spin_table spin_table[MAX_CPUS];
static u8 *secondary_stacks[MAX_CPUS];
static u8 *secondary_stacks_el3[MAX_EL3_CPUS];
static bool wfe_mode;
static int target_cpu;
static void *_reset_stack;
static void *_reset_stack_el1;
static u8 dummy_stack[0x1000];
static u8 dummy_stack_el1[0x1000];
static int boot_cpu_idx = -1;
static u8 _vectors_start[1];

struct cpu_features_mock {
    bool fast_ipi;
    bool apple_sysregs_unlocked;
};
static struct cpu_features_mock cpu_features_value;
static struct cpu_features_mock *cpu_features = &cpu_features_value;

static int mmu_gate_calls;
static int write_calls;
static int ipi_calls;
static int free_calls;
static u64 mock_target_retval = UINT64_C(0xfeedface);

static void firmware_printf(const char *format, ...)
{
    (void)format;
}
#define printf firmware_printf

static bool mmu_smp_start_allowed(void)
{
    mmu_gate_calls++;
    return true;
}

static bool has_el3(void) { return false; }

static bool smp_cpu_start_masks(int die, int cluster, int core, u32 *system_mask,
                                u32 *cluster_mask)
{
    (void)die; (void)cluster; (void)core;
    *system_mask = 1;
    *cluster_mask = 1;
    return true;
}

static u64 read64(u64 address) { (void)address; return (u64)_vectors_start; }
static void write64(u64 address, u64 value) { (void)address; (void)value; write_calls++; }
static void write32(u64 address, u32 value) { (void)address; (void)value; write_calls++; }
static void sysop(const char *operation) { (void)operation; }
static void udelay(u64 usec) { (void)usec; }
static void aic_write(u64 address, u32 value)
{
    ipi_calls++;
    if (address == AIC_IPI_SEND && value < MAX_CPUS) {
        spin_table[value].flag++;
        spin_table[value].target = 0;
        spin_table[value].retval = mock_target_retval;
    }
}
static void msr(u64 reg, u64 value) { (void)reg; (void)value; }
static u64 mrs(u64 reg) { (void)reg; return 0; }
static void deep_wfi(void) {}
static void aic_ack(void) {}
static void panic(const char *format, ...) { (void)format; abort(); }
static void *mock_memalign(size_t alignment, size_t size)
{
    (void)alignment; (void)size; return NULL;
}
static void mock_free(void *ptr) { (void)ptr; free_calls++; }
#define memalign mock_memalign
#define free mock_free

static void cpu_sleep(u64 value) { (void)value; }
void smp_call4(int cpu, void *func, u64 arg0, u64 arg1, u64 arg2, u64 arg3);
#define smp_call1(cpu, function, arg) smp_call4((cpu), (function), (arg), 0, 0, 0)

/* Actual functions extracted from the pinned source. */
/* INSERT_SMP_FUNCTIONS */

typedef struct {
    u64 args[6];
} ProxyRequest;
typedef struct {
    int status;
    u64 retval;
} ProxyReply;

enum {
    P_SMP_CALL = 0x501,
    P_SMP_CALL_SYNC,
    P_SMP_WAIT,
    P_SMP_SET_WFE_MODE,
    P_SMP_IS_ALIVE,
    P_SMP_STOP_SECONDARIES,
    P_SMP_CALL_EL1,
    P_SMP_CALL_EL1_SYNC,
    P_SMP_CALL_EL0,
    P_SMP_CALL_EL0_SYNC,
};

static void *el1_call(void) { return NULL; }
static void *el0_call(void) { return NULL; }

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
    memset(spin_table, 0, sizeof(spin_table));
    memset(secondary_stacks, 0, sizeof(secondary_stacks));
    memset(secondary_stacks_el3, 0, sizeof(secondary_stacks_el3));
    boot_cpu_idx = -1;
    target_cpu = -1;
    wfe_mode = false;
    mmu_gate_calls = 0;
    write_calls = 0;
    ipi_calls = 0;
    free_calls = 0;
    mock_target_retval = UINT64_C(0xfeedface);
    cpu_features_value.fast_ipi = false;
    cpu_features_value.apple_sysregs_unlocked = false;
}

static int invalid_api_case(int cpu)
{
    reset_fixture();
    smp_send_ipi(cpu);
    smp_call4(cpu, NULL, 1, 2, 3, 4);
    if (smp_wait(cpu) != 0 || smp_is_alive(cpu) || smp_get_mpidr(cpu) != 0 ||
        smp_get_release_addr(cpu) != 0)
        return 1;
    if (smp_start_cpu(cpu, 0, 0, 0, 0, 0) || mmu_gate_calls != 0)
        return 2;
    smp_stop_cpu(cpu, 0, 0, 0, 0, 0, false);
    return (write_calls || ipi_calls || free_calls) ? 3 : 0;
}

static int valid_api_case(int cpu)
{
    reset_fixture();
    boot_cpu_idx = cpu;
    spin_table[cpu].flag = 1;
    spin_table[cpu].mpidr = 0x100 + (u64)cpu;
    smp_send_ipi(cpu);
    boot_cpu_idx = -1;
    smp_call4(cpu, (void *)0x1234, 11, 22, 33, 44);
    if (!smp_is_alive(cpu) || smp_get_mpidr(cpu) != 0x100 + (u64)cpu ||
        spin_table[cpu].args[0] != 11 || spin_table[cpu].args[1] != 22 ||
        spin_table[cpu].args[2] != 33 || spin_table[cpu].args[3] != 44 ||
        smp_wait(cpu) != mock_target_retval || ipi_calls != 2)
        return 1;
    boot_cpu_idx = cpu;
    if (smp_call4(cpu, NULL, 0, 0, 0, 0), ipi_calls != 2)
        return 2;
    u64 release = smp_get_release_addr(cpu);
    if (release != (u64)&spin_table[cpu].target || spin_table[cpu].args[0] ||
        spin_table[cpu].args[1] || spin_table[cpu].args[2] || spin_table[cpu].args[3] ||
        !smp_start_cpu(cpu, 0, 0, 0, 0, 0) || mmu_gate_calls != 1)
        return 3;
    if (ipi_calls != 2)
        return 1;
    return 0;
}

static int proxy_case(u64 opcode, u64 raw, bool alive)
{
    ProxyRequest request = {0};
    ProxyReply reply = {.status = 0, .retval = 0};
    request.args[0] = raw;
    reset_fixture();
    if (raw < MAX_CPUS) {
        int cpu = (int)raw;
        boot_cpu_idx = -1;
        spin_table[cpu].flag = alive;
    } else if (raw >= UINT64_C(0x100000000) &&
               (raw & UINT64_C(0xffffffff)) < MAX_CPUS) {
        unsigned wrapped = (unsigned)(raw & UINT64_C(0xffffffff));
        spin_table[wrapped].flag = 1;
        spin_table[wrapped].mpidr = 0xabc000 + wrapped;
        spin_table[wrapped].retval = UINT64_C(0xabc123);
    }
    struct spin_table before[MAX_CPUS];
    memcpy(before, spin_table, sizeof(before));
    proxy_dispatch(opcode, &request, &reply);
    if (raw >= MAX_CPUS) {
        if (reply.status != 0 || reply.retval != 0 || write_calls || ipi_calls ||
            memcmp(before, spin_table, sizeof(before)) != 0)
            return 1;
        return 0;
    }
    if (opcode == P_SMP_IS_ALIVE && reply.retval != alive)
        return 2;
    if ((opcode == P_SMP_CALL_SYNC || opcode == P_SMP_CALL_EL1_SYNC ||
         opcode == P_SMP_CALL_EL0_SYNC) && reply.retval != mock_target_retval)
        return 3;
    return 0;
}

int main(void)
{
    const int invalid[] = {INT_MIN, -1, MAX_CPUS, INT_MAX};
    for (unsigned i = 0; i < sizeof(invalid) / sizeof(invalid[0]); i++)
        if (invalid_api_case(invalid[i])) return 10 + (int)i;
    if (valid_api_case(0) || valid_api_case(MAX_CPUS - 1)) return 20;

    const u64 opcodes[] = {
        P_SMP_CALL, P_SMP_CALL_SYNC, P_SMP_WAIT, P_SMP_IS_ALIVE,
        P_SMP_CALL_EL1, P_SMP_CALL_EL1_SYNC, P_SMP_CALL_EL0, P_SMP_CALL_EL0_SYNC,
    };
    const u64 invalid_raw[] = {MAX_CPUS, UINT64_C(0x100000000),
                               UINT64_C(0x10000001f), UINT64_MAX};
    for (unsigned op = 0; op < sizeof(opcodes) / sizeof(opcodes[0]); op++) {
        if (proxy_case(opcodes[op], 0, true) || proxy_case(opcodes[op], 31, true))
            return 30 + (int)op;
        for (unsigned i = 0; i < sizeof(invalid_raw) / sizeof(invalid_raw[0]); i++)
            if (proxy_case(opcodes[op], invalid_raw[i], true)) return 40 + (int)op;
    }
    puts("SMP API index bounds and proxy u64 narrowing passed");
    return 0;
}

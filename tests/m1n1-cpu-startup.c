/* Host-only template: the runner inserts pinned smp_start_cpu/secondaries(). */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;

#ifndef EXPECT_PATCHED
#define EXPECT_PATCHED 0
#endif

#define MAX_CPUS 32
#define MAX_EL3_CPUS 4
#define SECONDARY_STACK_SIZE 0x10000
#define DUMMY_STACK_SIZE 0x1000
#define MPIDR_EL1 1
#define CurrentEL 2
#define ID_AA64PFR0_EL1 3
#define TPIDR_EL1 4
#define TPIDR_EL2 5
#define TPIDR_EL3 6
#define BIT(n) (1ULL << (n))
#define GENMASK(h, l) (((~0ULL) >> (63 - (h))) & (~0ULL << (l)))
#define FIELD_GET(mask, value) (((u64)(value) & (mask)) >> __builtin_ctzll(mask))
/* INSERT_SOURCE_CONSTANTS */

struct spin_table {
    u64 mpidr;
    u64 flag;
    u64 target;
    u64 args[4];
    u64 retval;
};

struct cpu_features_stub {
    bool apple_sysregs_unlocked;
    bool fast_ipi;
};

static struct cpu_features_stub cpu_features_value;
static struct cpu_features_stub *cpu_features = &cpu_features_value;
static struct spin_table spin_table[MAX_CPUS];
static u8 *secondary_stacks[MAX_CPUS];
static u8 *secondary_stacks_el3[MAX_EL3_CPUS];
static u8 dummy_stack[DUMMY_STACK_SIZE];
static u8 dummy_stack_el1[DUMMY_STACK_SIZE];
static u8 fake_stacks[MAX_CPUS + MAX_EL3_CPUS][SECONDARY_STACK_SIZE];
static unsigned allocations;
static unsigned allocation_attempts;
static unsigned free_count;
static bool allocation_live[MAX_CPUS + MAX_EL3_CPUS];
static unsigned allocation_limit = MAX_CPUS + MAX_EL3_CPUS;
static int target_cpu;
static int cpu_nodes[MAX_CPUS];
static u64 pmgr_reg;
static u64 cpu_start_off;
static int boot_cpu_idx = -1;
static u64 boot_cpu_mpidr;
static void *_reset_stack;
static void *_reset_stack_el1;
static unsigned udelay_calls;
static int ack_after = -1;
static unsigned write32_count;
static unsigned write64_count;
static u64 write32_addr[4], write32_value[4];
static u64 write64_addr[2], write64_value[2];
static u64 mock_pfr0;
static u64 mock_current_el;
static u64 mock_rvbar;
static unsigned sysop_count;
static unsigned msr_count;
static u8 _vectors_start[1] __attribute__((aligned(4096)));
static unsigned cache_count;
static bool bad_delay_arg;

static void mock_free(void *ptr)
{
    if (!ptr)
        return;
    for (unsigned i = 0; i < MAX_CPUS + MAX_EL3_CPUS; i++)
        if (ptr == fake_stacks[i]) {
            if (!allocation_live[i])
                abort(); /* Reject unallocated or double-freed storage. */
            allocation_live[i] = false;
            free_count++;
            return;
        }
    abort(); /* In particular, never free a previously published sentinel. */
}

static u64 mock_mrs(unsigned reg)
{
    if (reg == ID_AA64PFR0_EL1)
        return mock_pfr0;
    if (reg == CurrentEL)
        return mock_current_el;
    return 0;
}

#define mrs(reg) mock_mrs(reg)

/* INSERT_SOURCE_EL_HELPERS */

static void mock_msr(unsigned reg, u64 value)
{
    (void)reg;
    (void)value;
    msr_count++;
}

#define msr(reg, value) mock_msr((reg), (value))

static u64 read64(u64 addr)
{
    (void)addr;
    return mock_rvbar;
}

static void write64(u64 addr, u64 value)
{
    if (write64_count < 2) {
        write64_addr[write64_count] = addr;
        write64_value[write64_count] = value;
    }
    write64_count++;
}

static void write32(u64 addr, u32 value)
{
    if (write32_count < 4) {
        write32_addr[write32_count] = addr;
        write32_value[write32_count] = value;
    }
    write32_count++;
}

static void *memalign(size_t alignment, size_t size)
{
    if (alignment != 0x4000)
        abort();
    allocation_attempts++;
    if (size != SECONDARY_STACK_SIZE || allocations >= allocation_limit)
        return NULL;
    allocation_live[allocations] = true;
    return fake_stacks[allocations++];
}

static void dc_civac_range(void *address, size_t size)
{
    (void)address;
    (void)size;
    cache_count++;
}

static void sysop(const char *op)
{
    (void)op;
    sysop_count++;
}

static void udelay(unsigned usec)
{
    udelay_calls++;
    if (usec != 1000)
        bad_delay_arg = true;
    if (ack_after >= 0 && (int)udelay_calls >= ack_after)
        spin_table[target_cpu].flag = 1;
    (void)usec;
}

static void *adt = (void *)1;
static u32 chip_id;

static int adt_path_offset_trace(const void *tree, const char *path, int *trace)
{
    (void)tree;
    (void)path;
    if (trace)
        trace[0] = 1;
    return 1;
}

static int adt_path_offset(const void *tree, const char *path)
{
    (void)tree;
    (void)path;
    return 1;
}

static int adt_get_reg(const void *tree, int *path, const char *prop, int index,
                       u64 *address, u64 *size)
{
    (void)tree;
    (void)path;
    (void)prop;
    (void)index;
    if (address)
        *address = 0x100000;
    if (size)
        *size = 0;
    return 0;
}

static const void *adt_getprop(const void *tree, int node, const char *name, u32 *length)
{
    (void)tree;
    (void)node;
    (void)name;
    if (length)
        *length = 0;
    return NULL;
}

#define ADT_GETPROP(tree, node, name, value) (-1)
#define ADT_GETPROP_ARRAY(tree, node, name, value) (-1)
#define ADT_FOREACH_CHILD(tree, node) for (int no_children = 0; no_children < 0; no_children++)
#define free mock_free

/* INSERT_SMP_START_CPU */
/* INSERT_SMP_START_SECONDARIES */

static void reset_effects(void)
{
    memset(spin_table, 0, sizeof(spin_table));
    memset(secondary_stacks, 0, sizeof(secondary_stacks));
    memset(secondary_stacks_el3, 0, sizeof(secondary_stacks_el3));
    memset(write32_addr, 0, sizeof(write32_addr));
    memset(write32_value, 0, sizeof(write32_value));
    memset(write64_addr, 0, sizeof(write64_addr));
    memset(write64_value, 0, sizeof(write64_value));
    allocations = 0;
    allocation_attempts = 0;
    free_count = 0;
    memset(allocation_live, 0, sizeof(allocation_live));
    _reset_stack = dummy_stack;
    _reset_stack_el1 = dummy_stack_el1;
    allocation_limit = MAX_CPUS + MAX_EL3_CPUS;
    udelay_calls = 0;
    ack_after = -1;
    write32_count = 0;
    write64_count = 0;
    sysop_count = 0;
    msr_count = 0;
    cache_count = 0;
    bad_delay_arg = false;
    mock_pfr0 = 0;
    mock_current_el = 1 << 2;
    mock_rvbar = (u64)_vectors_start;
    cpu_features->apple_sysregs_unlocked = false;
}

static int test_selection(void)
{
    reset_effects();
    chip_id = 0x6032;
    cpu_start_off = 0xfeed;
    smp_start_secondaries();
    if (write32_count || write64_count || allocations || cpu_start_off != 0xfeed)
        return 10;

    reset_effects();
    chip_id = 0x6031;
    boot_cpu_idx = -1;
    smp_start_secondaries();
    if (cpu_start_off != 0x88000 || write32_count || allocations)
        return 11;

    reset_effects();
    chip_id = 0x6022;
    boot_cpu_idx = -1;
    smp_start_secondaries();
    if (cpu_start_off != 0x28000 || write32_count || allocations)
        return 12;
    return 0;
}

static int test_start_cpu(void)
{
    static const u8 topology[32][3] = { /* INSERT_TOPOLOGY */ };
    for (int index = 0; index < MAX_CPUS; index++) {
        reset_effects();
        ack_after = 1;
        smp_start_cpu(index, topology[index][0], topology[index][1], topology[index][2],
                      0x3000, 0x100000);
        u64 base = 0x100000 + (u64)topology[index][0] * PMGR_DIE_OFFSET;
        if (write32_count != 2 || write32_addr[0] != base + 4 ||
            write32_value[0] != (1u << (4 * topology[index][1] + topology[index][2])) ||
            write32_addr[1] != base + 0x8 + 4 * topology[index][1] ||
            write32_value[1] != (1u << topology[index][2]) || udelay_calls != 1 ||
            cache_count != 1 || allocations != 1 || bad_delay_arg)
            return 19;
    }

    reset_effects();
    pmgr_reg = 0x100000;
    cpu_start_off = 0x88000;
    ack_after = 3;
    smp_start_cpu(31, 1, 2, 5, 0x3000, pmgr_reg + cpu_start_off);
    u64 base = pmgr_reg + cpu_start_off + PMGR_DIE_OFFSET;
    if (write32_count != 2 || write32_addr[0] != base + 4 || write32_value[0] != (1u << 13) ||
        write32_addr[1] != base + 0x10 || write32_value[1] != (1u << 5) || udelay_calls != 3 ||
        cache_count != 1 || allocations != 1 || allocation_attempts != 1 || free_count != 0 || bad_delay_arg)
        return 20;

    reset_effects();
    mock_pfr0 = 0x1000;
    ack_after = 1;
    smp_start_cpu(3, 0, 0, 3, 0x3000, 0x100000);
    if (!has_el3() || write32_count != 2 || allocations != 2 || allocation_attempts != 2 ||
        cache_count != 2 || free_count != 0 || bad_delay_arg)
        return 21;

    reset_effects();
    mock_pfr0 = 0x1000;
    smp_start_cpu(4, 0, 0, 0, 0x3000, 0x100000);
    if (write32_count || write64_count || cache_count || allocations || allocation_attempts)
        return 22;

    reset_effects();
    smp_start_cpu(32, 0, 0, 0, 0x3000, 0x100000);
    if (write32_count || write64_count || cache_count || allocations || allocation_attempts)
        return 23;

    reset_effects();
    spin_table[7].flag = 1;
    smp_start_cpu(7, 0, 1, 1, 0x3000, 0x100000);
    if (write32_count || write64_count || cache_count || allocations || allocation_attempts)
        return 24;

    reset_effects();
    ack_after = -1;
    smp_start_cpu(2, 0, 1, 5, 0x3000, 0x100000);
    if (write32_count != 2 || udelay_calls != 100 || cache_count != 1 || allocations != 1 ||
        allocation_attempts != 1 || free_count != 0 || !allocation_live[0] ||
        secondary_stacks[2] != fake_stacks[0] || bad_delay_arg)
        return 25;

    reset_effects();
    cpu_features->apple_sysregs_unlocked = true;
    ack_after = 1;
    smp_start_cpu(6, 0, 1, 2, 0x3000, 0x100000);
    if (write64_count != 1 || write64_addr[0] != 0x3000 ||
        write64_value[0] != (u64)_vectors_start)
        return 26;

    reset_effects();
    /* The lock bit is outside RVBAR_ADDR and must not create a false mismatch. */
    mock_rvbar = (u64)_vectors_start | 1;
    ack_after = 1;
    smp_start_cpu(7, 0, 1, 3, 0x3000, 0x100000);
    if (write32_count != 2 || write64_count || allocations != 1 || cache_count != 1)
        return 31;

    reset_effects();
    /* Unlocked hardware is rewritten even when its current RVBAR differs. */
    cpu_features->apple_sysregs_unlocked = true;
    mock_rvbar = 0;
    ack_after = 1;
    smp_start_cpu(7, 0, 1, 3, 0x3000, 0x100000);
    if (write64_count != 1 || write64_addr[0] != 0x3000 ||
        write64_value[0] != (u64)_vectors_start || write32_count != 2 ||
        allocations != 1 || cache_count != 1)
        return 32;

    reset_effects();
    /* Existing source behavior: locked RVBAR mismatch logs but still starts. */
    mock_rvbar = 0;
    ack_after = 1;
    spin_table[8].target = 0x8888;
    target_cpu = 25;
    smp_start_cpu(8, 0, 1, 4, 0x3000, 0x100000);
    if (!EXPECT_PATCHED && (write32_count != 2 || allocations != 1 || allocation_attempts != 1 || cache_count != 1))
        return 27;
    if (EXPECT_PATCHED && (write32_count || write64_count || allocations || allocation_attempts ||
                           cache_count || free_count || spin_table[8].target != 0x8888 ||
                           target_cpu != 25 || _reset_stack != dummy_stack ||
                           _reset_stack_el1 != dummy_stack_el1))
        return 27;
#if EXPECT_PATCHED
    reset_effects();
    secondary_stacks[9] = (u8 *)(uintptr_t)0x11110000;
    spin_table[9].target = 0x1111;
    target_cpu = 29;
    _reset_stack = (void *)(uintptr_t)0x2222;
    _reset_stack_el1 = (void *)(uintptr_t)0x3333;
    allocation_limit = 0;
    smp_start_cpu(9, 0, 1, 1, 0x3000, 0x100000);
    if (allocation_attempts != 1 || allocations || free_count || write32_count || write64_count ||
        cache_count || secondary_stacks[9] != (u8 *)(uintptr_t)0x11110000 ||
        spin_table[9].target != 0x1111 || target_cpu != 29 || _reset_stack != (void *)(uintptr_t)0x2222 ||
        _reset_stack_el1 != (void *)(uintptr_t)0x3333) {
        return 28;
    }

    reset_effects();
    mock_pfr0 = 0x1000;
    secondary_stacks[2] = (u8 *)(uintptr_t)0x4444;
    secondary_stacks_el3[2] = (u8 *)(uintptr_t)0x5555;
    spin_table[2].target = 0x2222;
    target_cpu = 28;
    allocation_limit = 0;
    smp_start_cpu(2, 0, 1, 2, 0x3000, 0x100000);
    if (allocation_attempts != 1 || allocations || free_count || write32_count || write64_count ||
        cache_count || secondary_stacks[2] != (u8 *)(uintptr_t)0x4444 ||
        secondary_stacks_el3[2] != (u8 *)(uintptr_t)0x5555 || spin_table[2].target != 0x2222 ||
        target_cpu != 28 || _reset_stack != dummy_stack || _reset_stack_el1 != dummy_stack_el1) {
        return 29;
    }

    reset_effects();
    mock_pfr0 = 0x1000;
    secondary_stacks[3] = (u8 *)(uintptr_t)0x6666;
    secondary_stacks_el3[3] = (u8 *)(uintptr_t)0x7777;
    spin_table[3].target = 0x3333;
    target_cpu = 27;
    allocation_limit = 1;
    smp_start_cpu(3, 1, 2, 3, 0x3000, 0x100000);
    if (allocation_attempts != 2 || allocations != 1 || free_count != 1 || write32_count ||
        write64_count || cache_count || secondary_stacks[3] != (u8 *)(uintptr_t)0x6666 ||
        secondary_stacks_el3[3] != (u8 *)(uintptr_t)0x7777 || spin_table[3].target != 0x3333 ||
        target_cpu != 27 || allocation_live[0] || _reset_stack != dummy_stack ||
        _reset_stack_el1 != dummy_stack_el1) {
        return 30;
    }
#endif
    return 0;
}

int main(void)
{
    for (unsigned el = 1; el <= 3; el++) {
        mock_current_el = el << 2;
        mock_pfr0 = 0x0001;
        if ((el == 2) != !!in_el2() || (el == 3) != !!in_el3() || has_el3())
            return 1;
        mock_pfr0 = 0x1001; /* EL3 field=1 plus unrelated low bit. */
        if ((el == 2) != !!in_el2() || (el == 3) != !!in_el3() || !has_el3())
            return 2;
    }
    int result = test_selection();
    if (result)
        return result;
    result = test_start_cpu();
    if (result)
        return result;
    printf("selection: T6032 returns before secondary-start effects, T6031=0x88000, T6022=0x28000\n");
    printf("start_cpu: index bounds, EL3 3/4, skip-alive, die stride, ack/timeout passed\n");
    printf("variant: %s\n", EXPECT_PATCHED ?
           "guarded: RVBAR rejection and allocation-failure ownership checks passed" :
           "baseline: successful starts and RVBAR-mismatch continuation reproduced");
    printf("note: status mask uses source expression 1 << (4*cluster+core); no uniqueness claim\n");
    return 0;
}

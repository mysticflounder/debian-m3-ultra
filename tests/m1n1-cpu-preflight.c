/* Host-only template: the runner inserts pinned m1n1 preflight functions. */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;

/* INSERT_SOURCE_DEFINES */
#define PMGR_DIE_OFFSET 0x2000000000ULL
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

struct spin_table {
    u64 mpidr, flag, target, args[4], retval;
};
struct cpu_features_stub {
    bool apple_sysregs_unlocked;
    bool fast_ipi;
};

static struct cpu_features_stub cpu_features_value;
static struct cpu_features_stub *cpu_features = &cpu_features_value;
static struct spin_table spin_table[MAX_CPUS];
static int cpu_nodes[MAX_CPUS];
static u8 *secondary_stacks[MAX_CPUS];
static u8 *secondary_stacks_el3[MAX_EL3_CPUS];
static u8 dummy_stack[DUMMY_STACK_SIZE], dummy_stack_el1[DUMMY_STACK_SIZE];
static u8 _vectors_start[1] __attribute__((aligned(4096)));
static void *_reset_stack, *_reset_stack_el1;
static int target_cpu;
static int boot_cpu_idx = -1;
static u64 boot_cpu_mpidr;
static u64 pmgr_reg, cpu_start_off;
static u32 chip_id;
static void *adt = (void *)1;

static u64 mock_pfr0, mock_current_el = 1 << 2;
static unsigned read64_count, write64_count, write32_count, msr_count;
static unsigned sysop_count, memalign_count, cache_count;
static unsigned adt_property_reads, adt_path_reads;

#define MOCK_CPUS 32
static int mock_child_count = MOCK_CPUS;
static int mock_child_nodes[MOCK_CPUS];
static u8 mock_id[MOCK_CPUS][4], mock_reg[MOCK_CPUS][4];
static u8 mock_die[MOCK_CPUS][4], mock_cluster[MOCK_CPUS][4], mock_core[MOCK_CPUS][4];
static u8 mock_state[MOCK_CPUS][8], mock_impl[MOCK_CPUS][16];
static u8 mock_max_cpus[4], mock_cluster_count[4];
static u8 mock_mode[4] = {1, 0, 0, 0};
static u8 mock_clusters[12] = {4, 0, 0, 0, 6, 0, 4, 0, 6, 0, 10, 0};
/* INSERT_LIVE_FIXTURE */
static struct spin_table spin_sentinel[MAX_CPUS];
static int mock_running_id;
static unsigned mock_case;
static bool mock_reverse;

static u64 mock_mrs(unsigned reg)
{
    if (reg == ID_AA64PFR0_EL1) return mock_pfr0;
    if (reg == CurrentEL) return mock_current_el;
    return 0;
}
#define mrs(reg) mock_mrs(reg)
static bool in_el2(void) { return ((mock_current_el >> 2) & 3) == 2; }
static bool in_el3(void) { return ((mock_current_el >> 2) & 3) == 3; }
static bool has_el3(void) { return !!(mock_pfr0 & 0xf00); }

static void mock_msr(unsigned reg, u64 value) { (void)reg; (void)value; msr_count++; }
#define msr(reg, value) mock_msr((reg), (value))
static _Noreturn void mock_panic(const char *format, ...)
{
    (void)format;
    abort();
}
#define panic(...) mock_panic(__VA_ARGS__)
static u64 read64(u64 address) { (void)address; read64_count++; return (u64)_vectors_start; }
static void write64(u64 address, u64 value) { (void)address; (void)value; write64_count++; }
static void write32(u64 address, u32 value) { (void)address; (void)value; write32_count++; }
static void sysop(const char *op) { (void)op; sysop_count++; }
/* 0016 adds this MMU lifecycle gate; the historical subset-9 harness keeps
 * the legacy path enabled explicitly. */
#ifdef TEST_MMU_SMP_GUARD
static bool mock_mmu_smp_start_allowed = true;
static bool mmu_smp_start_allowed(void) { return mock_mmu_smp_start_allowed; }
#else
static bool mmu_smp_start_allowed(void) { return true; }
#endif
static void udelay(unsigned usec) { (void)usec; }
static void dc_civac_range(void *address, size_t size) { (void)address; (void)size; cache_count++; }
static void *memalign(size_t alignment, size_t size)
{
    (void)alignment; (void)size; memalign_count++; return NULL;
}

static void encode_u32(u8 out[4], u32 value)
{
    out[0] = value; out[1] = value >> 8; out[2] = value >> 16; out[3] = value >> 24;
}
static u32 decode_u32(const u8 in[4])
{
    return (u32)in[0] | ((u32)in[1] << 8) | ((u32)in[2] << 16) | ((u32)in[3] << 24);
}
static void encode_u64(u8 out[8], u64 value)
{
    for (unsigned i = 0; i < 8; i++) out[i] = value >> (8 * i);
}

static int adt_path_offset_trace(const void *tree, const char *path, int *trace)
{
    (void)tree; adt_path_reads++;
    if (strcmp(path, "/arm-io/pmgr")) return -1;
    trace[0] = 1; trace[1] = 0; return 1;
}
static int adt_path_offset(const void *tree, const char *path)
{
    (void)tree; adt_path_reads++;
    if (!strcmp(path, "/arm-io/pmgr")) return 200;
    if (!strcmp(path, "/arm-io")) return 2;
    if (!strcmp(path, "/cpus")) return 100;
    return -1;
}
static int adt_get_reg(const void *tree, int *path, const char *prop, int index, u64 *addr, u64 *size)
{
    (void)tree; (void)path; (void)prop; (void)index;
    *addr = 0x100000; if (size) *size = 0x100000; return 0;
}
static int adt_get_child_count(const void *tree, int node)
{
    (void)tree; return node == 100 ? mock_child_count : 0;
}
static int adt_first_child_offset(const void *tree, int node) { (void)tree; (void)node; return 1; }
static int adt_next_sibling_offset(const void *tree, int node) { (void)tree; return node + 1; }
#define ADT_FOREACH_CHILD(tree, var) \
    for (int _child_i = 0; _child_i < mock_child_count && ((var) = mock_child_nodes[_child_i], 1); _child_i++)

static const void *adt_getprop(const void *tree, int node, const char *name, u32 *length)
{
    (void)tree; adt_property_reads++;
    if (node == 200 && !strcmp(name, "acc-harvesting")) { if (length) *length = 4; return mock_mode; }
    if (node == 200 && !strcmp(name, "clusters")) { if (length) *length = 12; return mock_clusters; }
    if (node == 100 && !strcmp(name, "max_cpus")) { if (length) *length = mock_case == 24 ? 3 : 4; return mock_max_cpus; }
    if (node == 100 && !strcmp(name, "cpu-cluster-count")) { if (length) *length = mock_case == 25 ? 8 : 4; return mock_cluster_count; }
    if (node < 1 || node > MOCK_CPUS) return NULL;
    unsigned i = (unsigned)(node - 1);
    if (!strcmp(name, "cpu-id")) { if (mock_case == 26 && i == 0) return NULL; if (length) *length = 4; return mock_id[i]; }
    if (!strcmp(name, "reg")) { if (length) *length = mock_case == 27 && i == 0 ? 3 : 4; return mock_reg[i]; }
    if (!strcmp(name, "die-id")) { if (mock_case == 28 && i == 0) return NULL; if (length) *length = 4; return mock_die[i]; }
    if (!strcmp(name, "die-cluster-id")) { if (length) *length = 4; return mock_cluster[i]; }
    if (!strcmp(name, "cluster-core-id")) { if (length) *length = mock_case == 30 && i == 0 ? 5 : 4; return mock_core[i]; }
    if (!strcmp(name, "state")) { if (mock_case == 29 && i == 0) return NULL; if (length) *length = (mock_case == 8 ? 7 : 8); return mock_state[i]; }
    if (!strcmp(name, "cpu-impl-reg")) {
        if (mock_case == 9) { if (length) *length = 24; return mock_impl[i]; }
        if (mock_case == 10) { if (length) *length = 8; return mock_impl[i]; }
        if (mock_case == 11) return NULL;
        if (length) *length = 16; return mock_impl[i];
    }
    return NULL;
}

#define ADT_GETPROP(tree, node, name, val) (-1)
#define ADT_GETPROP_ARRAY(tree, node, name, arr) (-1)

/* INSERT_MASK_HELPER */
/* INSERT_U32_HELPER */
/* INSERT_PREFLIGHT_HELPER */
/* INSERT_START_CPU */
/* INSERT_START_SECONDARIES */

static void reset_fixture(void)
{
    memset(spin_table, 0, sizeof(spin_table));
    memset(cpu_nodes, 0xA5, sizeof(cpu_nodes));
    memset(mock_id, 0, sizeof(mock_id)); memset(mock_reg, 0, sizeof(mock_reg));
    memset(mock_die, 0, sizeof(mock_die)); memset(mock_cluster, 0, sizeof(mock_cluster));
    memset(mock_core, 0, sizeof(mock_core)); memset(mock_state, 0, sizeof(mock_state));
    memset(mock_impl, 0, sizeof(mock_impl));
    encode_u32(mock_max_cpus, 32); encode_u32(mock_cluster_count, 3);
    mock_running_id = 0; mock_case = 0; mock_reverse = false; mock_child_count = MOCK_CPUS;
    for (unsigned i = 0; i < MOCK_CPUS; i++) {
        mock_child_nodes[i] = (int)i + 1;
        encode_u32(mock_id[i], live_ids[i]); encode_u32(mock_reg[i], live_regs[i]);
        encode_u32(mock_die[i], live_dies[i]); encode_u32(mock_cluster[i], live_clusters[i]);
        encode_u32(mock_core[i], live_cores[i]); memcpy(mock_state[i], live_states[i], 8);
        encode_u64(mock_impl[i], live_bases[i]);
        encode_u64(mock_impl[i] + 8, live_sizes[i]);
    }
    read64_count = write64_count = write32_count = msr_count = 0;
    sysop_count = memalign_count = cache_count = adt_property_reads = adt_path_reads = 0;
    chip_id = T6032; boot_cpu_idx = -1; boot_cpu_mpidr = 0; cpu_start_off = 0xfeed;
    mock_current_el = 1 << 2; mock_pfr0 = 0;
}

static void mark_sentinels(void)
{
    memset(spin_table, 0x5a, sizeof(spin_table));
    memcpy(spin_sentinel, spin_table, sizeof(spin_table));
    for (unsigned i = 0; i < MAX_CPUS; i++) {
        cpu_nodes[i] = (int)0xa5a5a5a5;
        secondary_stacks[i] = (u8 *)(uintptr_t)(0x11110000ULL + i * 0x100);
    }
    for (unsigned i = 0; i < MAX_EL3_CPUS; i++)
        secondary_stacks_el3[i] = (u8 *)(uintptr_t)(0x22220000ULL + i * 0x100);
    _reset_stack = (void *)(uintptr_t)0x3333;
    _reset_stack_el1 = (void *)(uintptr_t)0x4444;
    target_cpu = 27;
    boot_cpu_mpidr = 0xfeedface;
}

static bool sentinels_intact(void)
{
    if (memcmp(spin_table, spin_sentinel, sizeof(spin_table)) ||
        _reset_stack != (void *)(uintptr_t)0x3333 ||
        _reset_stack_el1 != (void *)(uintptr_t)0x4444 || target_cpu != 27 ||
        boot_cpu_mpidr != 0xfeedface)
        return false;
    for (unsigned i = 0; i < MAX_CPUS; i++)
        if (cpu_nodes[i] != (int)0xa5a5a5a5 ||
            secondary_stacks[i] != (u8 *)(uintptr_t)(0x11110000ULL + i * 0x100))
            return false;
    for (unsigned i = 0; i < MAX_EL3_CPUS; i++)
        if (secondary_stacks_el3[i] != (u8 *)(uintptr_t)(0x22220000ULL + i * 0x100))
            return false;
    return true;
}

static bool no_hardware_effects(void)
{
    return !read64_count && !write64_count && !write32_count && !msr_count &&
           !sysop_count && !memalign_count && !cache_count;
}

static int expect_direct(unsigned case_id, int expected)
{
    reset_fixture(); mock_case = case_id;
    if (case_id == 1) mock_reverse = true;
    if (case_id == 2) { mock_running_id = 7; for (unsigned i = 0; i < 32; i++) memcpy(mock_state[i], i == 7 ? "running\0" : "waiting\0", 8); }
    if (case_id == 3) encode_u32(mock_id[1], 0);
    if (case_id == 4) { encode_u32(mock_reg[1], 0); encode_u32(mock_die[1], 0); encode_u32(mock_cluster[1], 0); encode_u32(mock_core[1], 0); }
    if (case_id == 5) mock_case = 8;
    if (case_id == 6) { mock_case = 0; memset(mock_state[0], 'x', 8); }
    if (case_id == 7) { mock_case = 0; memcpy(mock_state[1], "running\0", 8); }
    if (case_id == 12) { encode_u64(mock_impl[0], 0); }
    if (case_id == 13) { encode_u64(mock_impl[0], 0x51000001); }
    if (case_id == 14) { encode_u64(mock_impl[1], live_bases[0] + 0x100); }
    if (case_id == 15) { encode_u64(mock_impl[0] + 8, 0x100); }
    if (case_id == 16) { encode_u64(mock_impl[0], ~(u64)0 - 0xfff); encode_u64(mock_impl[0] + 8, 0x2000); }
    if (case_id == 17) encode_u32(mock_max_cpus, 31);
    if (case_id == 18) encode_u32(mock_cluster_count, 2);
    if (case_id == 19) mock_child_count = 31;
    if (case_id == 20) boot_cpu_idx = 7;
    if (case_id == 21) { mock_case = 9; }
    if (case_id == 22) { mock_case = 10; }
    if (case_id == 23) { mock_case = 11; }
    if (case_id == 31) for (unsigned i = 0; i < 32; i++) memcpy(mock_state[i], "waiting\0", 8);
    if (case_id == 32) memcpy(mock_state[1], "running\0", 8);
    if (case_id == 33) boot_cpu_idx = LIVE_RUNNING_ID;
    if (case_id == 34) encode_u32(mock_id[0], 32);
    if (case_id == 35) encode_u32(mock_reg[0], 0x8000);
    if (case_id == 36) encode_u32(mock_core[0], 1);
    if (case_id == 37) { encode_u32(mock_reg[0], 2U << 11); encode_u32(mock_die[0], 2); }
    if (case_id == 38) { encode_u32(mock_reg[0], 3U << 8); encode_u32(mock_cluster[0], 3); }
    if (case_id == 39) { encode_u32(mock_reg[0], 6); encode_u32(mock_core[0], 6); }
    mark_sentinels();
    for (unsigned i = 0; i < 32 && mock_reverse; i++) mock_child_nodes[i] = 32 - (int)i;
    bool actual = smp_t6032_preflight(100);
    if ((actual ? 1 : 0) != expected || !no_hardware_effects()) return 100 + (int)case_id;
    if (!sentinels_intact() || cpu_start_off != 0xfeed) return 132;
    if (case_id == 2 && boot_cpu_idx != -1) return 130;
    if (case_id == 20 && boot_cpu_idx != 7) return 131;
    return 0;
}

int main(void)
{
    /* Legacy dispatch must bypass the T6032 inventory check, even with no children. */
    reset_fixture();
    chip_id = T6031;
    mock_child_count = 0;
    smp_start_secondaries();
    if (cpu_start_off != CPU_START_OFF_T6031 || adt_property_reads || !no_hardware_effects())
        return 204;
    reset_fixture();
    chip_id = T6031;
    u32 legacy_system = 0, legacy_cluster = 0;
    if (!smp_cpu_start_masks(1, 2, 5, &legacy_system, &legacy_cluster) ||
        legacy_system != (1U << 13) || legacy_cluster != (1U << 5) || adt_property_reads)
        return 3;
    chip_id = T6032;
    u32 value = 0xdeadbeef;
    if (!smp_t6032_u32(1, "cpu-id", &value) || value != 0 || !no_hardware_effects()) return 1;
    mock_case = 8;
    value = 0xdeadbeef;
    if (smp_t6032_u32(1, "state", &value) || value != 0xdeadbeef) return 2;

    for (unsigned i = 0; i <= 39; i++) {
        int expected = (i == 0 || i == 1 || i == 2 || i == 33) ? 1 : 0;
        int result = expect_direct(i, expected);
        if (result) return result;
    }
    for (unsigned invalid = 0; invalid < 3; invalid++) {
        reset_fixture();
        if (invalid == 0)
            encode_u32(mock_id[1], 0);
        else if (invalid == 1)
            for (unsigned i = 0; i < 32; i++) memcpy(mock_state[i], "waiting\0", 8);
        else
            encode_u32(mock_id[0], 32);
        mark_sentinels();
        smp_start_secondaries();
        if (!no_hardware_effects() || !sentinels_intact() || cpu_start_off != 0xfeed ||
            boot_cpu_idx != -1)
            return 201 + (int)invalid;
    }
    reset_fixture();
    mock_case = 0;
    smp_start_secondaries();
    if (!no_hardware_effects() || cpu_start_off != 0xfeed || boot_cpu_idx != -1) return 200;
    printf("T6032 preflight source harness passed: valid/reordered/boot-state, duplicate, malformed, window and integration gates\n");
    printf("all tests use raw bounded ADT mocks; T6032 dispatch remains closed and caller propagation is not tested\n");
    return 0;
}

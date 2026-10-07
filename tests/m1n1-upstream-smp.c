/* Host-only fixture for the reviewed upstream SMP source.
 * The runner inserts function bodies extracted from the materialized source.
 * No firmware, MMIO, AArch64 instruction, or native reset path is linked. */
#include <setjmp.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;
typedef uint64_t uint64_t_alias;
typedef unsigned long size_t_alias;

#define MAX_CPUS __MAX_CPUS__
#define MAX_EL3_CPUS __MAX_EL3_CPUS__
#define SECONDARY_STACK_SIZE __SECONDARY_STACK_SIZE__
#define DUMMY_STACK_SIZE 0x1000
#define PMGR_DIE_OFFSET __PMGR_DIE_OFFSET__
#define T6032 __T6032__
#define CPU_REG_CORE __CPU_REG_CORE__
#define CPU_REG_CLUSTER __CPU_REG_CLUSTER__
#define CPU_REG_DIE __CPU_REG_DIE__
#define GENMASK(h, l) ((((u64)~0ULL) >> (63 - (h))) & (~0ULL << (l)))
static unsigned field_shift(u32 mask) { return (unsigned)__builtin_ctz(mask); }
#define FIELD_GET(mask, value) (((u32)(value) & (u32)(mask)) >> field_shift(mask))
#define BIT(n) (1ULL << (n))
#define S_BADSTATE (-2)
#define MPIDR_EL1 1
#define TPIDR_EL1 2
#define TPIDR_EL2 3
#define RVBAR_LOCK BIT(0)
#define SYS_IMP_APL_IPI_RR_GLOBAL_EL1 1
#define SYS_IMP_APL_IPI_SR_EL1 4
#define AIC_IPI_SEND 0x2008
#define AIC_IPI_ACK 0x200c
#define AIC_IPI_MASK_SET 0x2024
#define AIC_IPI_MASK_CLR 0x2028
#define AIC_IPI_SEND_CPU(cpu) BIT(cpu)
#define AIC_IPI_OTHER BIT(0)
#define AIC_IPI_SELF BIT(31)
#define RVBAR_ADDR __RVBAR_ADDR__
/* INSERT_SOURCE_CONSTANTS */
#define SMP_SHARED
#define ALIGNED(x) __attribute__((aligned(x)))

struct spin_table { u64 mpidr, flag, target, args[4], retval; };
struct cpu_info { bool valid; u8 die, cluster, core; u64 impl_reg; };
struct smp_reset_stack { u64 mpidr, stack; };

struct cpu_features_mock { bool fast_ipi, apple_sysregs_unlocked; };
struct cpu_features_mock features;
struct cpu_features_mock *cpu_features = &features;
int chip_id = T6032;
void *adt = (void *)0x1;
int boot_cpu_idx = -1;
u64 boot_cpu_mpidr;
bool smp_initialized;
int target_cpu = -1;
bool wfe_mode;
u64 cpu_start_base = 0x100000;
u8 dummy_stack[DUMMY_STACK_SIZE], dummy_stack_el1[DUMMY_STACK_SIZE];
u8 secondary_stacks[MAX_CPUS][SECONDARY_STACK_SIZE] ALIGNED(0x4000);
u8 secondary_stacks_el3[MAX_EL3_CPUS][SECONDARY_STACK_SIZE] ALIGNED(0x4000);
struct spin_table spin_table[MAX_CPUS];
struct smp_reset_stack smp_reset_stacks[MAX_CPUS];
int cpu_nodes[MAX_CPUS];
struct cpu_info cpu_info[MAX_CPUS];
u8 _vectors_start[1] ALIGNED(0x4000), _stack_bot[1];
void *_reset_stack, *_reset_stack_el1;

static int child_count = MAX_CPUS;
static bool malformed;
static u32 ids[MAX_CPUS], regs[MAX_CPUS], dies[MAX_CPUS], clusters[MAX_CPUS], cores[MAX_CPUS];
static u64 impl_base[MAX_CPUS], impl_size[MAX_CPUS];
static char states[MAX_CPUS][8];
static u8 mode_prop[4] = {1, 0, 0, 0};
static u8 cluster_prop[12] = {4, 0, 0, 0, 6, 0, 4, 0, 6, 0, 10, 0};
static const u8 captured_topology[MAX_CPUS][4] = {
    /* INSERT_CAPTURED_TOPOLOGY */
};

static int read_calls, write64_calls, write32_calls, ipi_calls, call_calls;
static int preflight_calls;
static u64 write32_addresses[8];
static u32 write32_values[8];
static bool acknowledge_start, stop_status_busy, panic_seen, panic_jumps, locked_start_released;
static jmp_buf panic_env;
static jmp_buf entry_env;
static u64 mock_mpidr;

static u32 read_le32(const u8 *p)
{
    return (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24);
}

static void put_le32(u8 *p, u32 value)
{
    for (unsigned i = 0; i < 4; i++) p[i] = (u8)(value >> (8 * i));
}

static void put_le64(u8 *p, u64 value)
{
    for (unsigned i = 0; i < 8; i++) p[i] = (u8)(value >> (8 * i));
}

static void fixture_reset(void)
{
    memset(spin_table, 0, sizeof(spin_table));
    memset(smp_reset_stacks, 0, sizeof(smp_reset_stacks));
    for (unsigned i = 0; i < MAX_CPUS; i++) smp_reset_stacks[i].mpidr = ~0ULL;
    memset(ids, 0, sizeof(ids));
    memset(regs, 0, sizeof(regs));
    memset(dies, 0, sizeof(dies));
    memset(clusters, 0, sizeof(clusters));
    memset(cores, 0, sizeof(cores));
    memset(impl_base, 0, sizeof(impl_base));
    memset(impl_size, 0, sizeof(impl_size));
    for (unsigned i = 0; i < MAX_CPUS; i++) strcpy(states[i], "waiting");
    for (unsigned i = 0; i < MAX_CPUS; i++) {
        ids[i] = captured_topology[i][0];
        dies[i] = captured_topology[i][1];
        clusters[i] = captured_topology[i][2];
        cores[i] = captured_topology[i][3];
        regs[i] = (dies[i] << 11) | (clusters[i] << 8) | cores[i];
        impl_base[i] = 0x10000000ULL + (u64)i * 0x2000;
        impl_size[i] = 0x200;
    }
    strcpy(states[0], "running");
    child_count = MAX_CPUS;
    malformed = false;
    mode_prop[0] = 1; mode_prop[1] = mode_prop[2] = mode_prop[3] = 0;
    u8 good_clusters[12] = {4,0,0,0, 6,0,4,0, 6,0,10,0};
    memcpy(cluster_prop, good_clusters, sizeof(cluster_prop));
    boot_cpu_idx = -1; target_cpu = -1; wfe_mode = false;
    features.fast_ipi = false; features.apple_sysregs_unlocked = true;
    read_calls = write64_calls = write32_calls = ipi_calls = call_calls = 0;
    preflight_calls = 0;
    memset(write32_addresses, 0, sizeof(write32_addresses));
    memset(write32_values, 0, sizeof(write32_values));
    acknowledge_start = true; panic_seen = false;
    panic_jumps = false;
    locked_start_released = false;
    stop_status_busy = false;
    mock_mpidr = 0;
    _reset_stack = _reset_stack_el1 = NULL;
}

static int adt_path_offset(void *tree, const char *path)
{
    (void)tree;
    if (!strcmp(path, "/arm-io/pmgr")) return 99;
    if (!strcmp(path, "/arm-io")) return 98;
    if (!strcmp(path, "/cpus")) return 1;
    return -1;
}

static int pmgr_adt_path_offset_trace(void *tree, int path[8])
{ (void)tree; path[0] = 99; return 0; }

static int adt_get_reg(void *tree, const int path[8], const char *name, int index,
                       u64 *value, void *unused)
{ (void)tree; (void)path; (void)name; (void)index; (void)unused; *value = 0x200000; return 0; }

static bool in_el2(void) { return false; }
static const char *pmgr_name = "/arm-io/pmgr";
static const void *adt_getprop(void *, int, const char *, u32 *);

static int adt_copy_u32(void *tree, int node, const char *name, void *out)
{
    u32 length = 0; const u8 *raw = adt_getprop(tree, node, name, &length);
    if (!raw || length != 4) return -1;
    memcpy(out, raw, 4); return 0;
}
#define ADT_GETPROP(tree, node, name, out) adt_copy_u32((tree), (node), (name), (out))
#define ADT_GETPROP_ARRAY(tree, node, name, out) (-1)

static const void *adt_getprop(void *tree, int node, const char *name, u32 *length)
{
    static u8 raw[16];
    u32 ignored_length;
    if (!length) length = &ignored_length;
    (void)tree;
    if ((node < 1 || node > MAX_CPUS) && node != 99) return NULL;
    if (node == 99) {
        if (!strcmp(name, "acc-harvesting")) { *length = 4; return mode_prop; }
        if (!strcmp(name, "clusters")) { *length = 12; return cluster_prop; }
        return NULL;
    }
    unsigned i = (unsigned)(node - 1);
    if (node == 1 && !strcmp(name, "max_cpus")) { put_le32(raw, 32); *length = 4; return raw; }
    if (node == 1 && !strcmp(name, "cpu-cluster-count")) { put_le32(raw, 3); *length = 4; return raw; }
    if (!strcmp(name, "cpu-id")) { put_le32(raw, ids[i]); *length = malformed ? 3 : 4; return raw; }
    if (!strcmp(name, "reg")) { put_le32(raw, regs[i]); *length = 4; return raw; }
    if (!strcmp(name, "die-id")) { put_le32(raw, dies[i]); *length = 4; return raw; }
    if (!strcmp(name, "die-cluster-id")) { put_le32(raw, clusters[i]); *length = 4; return raw; }
    if (!strcmp(name, "cluster-core-id")) { put_le32(raw, cores[i]); *length = 4; return raw; }
    if (!strcmp(name, "state")) { memcpy(raw, states[i], 8); *length = 8; return raw; }
    if (!strcmp(name, "cpu-impl-reg")) {
        put_le64(raw, impl_base[i]); put_le64(raw + 8, impl_size[i]); *length = 16; return raw;
    }
    return NULL;
}

static int adt_get_child_count(void *tree, int node)
{ (void)tree; (void)node; return child_count; }

#define ADT_FOREACH_CHILD(tree, var) \
    for (int _child_i = 0; (void)(tree), _child_i < child_count && ((var) = _child_i + 1); _child_i++)

static u64 read64(u64 addr)
{
    read_calls++;
    if (addr == 0x1100) return stop_status_busy ? 1 : 0;
    return features.apple_sysregs_unlocked ? (u64)_vectors_start : 0;
}
static void write64(u64 addr, u64 value) { (void)addr; (void)value; write64_calls++; }
static void write32(u64 addr, u32 value)
{
    if (write32_calls < 8) { write32_addresses[write32_calls] = addr; write32_values[write32_calls] = value; }
    write32_calls++;
    if (!features.apple_sysregs_unlocked) locked_start_released = true;
    if (acknowledge_start && write32_calls >= 2) spin_table[target_cpu].flag = 1;
}
static void sysop(const char *op) { (void)op; }
static void udelay(u64 usec) { (void)usec; }
static bool has_el3(void) { return false; }
static void panic(const char *fmt, ...)
{
    (void)fmt;
    panic_seen = true;
    if (!panic_jumps) {
        fputs("FAIL: unexpected unarmed panic\n", stderr);
        abort();
    }
    longjmp(panic_env, 1);
}
static void mock_call1(int cpu, void *fn, u64 arg) { (void)cpu; (void)fn; (void)arg; call_calls++; }
#define smp_call1(cpu, fn, arg) mock_call1((cpu), (fn), (arg))
static void cpu_sleep(u64 value) { (void)value; }
static void msr(u64 reg, u64 value) { (void)reg; (void)value; }
static u64 mrs(u64 reg) { return reg == MPIDR_EL1 ? mock_mpidr : 0; }
static void aic_write(u64 reg, u32 value) { (void)reg; (void)value; ipi_calls++; }
static u32 aic_ack(void) { return 0; }
static void deep_wfi(void) { longjmp(entry_env, 1); }
static void smp_send_ipi_stub(int cpu) { (void)cpu; ipi_calls++; }

/* Actual functions/declarations extracted by scripts/test-m1n1-upstream-smp.py. */
/* INSERT_SMP_FUNCTIONS */
/* INSERT_CALLER_GUARDS */

static int expect(bool condition, const char *what)
{
    if (!condition) { fprintf(stderr, "FAIL: %s\n", what); return 1; }
    return 0;
}

static int test_inventory(void)
{
    fixture_reset();
    int ok = smp_t6032_preflight(1);
    if (expect(ok, "captured 32-node inventory accepted")) return 1;
    ids[7] = ids[6];
    if (expect(!smp_t6032_preflight(1), "duplicate CPU id rejected")) return 1;
    fixture_reset(); child_count = 31;
    if (expect(!smp_t6032_preflight(1), "short inventory rejected")) return 1;
    fixture_reset(); impl_base[4] = impl_base[3] + 0x100;
    if (expect(!smp_t6032_preflight(1), "overlapping implementation windows rejected")) return 1;
    fixture_reset(); strcpy(states[1], "running");
    if (expect(!smp_t6032_preflight(1), "multiple running states rejected")) return 1;
    fixture_reset(); mode_prop[0] = 0;
    if (expect(!smp_t6032_preflight(1), "invalid harvesting mode rejected")) return 1;
    return 0;
}

static int test_init_and_status(void)
{
    fixture_reset(); smp_initialized = false; ids[3] = ids[2];
    if (expect(smp_init() < 0 && !smp_initialized && preflight_calls == 1 &&
               write64_calls == 0 && write32_calls == 0,
               "invalid inventory init fails through the preflight gate before release side effects")) return 1;
    if (expect(smp_start_secondaries() < 0, "uninitialized T6032 startup is failure")) return 1;

    fixture_reset();
    smp_initialized = false;
    if (expect(smp_init() == 0 && smp_initialized && write64_calls == 0 && write32_calls == 0,
               "valid full inventory initializes without release side effects")) return 1;
    if (expect(cpu_info[0].valid && cpu_info[31].valid && cpu_nodes[31] == 32,
               "validated metadata is cached after preflight")) return 1;
    ids[3] = ids[2];
    if (expect(smp_init() == 0 && cpu_info[3].die == 0 && cpu_info[3].core == 3,
               "successful init keeps cached metadata on re-entry")) return 1;

    fixture_reset(); smp_initialized = false;
    if (expect(smp_init() == 0, "status fixture initializes")) return 1;
    features.apple_sysregs_unlocked = false;
    if (expect(smp_start_secondaries() < 0 && spin_table[2].flag == 0,
               "T6032 leaf failure stops continuation")) return 1;

    fixture_reset(); smp_initialized = false;
    if (expect(smp_init() == 0, "final-status fixture initializes")) return 1;
    features.apple_sysregs_unlocked = true;
    cpu_info[5].valid = false;
    if (expect(smp_start_secondaries() < 0,
               "T6032 final status rejects an unstarted slot")) return 1;

    fixture_reset(); chip_id = T6000; smp_initialized = false;
    if (expect(smp_init() == 0, "legacy fixture initializes")) return 1;
    features.apple_sysregs_unlocked = false;
    if (expect(smp_start_secondaries() == 0, "legacy startup preserves best effort")) return 1;
    chip_id = T6032;
    return 0;
}

static int test_masks(void)
{
    fixture_reset();
    u32 system_mask = 0, cluster_mask = 0;
    if (expect(smp_cpu_start_masks(0, 0, 3, &system_mask, &cluster_mask) &&
               system_mask == 8 && cluster_mask == 8, "cluster 0 masks")) return 1;
    if (expect(smp_cpu_start_masks(1, 2, 5, &system_mask, &cluster_mask) &&
               system_mask == (1U << 15) && cluster_mask == 32, "cluster 2 masks")) return 1;
    if (expect(!smp_cpu_start_masks(0, 0, 4, &system_mask, &cluster_mask), "cluster width boundary")) return 1;
    return 0;
}

static int test_start_stop(void)
{
    struct cpu_info cpu = {.valid = true, .die = 1, .cluster = 1, .core = 5, .impl_reg = 0x1000};
    fixture_reset(); features.apple_sysregs_unlocked = false;
    if (setjmp(panic_env) != 0) return 1;
    smp_start_cpu(1, &cpu);
    if (expect(read_calls >= 1 && write64_calls == 0 && write32_calls == 0 &&
               !locked_start_released &&
               spin_table[1].flag == 0, "locked RVBAR mismatch has no release side effects")) return 1;
    fixture_reset(); features.apple_sysregs_unlocked = true; acknowledge_start = true;
    smp_start_cpu(1, &cpu);
    if (expect(write32_calls == 2 && spin_table[1].flag == 1 &&
               write32_addresses[0] == cpu_start_base + PMGR_DIE_OFFSET + 0x4 &&
               write32_addresses[1] == cpu_start_base + PMGR_DIE_OFFSET + 0x8 + 4 * cpu.cluster &&
               write32_values[0] == (1U << 9) && write32_values[1] == 32,
               "valid start publishes packed masks at the source die offset")) return 1;
    fixture_reset(); features.apple_sysregs_unlocked = true; spin_table[1].flag = 1;
    smp_stop_cpu(1, &cpu, true);
    if (expect(write32_calls == 1 && call_calls == 1 &&
               write32_addresses[0] == cpu_start_base + PMGR_DIE_OFFSET &&
               write32_values[0] == (1U << 9), "stop uses current packed mask and die offset")) return 1;

    fixture_reset(); features.apple_sysregs_unlocked = true; acknowledge_start = false;
    panic_jumps = true;
    if (setjmp(panic_env) == 0) smp_start_cpu(1, &cpu);
    if (expect(panic_seen, "secondary-start timeout panics")) return 1;
    if (expect(_reset_stack != dummy_stack + DUMMY_STACK_SIZE, "secondary-start timeout retains reset stack")) return 1;
    if (expect(write32_calls >= 1, "secondary-start timeout published start state")) return 1;
    return 0;
}

static int test_stop_timeout(void)
{
    struct cpu_info cpu = {.valid = true, .die = 1, .cluster = 1, .core = 5, .impl_reg = 0x1000};
    fixture_reset(); features.apple_sysregs_unlocked = true; spin_table[1].flag = 1;
    smp_stop_cpu(1, &cpu, false);
    if (expect(write32_calls == 1 && call_calls == 1 && spin_table[1].flag == 0,
               "normal stop clears a successfully stopped CPU")) return 1;
    fixture_reset(); features.apple_sysregs_unlocked = true; stop_status_busy = true;
    spin_table[1].flag = 1;
    panic_jumps = true;
    if (setjmp(panic_env) == 0) smp_stop_cpu(1, &cpu, false);
    if (expect(panic_seen && spin_table[1].flag == 1 && write32_calls == 1,
               "normal-stop timeout is non-returning and retains state")) return 1;
    return 0;
}

static int test_secondary_entry(void)
{
    fixture_reset();
    target_cpu = 2;
    mock_mpidr = 0x555;
    if (setjmp(entry_env) == 0) smp_secondary_entry();
    if (expect(smp_reset_stacks[2].mpidr == mock_mpidr && smp_reset_stacks[2].stack &&
               spin_table[2].mpidr == mock_mpidr && spin_table[2].flag == 1,
               "initial secondary entry publishes the target slot")) return 1;

    fixture_reset();
    smp_reset_stacks[3].mpidr = 0x123;
    target_cpu = 1;
    mock_mpidr = 0x123;
    if (setjmp(entry_env) == 0) smp_secondary_entry();
    if (expect(smp_reset_stacks[3].stack && spin_table[3].mpidr == mock_mpidr &&
               spin_table[3].flag == 1,
               "re-entry resolves the registered MPIDR slot")) return 1;

    fixture_reset();
    target_cpu = -1;
    mock_mpidr = 0x42;
    panic_jumps = true;
    if (setjmp(panic_env) == 0) smp_secondary_entry();
    if (expect(panic_seen && smp_reset_stacks[0].stack == 0 && spin_table[0].flag == 0,
               "invalid secondary-entry index panics before publication")) return 1;

    fixture_reset();
    smp_reset_stacks[3].mpidr = 0x123;
    target_cpu = 3;
    mock_mpidr = 0x456;
    panic_jumps = true;
    if (setjmp(panic_env) == 0) smp_secondary_entry();
    if (expect(panic_seen && smp_reset_stacks[3].mpidr == 0x123 &&
               smp_reset_stacks[3].stack == 0 && spin_table[3].flag == 0,
               "unknown T6032 MPIDR cannot overwrite a registered slot")) return 1;
    return 0;
}

static int test_indices(void)
{
    int bad[] = {INT32_MIN, -1, MAX_CPUS, INT32_MAX};
    for (unsigned i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
        fixture_reset();
        smp_send_ipi(bad[i]); smp_call4(bad[i], NULL, 0, 0, 0, 0);
        if (expect(smp_wait(bad[i]) == 0 && !smp_is_alive(bad[i]) &&
                   smp_get_mpidr(bad[i]) == 0 && smp_get_release_addr(bad[i]) == 0 &&
                   ipi_calls == 0 && write32_calls == 0, "signed invalid index is inert")) return 1;
    }
    return 0;
}

static int test_caller_status(void)
{
    caller_start_status = -1; caller_continuation = 0;
    if (expect(payload_guard_probe() < 0 && hv_guard_probe() < 0 &&
               proxy_guard_probe() == S_BADSTATE && caller_continuation == 1,
               "payload/HV status failures cut off; proxy maps status and breaks case")) return 1;
    caller_start_status = 0; caller_continuation = 0;
    if (expect(payload_guard_probe() == 0 && hv_guard_probe() == 0 &&
               proxy_guard_probe() == 0 && caller_continuation == 3,
               "payload/HV/proxy success preserves continuation")) return 1;
    return 0;
}

int main(void)
{
    if (test_inventory() || test_masks() || test_start_stop() ||
        (__STOP_TIMEOUT_TEST__ && test_stop_timeout()) || test_secondary_entry() ||
        test_indices() || test_init_and_status() || test_caller_status()) return 1;
    puts("reviewed-upstream SMP host fixture passed");
    return 0;
}

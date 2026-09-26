/* Host-only template: test-m1n1-cpu-handoff.py inserts pinned dt_set_cpus(). */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libfdt.h"

typedef uint8_t u8;
typedef uint64_t u64;

#define MAX_CPUS 32
#define MAX_TEST_CPUS 33
#define SECONDARY_STACK_SIZE 0x10000
#define MPIDR_EL1 0

static void *dt;
static uint64_t current_mpidr;
static uint64_t test_mpidrs[MAX_TEST_CPUS];
static uint64_t test_release[MAX_TEST_CPUS];
static bool test_alive[MAX_TEST_CPUS];
static int test_cpu_count;
static int test_mismatch_cpu = -1;
static int test_missing_reg_cpu = -1;
static int test_boot_cpu;
static u8 *secondary_stacks[MAX_CPUS];
static u8 *secondary_stacks_el3[4];
static u8 stack_tokens[MAX_CPUS];
static u8 stack_tokens_el3[4];
static size_t tracked_allocations;

static void *tracked_calloc(size_t count, size_t size)
{
    void *ptr = calloc(count, size);
    if (ptr)
        tracked_allocations++;
    return ptr;
}

static void tracked_free(void *ptr)
{
    if (ptr)
        tracked_allocations--;
    free(ptr);
}

#define calloc tracked_calloc
#define free tracked_free

#define bail(...)                                                                            \
    do {                                                                                     \
        fprintf(stderr, __VA_ARGS__);                                                        \
        return -1;                                                                           \
    } while (0)
#define bail_cleanup(...)                                                                    \
    do {                                                                                     \
        fprintf(stderr, __VA_ARGS__);                                                        \
        ret = -1;                                                                            \
        goto err;                                                                            \
    } while (0)

static uint64_t test_mrs(unsigned reg)
{
    (void)reg;
    return current_mpidr;
}

#define mrs(reg) test_mrs(reg)

static bool has_el3(void)
{
    return false;
}

static bool smp_is_alive(int cpu)
{
    return cpu >= 0 && cpu < test_cpu_count && test_alive[cpu];
}

static u64 smp_get_mpidr(int cpu)
{
    if (cpu == test_mismatch_cpu)
        return test_mpidrs[cpu] ^ 1;
    return test_mpidrs[cpu];
}

static u64 smp_get_release_addr(int cpu)
{
    return test_release[cpu];
}

/* INSERT_DT_SET_CPUS */

#undef mrs
#undef calloc
#undef free

static int add_prop_u64(void *blob, int node, const char *name, uint64_t value)
{
    return fdt_setprop_u64(blob, node, name, value);
}

static int add_cpu_map(void *blob, int cpu_map, int count, int cluster)
{
    char cluster_name[32];
    snprintf(cluster_name, sizeof(cluster_name), "cluster%d", cluster);
    int cluster_node = fdt_add_subnode(blob, cpu_map, cluster_name);
    if (cluster_node < 0)
        return cluster_node;

    for (int i = 0; i < count; i++) {
        char core_name[32];
        snprintf(core_name, sizeof(core_name), "core%d", i);
        int core = fdt_add_subnode(blob, cluster_node, core_name);
        if (core < 0)
            return core;
    }
    return 0;
}

static int build_tree(int cpu_count, bool include_cpu_map, int dead_cpu)
{
    const size_t blob_size = 1024 * 1024;
    dt = calloc(1, blob_size);
    if (!dt || fdt_create_empty_tree(dt, blob_size)) {
        fprintf(stderr, "build: create tree failed\n");
        return -1;
    }

    int root = fdt_path_offset(dt, "/");
    int cpus = fdt_add_subnode(dt, root, "cpus");
    int aic = fdt_add_subnode(dt, root, "aic");
    if (cpus < 0 || aic < 0) {
        fprintf(stderr, "build: root children failed cpus=%d aic=%d\n", cpus, aic);
        return -1;
    }

    int affinities = fdt_add_subnode(dt, aic, "affinities");
    int affinity0 = fdt_add_subnode(dt, affinities, "cluster0");
    int affinity1 = fdt_add_subnode(dt, affinities, "cluster1");
    int cpu_map = fdt_add_subnode(dt, fdt_path_offset(dt, "/cpus"), "cpu-map");
    if (affinity0 < 0 || affinity1 < 0 || (include_cpu_map && cpu_map < 0)) {
        fprintf(stderr, "build: aic/map failed aff0=%d aff1=%d map=%d\n", affinity0, affinity1, cpu_map);
        return -1;
    }

    fdt32_t *affinity_phandles = calloc((size_t)cpu_count, sizeof(*affinity_phandles));
    if (!affinity_phandles)
        return -1;

    test_cpu_count = cpu_count;
    test_mismatch_cpu = -1;
    /* libfdt inserts each child before existing siblings; add in reverse so
     * the FDT traversal order remains Linux's ordinal CPU order. */
    for (int cpu = cpu_count - 1; cpu >= 0; cpu--) {
        char name[32];
        snprintf(name, sizeof(name), "cpu@%x", cpu);
        int node = fdt_add_subnode(dt, fdt_path_offset(dt, "/cpus"), name);
        if (node < 0) {
            fprintf(stderr, "build: cpu node %d failed %d\n", cpu, node);
            return -1;
        }

        /* Linux FDT cells are big-endian; fdt_setprop_u64 encodes that form. */
        /* Keep the synthetic second die distinct from boot MPIDR 0x100. */
        uint64_t mpidr = cpu == 0 ? 0x100 :
                         (((uint64_t)(cpu >= 16) << 12) | (uint64_t)(cpu & 0xf));
        test_mpidrs[cpu] = mpidr;
        test_release[cpu] = 0x80000000ULL + (uint64_t)cpu * 0x1000;
        test_alive[cpu] = cpu != dead_cpu;
        if (cpu < MAX_CPUS)
            secondary_stacks[cpu] = &stack_tokens[cpu];
        if (cpu < 4)
            secondary_stacks_el3[cpu] = &stack_tokens_el3[cpu];
        affinity_phandles[cpu] = cpu_to_fdt32(0x100 + cpu);
    }
    /* Exercise the ordinal-independent boot-MPIDR skip. */
    current_mpidr = test_mpidrs[test_boot_cpu];

    /* Build every node before adding properties: property insertion moves offsets. */
    int map_parent = include_cpu_map ? fdt_path_offset(dt, "/cpus/cpu-map") : -1;
    int map0_ret = include_cpu_map ? add_cpu_map(dt, map_parent,
                                                  (cpu_count + 1) / 2, 0) : 0;
    map_parent = include_cpu_map ? fdt_path_offset(dt, "/cpus/cpu-map") : -1;
    int map1_ret = include_cpu_map ? add_cpu_map(dt, map_parent,
                                                  cpu_count / 2, 1) : 0;
    if (map0_ret || map1_ret) {
        fprintf(stderr, "build: cpu map failed parent=%d ret0=%d ret1=%d (%s)\n",
                map_parent, map0_ret, map1_ret, fdt_strerror(map0_ret ? map0_ret : map1_ret));
        return -1;
    }

    if (fdt_setprop_string(dt, fdt_path_offset(dt, "/aic"), "compatible", "apple,aic"))
    {
        fprintf(stderr, "build: aic property failed\n");
        return -1;
    }
    for (int cpu = 0; cpu < cpu_count; cpu++) {
        char path[64];
        snprintf(path, sizeof(path), "/cpus/cpu@%x", cpu);
        int node = fdt_path_offset(dt, path);
        int r0 = node < 0 ? node : (cpu == test_missing_reg_cpu ? 0 :
                                    fdt_setprop_u64(dt, node, "reg", test_mpidrs[cpu]));
        int r1 = r0 ? r0 : fdt_setprop_u32(dt, node, "phandle", 0x100 + cpu);
        int r2 = r1 ? r1 : add_prop_u64(dt, node, "cpu-release-addr", 0);
        if (r2) {
            fprintf(stderr, "build: cpu props %d node=%d ret=%d\n", cpu, node, r2);
            return -1;
        }
    }

    affinity0 = fdt_path_offset(dt, "/aic/affinities/cluster0");
    affinity1 = fdt_path_offset(dt, "/aic/affinities/cluster1");
    int affinity0_ret = fdt_setprop(dt, affinity0, "cpus", affinity_phandles,
                                    (int)((cpu_count + 1) / 2) * (int)sizeof(*affinity_phandles));
    int affinity1_ret = fdt_setprop(dt, affinity1, "cpus", affinity_phandles + (cpu_count + 1) / 2,
                                    (int)(cpu_count / 2) * (int)sizeof(*affinity_phandles));
    if (affinity0_ret || affinity1_ret) {
        fprintf(stderr, "build: affinity props failed ret0=%d ret1=%d\n", affinity0_ret, affinity1_ret);
        return -1;
    }
    free(affinity_phandles);

    if (include_cpu_map) {
        for (int cpu = 0; cpu < cpu_count; cpu++) {
            int cluster = cpu >= (cpu_count + 1) / 2;
            int core = cpu - cluster * ((cpu_count + 1) / 2);
            char path[96];
            snprintf(path, sizeof(path), "/cpus/cpu-map/cluster%d/core%d", cluster, core);
            int node = fdt_path_offset(dt, path);
            if (node < 0 || fdt_setprop_u32(dt, node, "cpu", 0x100 + cpu))
            {
                fprintf(stderr, "build: map prop %d node=%d\n", cpu, node);
                return -1;
            }
        }
    }
    return 0;
}

static int count_cpu_nodes(void)
{
    int cpus = fdt_path_offset(dt, "/cpus");
    int count = 0;
    for (int node = fdt_first_subnode(dt, cpus); node >= 0; node = fdt_next_subnode(dt, node))
        if (!strncmp(fdt_get_name(dt, node, NULL), "cpu@", 4))
            count++;
    return count;
}

static int count_cpu_map_cores(void)
{
    int map = fdt_path_offset(dt, "/cpus/cpu-map");
    int count = 0;
    if (map < 0)
        return map;
    for (int cluster = fdt_first_subnode(dt, map); cluster >= 0;
         cluster = fdt_next_subnode(dt, cluster)) {
        for (int core = fdt_first_subnode(dt, cluster); core >= 0;
             core = fdt_next_subnode(dt, core)) {
            if (!strncmp(fdt_get_name(dt, core, NULL), "core", 4))
                count++;
        }
    }
    return count;
}

static int affinity_count(int affinity)
{
    int len = 0;
    const fdt32_t *cpus = fdt_getprop(dt, affinity, "cpus", &len);
    return cpus ? len / (int)sizeof(*cpus) : -1;
}

static int validate_cpu_set(bool map)
{
    bool seen[MAX_TEST_CPUS] = { false };
    int count = 0;
    int parent;
    if (map) {
        parent = fdt_path_offset(dt, "/cpus/cpu-map");
    } else {
        int aic = fdt_node_offset_by_compatible(dt, -1, "apple,aic");
        int affinities = fdt_subnode_offset(dt, aic, "affinities");
        parent = affinities;
    }
    if (parent < 0)
        return -1;

    for (int group = fdt_first_subnode(dt, parent); group >= 0;
         group = fdt_next_subnode(dt, group)) {
        if (map) {
            for (int core = fdt_first_subnode(dt, group); core >= 0;
                 core = fdt_next_subnode(dt, core)) {
                int len = 0;
                const fdt32_t *prop = fdt_getprop(dt, core, "cpu", &len);
                if (!prop || len != (int)sizeof(*prop))
                    return -1;
                uint32_t phandle = fdt32_ld(prop);
                if (phandle < 0x100 || phandle >= 0x100 + (uint32_t)test_cpu_count)
                    return -1;
                int cpu = (int)phandle - 0x100;
                if (!test_alive[cpu] || seen[cpu])
                    return -1;
                seen[cpu] = true;
                count++;
            }
        } else {
            int len = 0;
            const fdt32_t *props = fdt_getprop(dt, group, "cpus", &len);
            if (!props || len % (int)sizeof(*props))
                return -1;
            for (int i = 0; i < len / (int)sizeof(*props); i++) {
                uint32_t phandle = fdt32_ld(&props[i]);
                if (phandle < 0x100 || phandle >= 0x100 + (uint32_t)test_cpu_count)
                    return -1;
                int cpu = (int)phandle - 0x100;
                if (!test_alive[cpu] || seen[cpu])
                    return -1;
                seen[cpu] = true;
                count++;
            }
        }
    }
    for (int cpu = 0; cpu < test_cpu_count; cpu++)
        if (seen[cpu] != test_alive[cpu])
            return -1;
    return count;
}

static int run_handoff(int cpu_count, bool include_cpu_map, int dead_cpu,
                       int boot_cpu, int mismatch_cpu, int missing_reg_cpu,
                       int expected_result,
                       int expected_live,
                       int expected_affinity, int expected_reservations,
                       bool expect_known_success_leak)
{
    test_boot_cpu = boot_cpu;
    test_missing_reg_cpu = missing_reg_cpu;
    if (build_tree(cpu_count, include_cpu_map, dead_cpu))
    {
        fprintf(stderr, "scenario build failed cpu=%d\n", cpu_count);
        return 100;
    }
    test_mismatch_cpu = mismatch_cpu;
    /* Each invocation measures only allocations made by this dt_set_cpus call;
     * the known successful-path leak is intentionally left for the process to
     * report, while ASan leak scanning is disabled by the Python runner. */
    tracked_allocations = 0;
    int result = dt_set_cpus();
    if (result != expected_result) {
        fprintf(stderr, "scenario cpu=%d unexpected result=%d expected=%d\n",
                cpu_count, result, expected_result);
        return 101;
    }
    if (result == 0) {
        if (count_cpu_nodes() != expected_live) {
            fprintf(stderr, "scenario cpu=%d live=%d expected=%d\n",
                    cpu_count, count_cpu_nodes(), expected_live);
            return 102;
        }
        if (include_cpu_map && count_cpu_map_cores() != expected_live) {
            fprintf(stderr, "scenario cpu=%d map cores=%d expected=%d\n",
                    cpu_count, count_cpu_map_cores(), expected_live);
            return 106;
        }
        if (!include_cpu_map || validate_cpu_set(false) != expected_live) {
            fprintf(stderr, "scenario cpu=%d AIC membership validation failed\n", cpu_count);
            return 109;
        }
        if (include_cpu_map && validate_cpu_set(true) != expected_live) {
            fprintf(stderr, "scenario cpu=%d cpu-map membership validation failed\n", cpu_count);
            return 110;
        }
        int aic = fdt_node_offset_by_compatible(dt, -1, "apple,aic");
        int affinities = fdt_subnode_offset(dt, aic, "affinities");
        int affinity0 = fdt_subnode_offset(dt, affinities, "cluster0");
        int affinity1 = fdt_subnode_offset(dt, affinities, "cluster1");
        if (affinity_count(affinity0) != expected_affinity ||
            affinity_count(affinity1) != expected_live - expected_affinity) {
            fprintf(stderr, "scenario cpu=%d affinity=%d expected=%d\n",
                    cpu_count, affinity_count(affinity0), expected_affinity);
            return 103;
        }
        if (fdt_num_mem_rsv(dt) != expected_reservations) {
            fprintf(stderr, "scenario cpu=%d reservations=%d expected=%d\n",
                    cpu_count, fdt_num_mem_rsv(dt), expected_reservations);
            return 104;
        }
        for (int cpu = 0; cpu < cpu_count; cpu++) {
            char path[96];
            snprintf(path, sizeof(path), "/cpus/cpu@%x", cpu);
            int node = fdt_path_offset(dt, path);
            if (!test_alive[cpu]) {
                if (node >= 0) {
                    fprintf(stderr, "scenario cpu=%d dead node %d survived\n", cpu_count, cpu);
                    return 107;
                }
                continue;
            }
            int len = 0;
            const fdt64_t *release = fdt_getprop(dt, node, "cpu-release-addr", &len);
            uint64_t expected_release = cpu == test_boot_cpu ? 0 : test_release[cpu];
            if (!release || len != (int)sizeof(*release) || fdt64_ld(release) != expected_release) {
                fprintf(stderr, "scenario cpu=%d release cpu=%d value=%llx expected=%llx\n",
                        cpu_count, cpu, release ? (unsigned long long)fdt64_ld(release) : 0,
                        (unsigned long long)expected_release);
                return 108;
            }
        }
    }
    bool leak_expected = expect_known_success_leak && result == 0;
    if ((tracked_allocations != (leak_expected ? 1u : 0u))) {
        fprintf(stderr, "scenario cpu=%d allocations=%zu expected=%u\n", cpu_count,
                tracked_allocations, leak_expected ? 1u : 0u);
        return 105;
    }
    printf("scenario cpu=%d dead=%d result=%d live=%d tracked_allocations=%zu\n",
           cpu_count, dead_cpu, result, count_cpu_nodes(), tracked_allocations);
    free(dt);
    dt = NULL;
    return 0;
}

int main(void)
{
    int result = 0;
    /* 32 CPUs spanning two synthetic die encodings; ordinal 5 is boot CPU. */
    result |= run_handoff(32, true, -1, 5, -1, -1, 0, 32, 16, 31, true);
    /* Dead secondary pruning updates CPU nodes, AIC references and cpu-map. */
    result |= run_handoff(32, true, 20, 0, -1, -1, 0, 31, 16, 30, true);
    /* An ordinal 33rd CPU must fail before indexing fixed-size storage. */
    result |= run_handoff(33, true, -1, 0, -1, -1, -1, 0, 0, 0, false);
    /* A DT MPIDR mismatch is fatal and cleans the temporary prune array. */
    result |= run_handoff(32, true, -1, 0, 7, -1, -1, 0, 0, 0, false);
    /* A missing reg property is fatal. */
    result |= run_handoff(32, true, -1, 0, -1, 3, -1, 0, 0, 0, false);
    /* A 24-CPU legacy topology remains within the expanded bound. */
    result |= run_handoff(24, true, -1, 0, -1, -1, 0, 24, 12, 23, true);
    if (result)
        return result;
    printf("known existing dt_set_cpus success-path allocation leak observed: 1 per successful cpu-map run\n");
    return 0;
}

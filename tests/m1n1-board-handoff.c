/* Host-only template: the runner inserts pinned dt_set_cpus(). */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libfdt.h"

typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;

#define MAX_CPUS 32
#define SECONDARY_STACK_SIZE 0x10000
#define MPIDR_EL1 0

static void *dt;
static u64 current_mpidr;
static u64 test_mpidrs[MAX_CPUS];
static u64 test_release[MAX_CPUS];
static bool test_alive[MAX_CPUS];
static int test_cpu_count;
static int test_mismatch_cpu = -1;
static uint32_t test_phandles[MAX_CPUS];
static char test_cpu_names[MAX_CPUS][32];
static u8 *secondary_stacks[MAX_CPUS];
static u8 *secondary_stacks_el3[4];
static u8 stack_tokens[MAX_CPUS];
static size_t tracked_allocations;
#define TRACKED_MAX 8
static void *tracked_ptrs[TRACKED_MAX];

static void *tracked_calloc(size_t count, size_t size)
{
    void *ptr = calloc(count, size);
    if (!ptr)
        return NULL;
    for (size_t i = 0; i < TRACKED_MAX; i++) {
        if (!tracked_ptrs[i]) {
            tracked_ptrs[i] = ptr;
            tracked_allocations++;
            return ptr;
        }
    }
    abort();
}

static void tracked_free(void *ptr)
{
    if (ptr) {
        for (size_t i = 0; i < TRACKED_MAX; i++) {
            if (tracked_ptrs[i] == ptr) {
                tracked_ptrs[i] = NULL;
                tracked_allocations--;
                break;
            }
        }
    }
    free(ptr);
}

static void tracked_reclaim_all(void)
{
    for (size_t i = 0; i < TRACKED_MAX; i++)
        if (tracked_ptrs[i])
            tracked_free(tracked_ptrs[i]);
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

static u64 test_mrs(unsigned reg)
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

static int load_blob(const char *path)
{
    FILE *file = fopen(path, "rb");
    if (!file)
        return -1;
    if (fseek(file, 0, SEEK_END) || ftell(file) <= 0) {
        fclose(file);
        return -1;
    }
    long length = ftell(file);
    rewind(file);
    void *input = malloc((size_t)length);
    dt = calloc(1024 * 1024, 1);
    if (!input || !dt || fread(input, 1, (size_t)length, file) != (size_t)length ||
        fdt_open_into(input, dt, 1024 * 1024)) {
        free(input);
        fclose(file);
        return -1;
    }
    free(input);
    fclose(file);
    return 0;
}

static int collect_cpus(void)
{
    int cpus = fdt_path_offset(dt, "/cpus");
    if (cpus < 0)
        return -1;
    test_cpu_count = 0;
    for (int node = fdt_first_subnode(dt, cpus); node >= 0;
         node = fdt_next_subnode(dt, node)) {
        const char *name = fdt_get_name(dt, node, NULL);
        if (strncmp(name, "cpu@", 4))
            continue;
        if (test_cpu_count == MAX_CPUS)
            return -1;
        int len = 0;
        const fdt64_t *reg = fdt_getprop(dt, node, "reg", &len);
        if (!reg || len < (int)sizeof(*reg))
            return -1;
        snprintf(test_cpu_names[test_cpu_count], sizeof(test_cpu_names[0]), "%s", name);
        test_phandles[test_cpu_count] = fdt_get_phandle(dt, node);
        if (!test_phandles[test_cpu_count])
            return -1;
        test_mpidrs[test_cpu_count] = fdt64_ld(reg);
        test_release[test_cpu_count] = 0x100000 + (u64)test_cpu_count * 0x1000;
        secondary_stacks[test_cpu_count] = &stack_tokens[test_cpu_count];
        test_alive[test_cpu_count] = true;
        test_cpu_count++;
    }
    return test_cpu_count == MAX_CPUS ? 0 : -1;
}

static int validate_map_membership(void)
{
    bool seen[MAX_CPUS] = { false };
    int map = fdt_path_offset(dt, "/cpus/cpu-map");
    if (map < 0)
        return -1;
    for (int cluster = fdt_first_subnode(dt, map); cluster >= 0;
         cluster = fdt_next_subnode(dt, cluster)) {
        for (int core = fdt_first_subnode(dt, cluster); core >= 0;
             core = fdt_next_subnode(dt, core)) {
            int len = 0;
            const fdt32_t *prop = fdt_getprop(dt, core, "cpu", &len);
            if (!prop || len != (int)sizeof(*prop))
                return -1;
            uint32_t phandle = fdt32_ld(prop);
            int ordinal = -1;
            for (int i = 0; i < test_cpu_count; i++)
                if (test_phandles[i] == phandle)
                    ordinal = i;
            if (ordinal < 0 || seen[ordinal] || !test_alive[ordinal])
                return -1;
            seen[ordinal] = true;
        }
    }
    for (int i = 0; i < test_cpu_count; i++)
        if (seen[i] != test_alive[i])
            return -1;
    return 0;
}

static int validate_aic_membership(void)
{
    int aic = fdt_node_offset_by_compatible(dt, -1, "apple,t8122-aic3");
    int affinities = fdt_subnode_offset(dt, aic, "affinities");
    if (affinities < 0)
        return 0; /* J575d source DT has no AIC affinity node. */
    bool seen[MAX_CPUS] = { false };
    for (int group = fdt_first_subnode(dt, affinities); group >= 0;
         group = fdt_next_subnode(dt, group)) {
        int len = 0;
        const fdt32_t *props = fdt_getprop(dt, group, "cpus", &len);
        if (!props || len % (int)sizeof(*props))
            return -1;
        for (int j = 0; j < len / (int)sizeof(*props); j++) {
            uint32_t phandle = fdt32_ld(&props[j]);
            int ordinal = -1;
            for (int i = 0; i < test_cpu_count; i++)
                if (test_phandles[i] == phandle)
                    ordinal = i;
            if (ordinal < 0 || seen[ordinal] || !test_alive[ordinal])
                return -1;
            seen[ordinal] = true;
        }
    }
    for (int i = 0; i < test_cpu_count; i++)
        if (seen[i] != test_alive[i])
            return -1;
    return 0;
}

static int validate_nodes_and_releases(int expected_live, int base_reservations)
{
    int live = 0;
    for (int i = 0; i < test_cpu_count; i++) {
        char path[96];
        snprintf(path, sizeof(path), "/cpus/%s", test_cpu_names[i]);
        int node = fdt_path_offset(dt, path);
        if (!test_alive[i]) {
            if (node >= 0)
                return -1;
            continue;
        }
        live++;
        int len = 0;
        const fdt64_t *release = fdt_getprop(dt, node, "cpu-release-addr", &len);
        u64 expected = i == 0 ? 0 : test_release[i];
        if (!release || len != (int)sizeof(*release) || fdt64_ld(release) != expected)
            return -1;
    }
    if (live != expected_live || fdt_num_mem_rsv(dt) != base_reservations + live - 1)
        return -1;
    return 0;
}

static int count_cpu_nodes(void)
{
    int cpus = fdt_path_offset(dt, "/cpus");
    int count = 0;
    for (int node = fdt_first_subnode(dt, cpus); node >= 0;
         node = fdt_next_subnode(dt, node))
        if (!strncmp(fdt_get_name(dt, node, NULL), "cpu@", 4))
            count++;
    return count;
}

static int count_map_cores(void)
{
    int map = fdt_path_offset(dt, "/cpus/cpu-map");
    int count = 0;
    if (map < 0)
        return -1;
    for (int cluster = fdt_first_subnode(dt, map); cluster >= 0;
         cluster = fdt_next_subnode(dt, cluster))
        for (int core = fdt_first_subnode(dt, cluster); core >= 0;
             core = fdt_next_subnode(dt, core))
            if (!strncmp(fdt_get_name(dt, core, NULL), "core", 4))
                count++;
    return count;
}

static int cluster_count(int cluster_index)
{
    int map = fdt_path_offset(dt, "/cpus/cpu-map");
    char name[24];
    snprintf(name, sizeof(name), "cluster%d", cluster_index);
    int cluster = fdt_subnode_offset(dt, map, name);
    if (cluster < 0)
        return 0;
    int count = 0;
    for (int core = fdt_first_subnode(dt, cluster); core >= 0;
         core = fdt_next_subnode(dt, core))
        if (!strncmp(fdt_get_name(dt, core, NULL), "core", 4))
            count++;
    return count;
}

static int run_case(const char *name, int dead_cpu, int dead_cluster,
                    int mismatch_cpu, int expected_live, int expected_clusters)
{
    test_mismatch_cpu = mismatch_cpu;
    current_mpidr = test_mpidrs[0];
    for (int i = 0; i < test_cpu_count; i++)
        test_alive[i] = true;
    if (dead_cpu >= 0)
        test_alive[dead_cpu] = false;
    if (dead_cluster >= 0) {
        static const int starts[] = {0, 4, 10, 16, 20, 26};
        static const int counts[] = {4, 6, 6, 4, 6, 6};
        for (int i = starts[dead_cluster]; i < starts[dead_cluster] + counts[dead_cluster]; i++)
            test_alive[i] = false;
    }

    int base_reservations = fdt_num_mem_rsv(dt);
    int result = dt_set_cpus();
    if (mismatch_cpu >= 0) {
        if (result == 0) {
            fprintf(stderr, "%s: mismatch unexpectedly succeeded\n", name);
            return -1;
        }
        if (tracked_allocations != 0) {
            fprintf(stderr, "%s: mismatch left %zu allocations before cleanup\n",
                    name, tracked_allocations);
            tracked_reclaim_all();
            return -1;
        }
        printf("board scenario %-18s result=%d (mock mismatch rejected, allocations=0)\n", name, result);
        tracked_reclaim_all();
        return 0;
    }
    if (result || count_cpu_nodes() != expected_live || count_map_cores() != expected_live ||
        validate_map_membership() || validate_aic_membership() ||
        validate_nodes_and_releases(expected_live, base_reservations) || tracked_allocations != 0) {
        fprintf(stderr, "%s: result=%d nodes=%d map=%d allocations=%zu expected=%d\n", name,
                result, count_cpu_nodes(), count_map_cores(), tracked_allocations, expected_live);
        tracked_reclaim_all();
        return -1;
    }
    int map_counts = 0;
    int surviving_clusters = 0;
    for (int i = 0; i < 6; i++)
        if (cluster_count(i) > 0) {
            surviving_clusters++;
            map_counts += cluster_count(i);
        }
    if (map_counts != expected_live || surviving_clusters != expected_clusters) {
        fprintf(stderr, "%s: cluster map count=%d/%d expected=%d/%d\n", name,
                map_counts, surviving_clusters, expected_live, expected_clusters);
        return -1;
    }
    printf("board scenario %-18s result=0 live=%d clusters=%d allocations=0\n",
           name, expected_live, expected_clusters);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc != 2 || load_blob(argv[1]) || collect_cpus()) {
        fprintf(stderr, "board handoff: failed to load 32-CPU board DT\n");
        return 2;
    }
    int aic = fdt_node_offset_by_compatible(dt, -1, "apple,t8122-aic3");
    if (aic < 0 || fdt_path_offset(dt, "/cpus/cpu-map") < 0 ||
        cluster_count(0) != 4 || cluster_count(1) != 6 || cluster_count(2) != 6 ||
        cluster_count(3) != 4 || cluster_count(4) != 6 || cluster_count(5) != 6) {
        fprintf(stderr, "board handoff: six-cluster/AIC3 DT inventory mismatch\n");
        return 3;
    }
    printf("board inventory CPUs=%d clusters=[4,6,6,4,6,6] AIC=t8122-aic3 fallback\n",
           test_cpu_count);

    int result = 0;
    result |= run_case("alive32", -1, -1, -1, 32, 6);
    /* Re-load between cases: dt_set_cpus intentionally mutates the blob. */
    free(dt); dt = NULL; if (load_blob(argv[1]) || collect_cpus()) return 4;
    result |= run_case("dead-cpu24", 24, -1, -1, 31, 6);
    free(dt); dt = NULL; if (load_blob(argv[1]) || collect_cpus()) return 4;
    result |= run_case("dead-cluster5", -1, 5, -1, 26, 5);
    free(dt); dt = NULL; if (load_blob(argv[1]) || collect_cpus()) return 4;
    result |= run_case("mismatch-cpu7", -1, -1, 7, 0, -1);
    free(dt); dt = NULL;
    return result ? 1 : 0;
}

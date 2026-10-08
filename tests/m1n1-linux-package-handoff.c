/* Host-only package handoff fixture.
 * The runner inserts the exact retained m1n1 kboot_set_initrd(),
 * dt_set_chosen(), dt_set_memory(), and dt_set_cpus() bodies.  SMP/physical
 * addresses, ADT, and firmware callbacks are explicit synthetic fixtures; no
 * native or MMIO work is performed here.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libfdt.h"

typedef uint8_t u8;
typedef uint32_t u32;
typedef unsigned long u64;
_Static_assert(sizeof(u64) == 8, "fixture requires LP64 u64 ABI");

#define MAX_CPUS 32
#define MAX_EL3_CPUS 4
#define SECONDARY_STACK_SIZE 0x10000
#define MPIDR_EL1 0
#define MAX_CHOSEN_PARAMS 4
#define MOCK_RAM_BASE UINT64_C(0x10000000000)
#define MOCK_RAM_SIZE UINT64_C(0x400000000)
#define MOCK_LINUX_WINDOW_SIZE UINT64_C(0x40000000)
#define MOCK_IMAGE_BASE (MOCK_RAM_BASE + UINT64_C(0x02000000))
#define MOCK_IMAGE_SPAN UINT64_C(44040192)
#define MOCK_INITRD_BASE (MOCK_RAM_BASE + UINT64_C(0x08000000))

static void *dt;
static void *initrd_start;
static size_t initrd_size;
static bool is_mac;
static const char m1n1_version[] = "fixture-m1n1";
static struct {
    const char *iboot;
    const char *string;
} system_firmware = { "fixture-iboot1", "fixture-system" },
  os_firmware = { "fixture-iboot2", "fixture-os" };
struct cpu_features_fixture {
    bool apple_sysregs_unlocked;
};
static struct cpu_features_fixture cpu_features_fixture = { true };
static const char *chosen_params[MAX_CHOSEN_PARAMS][2] = {
    { "bootargs", "earlycon console=ttySAC0 rdinit=/init" },
    { NULL, NULL },
};
static const struct cpu_features_fixture *cpu_features = &cpu_features_fixture;

static u64 current_mpidr;
static u64 test_mpidrs[MAX_CPUS];
static u64 test_release[MAX_CPUS];
static bool test_alive[MAX_CPUS];
static int test_cpu_count;
static char test_cpu_names[MAX_CPUS][32];
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

#define bail(...)                                                                    \
    do {                                                                             \
        fprintf(stderr, __VA_ARGS__);                                                \
        return -1;                                                                   \
    } while (0)
#define bail_cleanup(...)                                                            \
    do {                                                                             \
        fprintf(stderr, __VA_ARGS__);                                                \
        ret = -1;                                                                    \
        goto err;                                                                    \
    } while (0)

static u64 test_mrs(unsigned reg)
{
    (void)reg;
    return current_mpidr;
}

#define mrs(reg) test_mrs(reg)

static bool smp_is_alive(int cpu)
{
    return cpu >= 0 && cpu < test_cpu_count && test_alive[cpu];
}

static u64 smp_get_mpidr(int cpu)
{
    return test_mpidrs[cpu];
}

static u64 smp_get_release_addr(int cpu)
{
    return test_release[cpu];
}

/* The selected kboot source reaches these callbacks from dt_set_chosen().
 * Their return values model a valid loader with no framebuffer or seed error.
 */
static int dt_set_fb(void) { return 0; }
static int dt_set_rng_seed_sep(int node) { (void)node; return 0; }
static int dt_set_rng_seed_adt(int node) { (void)node; return 0; }

/* Explicit synthetic ADT provider for the exact fields read by
 * dt_set_memory(): /chosen, dram-base, and dram-size. */
struct fake_adt {
    u64 dram_base;
    u64 dram_size;
};
static struct fake_adt adt_fixture;
static void *adt = &adt_fixture;
static struct {
    u64 phys_base;
    u64 mem_size;
} cur_boot_args;
static u64 mem_size_actual;
static int memory_adt_calls;
#define MAX_MEM_REGIONS 16

static int adt_path_offset(void *tree, const char *path)
{
    memory_adt_calls++;
    return tree == adt && !strcmp(path, "/chosen") ? 1 : -1;
}

static int fake_adt_getprop(void *tree, int node, const char *name, u64 *value)
{
    memory_adt_calls++;
    if (tree != adt || node != 1 || !value)
        return -1;
    if (!strcmp(name, "dram-base")) {
        *value = adt_fixture.dram_base;
        return 0;
    }
    if (!strcmp(name, "dram-size")) {
        *value = adt_fixture.dram_size;
        return 0;
    }
    return -1;
}

#define ADT_GETPROP(tree, node, name, out) fake_adt_getprop((tree), (node), (name), (out))
static u64 get_page_size(void) { return 0x4000; }

/* INSERT_KBOOT_SET_INITRD */
/* INSERT_DT_SET_CHOSEN */
/* INSERT_DT_SET_MEMORY */

#define calloc tracked_calloc
#define free tracked_free
/* INSERT_DT_SET_CPUS */
#undef calloc
#undef free
#undef mrs

static int load_blob(const char *path)
{
    FILE *file = fopen(path, "rb");
    long length;
    void *input;

    if (!file || fseek(file, 0, SEEK_END) || (length = ftell(file)) <= 0) {
        if (file)
            fclose(file);
        return -1;
    }
    rewind(file);
    input = malloc((size_t)length);
    dt = calloc(2 * 1024 * 1024, 1);
    if (!input || !dt || fread(input, 1, (size_t)length, file) != (size_t)length ||
        fdt_open_into(input, dt, 2 * 1024 * 1024)) {
        free(input);
        fclose(file);
        return -1;
    }
    free(input);
    fclose(file);
    return 0;
}

static uint64_t hash_bytes(uint64_t hash, const void *data, size_t len)
{
    const uint8_t *bytes = data;
    for (size_t i = 0; i < len; i++)
        hash = (hash ^ bytes[i]) * UINT64_C(1099511628211);
    return hash;
}

static bool wanted_label(const char *label)
{
    static const char *const labels[] = {
        "ans_die1", "apcie_sys_st_die1", "apcie_sys_st1_die1",
        "apcie_st_die1", "afnc3_lw1_die1", "afnc3_ls_die1",
        "afnc3_ioa_die1",
    };
    for (size_t i = 0; i < sizeof(labels) / sizeof(labels[0]); i++)
        if (!strcmp(label, labels[i]))
            return true;
    return false;
}

static uint64_t graph_hash(int *nvme, int *mailbox, int *sart, int *pmgr)
{
    static const char *const props[] = {
        "compatible", "reg", "reg-names", "mboxes", "apple,sart",
        "power-domains", "power-domain-names", "resets", "label", "status",
        "#reset-cells", "#power-domain-cells", "phandle",
    };
    uint64_t hash = UINT64_C(1469598103934665603);
    int depth = 0;

    *nvme = *mailbox = *sart = *pmgr = 0;
    for (int node = fdt_next_node(dt, -1, &depth); node >= 0;
         node = fdt_next_node(dt, node, &depth)) {
        const char *name = fdt_get_name(dt, node, NULL);
        int len;
        const char *label = fdt_getprop(dt, node, "label", &len);
        bool selected = strstr(name, "nvme@") || !strcmp(name, "mbox@349408000") ||
                        !strcmp(name, "sart@34dc50000") || strstr(name, "power-controller@");
        if (strstr(name, "nvme@")) (*nvme)++;
        if (!strcmp(name, "mbox@349408000")) (*mailbox)++;
        if (!strcmp(name, "sart@34dc50000")) (*sart)++;
        if (label && wanted_label(label)) (*pmgr)++;
        if (!selected)
            continue;
        hash = hash_bytes(hash, name, strlen(name) + 1);
        for (size_t i = 0; i < sizeof(props) / sizeof(props[0]); i++) {
            const void *value = fdt_getprop(dt, node, props[i], &len);
            if (!value)
                continue;
            hash = hash_bytes(hash, props[i], strlen(props[i]) + 1);
            hash = hash_bytes(hash, value, (size_t)len);
        }
    }
    return hash;
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
        int len;
        const fdt64_t *reg;
        if (strncmp(name, "cpu@", 4))
            continue;
        if (test_cpu_count == MAX_CPUS)
            return -1;
        reg = fdt_getprop(dt, node, "reg", &len);
        if (!reg || len < (int)sizeof(*reg) || !fdt_get_phandle(dt, node))
            return -1;
        snprintf(test_cpu_names[test_cpu_count], sizeof(test_cpu_names[0]), "%s", name);
        test_mpidrs[test_cpu_count] = fdt64_ld(reg);
        test_release[test_cpu_count] = MOCK_RAM_BASE + UINT64_C(0x101000) +
                                       (u64)test_cpu_count * 0x1000;
        test_alive[test_cpu_count] = true;
        stack_tokens[test_cpu_count] = 0;
        test_cpu_count++;
    }
    return test_cpu_count == MAX_CPUS ? 0 : -1;
}

static int validate_cpus(void)
{
    for (int i = 0; i < test_cpu_count; i++) {
        char path[96];
        int len;
        const fdt64_t *release;
        snprintf(path, sizeof(path), "/cpus/%s", test_cpu_names[i]);
        int node = fdt_path_offset(dt, path);
        if (node < 0)
            return -1;
        release = fdt_getprop(dt, node, "cpu-release-addr", &len);
        if (!release || len != (int)sizeof(*release) ||
            fdt64_ld(release) != (i == 0 ? 0 : test_release[i]))
            return -1;
    }
    return 0;
}

static int validate_chosen(u64 physical_start, size_t physical_size, int base_rsv)
{
    int chosen = fdt_path_offset(dt, "/chosen");
    int len;
    const char *bootargs;
    const fdt64_t *start, *end;
    uint64_t address, size;
    bool found = false;

    if (chosen < 0)
        return -1;
    bootargs = fdt_getprop(dt, chosen, "bootargs", &len);
    start = fdt_getprop(dt, chosen, "linux,initrd-start", &len);
    end = fdt_getprop(dt, chosen, "linux,initrd-end", &len);
    if (!bootargs || strcmp(bootargs, chosen_params[0][1]) || !start || !end ||
        fdt64_ld(start) != physical_start || fdt64_ld(end) != physical_start + physical_size)
        return -1;
    for (int i = 0; i < fdt_num_mem_rsv(dt); i++) {
        if (fdt_get_mem_rsv(dt, i, &address, &size) == 0 && address == physical_start &&
            size == physical_size)
            found = true;
    }
    return found && fdt_num_mem_rsv(dt) == base_rsv + 1 ? 0 : -1;
}

static int validate_memory(u64 base, u64 size)
{
    int node = fdt_path_offset(dt, "/memory");
    int len;
    const fdt64_t *reg = fdt_getprop(dt, node, "reg", &len);
    return (node >= 0 && reg && len == (int)(2 * sizeof(*reg)) && fdt64_ld(&reg[0]) == base &&
            fdt64_ld(&reg[1]) == size && size != UINT64_C(0x200000000)) ? 0 : -1;
}

static int validate_mock_layout(u64 ram_base, u64 ram_size, u64 image_base,
                                u64 image_span, u64 initrd_base, size_t initrd_span)
{
    u64 ram_end = ram_base + ram_size;
    u64 image_end = image_base + image_span;
    u64 initrd_end = initrd_base + initrd_span;

    if (image_base < ram_base || image_end > ram_end || initrd_base < ram_base ||
        initrd_end > ram_end || image_end > initrd_base ||
        ((image_base ^ initrd_base) & ~(MOCK_LINUX_WINDOW_SIZE - 1)))
        return -1;
    for (int i = 1; i < test_cpu_count; i++)
        if (test_release[i] < ram_base || test_release[i] + sizeof(u64) > ram_end)
            return -1;
    return 0;
}

static int save_blob(const char *path)
{
    FILE *file;
    size_t size = fdt_totalsize(dt);
    file = fopen(path, "wb");
    if (!file || fwrite(dt, 1, size, file) != size) {
        if (file)
            fclose(file);
        return -1;
    }
    fclose(file);
    return 0;
}

int main(int argc, char **argv)
{
    const u64 physical_start = MOCK_INITRD_BASE;
    const u64 memory_base = MOCK_RAM_BASE;
    const u64 memory_size = MOCK_RAM_SIZE;
    size_t package_size;
    int base_rsv, nvme, mailbox, sart, pmgr;
    uint64_t graph_before, graph_after;

    if (argc != 5 || sscanf(argv[2], "%zu", &package_size) != 1 || !package_size)
        return 2;
    if (load_blob(argv[1]) || collect_cpus())
        return 3;
    base_rsv = fdt_num_mem_rsv(dt);
    graph_before = graph_hash(&nvme, &mailbox, &sart, &pmgr);
    if (nvme > 1 || mailbox > 1 || sart > 1 || pmgr != 7)
        return 4;
    chosen_params[0][1] = argv[4];
    if (validate_mock_layout(memory_base, memory_size, MOCK_IMAGE_BASE, MOCK_IMAGE_SPAN,
                             physical_start, package_size))
        return 4;
    current_mpidr = test_mpidrs[0];
    adt_fixture.dram_base = memory_base;
    adt_fixture.dram_size = memory_size;
    cur_boot_args.phys_base = memory_base;
    cur_boot_args.mem_size = memory_size;
    mem_size_actual = memory_size;
    memory_adt_calls = 0;
    kboot_set_initrd((void *)(uintptr_t)physical_start, package_size);
    if (dt_set_chosen() || dt_set_memory() || dt_set_cpus() ||
        memory_adt_calls < 3 || tracked_allocations ||
        validate_chosen(physical_start, package_size, base_rsv) ||
        validate_memory(memory_base, memory_size) || validate_cpus())
        return 5;
    graph_after = graph_hash(&nvme, &mailbox, &sart, &pmgr);
    if (graph_before != graph_after || pmgr != 7 || fdt_pack(dt) || save_blob(argv[3]))
        return 6;
    printf("PASS dtb=%s initrd_size=%zu chosen=1 initrd_reservation=1 memory=actual+synthetic-adt memory_adt_reads=%d cpu_release=32 graph_unchanged=1 nvme=%d mailbox=%d sart=%d pmgr_required=%d\n",
           argv[1], package_size, memory_adt_calls, nvme, mailbox, sart, pmgr);
    free(dt);
    return 0;
}

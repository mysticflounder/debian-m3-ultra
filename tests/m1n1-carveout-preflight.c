/* Host-only source-extracted T6032 carveout preflight tests. */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;
typedef unsigned long size_t;
#define T6032 0x6032
#define GENMASK(h, l) (((~0ULL) >> (63 - (h))) & (~0ULL << (l)))
#define ARRAY_SIZE(x) (sizeof(x) / sizeof((x)[0]))
/* INSERT_MCC_DEFS */

struct boot_args {
    u64 phys_base;
    u64 mem_size;
    u64 top_of_kernel_data;
};
struct mcc_carveout {
    u64 base;
    u64 size;
};
extern u64 ram_base, mem_size_actual;
extern struct boot_args cur_boot_args;
extern u32 chip_id;
extern bool mcc_initialized;
extern int mcc_count;
extern struct mcc_regs *mcc_regs;
extern struct mcc_carveout mcc_carveouts[PLANE_TZ_MAX_REGS + 1];
extern size_t mcc_carveout_count;
extern u64 mock_payload_start;
static u64 get_page_size(void);
static void *heapblock_get_cursor(void);
static void *heapblock_get_limit(void);
static void heapblock_set_limit(void *limit);
static u32 plane_read32(int mcc, int plane, u64 offset);
static void mmu_rm_mapping(u64 from, size_t size);
#define _base ((char *)(uintptr_t)(ram_base + 0x100000))
#define _payload_start ((char *)(uintptr_t)mock_payload_start)

/* Source fragment from the pinned, patched m1n1 tree. */
/* INSERT_MCC_SOURCE */

static u64 mock_page_size;
static u32 mock_start[PLANE_TZ_MAX_REGS], mock_end[PLANE_TZ_MAX_REGS];
static bool mock_enabled[PLANE_TZ_MAX_REGS];
static unsigned mock_reads, mock_removals, mock_heap_sets;
static u64 removed_start[PLANE_TZ_MAX_REGS * 4], removed_size[PLANE_TZ_MAX_REGS * 4];
static u64 mock_heap_cursor, mock_heap_limit;
u64 mock_payload_start;
u64 ram_base, mem_size_actual;
struct boot_args cur_boot_args;
u32 chip_id;

bool mcc_initialized;
int mcc_count;
static struct mcc_regs mcc_regs_storage[16];
struct mcc_regs *mcc_regs = mcc_regs_storage;
struct mcc_carveout mcc_carveouts[PLANE_TZ_MAX_REGS + 1];
size_t mcc_carveout_count;

static u64 get_page_size(void) { return mock_page_size; }
static void *heapblock_get_cursor(void) { return (void *)(uintptr_t)mock_heap_cursor; }
static void *heapblock_get_limit(void) { return (void *)(uintptr_t)mock_heap_limit; }
static void heapblock_set_limit(void *limit)
{ mock_heap_sets++; mock_heap_limit = (u64)(uintptr_t)limit; }

static u32 plane_read32(int mcc, int plane, u64 offset)
{
    if (mcc != 0 || plane != 0) abort();
    mock_reads++;
    for (u32 i = 0; i < PLANE_TZ_MAX_REGS; i++) {
        u64 off = mcc_regs[0].tz->stride * i;
        if (offset == mcc_regs[0].tz->start + off) return mock_start[i];
        if (offset == mcc_regs[0].tz->end + off) return mock_end[i];
        if (offset == mcc_regs[0].tz->enable + off) return mock_enabled[i];
    }
    fprintf(stderr, "unexpected plane read 0x%llx\n", (unsigned long long)offset);
    abort();
}

static void mmu_rm_mapping(u64 from, size_t size)
{
    if (mock_removals < ARRAY_SIZE(removed_start)) {
        removed_start[mock_removals] = from;
        removed_size[mock_removals] = size;
    }
    mock_removals++;
}

static void reset_fixture(u64 page_size)
{
    memset(mock_start, 0, sizeof(mock_start));
    memset(mock_end, 0, sizeof(mock_end));
    memset(mock_enabled, 0, sizeof(mock_enabled));
    memset(removed_start, 0, sizeof(removed_start));
    memset(removed_size, 0, sizeof(removed_size));
    mock_reads = mock_removals = mock_heap_sets = 0;
    mock_page_size = page_size;
    ram_base = 0x800000000ULL;
    mem_size_actual = 0x20000000ULL;
    mock_heap_cursor = ram_base + 0x1000000;
    mock_heap_limit = ram_base + 0x1f000000;
    mock_payload_start = ram_base + 0x180000;
    cur_boot_args.phys_base = ram_base;
    cur_boot_args.mem_size = mem_size_actual;
    cur_boot_args.top_of_kernel_data = ram_base + 0x1000000;
    chip_id = T6032;
    mcc_initialized = true;
    mcc_count = T6032_MCC_INSTANCE_COUNT;
    memset(mcc_regs_storage, 0, sizeof(mcc_regs_storage));
    mcc_regs[0].tz = &t6031_tz_regs;
    mcc_carveout_count = 0;
    memset(mcc_carveouts, 0, sizeof(mcc_carveouts));
}

#define CHECK(test) do { if (!(test)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #test); return 1; } } while (0)

static int expect_failure_no_effects_alias(u64 alias_size)
{
    u64 old_limit = mock_heap_limit;
    for (u32 i = 0; i < ARRAY_SIZE(mcc_carveouts); i++) {
        mcc_carveouts[i].base = 0xdeadbeef + i;
        mcc_carveouts[i].size = 0xbeef + i;
    }
    mcc_carveout_count = ARRAY_SIZE(mcc_carveouts);
    CHECK(mcc_unmap_carveouts_t6032(alias_size) < 0);
    CHECK(mock_reads <= PLANE_TZ_MAX_REGS * 3 && mock_removals == 0 && mock_heap_sets == 0);
    CHECK(mcc_carveout_count == 0 && mock_heap_limit == old_limit);
    for (u32 i = 0; i < ARRAY_SIZE(mcc_carveouts); i++)
        CHECK(!mcc_carveouts[i].base && !mcc_carveouts[i].size);
    return 0;
}

static int expect_failure_no_effects(void)
{
    return expect_failure_no_effects_alias(mem_size_actual);
}

int main(void)
{
    /* The runner fails closed if the patch changes helper signatures/source shape. */
    reset_fixture(4096);
    mock_start[0] = 0x1000; mock_end[0] = 0x1003; mock_enabled[0] = true;
    CHECK(mcc_unmap_carveouts_t6032(mem_size_actual) == 0);
    CHECK(mock_reads == 12 && mock_removals == 4 && mcc_carveout_count == 1);
    CHECK(mock_heap_sets == 1 && mock_heap_limit == ram_base + 0x1000000);
    CHECK(removed_start[0] == ram_base + 0x1000000 &&
          removed_start[1] == ((ram_base + 0x1000000) | REGION_RWX_EL0) &&
          removed_start[2] == ((ram_base + 0x1000000) | REGION_RW_EL0) &&
          removed_start[3] == ((ram_base + 0x1000000) | REGION_RX_EL1));
    for (u32 i = 0; i < 4; i++) CHECK(removed_size[i] == 0x4000);
    CHECK(mcc_carveouts[0].base == ram_base + 0x1000000 &&
          mcc_carveouts[0].size == 0x4000);
    for (u32 i = 1; i < ARRAY_SIZE(mcc_carveouts); i++)
        CHECK(!mcc_carveouts[i].base && !mcc_carveouts[i].size);

    reset_fixture(4096);
    mock_start[0] = 0x1000; mock_end[0] = 0x1003; mock_enabled[0] = true;
    CHECK(expect_failure_no_effects_alias(0) == 0);
    reset_fixture(4096);
    mock_start[0] = 0x1000; mock_end[0] = 0x1003; mock_enabled[0] = true;
    CHECK(expect_failure_no_effects_alias(0x2001) == 0);
    reset_fixture(4096);
    mock_start[0] = 0x1000; mock_end[0] = 0x1003; mock_enabled[0] = true;
    CHECK(expect_failure_no_effects_alias(mem_size_actual + 0x1000) == 0);
    reset_fixture(4096);
    mock_start[0] = 0x1000; mock_end[0] = 0x1003; mock_enabled[0] = true;
    CHECK(mcc_unmap_carveouts_t6032(0x1000) == 0 && mock_removals == 1 &&
          removed_size[0] == 0x4000);
    reset_fixture(4096);
    mock_start[0] = 0x1000; mock_end[0] = 0x1003; mock_enabled[0] = true;
    CHECK(mcc_unmap_carveouts_t6032(0x1002000) == 0 && mock_removals == 4 &&
          removed_start[0] == ram_base + 0x1000000 &&
          removed_start[1] == ((ram_base + 0x1000000) | REGION_RWX_EL0) &&
          removed_size[0] == 0x4000 && removed_size[1] == 0x2000 &&
          removed_size[2] == 0x2000 && removed_size[3] == 0x2000);

    u64 mapped_start = 0, mapped_end = 0;
    CHECK(mcc_t6032_or_range(0x2000, 0x6000, 0, &mapped_start, &mapped_end));
    CHECK(mapped_start == 0x2000 && mapped_end == 0x6000);
    CHECK(!mcc_t6032_or_range(0, 0x2000, 0x1000, &mapped_start, &mapped_end));
    CHECK(!mcc_t6032_or_range(0x0, REGION_RWX_EL0 + 0x1000, REGION_RWX_EL0,
                              &mapped_start, &mapped_end));

    reset_fixture(16384);
    mock_start[0] = 0x1000; mock_end[0] = 0x1003; mock_enabled[0] = true;
    CHECK(mcc_unmap_carveouts_t6032(mem_size_actual) == 0);
    CHECK(mock_removals == 4 && removed_size[0] == 0x4000);

    reset_fixture(16384);
    mock_start[0] = 0x1001; mock_end[0] = 0x1004; mock_enabled[0] = true;
    CHECK(expect_failure_no_effects() == 0);
    reset_fixture(4096);
    mock_start[0] = 0x100; mock_end[0] = 0x103; mock_enabled[0] = true;
    CHECK(expect_failure_no_effects() == 0); /* linked image */
    reset_fixture(4096);
    mock_start[0] = 0xf00; mock_end[0] = 0x1100; mock_enabled[0] = true;
    CHECK(expect_failure_no_effects() == 0); /* allocated kernel/heap */
    reset_fixture(4096);
    mock_start[0] = 0x2000; mock_end[0] = 0x1fff; mock_enabled[0] = true;
    CHECK(expect_failure_no_effects() == 0);
    reset_fixture(4096);
    mock_start[0] = 0; mock_end[0] = 3; mock_enabled[0] = true;
    CHECK(expect_failure_no_effects() == 0);
    reset_fixture(4096);
    mock_start[0] = 0x1000; mock_end[0] = 0x1000; mock_enabled[0] = true;
    CHECK(expect_failure_no_effects() == 0);
    reset_fixture(4096);
    mock_start[0] = UINT32_MAX - 1; mock_end[0] = UINT32_MAX; mock_enabled[0] = true;
    CHECK(expect_failure_no_effects() == 0);
    reset_fixture(8192);
    mock_start[0] = 0x1000; mock_end[0] = 0x1003; mock_enabled[0] = true;
    CHECK(expect_failure_no_effects() == 0);
    reset_fixture(4096);
    mem_size_actual = 0;
    CHECK(expect_failure_no_effects() == 0);
    reset_fixture(4096);
    mock_heap_limit = mock_heap_cursor - 1;
    CHECK(expect_failure_no_effects() == 0);
    reset_fixture(4096);
    ram_base = UINT64_MAX - 0x1000;
    CHECK(expect_failure_no_effects() == 0);
    reset_fixture(4096);
    ram_base |= 1;
    CHECK(expect_failure_no_effects() == 0);
    reset_fixture(4096);
    mock_payload_start = mock_heap_cursor + 1;
    CHECK(expect_failure_no_effects() == 0);
    reset_fixture(4096);
    mock_heap_cursor = cur_boot_args.top_of_kernel_data - 1;
    CHECK(expect_failure_no_effects() == 0);
    reset_fixture(4096);
    mcc_initialized = false;
    CHECK(expect_failure_no_effects() == 0);
    reset_fixture(4096);
    mcc_count = 0;
    CHECK(expect_failure_no_effects() == 0);
    reset_fixture(4096);
    mcc_regs[0].tz = NULL;
    CHECK(expect_failure_no_effects() == 0);
    reset_fixture(4096);
    chip_id = 0x6031;
    CHECK(expect_failure_no_effects() == 0);

    reset_fixture(4096);
    mock_start[0] = 0x1000; mock_end[0] = 0x1003; mock_enabled[0] = true;
    mock_start[1] = 0x1002; mock_end[1] = 0x1005; mock_enabled[1] = true;
    CHECK(expect_failure_no_effects() == 0);

    reset_fixture(4096);
    mock_enabled[0] = mock_enabled[1] = mock_enabled[2] = mock_enabled[3] = false;
    CHECK(mcc_unmap_carveouts_t6032(mem_size_actual) == 0 && mock_removals == 0 && mcc_carveout_count == 0);

    reset_fixture(4096);
    mem_size_actual = 0x10000000;
    mock_heap_limit = ram_base + 0xf000000;
    for (u32 i = 0; i < 4; i++) {
        mock_start[i] = 0x2000 + i * 0x1000;
        mock_end[i] = mock_start[i] + 3;
        mock_enabled[i] = true;
    }
    CHECK(mcc_unmap_carveouts_t6032(mem_size_actual) == 0 && mock_removals == 16 && mcc_carveout_count == 4);
    for (u32 i = 0; i < 4; i++) {
        CHECK(mcc_carveouts[i].base == ram_base + ((u64)mock_start[i] << 12));
        CHECK(mcc_carveouts[i].size == 0x4000);
    }
    CHECK(!mcc_carveouts[4].base && !mcc_carveouts[4].size);
    CHECK(mock_heap_limit == ram_base + 0x2000000);

    reset_fixture(4096);
    mock_start[0] = 0x1000; mock_end[0] = 0x1003; mock_enabled[0] = true;
    CHECK(mcc_unmap_carveouts() < 0 && mock_removals == 0 && mock_heap_sets == 0);

    reset_fixture(4096);
    chip_id = 0x6031;
    mock_start[0] = 0x1000; mock_end[0] = 0x1003; mock_enabled[0] = true;
    CHECK(mcc_unmap_carveouts() == 0 && mock_removals == 4 && mock_heap_sets == 0);

    reset_fixture(4096);
    mock_start[0] = 0x1000; mock_end[0] = 0x1003; mock_enabled[0] = true;
    mock_start[1] = 0x1200; mock_end[1] = 0x1203; mock_enabled[1] = true;
    mem_size_actual = 0x1200000;
    CHECK(expect_failure_no_effects() == 0);

    puts("T6032 carveout preflight tests passed: granules, alias clipping, OR bounds, overlap, heap/image guards, late failure, no-effects");
    return 0;
}

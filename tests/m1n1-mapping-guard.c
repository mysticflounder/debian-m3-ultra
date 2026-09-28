/* Host-only source-extracted T6032 mapping guard tests. */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <setjmp.h>
#include <string.h>

typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;
typedef unsigned long size_t;
#define T6032 0x6032
#define ARRAY_SIZE(x) (sizeof(x) / sizeof((x)[0]))
#define BIT(x) (1ULL << (x))
#define MASK(x) (BIT(x) - 1)
#define ALIGN_UP(x, a) (((x) + ((a) - 1)) & ~((a) - 1))
#define ALIGN_DOWN(x, a) ((x) & ~((a) - 1))
#define min(a, b) ((a) < (b) ? (a) : (b))
#define GENMASK(h, l) (((~0ULL) >> (63 - (h))) & (~0ULL << (l)))
#define PTE_MAIR_IDX(i) ((i & 7) << 2)
#define UNUSED(x) ((void)(x))
void mmu_add_mapping(u64, u64, size_t, u8, u64);

/* INSERT_GUARD_DEFS */

struct mcc_carveout { u64 base; u64 size; };
struct boot_args {
    u64 phys_base;
    u64 mem_size;
    u64 top_of_kernel_data;
};
extern u64 ram_base;
extern u64 mem_size_actual;
extern struct boot_args cur_boot_args;
extern u32 chip_id;
extern bool mcc_carveouts_ready;
extern size_t mcc_carveout_count;
extern struct mcc_carveout mcc_carveouts[5];
extern u64 mock_page_size;
extern bool mcc_initialized;
extern int mcc_count;
extern struct mcc_regs mcc_regs[16];
extern u64 mock_payload_start;
static u64 get_page_size(void);
static bool is_16k(void);
static void *heapblock_get_cursor(void);
static void *heapblock_get_limit(void);
static void heapblock_set_limit(void *);
static u32 plane_read32(int, int, u64);
static void mmu_rm_mapping(u64, size_t);
static void mmu_pt_map_l1(u64, u64, u64);
static void mmu_pt_map_l2(u64, u64, u64);
static void mmu_pt_map_l3(u64, u64, u64);
static void dc_civac_range(void *, size_t);
static void sysop(const char *operation);
static void panic(const char *message, ...);
#define _base ((char *)(uintptr_t)(ram_base + 0x100000))
#define _payload_start ((char *)(uintptr_t)mock_payload_start)

/* INSERT_GUARD_SOURCE */

u64 ram_base;
u64 mem_size_actual;
struct boot_args cur_boot_args;
u32 chip_id;
bool mcc_carveouts_ready;
size_t mcc_carveout_count;
struct mcc_carveout mcc_carveouts[5];
u64 mock_page_size;
bool mcc_initialized;
int mcc_count;
struct mcc_regs mcc_regs[16];
u64 mock_payload_start;
struct tz_regs *test_tz = &t6031_tz_regs;
static unsigned page_effects, map_calls, cache_effects, remove_effects, panic_count;
static unsigned heap_limit_sets, tz_reads;
static u64 mock_heap_cursor, mock_heap_limit;
#define TEST_TZ_PLANES 4
static u32 mock_tz_start_ctx[16][TEST_TZ_PLANES][PLANE_TZ_MAX_REGS];
static u32 mock_tz_end_ctx[16][TEST_TZ_PLANES][PLANE_TZ_MAX_REGS];
static bool mock_tz_enabled_ctx[16][TEST_TZ_PLANES][PLANE_TZ_MAX_REGS];
static u8 mock_tz_override[16][TEST_TZ_PLANES][PLANE_TZ_MAX_REGS];
#define mock_tz_start mock_tz_start_ctx[0][0]
#define mock_tz_end mock_tz_end_ctx[0][0]
#define mock_tz_enabled mock_tz_enabled_ctx[0][0]
static unsigned tz_read_log[1024];
static u64 removed_base[PLANE_TZ_MAX_REGS * 4], removed_size[PLANE_TZ_MAX_REGS * 4];
static bool mock_16k;
static jmp_buf panic_env;
static bool panic_catch;

static u64 get_page_size(void) { return mock_page_size; }
static bool is_16k(void) { return mock_16k; }
static void *heapblock_get_cursor(void) { return (void *)(uintptr_t)mock_heap_cursor; }
static void *heapblock_get_limit(void) { return (void *)(uintptr_t)mock_heap_limit; }
static void heapblock_set_limit(void *limit) { mock_heap_limit = (u64)(uintptr_t)limit; heap_limit_sets++; }
static u32 plane_read32(int mcc, int plane, u64 offset)
{
    if (mcc < 0 || mcc >= 16 || plane < 0 || plane >= TEST_TZ_PLANES || !mcc_regs[mcc].tz)
        abort();
    tz_reads++;
    for (unsigned i = 0; i < PLANE_TZ_MAX_REGS; i++) {
        u64 off = (u64)mcc_regs[mcc].tz->stride * i;
        u8 override = mock_tz_override[mcc][plane][i];
        if (offset == mcc_regs[mcc].tz->start + off) {
            if (tz_reads <= ARRAY_SIZE(tz_read_log))
                tz_read_log[tz_reads - 1] = ((mcc * TEST_TZ_PLANES + plane) *
                    PLANE_TZ_MAX_REGS + i) * 3;
            return (override & 1) ? mock_tz_start_ctx[mcc][plane][i] : mock_tz_start[i];
        }
        if (offset == mcc_regs[mcc].tz->end + off) {
            if (tz_reads <= ARRAY_SIZE(tz_read_log))
                tz_read_log[tz_reads - 1] = ((mcc * TEST_TZ_PLANES + plane) *
                    PLANE_TZ_MAX_REGS + i) * 3 + 1;
            return (override & 2) ? mock_tz_end_ctx[mcc][plane][i] : mock_tz_end[i];
        }
        if (offset == mcc_regs[mcc].tz->enable + off) {
            if (tz_reads <= ARRAY_SIZE(tz_read_log))
                tz_read_log[tz_reads - 1] = ((mcc * TEST_TZ_PLANES + plane) *
                    PLANE_TZ_MAX_REGS + i) * 3 + 2;
            return (override & 4) ? mock_tz_enabled_ctx[mcc][plane][i] : mock_tz_enabled[i];
        }
    }
    abort();
}
static void mmu_rm_mapping(u64 address, size_t size)
{
    if (remove_effects < ARRAY_SIZE(removed_base)) {
        removed_base[remove_effects] = address;
        removed_size[remove_effects] = size;
    }
    remove_effects++;
}
static void mmu_pt_map_l1(u64 from, u64 to, u64 size)
{ (void)from; (void)to; (void)size; page_effects++; }
static void mmu_pt_map_l2(u64 from, u64 to, u64 size)
{ (void)from; (void)to; (void)size; page_effects++; }
static void mmu_pt_map_l3(u64 from, u64 to, u64 size)
{ (void)from; (void)to; (void)size; page_effects++; }
static void dc_civac_range(void *address, size_t size)
{ (void)address; (void)size; cache_effects++; }
static void sysop(const char *operation) { (void)operation; }
static void panic(const char *message, ...)
{ (void)message; panic_count++; if (panic_catch) longjmp(panic_env, 1); abort(); }

static bool expect_add_panic(u64 from, u64 to, size_t size)
{
    panic_catch = true;
    if (setjmp(panic_env) == 0)
        mmu_add_mapping(from, to, size, MAIR_IDX_NORMAL, PERM_RWX);
    panic_catch = false;
    return panic_count == 1 && !page_effects;
}

static bool expect_framebuffer_panic(u64 addr, size_t size)
{
    panic_catch = true;
    if (setjmp(panic_env) == 0)
        mmu_map_framebuffer(addr, size);
    panic_catch = false;
    return panic_count == 1 && !page_effects && !cache_effects;
}

static void reset_fixture(void)
{
    ram_base = 0x10000000000ULL;
    chip_id = T6032;
    mock_page_size = 4096;
    mock_16k = false;
    page_effects = map_calls = cache_effects = remove_effects = panic_count = 0;
    heap_limit_sets = tz_reads = 0;
    mcc_carveouts_ready = false;
    mcc_carveout_count = 0;
    memset(mcc_carveouts, 0, sizeof(mcc_carveouts));
    mem_size_actual = 0x20000000;
    cur_boot_args.phys_base = ram_base;
    cur_boot_args.top_of_kernel_data = ram_base + 0x1000000;
    mock_payload_start = ram_base + 0x180000;
    mock_heap_cursor = ram_base + 0x1800000;
    mock_heap_limit = ram_base + 0x1f000000;
    mcc_initialized = true;
    mcc_count = T6032_MCC_INSTANCE_COUNT;
    memset(mcc_regs, 0, sizeof(mcc_regs));
    for (unsigned i = 0; i < 16; i++) {
        mcc_regs[i].tz = &t6031_tz_regs;
        mcc_regs[i].plane_count = TEST_TZ_PLANES;
        mcc_regs[i].plane_stride = T6031_PLANE_STRIDE;
    }
    memset(mock_tz_start_ctx, 0, sizeof(mock_tz_start_ctx));
    memset(mock_tz_end_ctx, 0, sizeof(mock_tz_end_ctx));
    memset(mock_tz_enabled_ctx, 0, sizeof(mock_tz_enabled_ctx));
    memset(mock_tz_override, 0, sizeof(mock_tz_override));
    memset(tz_read_log, 0, sizeof(tz_read_log));
    memset(removed_base, 0, sizeof(removed_base));
    memset(removed_size, 0, sizeof(removed_size));
}

static void override_tz_context(unsigned mcc, unsigned plane, unsigned slot,
                                u32 first, u32 last, bool enabled, u8 fields)
{
    if (mcc >= 16 || plane >= TEST_TZ_PLANES || slot >= PLANE_TZ_MAX_REGS)
        abort();
    mock_tz_start_ctx[mcc][plane][slot] = first;
    mock_tz_end_ctx[mcc][plane][slot] = last;
    mock_tz_enabled_ctx[mcc][plane][slot] = enabled;
    mock_tz_override[mcc][plane][slot] = fields;
}

static void publish_one(u64 base, u64 size)
{
    mcc_carveouts[0].base = base;
    mcc_carveouts[0].size = size;
    mcc_carveout_count = 1;
    mcc_carveouts_ready = true;
}

static bool published_state_zero(void)
{
    if (mcc_carveout_count != 0)
        return false;
    for (unsigned i = 0; i < ARRAY_SIZE(mcc_carveouts); i++)
        if (mcc_carveouts[i].base || mcc_carveouts[i].size)
            return false;
    return true;
}

#define CHECK(test) do { if (!(test)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #test); return 1; } } while (0)
static void configure_one_tz(void);

static int check_complete_tz_read_log(void)
{
    unsigned seen[16][TEST_TZ_PLANES][PLANE_TZ_MAX_REGS][3] = {0};
    CHECK(tz_reads == 16 * TEST_TZ_PLANES * PLANE_TZ_MAX_REGS * 3);
    for (unsigned n = 0; n < tz_reads; n++) {
        unsigned key = tz_read_log[n];
        unsigned slot = (key / 3) % PLANE_TZ_MAX_REGS;
        unsigned context = key / (PLANE_TZ_MAX_REGS * 3);
        unsigned plane = context % TEST_TZ_PLANES;
        unsigned mcc = context / TEST_TZ_PLANES;
        CHECK(mcc < 16 && plane < TEST_TZ_PLANES && key % 3 < 3);
        seen[mcc][plane][slot][key % 3]++;
    }
    for (unsigned mcc = 0; mcc < 16; mcc++)
        for (unsigned plane = 0; plane < TEST_TZ_PLANES; plane++)
            for (unsigned slot = 0; slot < PLANE_TZ_MAX_REGS; slot++)
                for (unsigned field = 0; field < 3; field++)
                    CHECK(seen[mcc][plane][slot][field] == 1);
    return 0;
}

static int test_tz_consistency_matrix(void)
{
    for (unsigned granule = 0; granule < 2; granule++) {
        reset_fixture();
        mock_page_size = granule ? 16384 : 4096;
        mock_16k = granule;
        configure_one_tz();
        CHECK(mcc_unmap_carveouts_t6032(mem_size_actual) == 0);
        CHECK(check_complete_tz_read_log() == 0 && remove_effects == 4 &&
              heap_limit_sets == 1 && mcc_carveout_count == 1);
    }

    reset_fixture();
    configure_one_tz();
    override_tz_context(15, TEST_TZ_PLANES - 1, PLANE_TZ_MAX_REGS - 1,
                        0x3000, 0x3003, true, 4);
    CHECK(mcc_unmap_carveouts_t6032(mem_size_actual) < 0);
    CHECK(tz_reads == 16 * TEST_TZ_PLANES * PLANE_TZ_MAX_REGS * 3 &&
          remove_effects == 0 && heap_limit_sets == 0 && !mcc_carveouts_ready &&
          mcc_carveout_count == 0);

    reset_fixture();
    override_tz_context(15, TEST_TZ_PLANES - 1, PLANE_TZ_MAX_REGS - 1,
                        0xdead, 0xbeef, false, 3);
    CHECK(mcc_unmap_carveouts_t6032(mem_size_actual) == 0 &&
          tz_reads == 16 * TEST_TZ_PLANES * PLANE_TZ_MAX_REGS * 3 &&
          remove_effects == 0 && heap_limit_sets == 1 && mcc_carveout_count == 0);
    return 0;
}

static int test_tz_descriptor_rejection(void)
{
    for (unsigned variant = 0; variant < 3; variant++) {
        reset_fixture();
        if (variant == 0)
            mcc_regs[15].plane_count = 3;
        else if (variant == 1)
            mcc_regs[15].plane_stride = T6031_PLANE_STRIDE + 4;
        else
            mcc_regs[15].tz = NULL;
        CHECK(mcc_unmap_carveouts_t6032(mem_size_actual) < 0);
        CHECK(tz_reads == 0 && remove_effects == 0 && heap_limit_sets == 0 &&
              !mcc_carveouts_ready && mcc_carveout_count == 0);
    }
    return 0;
}

static void configure_one_tz(void)
{
    mock_tz_start[0] = 0x2000;
    mock_tz_end[0] = 0x2003;
    mock_tz_enabled[0] = true;
}

static int test_unmap_publication(void)
{
    reset_fixture();
    mcc_t6032_begin_carveout_setup();
    configure_one_tz();
    CHECK(mcc_unmap_carveouts_t6032(mem_size_actual) == 0);
    CHECK(mcc_carveouts_ready && mcc_carveout_count == 1);
    CHECK(mcc_carveouts[0].base == ram_base + 0x2000000 && mcc_carveouts[0].size == 0x4000);
    CHECK(tz_reads == 16 * TEST_TZ_PLANES * PLANE_TZ_MAX_REGS * 3 &&
          remove_effects == 4 && heap_limit_sets == 1);
    CHECK(removed_base[0] == ram_base + 0x2000000 && removed_size[0] == 0x4000);
    CHECK(removed_base[1] == (ram_base | REGION_RWX_EL0) + 0x2000000);
    CHECK(removed_base[2] == (ram_base | REGION_RW_EL0) + 0x2000000);
    CHECK(removed_base[3] == (ram_base | REGION_RX_EL1) + 0x2000000);
    unsigned reads = tz_reads, removals = remove_effects, limits = heap_limit_sets;
    CHECK(mcc_unmap_carveouts_t6032(mem_size_actual) < 0);
    CHECK(tz_reads == reads && remove_effects == removals && heap_limit_sets == limits);
    CHECK(mcc_carveouts_ready && mcc_carveout_count == 1 &&
          mcc_carveouts[0].base == ram_base + 0x2000000 &&
          mcc_carveouts[0].size == 0x4000);

    reset_fixture();
    mcc_t6032_begin_carveout_setup();
    configure_one_tz();
    mock_tz_start[1] = 0x2002;
    mock_tz_end[1] = 0x2005;
    mock_tz_enabled[1] = true;
    for (unsigned i = 0; i < ARRAY_SIZE(mcc_carveouts); i++) {
        mcc_carveouts[i].base = 0xdead0000 + i;
        mcc_carveouts[i].size = 0xbeef0000 + i;
    }
    CHECK(mcc_unmap_carveouts_t6032(mem_size_actual) < 0);
    CHECK(!mcc_carveouts_ready && published_state_zero());
    CHECK(remove_effects == 0 && heap_limit_sets == 0);

    reset_fixture();
    mcc_t6032_begin_carveout_setup();
    configure_one_tz();
    CHECK(mcc_unmap_carveouts_t6032(mem_size_actual) == 0);
    CHECK(mcc_carveouts_ready && mcc_carveout_count == 1);

    reset_fixture();
    mcc_t6032_begin_carveout_setup();
    CHECK(mcc_unmap_carveouts_t6032(mem_size_actual) == 0);
    CHECK(mcc_carveouts_ready && mcc_carveout_count == 0);
    CHECK(tz_reads == 16 * TEST_TZ_PLANES * PLANE_TZ_MAX_REGS * 3 &&
          remove_effects == 0 && heap_limit_sets == 1);

    reset_fixture();
    mcc_t6032_begin_carveout_setup();
    configure_one_tz();
    CHECK(mcc_unmap_carveouts_t6032(0x2002000) == 0);
    CHECK(mcc_carveout_count == 1 && remove_effects == 4);
    CHECK(removed_size[0] == 0x4000);
    for (unsigned i = 1; i < 4; i++) CHECK(removed_size[i] == 0x2000);

    reset_fixture();
    mcc_t6032_begin_carveout_setup();
    configure_one_tz();
    CHECK(mcc_unmap_carveouts_t6032(0x1000000) == 0);
    CHECK(mcc_carveouts_ready && remove_effects == 1 && removed_size[0] == 0x4000);

    reset_fixture();
    mcc_t6032_begin_carveout_setup();
    configure_one_tz();
    CHECK(mcc_unmap_carveouts_t6032(mem_size_actual + 0x1000) < 0);
    CHECK(!mcc_carveouts_ready && mcc_carveout_count == 0 && remove_effects == 0);

    reset_fixture();
    mcc_t6032_begin_carveout_setup();
    configure_one_tz();
    CHECK(mcc_unmap_carveouts_t6032(0x1001) < 0);
    CHECK(!mcc_carveouts_ready && mcc_carveout_count == 0 && tz_reads == 0);

    reset_fixture();
    mcc_t6032_begin_carveout_setup();
    mock_tz_start[0] = 0;
    mock_tz_end[0] = 0x2003;
    mock_tz_enabled[0] = true;
    CHECK(mcc_unmap_carveouts_t6032(mem_size_actual) < 0);
    CHECK(!mcc_carveouts_ready && mcc_carveout_count == 0 && remove_effects == 0);
    return 0;
}

int main(void)
{
    CHECK(test_tz_consistency_matrix() == 0);
    CHECK(test_tz_descriptor_rejection() == 0);
    CHECK(test_unmap_publication() == 0);
    reset_fixture();
    for (unsigned i = 0; i < ARRAY_SIZE(mcc_carveouts); i++) {
        mcc_carveouts[i].base = 0xdead + i;
        mcc_carveouts[i].size = 0xbeef + i;
    }
    mcc_carveout_count = 1; mcc_carveouts_ready = true;
    mcc_t6032_begin_carveout_setup();
    CHECK(!mcc_carveouts_ready && published_state_zero());
    CHECK(mcc_t6032_range_allowed(ram_base + 0x10000, 0x1000));

    publish_one(ram_base + 0x1000000, 0x4000);
    CHECK(!mcc_t6032_range_allowed(ram_base + 0x1000000, 0x1000));
    CHECK(!mcc_t6032_range_allowed(ram_base + 0x1001000, 0x4000));
    CHECK(mcc_t6032_range_allowed(ram_base + 0x1004000, 0x1000));
    CHECK(!mcc_t6032_range_allowed(UINT64_MAX - 0xfff, 0x2000));
    CHECK(mcc_t6032_range_allowed(ram_base, 0));

    mcc_carveouts[0].base = 0;
    CHECK(!mcc_t6032_range_allowed(ram_base, 0x1000));
    publish_one(ram_base + 0x1000000, 0x4000);
    mcc_carveout_count = PLANE_TZ_MAX_REGS + 1;
    CHECK(!mcc_t6032_range_allowed(ram_base, 0x1000));
    mcc_carveout_count = 1;
    mcc_carveouts[0].base = ram_base;
    mcc_carveouts[0].size = 1;
    CHECK(!mcc_t6032_range_allowed(ram_base + 0x1000, 0x1000));
    mcc_carveouts[0].base = UINT64_MAX - 0xfff;
    mcc_carveouts[0].size = 0x2000;
    CHECK(!mcc_t6032_range_allowed(ram_base + 0x1000, 0x1000));
    publish_one(ram_base + 0x1000000, 0x4000);
    CHECK(mmu_map(ram_base + 0x2000000,
                  (ram_base + 0x2000000) | PTE_ACCESS | PTE_VALID, 0x1000) == 0);
    CHECK(page_effects && !panic_count);

    page_effects = panic_count = 0;
    CHECK(mmu_map(ram_base + 0x2000000,
                  (ram_base + 0x1000000) | PTE_ACCESS | PTE_VALID, 0x1000) < 0 || panic_count);
    CHECK(!page_effects);

    page_effects = panic_count = 0;
    CHECK(mmu_map(BIT(48) - 0x1000,
                  (BIT(42) - 0x1000) | PTE_ACCESS | PTE_VALID, 0x1000) == 0);
    CHECK(page_effects && !panic_count);
    page_effects = panic_count = 0;
    CHECK(mmu_map(BIT(48) - 0x1000,
                  (BIT(42) - 0x1000) | PTE_ACCESS | PTE_VALID, 0x2000) < 0);
    CHECK(!page_effects);
    CHECK(mmu_map(0x200000, BIT(42) | PTE_ACCESS | PTE_VALID, 0x1000) < 0);
    CHECK(!page_effects);
    page_effects = panic_count = 0;
    CHECK(expect_add_panic(ram_base + 0x1000000, ram_base + 0x1000000, 0x1000));
    page_effects = panic_count = 0;
    CHECK(expect_add_panic((ram_base | REGION_RWX_EL0) + 0x1000000,
                           ram_base + 0x1000000, 0x1000));

    page_effects = panic_count = cache_effects = 0;
    CHECK(expect_framebuffer_panic(ram_base + 0x1000000, 0x1000));
    page_effects = panic_count = 0;
    CHECK(expect_add_panic(ram_base + 0x2000000, ram_base + 0x2000000, 1));

    mock_page_size = 16384; mock_16k = true; page_effects = panic_count = 0;
    CHECK(mmu_map(ram_base + 0x2000000,
                  (ram_base + 0x2000000) | PTE_ACCESS | PTE_VALID, 0x4000) == 0);
    CHECK(page_effects && !panic_count);
    page_effects = panic_count = 0;
    CHECK(mmu_map(ram_base + 0x2000001,
                  (ram_base + 0x2000000) | PTE_ACCESS | PTE_VALID, 0x4000) < 0 || panic_count);
    CHECK(!page_effects);

    /* Attributes must not conceal the physical target; every alias is checked. */
    const u64 aliases[] = {0, REGION_RWX_EL0, REGION_RW_EL0, REGION_RX_EL1};
    for (unsigned granule = 0; granule < 2; granule++) {
        reset_fixture();
        mock_page_size = granule ? 16384 : 4096;
        mock_16k = granule;
        publish_one(ram_base + 0x1000000, 0x4000);
        for (unsigned i = 0; i < ARRAY_SIZE(aliases); i++) {
            page_effects = panic_count = 0;
            u64 va = (ram_base + 0x2000000) | aliases[i];
            u64 attrs = PTE_VALID | PTE_ACCESS | PTE_PXN | PTE_UXN;
            CHECK(mmu_map(va, (ram_base + 0x1000000) | attrs, mock_page_size) < 0);
            CHECK(!page_effects);
            CHECK(expect_add_panic(va, ram_base + 0x1000000, mock_page_size));
            page_effects = panic_count = 0;
            CHECK(mmu_map(va, (ram_base + 0x2000000) | attrs, mock_page_size) == 0);
            CHECK(page_effects && !panic_count);
        }
        page_effects = panic_count = 0;
        CHECK(mmu_map(ram_base + 0x1000000, 0, mock_page_size) == 0);
        CHECK(page_effects && !panic_count); /* Invalid-PTE removal is allowed. */
        page_effects = 0;
        CHECK(mmu_map(ram_base, ram_base | PTE_VALID, 0) == 0 && !page_effects);
        CHECK(mmu_t6032_mapping_allowed(BIT(48) - mock_page_size,
                                       BIT(42) - mock_page_size, mock_page_size));
        CHECK(!mmu_t6032_mapping_allowed(BIT(48), ram_base, mock_page_size));
        CHECK(!mmu_t6032_mapping_allowed(ram_base, BIT(42), mock_page_size));
        CHECK(!mmu_t6032_mapping_allowed(UINT64_MAX - mock_page_size + 1,
                                        ram_base, mock_page_size));
        CHECK(!mmu_t6032_mapping_allowed(ram_base, ram_base, UINT64_MAX));
        CHECK(!mmu_t6032_mapping_allowed(ram_base, ram_base + 1, mock_page_size));
        CHECK(expect_add_panic(ram_base, ram_base | PTE_PXN, mock_page_size));
    }

    reset_fixture();
    publish_one(ram_base + 0x1000000, 0x4000);
    chip_id = 0x6031; page_effects = panic_count = 0;
    mmu_add_mapping(ram_base + 0x1000000, ram_base + 0x1000000, 0x1000, MAIR_IDX_NORMAL, PERM_RWX);
    CHECK(page_effects && !panic_count);

    puts("T6032 mapping guard tests passed: lifecycle, 16x4 TZ consistency, geometry, physical overlap, aliases, legacy");
    return 0;
}

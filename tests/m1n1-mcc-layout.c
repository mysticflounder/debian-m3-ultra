/* Host-only source-extracted MCC tests; no hardware accesses. */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;
#define T6032 0x6032
#define GENMASK(h, l) (((~0ULL) >> (63 - (h))) & (~0ULL << (l)))
#define FIELD_PREP(mask, value) (((u32)(value) << __builtin_ctzll(mask)) & (mask))

/* INSERT_MCC_DEFS */
/* INSERT_FIRMWARE_FIXTURES */

static bool mcc_initialized;
static int mcc_count;
static struct mcc_regs mcc_regs[MAX_MCC_INSTANCES];
static void *adt = (void *)1;
static u32 chip_id;
static u8 mock_reg[20 * 16];
static u64 mock_base[16], mock_size[16];
static u32 mock_plane_count, mock_dcs_count, mock_reg_len;
static u32 mock_plane_prop_len, mock_dcs_prop_len;
static bool mock_compatible, mock_missing_reg, mock_missing_plane, mock_missing_dcs;
static int mock_fail_index, mock_path_result, mock_offset, mock_banks, mock_poll_fail;
static unsigned mmio_read_count, mmio_write_count, mmio_poll_count, translate_count;
static bool bad_mmio;

struct adt_property { const char *value; };
static const struct adt_property mock_property = {"unsupported"};
static const void *adt_getprop(const void *tree, int node, const char *name, u32 *length)
{
    (void)tree; (void)node;
    if (!strcmp(name, "reg")) {
        if (length) *length = mock_reg_len;
        return mock_missing_reg ? NULL : mock_reg;
    }
    if (!strcmp(name, "plane-count-per-amcc")) {
        if (length) *length = mock_plane_prop_len;
        return mock_missing_plane ? NULL : &mock_plane_count;
    }
    if (!strcmp(name, "dcs-count-per-amcc")) {
        if (length) *length = mock_dcs_prop_len;
        return mock_missing_dcs ? NULL : &mock_dcs_count;
    }
    return NULL;
}
static int mock_getprop_copy(const void *tree, int node, const char *name, void *out, u32 size)
{
    u32 length = 0;
    const void *data = adt_getprop(tree, node, name, &length);
    if (!data || length != size) return -1;
    memcpy(out, data, size);
    return (int)size;
}
#define ADT_GETPROP(a, n, p, out) mock_getprop_copy(a, n, p, out, sizeof(*(out)))
static bool adt_is_compatible(const void *tree, int node, const char *compat)
{ (void)tree; (void)node; return mock_compatible && !strcmp(compat, "mcc,t6031"); }
static int adt_path_offset_trace(const void *tree, const char *path, int *offsets)
{ (void)tree; (void)path; offsets[0] = 1; return mock_path_result; }
static const struct adt_property *adt_get_property(const void *tree, int node, const char *name)
{ (void)tree; (void)node; (void)name; return &mock_property; }
/* Other SoCs are stubs; the Max m3/t6031 path below is actual source. */
static int mcc_init_t8103(int node, int *path, bool flag)
{ (void)node; (void)path; (void)flag; return 41; }
static int mcc_init_t6000(int node, int *path, bool flag)
{ (void)node; (void)path; (void)flag; return 42; }
static int mcc_init_t8122(int *path, u32 offset, u32 planes, u32 dcs, struct tz_regs *tz)
{ (void)path; (void)offset; (void)planes; (void)dcs; (void)tz; return 43; }
static int mcc_init_m4(int node, int *path)
{ (void)node; (void)path; return 44; }
static int adt_get_reg(const void *tree, int *path, const char *prop, int index, u64 *addr, u64 *size)
{
    (void)tree; (void)path; (void)prop;
    translate_count++;
    int i = index - mock_offset;
    if (i < 0 || i >= mock_banks || i == mock_fail_index) return -1;
    *addr = mock_base[i];
    if (size) *size = mock_size[i];
    return 0;
}
static u64 cache_address(unsigned ordinal, u32 offset)
{ return mock_base[ordinal / 4] + (ordinal % 4) * T6031_PLANE_STRIDE + offset; }
static u32 read32(u64 address)
{ (void)address; mmio_read_count++; return 0; }
static void write32(u64 address, u32 value)
{
    bad_mmio |= mmio_write_count >= (unsigned)mock_banks * 4;
    if (!bad_mmio)
        bad_mmio |= address != cache_address(mmio_write_count, PLANE_CACHE_ENABLE) || value != 1;
    mmio_write_count++;
}
static int poll32(u64 address, u32 mask, u32 target, u32 timeout)
{
    bad_mmio |= mmio_poll_count >= (unsigned)mock_banks * 4;
    if (!bad_mmio)
        bad_mmio |= address != cache_address(mmio_poll_count, PLANE_CACHE_STATUS) ||
                    mask != T6031_CACHE_STATUS_MASK || target != T6031_CACHE_STATUS_VAL ||
                    timeout != CACHE_ENABLE_TIMEOUT;
    return (int)mmio_poll_count++ == mock_poll_fail ? -1 : 0;
}

/* INSERT_MCC_SOURCE */

static void put64(u8 *out, u64 value)
{ for (unsigned byte = 0; byte < 8; byte++) out[byte] = (u8)(value >> (8 * byte)); }
static void fixture(bool max)
{
    const u64 (*windows)[2] = max ? fixture_J516c : fixture_J575d;
    unsigned count = max ? 11 : 20;
    mock_offset = max ? 3 : 4; mock_banks = max ? 8 : 16;
    memset(mock_reg, 0, sizeof(mock_reg));
    memset(mock_base, 0, sizeof(mock_base));
    memset(mock_size, 0, sizeof(mock_size));
    for (unsigned i = 0; i < count; i++) {
        put64(mock_reg + i * 16, windows[i][0]);
        put64(mock_reg + i * 16 + 8, windows[i][1]);
        if (i >= (unsigned)mock_offset) {
            /* Synthetic bus translation: raw addresses are NOT physical addresses. */
            mock_base[i - mock_offset] = windows[i][0] + 0x400000000ULL;
            mock_size[i - mock_offset] = windows[i][1];
        }
    }
    mock_reg_len = count * 16; mock_plane_count = mock_dcs_count = 4;
    mock_plane_prop_len = mock_dcs_prop_len = 4;
    mock_compatible = true; mock_missing_reg = mock_missing_plane = mock_missing_dcs = false;
    mock_fail_index = mock_poll_fail = -1; mock_path_result = 7;
    chip_id = max ? 0x6031 : T6032;
    mmio_read_count = mmio_write_count = mmio_poll_count = translate_count = 0;
    bad_mmio = false;
    mcc_initialized = false; mcc_count = 0; memset(mcc_regs, 0, sizeof(mcc_regs));
}
static bool empty_state(void)
{
    const struct mcc_regs zero[MAX_MCC_INSTANCES] = {0};
    return !mcc_initialized && !mcc_count && !memcmp(mcc_regs, zero, sizeof(zero));
}
static bool expect_fail(void)
{
    if (mcc_init() >= 0 || !empty_state()) return false;
    return mcc_enable_cache() < 0 && !mmio_read_count && !mmio_write_count && !mmio_poll_count;
}
#define CHECK(test) do { if (!(test)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #test); return 1; } } while (0)
#define REJECT(change) do { fixture(false); change; CHECK(expect_fail()); } while (0)

int main(void)
{
    for (unsigned max = 0; max < 2; max++) {
        fixture(max);
        CHECK(mcc_init() == 0 && mcc_initialized && mcc_count == mock_banks);
        CHECK(translate_count == (unsigned)mock_banks);
        CHECK(!mmio_read_count && !mmio_write_count && !mmio_poll_count);
        for (int i = 0; i < mock_banks; i++) {
            CHECK(mcc_regs[i].plane_base == mock_base[i]);
            CHECK(mcc_regs[i].plane_count == 4 && mcc_regs[i].dcs_count == 4);
            CHECK(mcc_regs[i].global_base == mock_base[i] + T6031_GLOBAL_OFFSET);
            CHECK(mcc_regs[i].dcs_base == mock_base[i] + T6031_DCS_OFFSET);
            CHECK(mcc_regs[i].tz == &t6031_tz_regs && mcc_regs[i].cache_ways == 12);
        }
        CHECK(mcc_enable_cache() == 0 && !bad_mmio);
        CHECK(mmio_write_count == (unsigned)mock_banks * 4 && mmio_poll_count == mmio_write_count);
    }
    REJECT(mock_compatible = false);
    REJECT(mock_missing_reg = true);
    REJECT(mock_missing_plane = true);
    REJECT(mock_missing_dcs = true);
    REJECT(mock_reg_len = 19 * 16);
    REJECT(mock_reg_len = 20 * 16 + 1);
    REJECT(mock_plane_count = 3);
    REJECT(mock_dcs_count = 0);
    REJECT(mock_plane_prop_len = 8);
    REJECT(mock_dcs_prop_len = 3);
    REJECT(put64(mock_reg + 24, 0x1000));
    REJECT(put64(mock_reg + 4 * 16 + 8, 0x1000));
    REJECT(put64(mock_reg + 5 * 16, fixture_J575d[4][0]));
    REJECT(put64(mock_reg, 0));
    REJECT(put64(mock_reg + 4 * 16, fixture_J575d[4][0] + 1));
    REJECT(put64(mock_reg + 4 * 16, UINT64_MAX - 0xfff));
    REJECT(mock_fail_index = 15);
    REJECT(mock_size[15] = 0x1000);
    REJECT(mock_base[15] = mock_base[14]);
    REJECT(mock_base[15] = UINT64_MAX - 0xfff);
    REJECT(mock_base[15] = 0);
    REJECT(mock_base[15]++);
    REJECT(mcc_regs[0].plane_base = 0xdeadbeef; mock_reg_len = 0);
    fixture(true); chip_id = T6032; CHECK(expect_fail());
    fixture(false); CHECK(mcc_init() == 0); mock_path_result = -1;
    CHECK(expect_fail());
    fixture(false); CHECK(mcc_init() == 0); mock_fail_index = 15;
    CHECK(expect_fail());
    fixture(false); CHECK(mcc_init() == 0); mock_poll_fail = 63;
    CHECK(mcc_enable_cache() < 0 && mmio_read_count == 1 && !bad_mmio);
    /* Numeric overlap across distinct bus/translated spaces is not aliasing. */
    fixture(false); mock_base[0] = fixture_J575d[0][0];
    CHECK(mcc_init() == 0 && mcc_regs[0].plane_base == mock_base[0]);
    CHECK(mcc_t6032_window_bounds(0x1000, 0x2000000, 4, 4));
    CHECK(!mcc_t6032_window_bounds(0x1000, 0x1000, 4, 4));
    CHECK(!mcc_t6032_window_bounds(0x1000, 0x2000000, 0, 4));
    CHECK(!mcc_t6032_window_bounds(0x1000, 0x2000000, 4, 0));
    puts("MCC tests passed: real Max/Ultra fixtures, translated windows, negative/reinit cases, mocked cache IO");
    return 0;
}

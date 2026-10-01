/* Host-only AIC init harness. The runner inserts the pinned aic.c body at
 * the marker below; ADT and MMIO operations are synthetic and observable. */

#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef unsigned long u64;

#define BIT(x)                 (1ULL << (x))
#define GENMASK(msb, lsb)      ((BIT((msb + 1) - (lsb)) - 1) << (lsb))
#define _FIELD_LSB(field)      ((field) & ~(field - 1))
#define FIELD_PREP(field, val) (((val) * (_FIELD_LSB(field))) & (field))
#define FIELD_GET(field, val)  (((val) & (field)) / _FIELD_LSB(field))

#define AIC_MAX_DIES 4
#define AIC_REG_SIZE 0x8000
#define AIC_INFO 0x0004
#define AIC_EVENT 0x2004
#define AIC_TARGET_CPU 0x3000
#define AIC_SW_SET 0x4000
#define AIC_SW_CLR 0x4080
#define AIC_MASK_SET 0x4100
#define AIC_MASK_CLR 0x4180
#define AIC2_CAP0 0x0004
#define AIC2_MAXNUMIRQ 0x000c
#define AIC2_IRQ_CFG 0x2000
#define AIC23_IRQ_CFG_TARGET GENMASK(3, 0)
#define AIC23_CAP0_NR_IRQ GENMASK(15, 0)
#define AIC23_CAP0_LAST_DIE GENMASK(27, 24)
#define AIC23_MAXNUMIRQ_MAX_IRQ GENMASK(15, 0)
#define AIC23_MAXNUMIRQ_MAX_DIE GENMASK(27, 24)
#define AIC_INFO_NR_HW GENMASK(15, 0)
#define AIC1_MAX_IRQ 0x400
#define AIC_MAX_HW_NUM (0x80 * 32)

struct aic_regs {
    u64 reg_size;
    u64 event;
    u64 tgt_cpu;
    u64 config;
    u64 sw_set;
    u64 sw_clr;
    u64 mask_set;
    u64 mask_clr;
};

struct aic {
    u64 base;
    uint32_t version;
    uint32_t nr_irq;
    uint32_t nr_die;
    uint32_t max_irq;
    uint32_t max_die;
    uint32_t extintrcfg_stride;
    uint32_t intmaskset_stride;
    uint32_t intmaskclear_stride;
    int32_t cap0_offset;
    int32_t maxnumirq_offset;
    struct aic_regs regs;
};

struct fixture {
    int version;
    int node;
    int path_ret;
    int reg_ret;
    u64 base;
    int cap_ret;
    int max_ret;
    int32_t cap_offset;
    int32_t max_offset;
    u32 cap_value;
    u32 max_value;
    u64 iack_offset;
    u32 iack_prop_len;
    u32 cap_prop_len;
    u32 max_prop_len;
    u32 config_prop_len;
    bool strides_present;
    u32 ext_stride;
    u32 set_stride;
    u32 clr_stride;
    u32 ext_stride_len;
    u32 set_stride_len;
    u32 clr_stride_len;
    bool config_present;
    u32 config_base;
    u8 ext[32];
    u32 ext_len;
};

struct mask_write {
    u64 addr;
    u32 clear;
    u32 value;
};

static struct fixture fixture;
static struct mask_write writes[32];
static unsigned write_count;
static unsigned read_count;
static unsigned adt_copy_count;
void *adt;

static void reset_io(void)
{
    memset(&fixture, 0, sizeof(fixture));
    memset(writes, 0, sizeof(writes));
    write_count = 0;
    read_count = 0;
    adt_copy_count = 0;
    adt = &fixture;
}

static int copy_u32(void *out, size_t len, u32 value)
{
    if (len != sizeof(value))
        return -2;
    memcpy(out, &value, sizeof(value));
    return (int)len;
}

static int copy_s32(void *out, size_t len, int32_t value)
{
    if (len != sizeof(value))
        return -2;
    memcpy(out, &value, sizeof(value));
    return (int)len;
}

static int copy_u64(void *out, size_t len, u64 value)
{
    if (len != sizeof(value))
        return -2;
    memcpy(out, &value, sizeof(value));
    return (int)len;
}

int adt_getprop_copy(const void *tree, int node, const char *name, void *out, size_t len)
{
    (void)tree;
    (void)node;
    adt_copy_count++;
    if (!strcmp(name, "aic-iack-offset")) {
        if (fixture.iack_prop_len != sizeof(fixture.iack_offset)) return -2;
        return copy_u64(out, len, fixture.iack_offset);
    }
    if (!strcmp(name, "cap0-offset"))
        return fixture.cap_ret ? fixture.cap_ret : copy_s32(out, len, fixture.cap_offset);
    if (!strcmp(name, "maxnumirq-offset"))
        return fixture.max_ret ? fixture.max_ret : copy_s32(out, len, fixture.max_offset);
    if (!strcmp(name, "extint-baseaddress")) {
        if (fixture.config_present && fixture.config_prop_len != sizeof(fixture.config_base))
            return -2;
        return fixture.config_present ? copy_u32(out, len, fixture.config_base) : -1;
    }
    if (!strcmp(name, "extintrcfg-stride") || !strcmp(name, "intmaskset-stride") ||
        !strcmp(name, "intmaskclear-stride")) {
        if (!fixture.strides_present) return -1;
        if (!strcmp(name, "extintrcfg-stride")) {
            if (fixture.ext_stride_len != sizeof(fixture.ext_stride)) return -2;
            return copy_u32(out, len, fixture.ext_stride);
        }
        if (!strcmp(name, "intmaskset-stride")) {
            if (fixture.set_stride_len != sizeof(fixture.set_stride)) return -2;
            return copy_u32(out, len, fixture.set_stride);
        }
        if (fixture.clr_stride_len != sizeof(fixture.clr_stride)) return -2;
        return copy_u32(out, len, fixture.clr_stride);
    }
    return -1;
}

const void *adt_getprop(const void *tree, int node, const char *name, u32 *len)
{
    (void)tree;
    (void)node;
    if (!strcmp(name, "aic-iack-offset")) {
        *len = fixture.iack_prop_len;
        return &fixture.iack_offset;
    }
    if (!strcmp(name, "cap0-offset")) {
        if (fixture.cap_ret == -1) return NULL;
        if (fixture.cap_ret == -2) {
            *len = sizeof(fixture.cap_offset) + 4;
            return &fixture.cap_offset;
        }
        *len = fixture.cap_prop_len;
        return &fixture.cap_offset;
    }
    if (!strcmp(name, "maxnumirq-offset")) {
        if (fixture.max_ret == -1) return NULL;
        if (fixture.max_ret == -2) {
            *len = sizeof(fixture.max_offset) + 4;
            return &fixture.max_offset;
        }
        *len = fixture.max_prop_len;
        return &fixture.max_offset;
    }
    if (!strcmp(name, "extint-baseaddress")) {
        if (!fixture.config_present) return NULL;
        *len = fixture.config_prop_len;
        return &fixture.config_base;
    }
    if (!strcmp(name, "extintrcfg-stride") || !strcmp(name, "intmaskset-stride") ||
        !strcmp(name, "intmaskclear-stride")) {
        if (!fixture.strides_present) return NULL;
        if (!strcmp(name, "extintrcfg-stride")) {
            *len = fixture.ext_stride_len;
            return &fixture.ext_stride;
        }
        if (!strcmp(name, "intmaskset-stride")) {
            *len = fixture.set_stride_len;
            return &fixture.set_stride;
        }
        *len = fixture.clr_stride_len;
        return &fixture.clr_stride;
    }
    if (!strcmp(name, "aic-ext-intr-cfg") && fixture.ext_len) {
        *len = fixture.ext_len;
        return fixture.ext;
    }
    *len = 0;
    return NULL;
}

int adt_path_offset_trace(const void *tree, const char *path, int *offsets)
{
    (void)tree;
    (void)path;
    offsets[0] = fixture.node;
    return fixture.path_ret;
}

int adt_get_reg(const void *tree, int *path, const char *prop, int index, u64 *addr, u64 *size)
{
    (void)tree;
    (void)path;
    (void)prop;
    (void)index;
    if (fixture.reg_ret)
        return fixture.reg_ret;
    *addr = fixture.base;
    if (size)
        *size = 0x100000;
    return 0;
}

bool adt_is_compatible(const void *tree, int node, const char *compat)
{
    (void)tree;
    (void)node;
    if (fixture.version == 1)
        return !strcmp(compat, "aic,1");
    if (fixture.version == 2)
        return !strcmp(compat, "aic,2");
    if (fixture.version == 3)
        return !strcmp(compat, "aic,3");
    return false;
}

u32 read32(u64 addr)
{
    read_count++;
    u64 offset = addr - fixture.base;
    if (fixture.version == 1 && offset == AIC_INFO)
        return fixture.cap_value;
    if (offset == (u32)fixture.cap_offset)
        return fixture.cap_value;
    if (offset == (u32)fixture.max_offset)
        return fixture.max_value;
    return 0;
}

void write32(u64 addr, u32 value)
{
    (void)addr;
    (void)value;
}

u32 mask32(u64 addr, u32 clear, u32 value)
{
    if (write_count < sizeof(writes) / sizeof(writes[0]))
        writes[write_count++] = (struct mask_write){addr, clear, value};
    return 0;
}

#define ADT_GETPROP(tree, node, name, value) \
    adt_getprop_copy((tree), (node), (name), (value), sizeof(*(value)))

/* INSERT_AIC_SOURCE */

static void reset_driver(void)
{
    aic1 = (struct aic){
        .version = 1,
        .nr_die = 1,
        .max_die = 1,
        .regs = {.reg_size = AIC_REG_SIZE, .event = AIC_EVENT, .tgt_cpu = AIC_TARGET_CPU,
                 .sw_set = AIC_SW_SET, .sw_clr = AIC_SW_CLR, .mask_set = AIC_MASK_SET,
                 .mask_clr = AIC_MASK_CLR},
    };
    aic2 = (struct aic){.version = 2, .regs = {.config = AIC2_IRQ_CFG}, .cap0_offset = AIC2_CAP0,
                            .maxnumirq_offset = AIC2_MAXNUMIRQ};
    aic3 = (struct aic){.version = 3, .cap0_offset = -1, .maxnumirq_offset = -1};
    aic = NULL;
}

static void valid_fixture(int version)
{
    reset_io();
    reset_driver();
    fixture.version = version;
    fixture.node = 7;
    fixture.path_ret = 0;
    fixture.reg_ret = 0;
    fixture.base = 0x100000;
    fixture.iack_offset = AIC_EVENT;
    fixture.iack_prop_len = sizeof(fixture.iack_offset);
    fixture.cap_prop_len = sizeof(fixture.cap_offset);
    fixture.max_prop_len = sizeof(fixture.max_offset);
    fixture.config_prop_len = sizeof(fixture.config_base);
    fixture.cap_offset = version == 3 ? 0x100 : AIC2_CAP0;
    fixture.max_offset = version == 3 ? 0x104 : AIC2_MAXNUMIRQ;
    fixture.cap_value = (1U << 24) | (version == 1 ? 64 : 128);
    fixture.max_value = (2U << 24) | 128;
    fixture.config_present = version == 3;
    fixture.config_base = version == 3 ? 0x10000 : AIC2_IRQ_CFG;
}

static int fail(const char *message)
{
    fprintf(stderr, "FAIL: %s\n", message);
    return 1;
}

static int expect_no_mmio(const char *message)
{
    if (read_count || write_count)
        return fail(message);
    return 0;
}

static int test_valid_aic1(void)
{
    valid_fixture(1);
    aic_init();
    if (!aic || aic->version != 1 || aic->base != fixture.base || aic->nr_irq != 64 ||
        aic->max_irq != AIC1_MAX_IRQ || read_count != 1 || write_count)
        return fail("valid AIC1 contract changed");
    return 0;
}

static void set_record(unsigned index, unsigned die, unsigned irq, unsigned target)
{
    fixture.ext[index * 3] = irq & 0xff;
    fixture.ext[index * 3 + 1] = (u8)((die << 4) | ((irq >> 8) & 0xf));
    fixture.ext[index * 3 + 2] = target;
}

static int test_valid_two_die_records(void)
{
    valid_fixture(2);
    fixture.ext_len = 6;
    set_record(0, 0, 3, 2);
    set_record(1, 1, 65, 3);
    aic_init();
    u64 base = fixture.base + AIC2_IRQ_CFG;
    if (!aic || aic->nr_die != 2 || aic->nr_irq != 128 || read_count != 2 || write_count != 2 ||
        writes[0].addr != base + 4 * 3 || writes[0].clear != AIC23_IRQ_CFG_TARGET ||
        writes[0].value != 2 || writes[1].addr != base + aic->extintrcfg_stride + 4 * 65 ||
        writes[1].clear != AIC23_IRQ_CFG_TARGET || writes[1].value != 3)
        return fail("valid two-die AIC2 records changed");
    return 0;
}

static int test_valid_aic3(void)
{
    valid_fixture(3);
    fixture.ext_len = 3;
    set_record(0, 1, 7, 4);
    aic_init();
    if (!aic || aic->version != 3 || read_count != 2 || write_count != 1 ||
        aic->regs.config != 0x10000 || aic->extintrcfg_stride != 0x250 ||
        writes[0].addr != fixture.base + 0x10000 + 0x250 + 4 * 7 ||
        writes[0].clear != AIC23_IRQ_CFG_TARGET || writes[0].value != 4)
        return fail("valid AIC3 contract changed");
    return 0;
}

static int test_optional_scalar_properties(void)
{
    valid_fixture(3);
    fixture.strides_present = true;
    fixture.ext_stride = 0x300;
    fixture.set_stride = 0x400;
    fixture.clr_stride = 0x500;
    fixture.ext_stride_len = sizeof(fixture.ext_stride);
    fixture.set_stride_len = sizeof(fixture.set_stride);
    fixture.clr_stride_len = sizeof(fixture.clr_stride);
    fixture.ext_len = 3;
    set_record(0, 1, 7, 4);
    aic_init();
    if (!aic || aic->regs.config != fixture.config_base ||
        aic->extintrcfg_stride != fixture.ext_stride ||
        aic->intmaskset_stride != fixture.set_stride ||
        aic->intmaskclear_stride != fixture.clr_stride || write_count != 1 ||
        writes[0].addr != fixture.base + fixture.config_base + fixture.ext_stride + 4 * 7)
        return fail("valid optional AIC scalar properties changed");

    valid_fixture(3);
    fixture.config_prop_len = sizeof(fixture.config_base) + 4;
    aic_init();
    if (aic != NULL || write_count != 0)
        return fail("wrong-size AIC config property did not fail closed");

    valid_fixture(3);
    fixture.strides_present = true;
    fixture.ext_stride = 0x300;
    fixture.set_stride = 0x400;
    fixture.clr_stride = 0x500;
    fixture.ext_stride_len = sizeof(fixture.ext_stride) + 4;
    fixture.set_stride_len = sizeof(fixture.set_stride);
    fixture.clr_stride_len = sizeof(fixture.clr_stride);
    aic_init();
    if (!aic || aic->extintrcfg_stride != 0x250 || aic->intmaskset_stride != 0x400 ||
        aic->intmaskclear_stride != 0x500)
        return fail("malformed AIC stride property did not use fallback");
    return 0;
}

static int test_iack_property_size(void)
{
    const u32 lengths[] = {0, 4, 12};
    for (unsigned i = 0; i < sizeof(lengths) / sizeof(lengths[0]); i++) {
        valid_fixture(3);
        fixture.iack_prop_len = lengths[i];
        aic_init();
        if (aic != NULL || read_count != 0 || write_count != 0)
            return fail("wrong-size AIC iack property touched MMIO");
    }
    return 0;
}

static int test_scalar_length_boundaries(void)
{
    const u32 lengths[] = {0, 2, 8};
    for (unsigned i = 0; i < sizeof(lengths) / sizeof(lengths[0]); i++) {
        for (unsigned which = 0; which < 2; which++) {
            valid_fixture(3);
            if (which)
                fixture.max_prop_len = lengths[i];
            else
                fixture.cap_prop_len = lengths[i];
            aic_init();
            if (aic != NULL || read_count || write_count || adt_copy_count)
                return fail("scalar length boundary reached MMIO or legacy copy");
        }
        valid_fixture(2);
        fixture.config_present = true;
        fixture.config_base = 0x10000;
        fixture.config_prop_len = lengths[i];
        fixture.strides_present = true;
        fixture.ext_stride_len = fixture.set_stride_len = fixture.clr_stride_len = lengths[i];
        fixture.ext_stride = fixture.set_stride = fixture.clr_stride = 0xdead;
        aic_init();
        if (!aic || aic->regs.config != AIC2_IRQ_CFG ||
            aic->extintrcfg_stride != 0x250 || aic->intmaskset_stride != 0x250 ||
            aic->intmaskclear_stride != 0x250 || read_count != 2 || write_count || adt_copy_count)
            return fail("AIC2 malformed optional scalar fallback changed");
    }
    return 0;
}

static int test_dynamic_offset_failure(int cap_ret, int max_ret, int32_t cap, int32_t max,
                                       const char *message)
{
    valid_fixture(3);
    fixture.cap_ret = cap_ret;
    fixture.max_ret = max_ret;
    fixture.cap_offset = cap;
    fixture.max_offset = max;
    aic_init();
    if (aic != NULL)
        return fail(message);
    return expect_no_mmio("AIC3 dynamic offset failure touched MMIO");
}

static int test_malformed_lengths(void)
{
    for (u32 len = 1; len <= 5; len++) {
        if (len == 3)
            continue;
        valid_fixture(2);
        fixture.ext_len = len;
        memset(fixture.ext, 0, sizeof(fixture.ext));
        aic_init();
        if (aic != NULL || write_count != 0)
            return fail("malformed extintrcfg did not fail closed");
    }
    return 0;
}

static int test_later_record_validation(void)
{
    valid_fixture(2);
    fixture.ext_len = 6;
    set_record(0, 0, 3, 2);
    set_record(1, 2, 65, 3);
    aic_init();
    if (aic != NULL || write_count != 0)
        return fail("invalid later die wrote before validation");

    valid_fixture(2);
    fixture.ext_len = 6;
    set_record(0, 0, 3, 2);
    set_record(1, 1, 128, 3);
    aic_init();
    if (aic != NULL || write_count != 0)
        return fail("invalid later IRQ wrote before validation");
    return 0;
}

int main(void)
{
    if (test_valid_aic1() || test_valid_two_die_records() || test_valid_aic3() ||
        test_optional_scalar_properties() || test_iack_property_size() ||
        test_dynamic_offset_failure(-1, 0, 0x100, 0x104, "AIC3 missing cap0 did not fail closed") ||
        test_dynamic_offset_failure(0, -1, 0x100, 0x104, "AIC3 missing maxnumirq did not fail closed") ||
        test_dynamic_offset_failure(-2, 0, 0x100, 0x104, "AIC3 wrong-size cap0 did not fail closed") ||
        test_dynamic_offset_failure(0, -2, 0x100, 0x104, "AIC3 wrong-size maxnumirq did not fail closed") ||
        test_dynamic_offset_failure(0, 0, -4, 0x104, "AIC3 negative cap0 did not fail closed") ||
        test_dynamic_offset_failure(0, 0, 0x102, 0x104, "AIC3 misaligned cap0 did not fail closed") ||
        test_dynamic_offset_failure(0, 0, 0x100, -4, "AIC3 negative maxnumirq did not fail closed") ||
        test_dynamic_offset_failure(0, 0, 0x100, 0x106, "AIC3 misaligned maxnumirq did not fail closed") ||
        test_scalar_length_boundaries() || test_malformed_lengths() || test_later_record_validation())
        return 1;
    puts("AIC init harness: valid AIC1/AIC2/AIC3, fail-closed metadata, and table validation passed");
    return 0;
}

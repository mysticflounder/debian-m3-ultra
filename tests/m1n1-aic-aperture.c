/* Host-only AIC aperture/stride harness.  The runner supplies the pinned
 * source headers and inserts the patched aic.c body at the marker.  All
 * addresses are integers observed by bounded mocks; no MMIO is performed. */

#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "types.h"
#include "aic.h"
#include "aic_regs.h"

static int host_printf(const char *format, ...)
{
    va_list ap;
    va_start(ap, format);
    int result = vfprintf(stderr, format, ap);
    va_end(ap);
    return result;
}

#define printf(...) host_printf(__VA_ARGS__)

#define BACKING_SIZE 0x80000u
#define CANARY_SIZE 32u
#define MAX_WRITES 64u

struct fixture {
    int version;
    int node;
    int path_ret;
    int reg_ret;
    u64 base;
    u64 reg_size;
    bool reg_size_present;
    u64 iack_offset;
    u32 iack_prop_len;
    int32_t cap_offset;
    int32_t max_offset;
    u32 cap_prop_len;
    u32 max_prop_len;
    int cap_ret;
    int max_ret;
    u32 cap_value;
    u32 max_value;
    bool config_present;
    u32 config_base;
    u32 config_prop_len;
    bool strides_present;
    u32 ext_stride;
    u32 set_stride;
    u32 clr_stride;
    u32 ext_stride_len;
    u32 set_stride_len;
    u32 clr_stride_len;
    u8 ext[64];
    u32 ext_len;
    u8 backing[BACKING_SIZE];
    u8 before[CANARY_SIZE];
    u8 after[CANARY_SIZE];
    bool mmio_fault;
    u64 fault_addr;
    unsigned read_count;
    unsigned write_count;
    unsigned reg_count;
    u64 raw_addrs[MAX_WRITES];
};

struct observed_write {
    u64 addr;
    u32 clear;
    u32 value;
};

static struct fixture fixture;
static struct observed_write writes[MAX_WRITES];
static void *adt;
static bool fixture_started;

static void reset_io(void)
{
    memset(&fixture, 0, sizeof(fixture));
    memset(writes, 0, sizeof(writes));
    memset(fixture.backing, 0xa5, sizeof(fixture.backing));
    memset(fixture.before, 0x5a, sizeof(fixture.before));
    memset(fixture.after, 0x5a, sizeof(fixture.after));
    adt = &fixture;
}

static void fail_mmio(u64 addr)
{
    fixture.mmio_fault = true;
    fixture.fault_addr = addr;
}

/* The sparse observer deliberately permits an address beyond backing storage
 * when it is inside the declared aperture.  It still rejects every address
 * outside the declared aperture, so large-stride tests cannot hide a wrap. */
static bool mmio_range(u64 addr, size_t len, u8 **mapped)
{
    if (addr < fixture.base) {
        fail_mmio(addr);
        return false;
    }
    u64 off = addr - fixture.base;
    if ((addr & 3) || (off > fixture.reg_size) || len > fixture.reg_size - off) {
        fail_mmio(addr);
        return false;
    }
    if (off <= BACKING_SIZE && len <= BACKING_SIZE - off)
        *mapped = fixture.backing + off;
    else
        *mapped = NULL;
    return true;
}

int adt_get_reg(const void *tree, int *path, const char *prop, int index, u64 *addr, u64 *size)
{
    (void)tree; (void)path; (void)prop; (void)index;
    fixture.reg_count++;
    if (fixture.reg_ret || !fixture.reg_size_present || !size)
        return fixture.reg_ret ? fixture.reg_ret : -1;
    *addr = fixture.base;
    *size = fixture.reg_size;
    return 0;
}

const void *adt_getprop(const void *, int, const char *, u32 *);

int adt_getprop_copy(const void *tree, int node, const char *name, void *out, size_t len)
{
    u32 actual = 0;
    const void *raw = adt_getprop(tree, node, name, &actual);
    if (!raw || actual != len)
        return -1;
    memcpy(out, raw, len);
    return (int)len;
}

const void *adt_getprop(const void *tree, int node, const char *name, u32 *len)
{
    (void)tree; (void)node;
    if (!strcmp(name, "aic-iack-offset")) {
        *len = fixture.iack_prop_len;
        return &fixture.iack_offset;
    }
    if (!strcmp(name, "cap0-offset")) {
        if (fixture.cap_ret == -1) return NULL;
        *len = fixture.cap_ret == -2 ? sizeof(fixture.cap_offset) + 4 : fixture.cap_prop_len;
        return &fixture.cap_offset;
    }
    if (!strcmp(name, "maxnumirq-offset")) {
        if (fixture.max_ret == -1) return NULL;
        *len = fixture.max_ret == -2 ? sizeof(fixture.max_offset) + 4 : fixture.max_prop_len;
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
        if (!strcmp(name, "extintrcfg-stride")) { *len = fixture.ext_stride_len; return &fixture.ext_stride; }
        if (!strcmp(name, "intmaskset-stride")) { *len = fixture.set_stride_len; return &fixture.set_stride; }
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
    (void)tree; (void)path;
    offsets[0] = fixture.node;
    return fixture.path_ret;
}

bool adt_is_compatible(const void *tree, int node, const char *compat)
{
    (void)tree; (void)node;
    if (fixture.version == 1) return !strcmp(compat, "aic,1");
    if (fixture.version == 2) return !strcmp(compat, "aic,2");
    if (fixture.version == 3) return !strcmp(compat, "aic,3");
    return false;
}

u32 read32(u64 addr)
{
    u8 *mapped = NULL;
    fixture.read_count++;
    if (!mmio_range(addr, sizeof(u32), &mapped)) return 0;
    u64 off = addr - fixture.base;
    if (fixture.version == 1 && off == AIC_INFO) return fixture.cap_value;
    if (off == (u32)fixture.cap_offset) return fixture.cap_value;
    if (off == (u32)fixture.max_offset) return fixture.max_value;
    if (mapped) { u32 value; memcpy(&value, mapped, sizeof(value)); return value; }
    return 0;
}

void write32(u64 addr, u32 value)
{
    u8 *mapped = NULL;
    if (!mmio_range(addr, sizeof(value), &mapped)) return;
    if (fixture.write_count < MAX_WRITES)
        fixture.raw_addrs[fixture.write_count] = addr;
    fixture.write_count++;
    if (mapped) memcpy(mapped, &value, sizeof(value));
}

u32 mask32(u64 addr, u32 clear, u32 value)
{
    u8 *mapped = NULL;
    if (!mmio_range(addr, sizeof(value), &mapped)) return 0;
    if (fixture.write_count < MAX_WRITES)
        writes[fixture.write_count] = (struct observed_write){addr, clear, value};
    fixture.write_count++;
    if (mapped) {
        u32 old = 0;
        memcpy(&old, mapped, sizeof(old));
        old = (old & ~clear) | value;
        memcpy(mapped, &old, sizeof(old));
    }
    return 0;
}

/* INSERT_AIC_SOURCE */

static void set_record(unsigned index, unsigned die, unsigned irq, unsigned target)
{
    fixture.ext[index * 3] = irq & 0xff;
    fixture.ext[index * 3 + 1] = (u8)((die << 4) | ((irq >> 8) & 0xf));
    fixture.ext[index * 3 + 2] = target;
}

static void valid_fixture(int version)
{
    if (fixture_started && fixture.mmio_fault) {
        fprintf(stderr, "FAIL: prior fixture observed invalid MMIO\n");
        abort();
    }
    reset_io();
    fixture_started = true;
    aic = NULL;
    fixture.version = version;
    fixture.node = 7;
    fixture.base = 0x100000;
    fixture.reg_size_present = true;
    fixture.reg_size = version == 3 ? 0x50000 : 0x8000;
    fixture.iack_offset = version == 3 ? 0x40000 : AIC_EVENT;
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

static int expect_clean(const char *message)
{
    for (unsigned i = 0; i < CANARY_SIZE; i++)
        if (fixture.before[i] != 0x5a || fixture.after[i] != 0x5a)
            return fail(message);
    if (fixture.mmio_fault)
        return fail(message);
    return 0;
}

static void set_caps(unsigned nr_die, unsigned nr_irq, unsigned max_die, unsigned max_irq)
{
    fixture.cap_value = ((u32)(nr_die - 1) << 24) | nr_irq;
    fixture.max_value = ((u32)max_die << 24) | max_irq;
}

static int test_valid_layouts(void)
{
    valid_fixture(1);
    aic_init();
    if (!aic || aic->nr_irq != 64 || aic->regs.reg_size != AIC_REG_SIZE ||
        fixture.read_count != 1 || fixture.write_count)
        return fail("valid AIC1 aperture contract changed");
    valid_fixture(1); fixture.cap_value = 1025; aic_init();
    if (aic || fixture.read_count != 1) return fail("AIC1 IRQ capacity guard changed");

    valid_fixture(2); fixture.ext_len = 3; set_record(0, 0, 3, 2); aic_init();
    if (!aic || aic->extintrcfg_stride != 0x250 || aic->regs.reg_size != 0x2008 ||
        fixture.write_count != 1)
        return fail("AIC2 fallback layout contract changed");

    valid_fixture(2);
    fixture.strides_present = true;
    fixture.ext_stride = 0x300; fixture.set_stride = 0x500; fixture.clr_stride = 0x700;
    fixture.ext_stride_len = fixture.set_stride_len = fixture.clr_stride_len = sizeof(u32);
    fixture.ext_len = 6;
    set_caps(2, 128, 2, 128);
    set_record(0, 0, 3, 2); set_record(1, 1, 65, 3);
    aic_init();
    if (!aic || aic->regs.reg_size != 0x2008 || fixture.write_count != 2 ||
        writes[0].addr != fixture.base + AIC2_IRQ_CFG + 12 ||
        writes[1].addr != fixture.base + AIC2_IRQ_CFG + 0x300 + 260)
        return fail("valid unequal-stride AIC2 contract changed");

    valid_fixture(3);
    fixture.cap_offset = 4; fixture.max_offset = 12;
    fixture.iack_offset = 0x40000; fixture.config_base = 0x10000;
    fixture.strides_present = true;
    fixture.ext_stride = 0x4a00; fixture.set_stride = 0x4c00; fixture.clr_stride = 0x4e00;
    fixture.ext_stride_len = fixture.set_stride_len = fixture.clr_stride_len = sizeof(u32);
    fixture.ext_len = 6; set_caps(2, 128, 2, 128);
    set_record(0, 0, 7, 4); set_record(1, 1, 65, 5);
    aic_init();
    if (!aic || aic->regs.reg_size != 0x40004 || fixture.write_count != 2 ||
        writes[0].addr != fixture.base + 0x10000 + 28 ||
        writes[1].addr != fixture.base + 0x10000 + 0x4a00 + 260)
        return fail("valid unequal-stride AIC3 contract changed");

    /* The restore snapshot supplies a declared 0x1cc000 aperture and the
     * scalar layout, but no aic-iack-offset property; retain that distinction
     * from the live metadata fixture above. */
    valid_fixture(3); fixture.reg_size = 0x1cc000; fixture.cap_offset = 4;
    fixture.max_offset = 12; fixture.iack_offset = 0x40000;
    fixture.strides_present = true; fixture.ext_stride = fixture.set_stride = fixture.clr_stride = 0x4a00;
    fixture.ext_stride_len = fixture.set_stride_len = fixture.clr_stride_len = sizeof(u32);
    fixture.ext_len = 6; set_caps(2, 4096, 99, 4096);
    set_record(0, 0, 4095, 4); set_record(1, 1, 4095, 5); aic_init();
    if (!aic || fixture.write_count != 2)
        return fail("captured restore AIC aperture contract changed");
    return expect_clean("valid layout changed backing or canary");
}

static int test_single_die_zero_stride(void)
{
    valid_fixture(3);
    fixture.strides_present = true;
    fixture.ext_stride = fixture.set_stride = fixture.clr_stride = 0;
    fixture.ext_stride_len = fixture.set_stride_len = fixture.clr_stride_len = sizeof(u32);
    fixture.ext_len = 3; set_caps(1, 128, 0, 128); set_record(0, 0, 7, 4);
    aic_init();
    if (!aic || fixture.write_count != 1 ||
        writes[0].addr != fixture.base + fixture.config_base + 28)
        return fail("single-die zero stride was rejected or misaddressed");
    return expect_clean("single-die zero stride touched invalid backing");
}

static int test_large_stride_cast(void)
{
    valid_fixture(2);
    fixture.reg_size = 0x200002100ULL;
    fixture.strides_present = true;
    fixture.ext_stride = 0xfffffff0U;
    fixture.ext_stride_len = sizeof(u32);
    fixture.ext_len = 3; set_caps(3, 32, 0, 32); set_record(0, 2, 0, 1);
    aic_init();
    u64 expected = fixture.base + AIC2_IRQ_CFG + 2ULL * 0xfffffff0ULL;
    if (!aic || fixture.write_count != 1 || writes[0].addr != expected)
        return fail("large die stride wrapped before 64-bit multiplication");
    aic->intmaskset_stride = 0xfffffff0U;
    aic->intmaskclear_stride = 0xfffffff0U;
    fixture.write_count = 0; aic_set_sw(64, true); aic_set_sw(64, false);
    u64 sw_expected = fixture.base + aic->regs.sw_set + 2ULL * 0xfffffff0ULL;
    u64 clr_expected = fixture.base + aic->regs.sw_clr + 2ULL * 0xfffffff0ULL;
    if (fixture.write_count != 2 || fixture.raw_addrs[0] != sw_expected ||
        fixture.raw_addrs[1] != clr_expected)
        return fail("large software die stride wrapped before 64-bit multiplication");
    return expect_clean("large stride observer faulted");
}

static int test_aperture_rejections(void)
{
    valid_fixture(2); fixture.base = 0; aic_init();
    if (aic || fixture.read_count) return fail("null AIC base read MMIO");
    valid_fixture(1); fixture.reg_size = AIC_REG_SIZE - 4; aic_init();
    if (aic || fixture.read_count || fixture.write_count) return fail("short AIC1 aperture read MMIO");
    valid_fixture(2); fixture.base = 2; aic_init();
    if (aic || fixture.read_count) return fail("unaligned AIC base read MMIO");
    valid_fixture(2); fixture.reg_size = 0; aic_init();
    if (aic || fixture.read_count) return fail("zero AIC aperture read MMIO");
    valid_fixture(2); fixture.base = UINT64_MAX - 3; fixture.reg_size = 8; aic_init();
    if (aic || fixture.read_count) return fail("wrapping AIC aperture read MMIO");

    valid_fixture(3); fixture.reg_size = 0x40000; aic_init();
    if (aic || fixture.read_count) return fail("out-of-range AIC3 IACK read MMIO");
    valid_fixture(3); fixture.cap_offset = 0x50000; aic_init();
    if (aic || fixture.read_count) return fail("out-of-range AIC3 capability read MMIO");
    valid_fixture(3); fixture.max_offset = 0x50000; aic_init();
    if (aic || fixture.read_count) return fail("out-of-range AIC3 max IRQ read MMIO");

    valid_fixture(2); set_caps(2, 128, 0, 0); aic_init();
    if (aic || fixture.read_count != 2) return fail("zero max IRQ was accepted");
    valid_fixture(2); set_caps(2, 128, 0, 31); aic_init();
    if (aic || fixture.read_count != 2) return fail("non-word IRQ capacity was accepted");
    valid_fixture(2); set_caps(2, 32, 0, 32); aic_init();
    if (!aic) return fail("valid word IRQ capacity was rejected");
    valid_fixture(2); set_caps(2, 64, 0, 32); aic_init();
    if (aic) return fail("nr_irq greater than max_irq was accepted");
    valid_fixture(2); fixture.reg_size = 0x10000; set_caps(2, 4096, 0, 4096); aic_init();
    if (!aic) return fail("exact maximum word IRQ capacity was rejected");
    valid_fixture(2); set_caps(2, 4096, 0, 4128); aic_init();
    if (aic) return fail("IRQ capacity above hardware maximum was accepted");
    return expect_clean("aperture rejection changed backing or canary");
}

static int test_stride_and_capacity_guards(void)
{
    valid_fixture(2); fixture.strides_present = true; fixture.ext_stride = 2;
    fixture.set_stride = fixture.clr_stride = 16;
    fixture.ext_stride_len = fixture.set_stride_len = fixture.clr_stride_len = sizeof(u32);
    aic_init();
    if (aic || fixture.write_count) return fail("unaligned external stride was accepted");

    valid_fixture(2); fixture.strides_present = true; fixture.ext_stride = 0x1fc;
    fixture.set_stride = fixture.clr_stride = 16;
    fixture.ext_stride_len = fixture.set_stride_len = fixture.clr_stride_len = sizeof(u32);
    aic_init();
    if (aic || fixture.write_count) return fail("short multi-die config bank was accepted");

    valid_fixture(2); fixture.strides_present = true; fixture.ext_stride = 0x200;
    fixture.set_stride = fixture.clr_stride = 12;
    fixture.ext_stride_len = fixture.set_stride_len = fixture.clr_stride_len = sizeof(u32);
    aic_init();
    if (aic || fixture.write_count) return fail("short multi-die mask bank was accepted");

    valid_fixture(2); fixture.config_base = 0x7ffc; fixture.config_present = true;
    fixture.config_prop_len = sizeof(u32); aic_init();
    if (aic || fixture.write_count) return fail("out-of-aperture last bank was accepted");

    valid_fixture(2); fixture.ext_len = 6;
    set_record(0, 0, 3, 2); set_record(1, 2, 65, 3); aic_init();
    if (aic || fixture.write_count) return fail("later invalid record wrote before preflight");

    valid_fixture(2); aic_init();
    if (!aic) return fail("pointer-clear precondition did not initialize");
    unsigned reads = fixture.read_count;
    fixture.base = 0; aic_init();
    if (aic || fixture.read_count != reads) return fail("failed AIC init retained stale pointer");
    return expect_clean("stride guard changed backing or canary");
}

static int test_existing_metadata_guards(void)
{
    const u32 iack_lengths[] = {0, 4, 12};
    const u32 scalar_lengths[] = {0, 2, 8};
    for (unsigned i = 0; i < sizeof(iack_lengths) / sizeof(iack_lengths[0]); i++) {
        valid_fixture(3); fixture.iack_prop_len = iack_lengths[i]; aic_init();
        if (aic || fixture.read_count || fixture.write_count)
            return fail("AIC3 IACK exact-length guard changed");
    }
    for (unsigned i = 0; i < sizeof(scalar_lengths) / sizeof(scalar_lengths[0]); i++) {
        valid_fixture(3); fixture.cap_prop_len = scalar_lengths[i]; aic_init();
        if (aic || fixture.read_count || fixture.write_count)
            return fail("AIC3 cap0 exact-length guard changed");
        valid_fixture(3); fixture.max_prop_len = scalar_lengths[i]; aic_init();
        if (aic || fixture.read_count || fixture.write_count)
            return fail("AIC3 maxnumirq exact-length guard changed");
    }
    for (u32 len = 1; len <= 5; len++) {
        if (len == 3) continue;
        valid_fixture(2); fixture.ext_len = len; aic_init();
        if (aic || fixture.write_count)
            return fail("malformed external IRQ table was accepted");
    }
    valid_fixture(3); fixture.cap_ret = -1; aic_init();
    if (aic || fixture.read_count) return fail("missing AIC3 cap0 was accepted");
    valid_fixture(3); fixture.max_ret = -1; aic_init();
    if (aic || fixture.read_count) return fail("missing AIC3 maxnumirq was accepted");
    valid_fixture(3); fixture.cap_offset = -4; aic_init();
    if (aic || fixture.read_count) return fail("negative AIC3 cap0 offset was accepted");
    valid_fixture(3); fixture.max_offset = 0x106; aic_init();
    if (aic || fixture.read_count) return fail("unaligned AIC3 maxnumirq offset was accepted");
    valid_fixture(3); fixture.config_present = true; fixture.config_base = 0x18000;
    fixture.ext_len = 3; set_record(0, 0, 7, 4); aic_init();
    if (!aic || aic->regs.config != 0x18000) return fail("AIC3 config override was rejected");
    fixture.config_present = false; fixture.write_count = 0; aic_init();
    if (aic) return fail("missing AIC3 config retained prior override");
    valid_fixture(2); fixture.config_present = true; fixture.config_base = 0x3000;
    fixture.ext_len = 3; set_record(0, 0, 7, 4); aic_init();
    if (!aic || aic->regs.config != 0x3000) return fail("AIC2 config override was rejected");
    fixture.config_present = false; fixture.write_count = 0; aic_init();
    if (!aic || aic->regs.config != AIC2_IRQ_CFG) return fail("AIC2 config fallback changed");
    return expect_clean("metadata guard changed backing or canary");
}

static int test_runtime_guards(void)
{
    valid_fixture(2); aic_init();
    if (!aic) return fail("runtime fixture did not initialize");
    u32 ack_value = 0x12345678;
    memcpy(fixture.backing + AIC_EVENT, &ack_value, sizeof(ack_value));
    if (aic_ack() != ack_value) return fail("valid AIC ack changed");
    fixture.write_count = 0;
    aic_set_sw(3, true);
    aic_set_sw(130, false);
    if (fixture.write_count != 2 || fixture.raw_addrs[0] != fixture.base + aic->regs.sw_set + 0 ||
        fixture.raw_addrs[1] != fixture.base + aic->regs.sw_clr + aic->intmaskclear_stride)
        return fail("valid software set/clear address changed");
    fixture.write_count = 0; aic_set_sw(-1, true); aic_set_sw(256, true);
    if (fixture.write_count || fixture.mmio_fault) return fail("invalid software IRQ wrote");
    fixture.write_count = 0; aic->nr_irq = 3; aic_set_sw(3, true); aic->nr_irq = 128;
    if (fixture.write_count || fixture.mmio_fault) return fail("local IRQ boundary runtime guard wrote");
    fixture.write_count = 0; aic->nr_die = 1; aic_set_sw(128, true); aic->nr_die = 2;
    if (fixture.write_count || fixture.mmio_fault) return fail("die IRQ boundary runtime guard wrote");
    fixture.write_count = 0; aic->max_irq = 0; aic_set_sw(0, true);
    if (fixture.write_count || fixture.mmio_fault) return fail("zero max IRQ runtime guard wrote");
    aic->max_irq = 128;
    fixture.write_count = 0; aic->regs.sw_set = fixture.reg_size;
    aic_set_sw(0, true);
    if (fixture.write_count || fixture.mmio_fault) return fail("out-of-aperture software IRQ wrote");
    fixture.write_count = 0; aic_write(2, 1); aic_write((u32)fixture.reg_size, 1);
    if (fixture.write_count) return fail("invalid raw AIC write wrote");
    aic_write((u32)fixture.reg_size - 4, 1);
    if (fixture.write_count != 1) return fail("exact-end raw AIC write was rejected");
    unsigned reads = fixture.read_count;
    aic->regs.event = fixture.reg_size; if (aic_ack() != 0 || fixture.read_count != reads)
        return fail("out-of-aperture AIC ack read");
    aic->regs.event = fixture.reg_size - 2; if (aic_ack() != 0 || fixture.read_count != reads)
        return fail("unaligned AIC ack read");
    aic = NULL;
    if (aic_ack() != 0) return fail("NULL AIC ack was nonzero");
    aic_set_sw(0, true); aic_write(0, 1);
    if (fixture.write_count != 1) return fail("NULL AIC runtime guard wrote");
    return expect_clean("runtime guard changed backing or canary");
}

int main(void)
{
    if (test_valid_layouts() || test_single_die_zero_stride() || test_large_stride_cast() ||
        test_aperture_rejections() || test_stride_and_capacity_guards() ||
        test_existing_metadata_guards() || test_runtime_guards())
        return 1;
    puts("AIC aperture/stride harness: valid layouts, bounds, capacities, strides and runtime guards passed");
    return 0;
}

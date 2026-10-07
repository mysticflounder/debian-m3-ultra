/* Host-only hv_aic.c trace harness.  The runner inserts the reviewed
 * production body at INSERT_HV_AIC_SOURCE and production-derived constants at
 * INSERT_PRODUCTION_CONSTANTS.  No native MMIO or firmware is used. */

#include <assert.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "types.h"
#include "aic.h"
#include "aic_regs.h"

/* INSERT_PRODUCTION_CONSTANTS */

/* INSERT_PRODUCTION_HV_TYPES */

struct aic *aic;

static bool rw_result;
static int map_result;
static unsigned rw_calls;
static unsigned map_calls;
static unsigned suspend_calls;
static unsigned resume_calls;
static unsigned event_calls;
static u64 mapped_base;
static u64 mapped_size;
static hv_hook_t *mapped_hook;
static struct hv_evt_irqtrace last_event;
static void reset_trace_bitmap(void);
static bool trace_bitmap_bit(unsigned die, unsigned num);
static void set_trace_bitmap(unsigned die, unsigned num);

static void reset_mocks(void)
{
    rw_result = true;
    map_result = 0;
    rw_calls = 0;
    map_calls = 0;
    suspend_calls = 0;
    resume_calls = 0;
    event_calls = 0;
    mapped_base = 0;
    mapped_size = 0;
    mapped_hook = NULL;
    memset(&last_event, 0, sizeof(last_event));
    reset_trace_bitmap();
}

static void configure_aic(void)
{
    static struct aic fixture;
    memset(&fixture, 0, sizeof(fixture));
    fixture.base = 0x100000;
    fixture.nr_die = 2;
    fixture.nr_irq = 64;
    fixture.max_irq = 128;
    fixture.max_die = 2;
    fixture.regs.event = AIC_EVENT;
    fixture.regs.reg_size = AIC_REG_SIZE;
    aic = &fixture;
}

static int fail(const char *message)
{
    fprintf(stderr, "FAIL: %s\n", message);
    return 1;
}

static void debug_printf(const char *format, ...)
{
    va_list args;
    va_start(args, format);
    vfprintf(stderr, format, args);
    va_end(args);
}

static bool bitmap_bit(unsigned die, unsigned num)
{
    return trace_bitmap_bit(die, num);
}

bool hv_pa_rw(struct exc_info *ctx, u64 addr, u64 *val, bool write, int width)
{
    (void)ctx;
    (void)addr;
    (void)val;
    (void)write;
    (void)width;
    rw_calls++;
    return rw_result;
}

int hv_map_hook(u64 from, hv_hook_t *hook, u64 size)
{
    map_calls++;
    mapped_base = from;
    mapped_hook = hook;
    mapped_size = size;
    return map_result;
}

void hv_wdt_suspend(void) { suspend_calls++; }
void hv_wdt_resume(void) { resume_calls++; }

void uartproxy_send_event(u16 event_type, void *data, u16 length)
{
    if (event_type == EVT_IRQTRACE && length == sizeof(last_event)) {
        memcpy(&last_event, data, sizeof(last_event));
        event_calls++;
    }
}

/* INSERT_HV_AIC_SOURCE */

static void reset_trace_bitmap(void)
{
    memset(trace_hw_num, 0, sizeof(trace_hw_num));
}

static bool trace_bitmap_bit(unsigned die, unsigned num)
{
    return (trace_hw_num[die][num / 32] & BIT(num & 31)) != 0;
}

static void set_trace_bitmap(unsigned die, unsigned num)
{
    trace_hw_num[die][num / 32] |= BIT(num & 31);
}

static int test_invalid_state(void)
{
    u32 invalid[] = {0, AIC_MAX_HW_NUM + 1};
    for (unsigned i = 0; i < sizeof(invalid) / sizeof(invalid[0]); i++) {
        configure_aic();
        aic->max_irq = invalid[i];
        unsigned before = map_calls;
        if (hv_trace_irq(AIC_EVENT_TYPE_HW, 0, 1, IRQTRACE_IRQ) || map_calls != before)
            return fail("invalid max_irq was accepted");
    }
    configure_aic(); aic->nr_die = 0;
    if (hv_trace_irq(AIC_EVENT_TYPE_HW, 0, 1, IRQTRACE_IRQ))
        return fail("zero nr_die was accepted");
    configure_aic(); aic->nr_die = AIC_MAX_DIES + 1;
    if (hv_trace_irq(AIC_EVENT_TYPE_HW, 0, 1, IRQTRACE_IRQ))
        return fail("oversized nr_die was accepted");
    configure_aic(); aic->nr_irq = aic->max_irq + 1;
    if (hv_trace_irq(AIC_EVENT_TYPE_HW, 0, 1, IRQTRACE_IRQ))
        return fail("nr_irq over max_irq was accepted");
    configure_aic(); aic->nr_irq = 0;
    if (hv_trace_irq(AIC_EVENT_TYPE_HW, 0, 1, IRQTRACE_IRQ))
        return fail("zero nr_irq request was accepted");
    aic = NULL;
    if (hv_trace_irq(AIC_EVENT_TYPE_HW, 0, 1, IRQTRACE_IRQ))
        return fail("NULL AIC request was accepted");
    configure_aic();
    if (hv_trace_irq(AIC_EVENT_TYPE_IPI, 0, 1, IRQTRACE_IRQ))
        return fail("unsupported trace type was accepted");
    return 0;
}

static int test_mapping_and_ranges(void)
{
    configure_aic();
    map_result = -1;
    if (hv_trace_irq(AIC_EVENT_TYPE_HW, 0, 1, IRQTRACE_IRQ) ||
        map_calls != 1 || bitmap_bit(0, 0))
        return fail("failed hv_map_hook mutated trace state");
    map_result = 0;
    if (!hv_trace_irq(AIC_EVENT_TYPE_HW, 0, 1, IRQTRACE_IRQ) ||
        map_calls != 2 || !bitmap_bit(0, 0))
        return fail("valid trace did not retry hook and set bitmap");
    if (mapped_base != aic->base || mapped_size != aic->regs.reg_size || !mapped_hook)
        return fail("hook geometry changed");

    unsigned before = rw_calls;
    if (!hv_trace_irq(AIC_EVENT_TYPE_HW, 63, 0, IRQTRACE_IRQ) ||
        bitmap_bit(0, 63) || rw_calls != before)
        return fail("zero-count valid start changed bitmap");
    if (!hv_trace_irq(AIC_EVENT_TYPE_HW, 63, 1, IRQTRACE_IRQ) || !bitmap_bit(0, 63))
        return fail("final local IRQ was rejected");
    if (!hv_trace_irq(AIC_EVENT_TYPE_HW, 128, 1, IRQTRACE_IRQ) || !bitmap_bit(1, 0))
        return fail("global die mapping changed");
    if (!hv_trace_irq(AIC_EVENT_TYPE_HW, 191, 1, IRQTRACE_IRQ) || !bitmap_bit(1, 63))
        return fail("final multi-die IRQ was rejected");

    const u32 invalid_starts[] = {64, 192, 256, 4096, 65535};
    for (unsigned i = 0; i < sizeof(invalid_starts) / sizeof(invalid_starts[0]); i++) {
        if (hv_trace_irq(AIC_EVENT_TYPE_HW, invalid_starts[i], 1, IRQTRACE_IRQ))
            return fail("invalid global IRQ start was accepted");
    }
    if (hv_trace_irq(AIC_EVENT_TYPE_HW, 63, 2, IRQTRACE_IRQ) ||
        hv_trace_irq(AIC_EVENT_TYPE_HW, UINT32_MAX, UINT32_MAX, IRQTRACE_IRQ) ||
        hv_trace_irq(AIC_EVENT_TYPE_HW, 0, UINT32_MAX, IRQTRACE_IRQ))
        return fail("cross-die or overflowing IRQ range was accepted");
    if (!hv_trace_irq(AIC_EVENT_TYPE_HW, 63, 1, 0) || bitmap_bit(0, 63))
        return fail("clear flags semantics changed");
    return 0;
}

static int test_event_callback(void)
{
    configure_aic();
    u64 value = ((u64)1 << 24) | ((u64)AIC_EVENT_TYPE_HW << 16) | 63;
    rw_result = true;
    rw_calls = 0;
    event_calls = 0;
    if (!mapped_hook || !bitmap_bit(1, 63))
        return fail("event callback precondition missing");
    if (!mapped_hook(NULL, aic->base + aic->regs.event, &value, false, 2) ||
        rw_calls != 1 || event_calls != 1 || last_event.num != 191 ||
        last_event.flags != IRQTRACE_IRQ || last_event.type != AIC_EVENT_TYPE_HW ||
        suspend_calls != 1 || resume_calls != 1)
        return fail("valid event was not emitted");
    const u32 bad_values[] = {
        (4U << 24) | (AIC_EVENT_TYPE_HW << 16) | 1U,
        (2U << 24) | (AIC_EVENT_TYPE_HW << 16) | 1U,
        (1U << 24) | (AIC_EVENT_TYPE_HW << 16) | 64U,
        (1U << 24) | (AIC_EVENT_TYPE_HW << 16) | 4096U,
        (1U << 24) | (AIC_EVENT_TYPE_HW << 16) | 65535U,
    };
    /* die==nr_die is within the four-element production bitmap, but must be
     * rejected by the configured-die bound.  This is also a safe mutation
     * witness when that one guard is removed. */
    set_trace_bitmap(2, 1);
    set_trace_bitmap(1, 64);
    for (unsigned i = 0; i < sizeof(bad_values) / sizeof(bad_values[0]); i++) {
        value = bad_values[i];
        rw_calls = 0;
        unsigned before_events = event_calls;
        if (!mapped_hook(NULL, aic->base + aic->regs.event, &value, false, 2) || rw_calls != 1)
            return fail("invalid event geometry passthrough changed");
        if (event_calls != before_events)
            return fail("invalid event geometry emitted an event");
    }
    /* With all four production bitmap dies enabled, die==4 must still be
     * rejected by the fixed AIC_MAX_DIES bound before bitmap indexing. */
    aic->nr_die = AIC_MAX_DIES;
    value = (AIC_MAX_DIES << 24) | (AIC_EVENT_TYPE_HW << 16) | 1U;
    rw_calls = 0;
    if (!mapped_hook(NULL, aic->base + aic->regs.event, &value, false, 2) ||
        rw_calls != 1 || event_calls != 1)
        return fail("event die equal to AIC_MAX_DIES was emitted");
    aic->nr_die = 2;
    aic->max_irq = 0;
    rw_calls = 0;
    if (mapped_hook(NULL, aic->base + aic->regs.event, &value, false, 2) || rw_calls != 0)
        return fail("callback accepted invalid max_irq or performed RW");
    aic = NULL;
    rw_calls = 0;
    if (mapped_hook(NULL, 0, &value, false, 2) || rw_calls != 0)
        return fail("callback accepted NULL AIC or performed RW");
    configure_aic();
    value = ((u64)1 << 24) | ((u64)AIC_EVENT_TYPE_HW << 16) | 63;
    rw_result = false;
    rw_calls = 0;
    if (mapped_hook(NULL, aic->base + aic->regs.event, &value, false, 2) || rw_calls != 1)
        return fail("failed hv_pa_rw was not propagated");
    rw_result = true;
    rw_calls = 0;
    if (!mapped_hook(NULL, aic->base + aic->regs.event, &value, true, 2) || rw_calls != 1)
        return fail("event write passthrough changed");
    rw_calls = 0;
    if (!mapped_hook(NULL, aic->base + aic->regs.event, &value, false, 4) || rw_calls != 1)
        return fail("event width passthrough changed");
    rw_calls = 0;
    if (!mapped_hook(NULL, aic->base + aic->regs.event + 4, &value, false, 2) || rw_calls != 1)
        return fail("non-event passthrough changed");
    return 0;
}

int main(void)
{
    reset_mocks();
    if (test_invalid_state() || test_mapping_and_ranges() || test_event_callback())
        return 1;
    puts("HV AIC trace harness: state, global ranges, mapping retry and event geometry passed");
    return 0;
}

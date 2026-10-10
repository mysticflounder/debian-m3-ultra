/* Actual Linux Apple-SPMI wait/raw-command bodies are injected by the runner. */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef unsigned long size_t_kernel;
typedef int ktime_t;

#define EIO 5
#define ETIMEDOUT 110
#define BIT(n) (1u << (n))
#define GENMASK(h, l) ((((1u << ((h) - (l) + 1)) - 1u)) << (l))
#define FIELD_GET(mask, value) (((value) & (mask)) >> __builtin_ctz(mask))
#define min_t(type, a, b) ((type)((a) < (b) ? (a) : (b)))
#define __iomem
#define SPMI_STATUS_REG 0
#define SPMI_CMD_REG 0x4
#define SPMI_RSP_REG 0x8
#define SPMI_ACT_REG 0xa4
#define SPMI_IRQ_NOTIFY 256
#define SPMI_ACT_FIFO_FLUSH BIT(0)
#define SPMI_RX_FIFO_EMPTY BIT(24)
#define SPMI_REPLY_FRAME_PARITY_STATUS GENMASK(31, 16)
#define SPMI_REPLY_ACK BIT(15)
#define REG_POLL_INTERVAL_US 10000
#define REG_POLL_TIMEOUT_US 100000

struct completion { int count; };
struct mutex { int held; };
struct device { void *drvdata; };
struct spmi_controller { struct device dev; };
struct apple_spmi {
    unsigned char *regs;
    struct mutex fifo_lock;
    struct completion fifo_rx;
    bool notify_irq;
    bool prev_fail;
};

static unsigned char fake_regs[0x200];
static int wait_result;
static u32 reply_word;
static u32 status_word;
static unsigned int status_reads;
static int reinit_count;
static int notify_ack_calls;
struct write_event { size_t offset; u32 value; };
static struct write_event writes[32];
static size_t write_count;

static void reset_fixture(void)
{
    memset(fake_regs, 0, sizeof(fake_regs));
    memset(writes, 0, sizeof(writes));
    wait_result = 1;
    reply_word = SPMI_REPLY_ACK | SPMI_REPLY_FRAME_PARITY_STATUS;
    status_word = 0;
    status_reads = 0;
    reinit_count = notify_ack_calls = 0;
    write_count = 0;
}
static struct apple_spmi *spmi_controller_get_drvdata(struct spmi_controller *ctrl)
{ return (struct apple_spmi *)ctrl->dev.drvdata; }
static void fake_guard_mutex(struct mutex *lock) { lock->held++; }
#define guard(type) fake_guard_##type
static void reinit_completion(struct completion *c) { c->count = 0; reinit_count++; }
static unsigned long wait_for_completion_timeout(struct completion *c, unsigned long timeout)
{ (void)c; (void)timeout; return (unsigned long)wait_result; }
static unsigned long usecs_to_jiffies(unsigned int usec) { return usec; }
static u32 readl(const void *address)
{
    size_t offset = (size_t)((const unsigned char *)address - fake_regs);
    if (offset == SPMI_STATUS_REG)
        return (status_reads++ % 2) ? SPMI_RX_FIFO_EMPTY : status_word;
    if (offset == SPMI_RSP_REG) return reply_word;
    return 0;
}
static void writel(u32 value, void *address)
{
    size_t offset = (size_t)((unsigned char *)address - fake_regs);
    if (write_count < sizeof(writes) / sizeof(writes[0]))
        writes[write_count++] = (struct write_event){offset, value};
}
static int fake_poll_reg(struct apple_spmi *spmi, unsigned int reg, u32 *value)
{ (void)spmi; (void)reg; *value = status_word; return 0; }
#define poll_reg(spmi, reg, value, cond) fake_poll_reg((spmi), (reg), &(value))
static void apple_spmi_irq_ack_raw(struct apple_spmi *spmi, u32 irq)
{ (void)spmi; (void)irq; notify_ack_calls++; }
static void dev_err(void *dev, const char *fmt, ...) { (void)dev; (void)fmt; }
static void dev_err_ratelimited(void *dev, const char *fmt, ...) { (void)dev; (void)fmt; }
static void dev_warn(void *dev, const char *fmt, ...) { (void)dev; (void)fmt; }

/* ACTUAL_FUNCTIONS_BEGIN */
/* ACTUAL_FUNCTIONS_END */

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL:%s:%d:%s\n", __FILE__, __LINE__, #x); return 1; } } while (0)

static void setup(struct spmi_controller *ctrl, struct apple_spmi *spmi)
{
    reset_fixture();
    memset(ctrl, 0, sizeof(*ctrl));
    memset(spmi, 0, sizeof(*spmi));
    spmi->regs = fake_regs;
    spmi->notify_irq = true;
    ctrl->dev.drvdata = spmi;
}

static int test_normal_no_flush(void)
{
    struct spmi_controller ctrl; struct apple_spmi spmi;
    setup(&ctrl, &spmi);
    CHECK(spmi_raw_cmd(&ctrl, 0x80, 3, 0, NULL, 0, NULL, 0) == 0);
    CHECK(!spmi.prev_fail && reinit_count == 1 && notify_ack_calls == 0);
    CHECK(write_count == 1 && writes[0].offset == SPMI_CMD_REG);
    for (size_t i = 0; i < write_count; ++i)
        CHECK(writes[i].offset != SPMI_ACT_REG && writes[i].offset != SPMI_RSP_REG);
    return 0;
}

static int test_timeout_then_retry_act_flush(void)
{
    struct spmi_controller ctrl; struct apple_spmi spmi;
    setup(&ctrl, &spmi);
    wait_result = 0;
    CHECK(spmi_raw_cmd(&ctrl, 0x80, 3, 0, NULL, 0, NULL, 0) == -ETIMEDOUT);
    CHECK(spmi.prev_fail && write_count == 1 && writes[0].offset == SPMI_CMD_REG);
    wait_result = 1;
    CHECK(spmi_raw_cmd(&ctrl, 0x80, 3, 0, NULL, 0, NULL, 0) == 0);
    CHECK(!spmi.prev_fail && notify_ack_calls == 1 && reinit_count == 2);
    CHECK(write_count == 3);
    CHECK(writes[1].offset == SPMI_ACT_REG && writes[1].value == SPMI_ACT_FIFO_FLUSH);
    CHECK(writes[2].offset == SPMI_CMD_REG);
    CHECK(writes[1].offset != SPMI_RSP_REG);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc == 2 && strcmp(argv[1], "mutation") == 0) {
        /* The mutant changes the recovery target; this assertion must exit 1. */
        return test_timeout_then_retry_act_flush();
    }
    if (test_normal_no_flush() || test_timeout_then_retry_act_flush()) return 1;
    puts("spmi-fifo-recovery-host: PASS normal=1 timeout-retry=1");
    return 0;
}

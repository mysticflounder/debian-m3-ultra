/* Host fixture: the implementation bodies are injected by test-j575d-select-polling.py. */
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

typedef uint8_t u8;
typedef uint32_t u32;
typedef long long ktime_t;
typedef int irqreturn_t;
typedef unsigned long size_t_kernel;

#define IRQ_HANDLED 1
#define EIO 5
#define ETIMEDOUT 110
#define EINVAL 22
#define ENXIO 6
#define EREMOTEIO 121
#define EPROBE_DEFER 517
#define ENOMEM 12
#define ENODATA 61
#define EILSEQ 84
#define IRQ_TYPE_EDGE_RISING 1
#define REGMAP_ENDIAN_NATIVE 0
#define WARN_ON(x) ((void)(x))
#define GFP_KERNEL 0
#define IS_ERR(x) false
#define PTR_ERR(x) (-1)
#define min_t(type, a, b) ((type)((a) < (b) ? (a) : (b)))
#define BIT(n) (1U << (n))
#define ARRAY_SIZE(a) ((int)(sizeof(a) / sizeof((a)[0])))
#define container_of_const(ptr, type, member) \
    ((type *)((char *)(ptr) - offsetof(type, member)))
#define tps_to_sn(tps) container_of_const((tps), struct sn201202x, cd.tps)

struct device_node;
struct device { struct device_node *of_node; void *drvdata; };
struct completion { int count; };
struct spmi_device { struct device dev; void *drvdata; };
struct mutex { int initialized; };
struct regmap { int dummy; };
struct tps6598x { struct device *dev; struct mutex lock; const void *data; int irq; struct regmap *regmap; };
struct cd321x { struct tps6598x tps; };
struct sn201202x {
    struct cd321x cd;
    struct completion select_completion;
    struct completion sleep_completion;
    struct completion wake_completion;
    struct spmi_device *sdev;
    bool experimental_polling;
};
struct regmap_bus {
    int (*read)(void *, const void *, size_t, void *, size_t);
    int (*write)(void *, const void *, size_t);
    int reg_format_endian_default;
    int val_format_endian_default;
};
struct property { int length; };
struct device_node {
    const struct property *poll_property;
    int name_count, name_count_error, name_errors[4], irq_count;
    const char *names[4];
    int irq_values[4], irq_errors[4];
};
struct of_device_id { const void *data; };
struct tipd_data { size_t tps_struct_size; };
static const struct tipd_data tipd_sn201202x_data = { sizeof(struct sn201202x) };
static const struct of_device_id sn201202x_of_match[] = {{ &tipd_sn201202x_data }, { NULL }};
static struct sn201202x probe_storage;
static struct regmap probe_regmap;
static const int tps6598x_regmap_config;
static struct device_node probe_node;
static struct property probe_property;
static int request_irq_error;
static int probe_wakeup_error;
static unsigned int request_irq_calls;

static long long fake_now_us;
static int zero_write_error;
static int register_read_error_at;
static int register_read_error_code;
static int ext_read_error_at;
static int ext_read_error_code;
static int ext_write_error_at;
static int ext_write_error_code;
static int ext_read_advance_us;
static int register_read_advance_at;
static int register_read_advance_us;
static unsigned long completion_wait_result;
static int zero_writes;
static int register_reads;
static int ext_reads;
static int ext_writes;
static int complete_calls;
static size_t read_offsets[8], read_lengths[8];
static size_t write_offsets[8], write_lengths[8];
static u8 statuses[256];
static size_t status_count, status_index;
static u8 payload[64];

static void reset_state(void)
{
    fake_now_us = 0;
    zero_write_error = 0;
    register_read_error_at = -1;
    register_read_error_code = -EIO;
    ext_read_error_at = -1;
    ext_read_error_code = -EIO;
    ext_write_error_at = -1;
    ext_write_error_code = -EIO;
    ext_read_advance_us = 0;
    register_read_advance_at = -1;
    register_read_advance_us = 0;
    completion_wait_result = 1;
    zero_writes = register_reads = ext_reads = ext_writes = 0;
    complete_calls = 0;
    status_count = status_index = 0;
    memset(statuses, 0, sizeof(statuses));
    memset(payload, 0, sizeof(payload));
    memset(&probe_node, 0, sizeof(probe_node));
    memset(&probe_storage, 0, sizeof(probe_storage));
    request_irq_error = 0;
    probe_wakeup_error = 0;
    request_irq_calls = 0;
}

static void set_statuses(const u8 *values, size_t count)
{
    if (count > sizeof(statuses)) count = sizeof(statuses);
    memcpy(statuses, values, count);
    status_count = count;
    status_index = 0;
}

static ktime_t ktime_get(void) { return fake_now_us; }
static ktime_t ktime_add_us(ktime_t now, unsigned int usec) { return now + usec; }
static bool ktime_before(ktime_t a, ktime_t b) { return a < b; }
static void usleep_range(unsigned int min, unsigned int max) { (void)max; fake_now_us += min; }
static unsigned long msecs_to_jiffies(unsigned int msec) { return msec; }
static void msleep(unsigned int msec) { fake_now_us += (long long)msec * 1000; }
static void reinit_completion(struct completion *c) { c->count = 0; }
static void init_completion(struct completion *c) { c->count = 0; }
static unsigned long wait_for_completion_timeout(struct completion *c, unsigned long t)
{
    (void)c; (void)t; return completion_wait_result;
}
static void complete(struct completion *c) { c->count++; complete_calls++; }
static void dev_warn(void *dev, const char *fmt, ...) { (void)dev; (void)fmt; }
static void mutex_init(struct mutex *m) { m->initialized = 1; }
static void *devm_kzalloc(struct device *dev, size_t size, int flags)
{ (void)dev; (void)size; (void)flags; memset(&probe_storage, 0, sizeof(probe_storage)); return &probe_storage; }
static const struct of_device_id *of_match_device(const struct of_device_id *ids,
                                                   const struct device *dev)
{ (void)dev; return ids; }
static const struct property *of_find_property(const struct device_node *np,
                                                const char *name, int *lenp)
{ (void)name; if (lenp) *lenp = np->poll_property ? np->poll_property->length : 0; return np->poll_property; }
static int of_property_count_strings(const struct device_node *np, const char *name)
{ (void)name; return np->name_count_error ? np->name_count_error : np->name_count; }
static int of_property_read_string_index(const struct device_node *np, const char *name,
                                         int index, const char **value)
{ (void)name; if (index < 0 || index >= np->name_count || !np->names[index]) return -ENODATA; if (np->name_errors[index]) return np->name_errors[index]; *value = np->names[index]; return 0; }
static int of_irq_get_byname(const struct device_node *np, const char *name)
{
    for (int i = 0; i < np->name_count; ++i)
        if (np->names[i] && strcmp(np->names[i], name) == 0)
            return np->irq_errors[i] ? np->irq_errors[i] : np->irq_values[i];
    return -ENODATA;
}
static int of_irq_count(const struct device_node *np) { return np->irq_count; }
static int devm_request_irq(struct device *dev, int irq, irqreturn_t (*fn)(int, void *),
                            unsigned long flags, const char *name, void *data)
{ (void)dev; (void)irq; (void)fn; (void)flags; (void)name; (void)data; request_irq_calls++; return request_irq_error; }
static void spmi_device_set_drvdata(struct spmi_device *sdev, void *data) { sdev->drvdata = data; sdev->dev.drvdata = data; }
static struct regmap *devm_regmap_init_sn201202x(struct spmi_device *sdev, const void *config)
{ (void)sdev; (void)config; return &probe_regmap; }
static int spmi_command_wakeup(struct spmi_device *sdev) { (void)sdev; return probe_wakeup_error; }
static void spmi_command_sleep(struct spmi_device *sdev) { (void)sdev; }
static int tipd_init(struct tps6598x *tps) { (void)tps; return 0; }
static struct tps6598x *spmi_device_get_drvdata(struct spmi_device *sdev)
{ return (struct tps6598x *)sdev->drvdata; }

static int spmi_register_zero_write(struct spmi_device *sdev, u8 reg)
{
    (void)sdev; (void)reg; zero_writes++; status_index = 0;
    return zero_write_error;
}
static int spmi_register_read(struct spmi_device *sdev, unsigned int reg, u8 *value)
{
    (void)sdev; (void)reg;
    if (register_read_error_at >= 0 && register_reads == register_read_error_at)
        return register_read_error_code;
    register_reads++;
    if (!status_count) return -EIO;
    *value = statuses[status_index < status_count ? status_index++ : status_count - 1];
    if (register_read_advance_at < 0 || register_reads - 1 == register_read_advance_at)
        fake_now_us += register_read_advance_us;
    return 0;
}
static int spmi_ext_register_read(struct spmi_device *sdev, unsigned int offset,
                                  void *value, size_t len)
{
    (void)sdev;
    if (ext_read_error_at >= 0 && ext_reads == ext_read_error_at) return ext_read_error_code;
    if (ext_reads < 8) { read_offsets[ext_reads] = offset; read_lengths[ext_reads] = len; }
    memset(value, (int)(offset & 0xff), len);
    ext_reads++;
    fake_now_us += ext_read_advance_us;
    return 0;
}
static int spmi_ext_register_write(struct spmi_device *sdev, unsigned int offset,
                                   const void *value, size_t len)
{
    (void)sdev; (void)value;
    if (ext_write_error_at >= 0 && ext_writes == ext_write_error_at) return ext_write_error_code;
    if (ext_writes < 8) { write_offsets[ext_writes] = offset; write_lengths[ext_writes] = len; }
    ext_writes++;
    return 0;
}

/* ACTUAL_MACROS_BEGIN */
/* ACTUAL_MACROS_END */
/* ACTUAL_FUNCTIONS_BEGIN */
/* ACTUAL_FUNCTIONS_END */

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL:%s:%d:%s\n", __FILE__, __LINE__, #x); return 1; } } while (0)

static struct sn201202x sn;
static struct spmi_device sdev;
static u8 reg;

static void fixture(bool polling)
{
    memset(&sn, 0, sizeof(sn));
    memset(&sdev, 0, sizeof(sdev));
    sn.experimental_polling = polling;
    sn.sdev = &sdev;
    sdev.drvdata = &sn.cd.tps;
    sdev.dev.of_node = &probe_node;
    reset_state();
}

static void probe_fixture(bool polling, int property_length, int count,
                          int irq_count)
{
    fixture(false);
    probe_node.name_count = count;
    probe_node.irq_count = irq_count;
    if (polling) {
        probe_property.length = property_length;
        probe_node.poll_property = &probe_property;
    }
    for (int i = 0; i < count && i < 4; ++i) {
        static const char * const names[] = { "irq", "sleep", "wake", "select" };
        probe_node.names[i] = names[i];
        probe_node.irq_values[i] = 11 + i;
    }
}

static int expect_select(const u8 *values, size_t count, int expected)
{
    set_statuses(values, count);
    reg = 0x12;
    return regmap_sn201202x_select_reg(&sdev, reg) == expected ? 0 : 1;
}

static int test_polling(void)
{
    const u8 busy_ready[] = { 0x92, 0x12 };
    const u8 ready[] = { 0x12 };
    const u8 busy[] = { 0x92 };
    const u8 mismatch[] = { 0x33 };
    fixture(true);
    CHECK(expect_select(busy_ready, 2, 0) == 0);
    CHECK(zero_writes == 1 && register_reads == 2);
    CHECK(expect_select(ready, 1, -ETIMEDOUT) == 0);
    CHECK(zero_writes == 2 && register_reads >= 2);
    fixture(true); CHECK(expect_select(busy, 1, -ETIMEDOUT) == 0);
    CHECK(register_reads <= 128 && fake_now_us >= 100000);
    fixture(true); set_statuses(busy_ready, 2); reg = 0x12;
    CHECK(regmap_sn201202x_select_reg(&sdev, reg) == 0);
    set_statuses(ready, 1); CHECK(regmap_sn201202x_select_reg(&sdev, reg) == -ETIMEDOUT);
    fixture(true); set_statuses(busy_ready, 2); reg = 0x80;
    CHECK(regmap_sn201202x_select_reg(&sdev, reg) == -EINVAL && zero_writes == 0);
    fixture(true); CHECK(expect_select(mismatch, 1, -EIO) == 0);
    fixture(true); zero_write_error = -EIO; CHECK(expect_select(busy_ready, 2, -EIO) == 0);
    fixture(true); zero_write_error = -EREMOTEIO; CHECK(expect_select(busy_ready, 2, -EREMOTEIO) == 0);
    fixture(true); register_read_error_at = 0; register_read_error_code = -ENXIO; CHECK(expect_select(busy_ready, 2, -ENXIO) == 0);
    fixture(true); set_statuses(busy_ready, 2); ext_read_error_at = 0; ext_read_error_code = -EREMOTEIO; reg = 0x12;
    { u8 out[0x20]; CHECK(regmap_sn201202x_read(&sdev, &reg, 1, out, sizeof(out)) == -EREMOTEIO); CHECK(ext_reads == 0); }
    fixture(true); set_statuses(busy_ready, 2); ext_read_error_at = 1; ext_read_error_code = -ENXIO; reg = 0x12;
    { u8 out[0x20]; CHECK(regmap_sn201202x_read(&sdev, &reg, 1, out, sizeof(out)) == -ENXIO); CHECK(ext_reads == 1); CHECK(read_offsets[0] == 0x20); }
    fixture(true); set_statuses(busy_ready, 2); register_read_advance_at = 1; register_read_advance_us = 101000; reg = 0x12;
    { u8 out[1]; CHECK(regmap_sn201202x_read(&sdev, &reg, 1, out, sizeof(out)) == -ETIMEDOUT); }
    fixture(true); set_statuses(busy_ready, 2); reg = 0x12;
    { u8 out[0x20]; CHECK(regmap_sn201202x_read(&sdev, &reg, 1, out, sizeof(out)) == 0); CHECK(ext_reads == 2); CHECK(read_offsets[0] == 0x20 && read_offsets[1] == 0x30); CHECK(read_lengths[0] == 16 && read_lengths[1] == 16); }
    fixture(true); set_statuses(busy_ready, 2); reg = 0x12;
    { u8 in[0x21] = {0x12}; CHECK(regmap_sn201202x_write(&sdev, in, sizeof(in)) == 0); CHECK(ext_writes == 2); CHECK(write_offsets[0] == 0xa0 && write_offsets[1] == 0xb0); CHECK(write_lengths[0] == 16 && write_lengths[1] == 16); }
    fixture(true); set_statuses(busy_ready, 2); ext_write_error_at = 1; ext_write_error_code = -ENXIO; reg = 0x12;
    { u8 in[0x21] = {0x12}; CHECK(regmap_sn201202x_write(&sdev, in, sizeof(in)) == -ENXIO); CHECK(ext_writes == 1); }
    return 0;
}

static int test_stale_only(void)
{
    const u8 ready[] = { 0x12 };
    fixture(true);
    CHECK(expect_select(ready, 1, -ETIMEDOUT) == 0);
    CHECK(zero_writes == 1 && ext_reads == 0 && ext_writes == 0);
    fixture(true); set_statuses(ready, 1); reg = 0x12;
    { u8 out[1]; CHECK(regmap_sn201202x_read(&sdev, &reg, 1, out, sizeof(out)) == -ETIMEDOUT); CHECK(ext_reads == 0); }
    fixture(true); set_statuses(ready, 1); reg = 0x12;
    { u8 in[2] = {0x12, 1}; CHECK(regmap_sn201202x_write(&sdev, in, sizeof(in)) == -ETIMEDOUT); CHECK(ext_writes == 0); }
    return 0;
}

static int test_irq_legacy(void)
{
    struct completion c = {0};
    const u8 ready[] = { 0x12 };
    fixture(false);
    set_statuses(ready, 1); reg = 0x12;
    CHECK(regmap_sn201202x_select_reg(&sdev, reg) == 0);
    CHECK(zero_writes == 1 && register_reads == 1);
    fixture(false); completion_wait_result = 0; set_statuses(ready, 1); reg = 0x12;
    CHECK(regmap_sn201202x_select_reg(&sdev, reg) == -ETIMEDOUT);
    fixture(false); { const u8 busy[] = {0x92}; set_statuses(busy, 1); reg = 0x12; CHECK(regmap_sn201202x_select_reg(&sdev, reg) == -EIO); }
    CHECK(sn201202x_irq(7, &c) == IRQ_HANDLED);
    CHECK(c.count == 1 && complete_calls == 1);
    return 0;
}

static int test_probe_runtime(void)
{
    probe_fixture(false, 0, 4, 4);
    CHECK(sn201202x_probe(&sdev) == 0 && !probe_storage.experimental_polling);
    CHECK(request_irq_calls == 3);
    probe_fixture(false, 0, 3, 3);
    CHECK(sn201202x_probe(&sdev) == -ENODATA);
    CHECK(request_irq_calls == 0 && !probe_storage.experimental_polling);
    probe_fixture(true, 0, 3, 3);
    CHECK(sn201202x_probe(&sdev) == 0 && probe_storage.experimental_polling);
    CHECK(request_irq_calls == 2);
    probe_fixture(true, 1, 3, 3);
    CHECK(sn201202x_probe(&sdev) == -EINVAL);
    probe_fixture(true, 0, 4, 4);
    CHECK(sn201202x_probe(&sdev) == -EINVAL);
    probe_fixture(true, 0, 3, 0);
    CHECK(sn201202x_probe(&sdev) == -EINVAL && request_irq_calls == 0);
    probe_fixture(true, 0, 3, 4);
    CHECK(sn201202x_probe(&sdev) == -EINVAL && request_irq_calls == 0);
    probe_fixture(true, 0, 3, 3); probe_node.names[1] = "wake";
    CHECK(sn201202x_probe(&sdev) == -EINVAL);
    probe_fixture(true, 0, 3, 3); probe_node.names[2] = "sleep";
    CHECK(sn201202x_probe(&sdev) == -EINVAL);
    probe_fixture(true, 0, 3, 3); probe_node.name_errors[1] = -EINVAL;
    CHECK(sn201202x_probe(&sdev) == -EINVAL);
    probe_fixture(true, 0, 3, 3); probe_node.names[1] = NULL;
    CHECK(sn201202x_probe(&sdev) == -ENODATA);
    probe_fixture(true, 0, 3, 3); probe_node.name_count_error = -EILSEQ;
    CHECK(sn201202x_probe(&sdev) == -EILSEQ);
    probe_fixture(true, 0, 3, 3); probe_node.name_errors[1] = -EILSEQ;
    CHECK(sn201202x_probe(&sdev) == -EILSEQ);
    probe_fixture(true, 0, 3, 3); probe_node.irq_values[0] = 0;
    CHECK(sn201202x_probe(&sdev) == -EINVAL);
    probe_fixture(true, 0, 3, 3); probe_node.irq_values[1] = 0;
    CHECK(sn201202x_probe(&sdev) == -EINVAL);
    probe_fixture(true, 0, 3, 3); probe_node.irq_values[2] = 0;
    CHECK(sn201202x_probe(&sdev) == -EINVAL);
    probe_fixture(true, 0, 3, 3); probe_node.irq_errors[0] = -EPROBE_DEFER;
    CHECK(sn201202x_probe(&sdev) == -EPROBE_DEFER);
    probe_fixture(true, 0, 3, 3); probe_node.irq_errors[1] = -EPROBE_DEFER;
    CHECK(sn201202x_probe(&sdev) == -EPROBE_DEFER);
    probe_fixture(true, 0, 3, 3); probe_node.irq_errors[2] = -EPROBE_DEFER;
    CHECK(sn201202x_probe(&sdev) == -EPROBE_DEFER);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc == 2 && strcmp(argv[1], "stale-only") == 0) {
        if (test_stale_only()) return 1;
        puts("stale-ready-host: PASS");
        return 0;
    }
    if (test_polling() || test_stale_only() || test_irq_legacy() || test_probe_runtime()) return 1;
    puts("select-polling-host: PASS");
    return 0;
}

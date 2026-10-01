/* Host-only harness template.  The runner inserts the pinned cpufreq.c body
 * at the marker below; every platform operation is a test-visible mock. */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;

#define BIT(x)                 (1ULL << (x))
#define GENMASK(msb, lsb)      ((BIT((msb + 1) - (lsb)) - 1) << (lsb))
#define _FIELD_LSB(field)      ((field) & ~(field - 1))
#define FIELD_PREP(field, val) (((val) * (_FIELD_LSB(field))) & (field))
#define FIELD_GET(field, val)  (((val) & (field)) / _FIELD_LSB(field))

#define S5L8960X 0x8960
#define T7000    0x7000
#define T7001    0x7001
#define S8000    0x8000
#define S8001    0x8001
#define S8003    0x8003
#define T8010    0x8010
#define T8011    0x8011
#define T8012    0x8012
#define T8015    0x8015
#define T8103    0x8103
#define T8112    0x8112
#define T8122    0x8122
#define T6000    0x6000
#define T6001    0x6001
#define T6002    0x6002
#define T6020    0x6020
#define T6021    0x6021
#define T6022    0x6022
#define T6030    0x6030
#define T6031    0x6031
#define T6034    0x6034

enum fw_version { V_UNKNOWN = 0, V13_3 = 1 };
struct fw_version_info { enum fw_version version; };
struct fw_version_info os_firmware;
void *adt;
u32 board_id;
u32 chip_id;

enum event_kind {
    EV_READ64,
    EV_WRITE64_PSTATE,
    EV_WRITE64_RESTORE,
    EV_WRITE64_OTHER,
    EV_POLL64,
    EV_FEATURE_QUERY,
    EV_MASK64,
    EV_POLL32,
    EV_ADT_PATH,
    EV_ADT_REG,
    EV_SET64,
};

struct event { enum event_kind kind; u64 addr; };
struct mock_state {
    struct event events[256];
    unsigned event_count;
    u64 pstate_value;
    unsigned poll64_calls;
    unsigned poll32_calls;
    unsigned fail_poll64_at;
    unsigned fail_poll32_at;
};
static struct mock_state mock;

static void record(enum event_kind kind, u64 addr)
{
    if (mock.event_count >= sizeof(mock.events) / sizeof(mock.events[0])) {
        fprintf(stderr, "event log overflow\n");
        __builtin_trap();
    }
    mock.events[mock.event_count++] = (struct event){kind, addr};
}

static void reset_mock(void)
{
    memset(&mock, 0, sizeof(mock));
    os_firmware.version = V_UNKNOWN;
}

static u64 read64(u64 addr)
{
    record(EV_READ64, addr);
    return mock.pstate_value;
}

static void write64(u64 addr, u64 value)
{
    (void)value;
    u64 offset = addr & 0xfffff;
    record(offset == 0x20020 ? EV_WRITE64_PSTATE
                             : (offset == 0x440f8 ? EV_WRITE64_RESTORE : EV_WRITE64_OTHER), addr);
}

static void write32(u64 addr, u32 value)
{
    (void)value;
    record(EV_WRITE64_OTHER, addr);
}

static u64 set64(u64 addr, u64 value)
{
    (void)value;
    record(EV_SET64, addr);
    return 0;
}

static u64 mask64(u64 addr, u64 clear, u64 set)
{
    (void)clear;
    (void)set;
    record(EV_MASK64, addr);
    return 0;
}

static int poll64(u64 addr, u64 mask, u64 target, u32 timeout)
{
    (void)mask;
    (void)target;
    (void)timeout;
    record(EV_POLL64, addr);
    mock.poll64_calls++;
    return mock.fail_poll64_at == mock.poll64_calls ? -1 : 0;
}

static int poll32(u64 addr, u32 mask, u32 target, u32 timeout)
{
    (void)mask;
    (void)target;
    (void)timeout;
    record(EV_POLL32, addr);
    mock.poll32_calls++;
    return mock.fail_poll32_at == mock.poll32_calls ? -1 : 0;
}

u32 read32(u64 addr)
{
    record(EV_READ64, addr);
    return 0;
}

static u32 pmgr_get_feature(const char *name)
{
    (void)name;
    record(EV_FEATURE_QUERY, 0);
    return 0;
}

static int pmgr_power_on(int die, const char *name)
{
    (void)die;
    (void)name;
    return 0;
}

static int adt_path_offset_trace(const void *tree, const char *path, int *offsets)
{
    (void)tree;
    (void)path;
    offsets[0] = 0;
    record(EV_ADT_PATH, 0);
    return 0;
}

static int adt_get_reg(const void *tree, int *path, const char *prop, int index,
                       u64 *addr, u64 *size)
{
    (void)tree;
    (void)path;
    (void)prop;
    (void)index;
    *addr = 0x100000000ULL;
    if (size)
        *size = 0;
    record(EV_ADT_REG, *addr);
    return 0;
}

/* INSERT_CPUFREQ_SOURCE */

static int fail(const char *message)
{
    fprintf(stderr, "FAIL: %s\n", message);
    return 1;
}

static int expect_event(unsigned *index, enum event_kind kind, u64 addr)
{
    if (*index >= mock.event_count || mock.events[*index].kind != kind ||
        mock.events[*index].addr != addr) {
        fprintf(stderr, "event %u mismatch (wanted kind=%d addr=0x%llx, got kind=%d addr=0x%llx)\n",
                *index, kind, (unsigned long long)addr,
                *index < mock.event_count ? mock.events[*index].kind : -1,
                *index < mock.event_count ? (unsigned long long)mock.events[*index].addr : 0);
        return 1;
    }
    (*index)++;
    return 0;
}

static int expect_cluster(unsigned *index, const struct cluster_t *cluster,
                          const struct feat_t *features)
{
    u64 pstate = cluster->base + 0x20020;
    if (expect_event(index, EV_READ64, pstate) ||
        expect_event(index, EV_WRITE64_PSTATE, pstate) ||
        expect_event(index, EV_POLL64, pstate))
        return 1;
    for (; features->name; features++) {
        if (features->pcluster_only && !cluster->pcluster)
            continue;
        u64 reg = cluster->base + features->offset;
        if (expect_event(index, EV_FEATURE_QUERY, 0) || expect_event(index, EV_MASK64, reg))
            return 1;
        if (features->wait && expect_event(index, EV_POLL32, reg))
            return 1;
    }
    if (expect_event(index, EV_ADT_PATH, 0) ||
        expect_event(index, EV_ADT_REG, 0x100000000ULL) ||
        expect_event(index, EV_WRITE64_RESTORE, cluster->base + 0x440f8) ||
        expect_event(index, EV_READ64, pstate) ||
        expect_event(index, EV_WRITE64_PSTATE, pstate) ||
        expect_event(index, EV_POLL64, pstate))
        return 1;
    return 0;
}

static int test_t6032_fail_closed(void)
{
    chip_id = 0x6032;
    reset_mock();
    if (cpufreq_init() != -1 || mock.event_count != 0)
        return fail("T6032 cpufreq_init did not reject before MMIO");
    cpufreq_fixup();
    if (mock.event_count != 0)
        return fail("T6032 cpufreq_fixup performed MMIO");
    return 0;
}

static int test_t6031_sequence(void)
{
    chip_id = T6031;
    reset_mock();
    if (cpufreq_init() != 0)
        return fail("T6031 cpufreq_init failed");
    const struct cluster_t *clusters = cpufreq_get_clusters();
    const struct feat_t *features = cpufreq_get_features();
    unsigned index = 0;
    for (unsigned i = 0; i < 3; i++)
        if (expect_cluster(&index, &clusters[i], features))
            return fail("T6031 APSC/features/wait/restore/default order mismatch");
    if (index != mock.event_count)
        return fail("unexpected T6031 event count");
    return 0;
}

static int test_same_state_skips_poll(void)
{
    chip_id = T6031;
    reset_mock();
    mock.pstate_value = 1 | BIT(31);
    const struct cluster_t *cluster = cpufreq_get_clusters();
    if (set_pstate(&cluster[0], 1) != 0 || mock.event_count != 1 ||
        mock.events[0].kind != EV_READ64)
        return fail("same-requested-state path did not skip polling");
    return 0;
}

static int test_busy_failure_continues_outer_loop(void)
{
    chip_id = T6031;
    reset_mock();
    mock.fail_poll64_at = 1;
    if (cpufreq_init() != -1)
        return fail("busy timeout was not reported");
    const struct cluster_t *clusters = cpufreq_get_clusters();
    const struct feat_t *features = cpufreq_get_features();
    unsigned index = 3;
    if (mock.event_count != 47 || expect_cluster(&index, &clusters[1], features) ||
        expect_cluster(&index, &clusters[2], features) || index != mock.event_count) {
        fprintf(stderr, "busy: events=%u index=%u\n", mock.event_count, index);
        return fail("busy failure did not continue to later clusters only");
    }
    return 0;
}

static int test_feature_failure_stops_cluster(void)
{
    chip_id = T6031;
    reset_mock();
    mock.fail_poll32_at = 1;
    if (cpufreq_init() != -1)
        return fail("feature wait timeout was not reported");
    const struct cluster_t *clusters = cpufreq_get_clusters();
    const struct feat_t *features = cpufreq_get_features();
    unsigned index = 6;
    if (mock.event_count != 50 || expect_cluster(&index, &clusters[1], features) ||
        expect_cluster(&index, &clusters[2], features) || index != mock.event_count) {
        fprintf(stderr, "feature: events=%u index=%u\n", mock.event_count, index);
        return fail("feature failure did not stop same-cluster work and continue outer loop");
    }
    return 0;
}

int main(void)
{
    if (test_t6032_fail_closed() || test_t6031_sequence() || test_same_state_skips_poll() ||
        test_busy_failure_continues_outer_loop() || test_feature_failure_stops_cluster())
        return 1;
    puts("cpufreq driver harness: 5 contract cases passed");
    return 0;
}

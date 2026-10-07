/* Host-only integration harness template.
 *
 * The runner supplies the reviewed source definitions, the complete
 * cpufreq.c body, and the payload caller fragment.  No production source is
 * copied into this fixture.
 */

#include <stdbool.h>
#include <stdint.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>

typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;

_Static_assert(sizeof(unsigned long) == 8, "fixture requires 64-bit unsigned long");

/* INSERT_SOURCE_DEFINES */

/* The runner supplies enum fw_version; only the field used by cpufreq.c is
 * needed here, so this anonymous type cannot collide with a source header's
 * full fw_version_info declaration. */
struct {
    enum fw_version version;
} os_firmware;

u32 chip_id;
u32 board_id;

enum event_kind {
    EV_READ64,
    EV_WRITE64,
    EV_MASK64,
    EV_SET64,
    EV_POLL64,
    EV_POLL32,
    EV_FEATURE_QUERY,
    EV_VOLTAGE_CTL,
    EV_POWER_ON,
};

struct event {
    enum event_kind kind;
    u64 addr;
    u64 value;
    u64 mask;
    u64 target;
    u64 clear;
    u64 set;
    u32 timeout;
    unsigned call;
};

#define MAX_EVENTS 1024
#define MOCK_CLUSTERS 6

struct mock_state {
    struct event events[MAX_EVENTS];
    unsigned event_count;
    bool overflow;
    bool feature_enabled;
    u64 pstate[MOCK_CLUSTERS];
    unsigned poll64_calls;
    unsigned poll32_calls;
    unsigned fail_poll64_at;
    unsigned fail_poll32_at;
    unsigned failed_event;
    bool failed_event_valid;
    unsigned feature_queries;
    bool invalid_address;
};

static struct mock_state mock;

static const u64 mock_cluster_bases[MOCK_CLUSTERS] = {
    0x210e00000ULL, 0x211e00000ULL, 0x212e00000ULL,
    0x2210e00000ULL, 0x2211e00000ULL, 0x2212e00000ULL,
};

static int cluster_index_for_address(u64 addr)
{
    for (unsigned i = 0; i < MOCK_CLUSTERS; i++) {
        if (addr >= mock_cluster_bases[i] && addr < mock_cluster_bases[i] + 0x100000ULL)
            return (int)i;
    }
    return -1;
}

static int pstate_index(u64 addr)
{
    for (unsigned i = 0; i < MOCK_CLUSTERS; i++)
        if (addr == mock_cluster_bases[i] + 0x20020ULL)
            return (int)i;
    return -1;
}

static void check_address(u64 addr)
{
    if (cluster_index_for_address(addr) < 0)
        mock.invalid_address = true;
}

static void record_event(enum event_kind kind, u64 addr, u64 value, u64 mask, u64 target,
                         u64 clear, u64 set, u32 timeout, unsigned call)
{
    if (mock.event_count >= MAX_EVENTS) {
        mock.overflow = true;
        return;
    }
    mock.events[mock.event_count++] =
        (struct event){kind, addr, value, mask, target, clear, set, timeout, call};
}

static void reset_mock(u32 soc, bool feature_enabled)
{
    memset(&mock, 0, sizeof(mock));
    chip_id = soc;
    board_id = 0;
    os_firmware.version = V_UNKNOWN;
    mock.feature_enabled = feature_enabled;
    for (unsigned i = 0; i < MOCK_CLUSTERS; i++)
        mock.pstate[i] = BIT(20) | BIT(31) | BIT(60);
}

static u64 read64(u64 addr)
{
    check_address(addr);
    int index = pstate_index(addr);
    u64 value = index >= 0 ? mock.pstate[index] : 0;
    record_event(EV_READ64, addr, value, 0, 0, 0, 0, 0, 0);
    return value;
}

static void write64(u64 addr, u64 value)
{
    check_address(addr);
    record_event(EV_WRITE64, addr, value, 0, 0, 0, 0, 0, 0);
    int index = pstate_index(addr);
    if (index >= 0)
        mock.pstate[index] = value;
}

static u64 mask64(u64 addr, u64 clear, u64 set)
{
    check_address(addr);
    record_event(EV_MASK64, addr, 0, 0, 0, clear, set, 0, 0);
    int index = pstate_index(addr);
    if (index >= 0)
        mock.pstate[index] = (mock.pstate[index] & ~clear) | set;
    return 0;
}

static u64 set64(u64 addr, u64 set)
{
    check_address(addr);
    record_event(EV_SET64, addr, 0, 0, 0, 0, set, 0, 0);
    int index = pstate_index(addr);
    if (index >= 0)
        mock.pstate[index] |= set;
    return 0;
}

static int poll64(u64 addr, u64 mask, u64 target, u32 timeout)
{
    (void)mask;
    (void)target;
    (void)timeout;
    unsigned call = ++mock.poll64_calls;
    check_address(addr);
    record_event(EV_POLL64, addr, 0, mask, target, 0, 0, timeout, call);
    if (mock.fail_poll64_at && call == mock.fail_poll64_at) {
        mock.failed_event = mock.event_count - 1;
        mock.failed_event_valid = true;
        return -1;
    }
    int index = pstate_index(addr);
    if (index >= 0)
        mock.pstate[index] = (mock.pstate[index] & ~mask) | target;
    return 0;
}

static int poll32(u64 addr, u32 mask, u32 target, u32 timeout)
{
    (void)mask;
    (void)target;
    (void)timeout;
    unsigned call = ++mock.poll32_calls;
    check_address(addr);
    record_event(EV_POLL32, addr, 0, mask, target, 0, 0, timeout, call);
    if (mock.fail_poll32_at && call == mock.fail_poll32_at) {
        mock.failed_event = mock.event_count - 1;
        mock.failed_event_valid = true;
        return -1;
    }
    int index = pstate_index(addr);
    if (index >= 0)
        mock.pstate[index] = (mock.pstate[index] & ~(u64)mask) | target;
    return 0;
}

static u32 pmgr_get_feature(const char *name)
{
    (void)name;
    unsigned ordinal = ++mock.feature_queries;
    unsigned feature = (ordinal - 1) % 6 + 1;
    record_event(EV_FEATURE_QUERY, 0, 0, 0, 0, 0, 0, 0, feature);
    return mock.feature_enabled;
}

static int pmgr_set_voltage_ctl(uint32_t offset)
{
    record_event(EV_VOLTAGE_CTL, offset, 0, 0, 0, 0, 0, 0, 0);
    return 0;
}

static int pmgr_power_on(int die, const char *name)
{
    (void)die;
    (void)name;
    record_event(EV_POWER_ON, 0, 0, 0, 0, 0, 0, 0, 0);
    return 0;
}

/* Keep the real driver's diagnostics out of the one-line test summary. */
#define printf(...) ((void)0)
#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wmissing-field-initializers"
#endif

/* INSERT_CPUFREQ_SOURCE */

#if defined(__clang__)
#pragma clang diagnostic pop
#endif
#undef printf

static unsigned smp_calls;
static unsigned downstream_calls;
static int mock_smp_result;

static int smp_start_secondaries(void)
{
    smp_calls++;
    return mock_smp_result;
}

static void mitigations_perform(void)
{
    downstream_calls++;
}

static int payload_gate(void)
{
    bool kernel = true;
    bool fdt = true;
#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-variable"
#endif
    /* INSERT_PAYLOAD_CPUFREQ_FRAGMENT */
#if defined(__clang__)
#pragma clang diagnostic pop
#endif
    return 0;
}

static int fail_case(const char *message)
{
    fprintf(stderr, "%s\n", message);
    return 1;
}

static unsigned cases_passed;

static int pass_case(void)
{
    cases_passed++;
    return 0;
}

static unsigned event_kind_count(enum event_kind kind)
{
    unsigned count = 0;
    for (unsigned i = 0; i < mock.event_count; i++)
        if (mock.events[i].kind == kind)
            count++;
    return count;
}

static unsigned event_kind_count_before(unsigned cursor, enum event_kind kind)
{
    unsigned count = 0;
    for (unsigned i = 0; i < cursor; i++)
        if (mock.events[i].kind == kind)
            count++;
    return count;
}

enum failure_kind {
    FAIL_APSC,
    FAIL_FEATURE,
    FAIL_DEFAULT,
};

static const u64 expected_feature_offsets[6] = {
    0x20020, 0x48400, 0x48408, 0x40270, 0x40250, 0x20020,
};
static const u64 expected_feature_clears[6] = {BIT(23), 0, 0, 0, 0, 0};
static const u64 expected_feature_sets[6] = {0, BIT(63), BIT(63), BIT(63), BIT(63), BIT(42)};
static const u64 expected_feature_waits[6] = {BIT(7), 0, 0, 0, 0, 0};

static u64 expected_pstate_value(bool feature_enabled, u32 pstate, bool busy)
{
    return BIT(20) | BIT(60) | (busy ? BIT(31) : 0) | BIT(25) |
           (feature_enabled ? BIT(42) : 0) |
           (feature_enabled ? 0 : BIT(23)) | pstate;
}

static int expect_event(unsigned *cursor, enum event_kind kind, u64 addr, u64 value, u64 mask,
                        u64 target, u64 clear, u64 set, u32 timeout, unsigned call)
{
    if (*cursor >= mock.event_count)
        return 1;
    const struct event *event = &mock.events[*cursor];
    if (event->kind != kind || event->addr != addr || event->value != value ||
        event->mask != mask || event->target != target || event->clear != clear ||
        event->set != set || event->timeout != timeout ||
        (call != UINT_MAX && event->call != call)) {
        return 1;
    }
    (*cursor)++;
    return 0;
}

static int validate_cluster_prefix(unsigned *cursor, unsigned cluster, bool feature_enabled,
                                  const u32 *defaults, enum failure_kind stop)
{
    const u64 base = mock_cluster_bases[cluster];
    const u64 pstate = base + 0x20020;
    unsigned poll64_call = event_kind_count_before(*cursor, EV_POLL64) + 1;
    if (expect_event(cursor, EV_READ64, pstate, BIT(20) | BIT(31) | BIT(60), 0, 0, 0, 0, 0, 0) ||
        expect_event(cursor, EV_WRITE64, pstate, BIT(20) | BIT(60) | BIT(31) | BIT(25) | 1,
                     0, 0, 0, 0, 0, 0) ||
        expect_event(cursor, EV_POLL64, pstate, 0, BIT(31), 0, 0, 0, 400,
                     poll64_call))
        return 1;
    if (stop == FAIL_APSC)
        return 0;

    for (unsigned feature = 0; feature < 6; feature++) {
        u64 clear = feature_enabled ? expected_feature_clears[feature] : expected_feature_sets[feature];
        u64 set = feature_enabled ? expected_feature_sets[feature] : expected_feature_clears[feature];
        if (expect_event(cursor, EV_FEATURE_QUERY, 0, 0, 0, 0, 0, 0, 0,
                         event_kind_count_before(*cursor, EV_FEATURE_QUERY) % 6 + 1) ||
            expect_event(cursor, EV_MASK64, base + expected_feature_offsets[feature], 0, 0, 0,
                         clear, set, 0, 0))
            return 1;
        if (feature == 0 &&
            expect_event(cursor, EV_POLL32, pstate, 0, expected_feature_waits[feature], 0, 0, 0,
                         400, event_kind_count_before(*cursor, EV_POLL32) + 1))
            return 1;
        if (stop == FAIL_FEATURE && feature == 0)
            return 0;
    }
    if (expect_event(cursor, EV_WRITE64, base + 0x440f8, 1, 0, 0, 0, 0, 0, 0) ||
        expect_event(cursor, EV_READ64, pstate, expected_pstate_value(feature_enabled, 1, false), 0, 0, 0, 0, 0, 0) ||
        expect_event(cursor, EV_WRITE64, pstate, expected_pstate_value(feature_enabled, defaults[cluster], false), 0, 0,
                     0, 0, 0, 0) ||
        expect_event(cursor, EV_POLL64, pstate, 0, BIT(31), 0, 0, 0, 400,
                     event_kind_count_before(*cursor, EV_POLL64) + 1))
        return 1;
    return 0;
}

static int test_t6032_cluster_records(void)
{
    static const u64 bases[MOCK_CLUSTERS] = {
        0x210e00000ULL, 0x211e00000ULL, 0x212e00000ULL,
        0x2210e00000ULL, 0x2211e00000ULL, 0x2212e00000ULL,
    };
    static const char *names[MOCK_CLUSTERS] = {
        "ECPU0", "PCPU0", "PCPU1", "ECPU1", "PCPU2", "PCPU3",
    };
    static const bool pclusters[MOCK_CLUSTERS] = {false, true, true, false, true, true};
    static const u32 defaults[MOCK_CLUSTERS] = {5, 6, 6, 5, 6, 6};
    const struct cluster_t *clusters;

    reset_mock(T6032, true);
    clusters = cpufreq_get_clusters();
    if (!clusters)
        return fail_case("T6032 cluster table missing");
    for (unsigned i = 0; i < MOCK_CLUSTERS; i++) {
        if (!clusters[i].name || strcmp(clusters[i].name, names[i]) != 0 ||
            clusters[i].base != bases[i] || clusters[i].pcluster != pclusters[i] ||
            clusters[i].apsc_pstate != 1 || clusters[i].default_pstate != defaults[i] ||
            clusters[i].voltage_ctl != 0)
            return fail_case("T6032 cluster record mismatch");
    }
    if (clusters[MOCK_CLUSTERS].base || clusters[MOCK_CLUSTERS].name)
        return fail_case("T6032 cluster table lacks terminator");
    return pass_case();
}

static int test_t6030_features(void)
{
    static const char *names[6] = {
        "cpu-apsc", "ppt-thrtl", "ppt-thrtl", "llc-thrtl", "amx-thrtl",
        "cpu-fixed-freq-pll-relock",
    };
    static const u64 offsets[6] = {0x20020, 0x48400, 0x48408, 0x40270, 0x40250, 0x20020};
    static const u64 clears[6] = {BIT(23), 0, 0, 0, 0, 0};
    static const u64 sets[6] = {0, BIT(63), BIT(63), BIT(63), BIT(63), BIT(42)};
    static const u64 waits[6] = {BIT(7), 0, 0, 0, 0, 0};
    const struct feat_t *features;

    reset_mock(T6032, true);
    features = cpufreq_get_features();
    if (!features)
        return fail_case("T6032 feature table missing");
    for (unsigned i = 0; i < 6; i++) {
        if (!features[i].name || strcmp(features[i].name, names[i]) != 0 ||
            features[i].offset != offsets[i] || features[i].clear != clears[i] ||
            features[i].set != sets[i] || features[i].wait != waits[i] ||
            features[i].pcluster_only)
            return fail_case("T6030 feature record mismatch");
    }
    if (features[6].name)
        return fail_case("T6030 feature table lacks terminator");
    return pass_case();
}

static int test_t6032_success(bool feature_enabled)
{
    static const u32 defaults[MOCK_CLUSTERS] = {5, 6, 6, 5, 6, 6};
    unsigned cursor = 0;

    reset_mock(T6032, feature_enabled);
    if (cpufreq_init() != 0 || mock.overflow || mock.poll64_calls != 12 ||
        mock.poll32_calls != 6 || mock.event_count == 0 ||
        event_kind_count(EV_FEATURE_QUERY) != 36 || event_kind_count(EV_MASK64) != 36 ||
        event_kind_count(EV_VOLTAGE_CTL) != 0 || event_kind_count(EV_POWER_ON) != 0 ||
        mock.invalid_address)
        return fail_case("T6032 DVFS success case failed");
    for (unsigned cluster = 0; cluster < MOCK_CLUSTERS; cluster++)
        if (validate_cluster_prefix(&cursor, cluster, feature_enabled, defaults, FAIL_DEFAULT))
            return fail_case("DVFS event/order mismatch");
    if (cursor != mock.event_count)
        return fail_case("DVFS event/order mismatch");
    return pass_case();
}

static int test_t6032_fail_fast(enum failure_kind kind, unsigned cluster)
{
    static const u32 defaults[MOCK_CLUSTERS] = {5, 6, 6, 5, 6, 6};
    unsigned expected_poll64 = cluster * 2 + (kind == FAIL_DEFAULT ? 2 : 1);
    unsigned expected_poll32 = cluster + 1;
    unsigned cursor = 0;

    reset_mock(T6032, true);
    if (kind == FAIL_FEATURE)
        mock.fail_poll32_at = expected_poll32;
    else
        mock.fail_poll64_at = expected_poll64;

    if (cpufreq_init() != -1 || !mock.failed_event_valid || mock.overflow || mock.invalid_address)
        return fail_case("T6032 DVFS failure did not return -1");
    for (unsigned i = 0; i < cluster; i++)
        if (validate_cluster_prefix(&cursor, i, true, defaults, FAIL_DEFAULT))
            return fail_case("DVFS event/order mismatch");
    if (validate_cluster_prefix(&cursor, cluster, true, defaults, kind))
        return fail_case("DVFS event/order mismatch");
    if (cursor != mock.failed_event + 1)
        return fail_case("DVFS event/order mismatch");
    if (mock.event_count != cursor)
        return fail_case("T6032 DVFS continued after failed cluster");
    return pass_case();
}

static int test_t6031_legacy_continuation(enum failure_kind kind)
{
    static const u32 defaults[3] = {5, 6, 6};
    unsigned cursor = 0;

    reset_mock(T6031, true);
    if (kind == FAIL_FEATURE)
        mock.fail_poll32_at = 1;
    else
        mock.fail_poll64_at = kind == FAIL_DEFAULT ? 2 : 1;

    if (cpufreq_init() != -1 || !mock.failed_event_valid || mock.overflow || mock.invalid_address)
        return fail_case("T6031 DVFS failure status mismatch");
    if (validate_cluster_prefix(&cursor, 0, true, defaults, kind))
        return fail_case("DVFS event/order mismatch");
    if (validate_cluster_prefix(&cursor, 1, true, defaults, FAIL_DEFAULT) ||
        validate_cluster_prefix(&cursor, 2, true, defaults, FAIL_DEFAULT)) {
        return fail_case("T6031 DVFS did not retain legacy continuation");
    }
    if (cursor != mock.event_count)
        return fail_case("T6031 DVFS did not retain legacy continuation");
    return pass_case();
}

static int test_same_state_skips_poll(void)
{
    reset_mock(T6032, true);
    mock.pstate[0] = 1 | BIT(31);
    const struct cluster_t *clusters = cpufreq_get_clusters();
    if (!clusters || set_pstate(&clusters[0], 1) != 0 || mock.event_count != 1 ||
        mock.events[0].kind != EV_READ64 || mock.poll64_calls != 0)
        return fail_case("already-desired set_pstate did not preserve no-write/no-poll behavior");
    return pass_case();
}

static int test_payload_integration(void)
{
    reset_mock(T6032, true);
    mock.fail_poll64_at = 1;
    smp_calls = downstream_calls = 0;
    mock_smp_result = 0;
    if (payload_gate() != -1 || smp_calls != 0 || downstream_calls != 0)
        return fail_case("T6032 DVFS failure reached secondary startup");
    if (pass_case())
        return 1;

    reset_mock(T6032, true);
    smp_calls = downstream_calls = 0;
    if (payload_gate() != 0 || smp_calls != 1 || downstream_calls != 1)
        return fail_case("T6032 DVFS success did not continue payload");
    if (pass_case())
        return 1;

    reset_mock(T6031, true);
    mock.fail_poll64_at = 1;
    smp_calls = downstream_calls = 0;
    if (payload_gate() != 0 || smp_calls != 1 || downstream_calls != 1)
        return fail_case("T6031 DVFS failure lost legacy payload continuation");
    if (pass_case())
        return 1;

    reset_mock(T6032, true);
    smp_calls = downstream_calls = 0;
    mock_smp_result = -1;
    if (payload_gate() != -1 || smp_calls != 1 || downstream_calls != 0)
        return fail_case("payload SMP failure was not propagated");
    return pass_case();
}

static int test_payload_t6032_failures(void)
{
    for (enum failure_kind kind = FAIL_APSC; kind <= FAIL_DEFAULT; kind++) {
        for (unsigned cluster = 0; cluster < MOCK_CLUSTERS; cluster++) {
            unsigned expected_poll64 = cluster * 2 + (kind == FAIL_DEFAULT ? 2 : 1);
            unsigned expected_poll32 = cluster + 1;

            reset_mock(T6032, true);
            if (kind == FAIL_FEATURE)
                mock.fail_poll32_at = expected_poll32;
            else
                mock.fail_poll64_at = expected_poll64;
            smp_calls = downstream_calls = 0;
            mock_smp_result = 0;

            if (payload_gate() != -1 || smp_calls != 0 || downstream_calls != 0)
                return fail_case("T6032 DVFS failure reached secondary startup");
            if (pass_case())
                return 1;
        }
    }
    return 0;
}

int main(void)
{
    if (test_t6032_cluster_records() || test_t6030_features() ||
        test_t6032_success(true) || test_t6032_success(false) ||
        test_same_state_skips_poll())
        return 1;

    for (enum failure_kind kind = FAIL_APSC; kind <= FAIL_DEFAULT; kind++)
        for (unsigned cluster = 0; cluster < MOCK_CLUSTERS; cluster++)
            if (test_t6032_fail_fast(kind, cluster))
                return 1;

    for (enum failure_kind kind = FAIL_APSC; kind <= FAIL_DEFAULT; kind++)
        if (test_t6031_legacy_continuation(kind))
            return 1;

    if (test_payload_integration() || test_payload_t6032_failures())
        return 1;

    printf("PASS: m1n1 upstream cpufreq: %u cases passed (metadata=2, success=2, same-state=1, T6032 fail-fast=18, T6031 legacy=3, payload=22)\n",
           cases_passed);
    return cases_passed == 48 ? 0 : 1;
}

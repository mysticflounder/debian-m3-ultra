/* Host-only busy-state harness.  The runner injects the reviewed source
 * definitions, cpufreq.c body, and payload caller prefix.  No MMIO runs. */
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

struct { enum fw_version version; } os_firmware;
u32 chip_id;
u32 board_id;

enum event_kind { EV_READ64, EV_WRITE64, EV_MASK64, EV_SET64, EV_POLL64,
                  EV_POLL32, EV_FEATURE_QUERY, EV_VOLTAGE_CTL, EV_POWER_ON };
struct event {
    enum event_kind kind;
    u64 addr, value, mask, target, clear, set;
    u32 timeout;
    unsigned call;
};

#define MAX_EVENTS 4096
#define MOCK_CLUSTERS 6
struct mock_state {
    struct event events[MAX_EVENTS];
    unsigned event_count, poll64_calls, poll32_calls, feature_queries;
    unsigned fail_poll64_at, fail_poll32_at;
    unsigned failed_event;
    bool failed_event_valid, overflow, invalid_address, feature_enabled;
    u64 pstate[MOCK_CLUSTERS];
    unsigned completion_call;
    bool completion_updates;
    u32 completion_pstate;
};
static struct mock_state mock;
static const u64 mock_cluster_bases[MOCK_CLUSTERS] = {
    0x210e00000ULL, 0x211e00000ULL, 0x212e00000ULL,
    0x2210e00000ULL, 0x2211e00000ULL, 0x2212e00000ULL,
};

static int cluster_index_for_address(u64 addr)
{
    for (unsigned i = 0; i < MOCK_CLUSTERS; i++)
        if (addr >= mock_cluster_bases[i] && addr < mock_cluster_bases[i] + 0x100000ULL)
            return (int)i;
    return -1;
}
static int pstate_index(u64 addr)
{
    for (unsigned i = 0; i < MOCK_CLUSTERS; i++)
        if (addr == mock_cluster_bases[i] + 0x20020ULL)
            return (int)i;
    return -1;
}
static void record_event(enum event_kind kind, u64 addr, u64 value, u64 mask,
                         u64 target, u64 clear, u64 set, u32 timeout, unsigned call)
{
    if (cluster_index_for_address(addr) < 0 && kind != EV_FEATURE_QUERY &&
        kind != EV_VOLTAGE_CTL && kind != EV_POWER_ON)
        mock.invalid_address = true;
    if (mock.event_count >= MAX_EVENTS) { mock.overflow = true; return; }
    mock.events[mock.event_count++] = (struct event){kind, addr, value, mask, target,
                                                      clear, set, timeout, call};
}
static void reset_mock(u32 soc, bool feature_enabled)
{
    memset(&mock, 0, sizeof(mock));
    chip_id = soc;
    board_id = 0;
    os_firmware.version = V_UNKNOWN;
    mock.feature_enabled = feature_enabled;
    for (unsigned i = 0; i < MOCK_CLUSTERS; i++)
        mock.pstate[i] = BIT(20) | BIT(31) | BIT(60) | 1;
}
static u64 read64(u64 addr)
{
    int i = pstate_index(addr);
    u64 value = i >= 0 ? mock.pstate[i] : 0;
    record_event(EV_READ64, addr, value, 0, 0, 0, 0, 0, 0);
    return value;
}
static void write64(u64 addr, u64 value)
{
    int i = pstate_index(addr);
    record_event(EV_WRITE64, addr, value, 0, 0, 0, 0, 0, 0);
    if (i >= 0) mock.pstate[i] = value;
}
static u64 mask64(u64 addr, u64 clear, u64 set)
{
    int i = pstate_index(addr);
    record_event(EV_MASK64, addr, 0, 0, 0, clear, set, 0, 0);
    if (i >= 0) mock.pstate[i] = (mock.pstate[i] & ~clear) | set;
    return 0;
}
static u64 set64(u64 addr, u64 set)
{
    int i = pstate_index(addr);
    record_event(EV_SET64, addr, 0, 0, 0, 0, set, 0, 0);
    if (i >= 0) mock.pstate[i] |= set;
    return 0;
}
static int poll64(u64 addr, u64 mask, u64 target, u32 timeout)
{
    unsigned call = ++mock.poll64_calls;
    int i = pstate_index(addr);
    record_event(EV_POLL64, addr, 0, mask, target, 0, 0, timeout, call);
    if (mock.fail_poll64_at && call == mock.fail_poll64_at) {
        mock.failed_event = mock.event_count - 1;
        mock.failed_event_valid = true;
        return -1;
    }
    if (i >= 0) {
        mock.pstate[i] = (mock.pstate[i] & ~mask) | target;
        if (mock.completion_updates && call == mock.completion_call) {
            mock.pstate[i] &= ~CLUSTER_PSTATE_DESIRED1;
            mock.pstate[i] |= FIELD_PREP(CLUSTER_PSTATE_DESIRED1, mock.completion_pstate);
        }
    }
    return 0;
}
static int poll32(u64 addr, u32 mask, u32 target, u32 timeout)
{
    unsigned call = ++mock.poll32_calls;
    record_event(EV_POLL32, addr, 0, mask, target, 0, 0, timeout, call);
    if (mock.fail_poll32_at && call == mock.fail_poll32_at) {
        mock.failed_event = mock.event_count - 1;
        mock.failed_event_valid = true;
        return -1;
    }
    return 0;
}
static u32 pmgr_get_feature(const char *name)
{ (void)name; record_event(EV_FEATURE_QUERY, 0, 0, 0, 0, 0, 0, 0, ++mock.feature_queries); return mock.feature_enabled; }
static int pmgr_set_voltage_ctl(uint32_t offset)
{ record_event(EV_VOLTAGE_CTL, offset, 0, 0, 0, 0, 0, 0, 0); return 0; }
static int pmgr_power_on(int die, const char *name)
{ (void)die; (void)name; record_event(EV_POWER_ON, 0, 0, 0, 0, 0, 0, 0, 0); return 0; }

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

static unsigned smp_calls, downstream_calls;
static int mock_smp_result;
static int smp_start_secondaries(void) { smp_calls++; return mock_smp_result; }
static void mitigations_perform(void) { downstream_calls++; }
static int payload_gate(void)
{
    bool kernel = true, fdt = true;
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

static int fail_case(const char *msg) { fprintf(stderr, "%s\n", msg); return 1; }
static unsigned cases_passed;
static int pass_case(void) { cases_passed++; return 0; }
static unsigned count_kind(enum event_kind kind)
{
    unsigned n = 0;
    for (unsigned i = 0; i < mock.event_count; i++) n += mock.events[i].kind == kind;
    return n;
}
static int check_common(void)
{ return mock.overflow || mock.invalid_address; }

static int check_poll64_event(const struct event *event, const struct cluster_t *cluster)
{
    return event->kind != EV_POLL64 || event->addr != cluster->base + CLUSTER_PSTATE ||
           event->mask != CLUSTER_PSTATE_BUSY || event->target != 0 ||
           event->timeout != CLUSTER_SWITCH_TIMEOUT;
}

static int check_poll32_events(void)
{
    for (unsigned i = 0; i < mock.event_count; i++) {
        const struct event *event = &mock.events[i];
        if (event->kind != EV_POLL32)
            continue;
        if (event->target != 0 || event->timeout != CLUSTER_SWITCH_TIMEOUT ||
            cluster_index_for_address(event->addr) < 0)
            return 1;
    }
    return 0;
}

static int test_t6032_busy_reread(void)
{
    reset_mock(T6032, true);
    const struct cluster_t *clusters = cpufreq_get_clusters();
    if (!clusters) return fail_case("missing T6032 clusters");
    for (unsigned i = 0; i < MOCK_CLUSTERS; i++) {
        reset_mock(T6032, true);
        mock.completion_updates = true; mock.completion_call = 1; mock.completion_pstate = 1;
        if (set_pstate(&clusters[i], 1) || mock.poll64_calls != 1 || count_kind(EV_READ64) != 1 ||
            count_kind(EV_WRITE64) != 0 || mock.event_count != 2 || check_common())
            return fail_case("T6032 equal busy state was not waited and reread");
        if (check_poll64_event(&mock.events[0], &clusters[i]) || mock.events[1].kind != EV_READ64)
            return fail_case("T6032 prewait/read order mismatch");
        if (pass_case()) return 1;

        reset_mock(T6032, true);
        mock.completion_updates = true; mock.completion_call = 1; mock.completion_pstate = 2;
        if (set_pstate(&clusters[i], 2) || mock.poll64_calls != 1 || count_kind(EV_READ64) != 1 ||
            count_kind(EV_WRITE64) != 0 || (mock.pstate[i] & CLUSTER_PSTATE_BUSY) || check_common() ||
            check_poll64_event(&mock.events[0], &clusters[i]) || mock.event_count != 2 ||
            mock.events[1].kind != EV_READ64)
            return fail_case("T6032 completion-to-request reread failed");
        if (pass_case()) return 1;

        reset_mock(T6032, true);
        mock.completion_updates = true; mock.completion_call = 1; mock.completion_pstate = 2;
        if (set_pstate(&clusters[i], 1) || mock.poll64_calls != 2 || count_kind(EV_READ64) != 1 ||
            count_kind(EV_WRITE64) != 1 || check_common() || mock.event_count != 4 ||
            check_poll64_event(&mock.events[0], &clusters[i]) ||
            check_poll64_event(&mock.events[3], &clusters[i]) ||
            mock.events[1].kind != EV_READ64 || mock.events[2].kind != EV_WRITE64 ||
            mock.events[2].value != (BIT(20) | BIT(60) | CLUSTER_PSTATE_SET | 1) ||
            (mock.pstate[i] & CLUSTER_PSTATE_BUSY))
            return fail_case("T6032 changed completion was stale-written");
        if (pass_case()) return 1;
    }
    return 0;
}
static int test_t6032_busy_different_and_timeout(void)
{
    reset_mock(T6032, true);
    const struct cluster_t *clusters = cpufreq_get_clusters();
    for (unsigned i = 0; i < MOCK_CLUSTERS; i++) {
        reset_mock(T6032, true);
        if (set_pstate(&clusters[i], 2) || mock.poll64_calls != 2 || count_kind(EV_WRITE64) != 1 ||
            check_poll64_event(&mock.events[0], &clusters[i]) ||
            check_poll64_event(&mock.events[3], &clusters[i]) ||
            mock.events[1].kind != EV_READ64 || mock.events[2].kind != EV_WRITE64 || check_common())
            return fail_case("T6032 different busy state ordering failed");
        reset_mock(T6032, true); mock.fail_poll64_at = 1;
        if (set_pstate(&clusters[i], 2) != -1 || count_kind(EV_READ64) || count_kind(EV_WRITE64) ||
            mock.event_count != 1 || !mock.failed_event_valid)
            return fail_case("T6032 prewait timeout did not stop before read/write");
        if (pass_case()) return 1;
    }
    return 0;
}

static int test_t6031_legacy_and_idle(void)
{
    reset_mock(T6031, true);
    const struct cluster_t *legacy = cpufreq_get_clusters();
    reset_mock(T6031, true);
    if (set_pstate(&legacy[0], 1) || mock.poll64_calls != 0 || count_kind(EV_WRITE64) != 0)
        return fail_case("T6031 equal busy behavior changed");
    reset_mock(T6031, true);
    if (set_pstate(&legacy[0], 2) || mock.poll64_calls != 1 || count_kind(EV_WRITE64) != 1 ||
        check_poll64_event(&mock.events[2], &legacy[0]))
        return fail_case("T6031 unequal legacy state lost its postwait");
    if (pass_case()) return 1;
    reset_mock(T6032, true);
    const struct cluster_t *clusters = cpufreq_get_clusters();
    for (unsigned i = 0; i < MOCK_CLUSTERS; i++) {
        reset_mock(T6032, true);
        mock.pstate[i] &= ~CLUSTER_PSTATE_BUSY;
        if (set_pstate(&clusters[i], 1) || mock.poll64_calls != 1 || count_kind(EV_WRITE64) != 0 ||
            mock.event_count != 2 || check_poll64_event(&mock.events[0], &clusters[i]))
            return fail_case("T6032 idle equal state did not preserve prewait/read");
        if (pass_case()) return 1;
        reset_mock(T6032, true);
        mock.pstate[i] &= ~CLUSTER_PSTATE_BUSY;
        if (set_pstate(&clusters[i], 2) || mock.poll64_calls != 2 || count_kind(EV_WRITE64) != 1 ||
            mock.event_count != 4 || check_poll64_event(&mock.events[0], &clusters[i]) ||
            check_poll64_event(&mock.events[3], &clusters[i]))
            return fail_case("T6032 idle unequal state did not postwait");
        if (pass_case()) return 1;
    }
    return 0;
}

static int test_t6032_init_modes_and_failures(void)
{
    static struct event baseline[MAX_EVENTS];
    for (unsigned mode = 0; mode < 2; mode++) {
        reset_mock(T6032, mode != 0);
        if (cpufreq_init() != 0 || mock.poll64_calls == 0 || mock.poll32_calls == 0 ||
            check_common() || check_poll32_events())
            return fail_case("T6032 feature-mode initialization failed");
        unsigned baseline_count = mock.event_count;
        unsigned baseline_poll64 = mock.poll64_calls;
        unsigned baseline_poll32 = mock.poll32_calls;
        memcpy(baseline, mock.events, baseline_count * sizeof(*baseline));
        bool seen[MOCK_CLUSTERS] = {false};
        for (unsigned i = 0; i < baseline_count; i++) {
            if (mock.events[i].kind != EV_POLL64)
                continue;
            int cluster = cluster_index_for_address(mock.events[i].addr);
            if (cluster < 0 || check_poll64_event(&mock.events[i], &cpufreq_get_clusters()[cluster]))
                return fail_case("T6032 poll transcript metadata changed");
            seen[cluster] = true;
        }
        for (unsigned i = 0; i < MOCK_CLUSTERS; i++)
            if (!seen[i]) return fail_case("T6032 poll transcript missed a cluster");
        reset_mock(T6032, mode != 0);
        if (cpufreq_init() != 0 || mock.event_count != baseline_count ||
            memcmp(mock.events, baseline, baseline_count * sizeof(*baseline)) != 0)
            return fail_case("T6032 feature-mode baseline transcript was not stable");
        if (pass_case()) return 1;
        for (unsigned call = 1; call <= baseline_poll64; call++) {
            reset_mock(T6032, mode != 0); mock.fail_poll64_at = call;
            if (cpufreq_init() != -1 || !mock.failed_event_valid ||
                mock.event_count != mock.failed_event + 1 || check_common())
                return fail_case("T6032 poll64 failure continued after the failed poll");
            if (pass_case()) return 1;
        }
        for (unsigned call = 1; call <= baseline_poll32; call++) {
            reset_mock(T6032, mode != 0); mock.fail_poll32_at = call;
            if (cpufreq_init() != -1 || !mock.failed_event_valid ||
                mock.event_count != mock.failed_event + 1 || check_common())
                return fail_case("T6032 poll32 failure continued after the failed poll");
            if (pass_case()) return 1;
        }
    }
    return 0;
}
static int test_payload_cutoff(void)
{
    for (unsigned call = 1; call <= 2; call++) {
        reset_mock(T6032, true); mock.fail_poll64_at = call; smp_calls = downstream_calls = 0;
        if (payload_gate() != -1 || smp_calls || downstream_calls)
            return fail_case("T6032 payload cutoff was bypassed");
        if (pass_case()) return 1;
    }
    reset_mock(T6031, true); mock.fail_poll64_at = 1; smp_calls = downstream_calls = 0;
    if (payload_gate() != 0 || smp_calls != 1 || downstream_calls != 1)
        return fail_case("T6031 payload legacy continuation changed");
    return pass_case();
}
int main(void)
{
    if (test_t6032_busy_reread() || test_t6032_busy_different_and_timeout() ||
        test_t6031_legacy_and_idle() || test_t6032_init_modes_and_failures() ||
        test_payload_cutoff()) return 1;
    printf("PASS: m1n1 upstream cpufreq busy harness: %u cases\n", cases_passed);
    return 0;
}

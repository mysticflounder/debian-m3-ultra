/* Host-only caller/status harness. The caller fragment is extracted from the
 * patched payload_run(), not retyped in the test. */

#include <stdbool.h>
#include <stdint.h>

#define T6031 0x6031
#define T6032 0x6032

static unsigned chip_id;
static int cpufreq_result, smp_result;
static unsigned cpufreq_calls, smp_calls, downstream_calls;
static unsigned call_order[4];
static unsigned call_count;

static int cpufreq_init(void)
{
    cpufreq_calls++;
    call_order[call_count++] = 1;
    return cpufreq_result;
}

static int smp_start_secondaries(void)
{
    smp_calls++;
    call_order[call_count++] = 2;
    return smp_result;
}

static void mitigations_perform(void)
{
    downstream_calls++;
    call_order[call_count++] = 3;
}

static int payload_gate(void)
{
    bool kernel = true;
    bool fdt = true;
    /* INSERT_PAYLOAD_CPUFREQ_FRAGMENT */
    downstream_calls++;
    call_order[call_count++] = 4;
    return 0;
}

static void reset_case(unsigned chip, int result, int smp)
{
    chip_id = chip;
    cpufreq_result = result;
    smp_result = smp;
    cpufreq_calls = smp_calls = downstream_calls = call_count = 0;
    for (unsigned i = 0; i < 4; i++)
        call_order[i] = 0;
}

static int valid_order(unsigned a, unsigned b, unsigned c)
{
    return call_count >= 3 && call_order[0] == a && call_order[1] == b && call_order[2] == c;
}

int main(void)
{
    reset_case(T6032, -1, 0);
    if (payload_gate() != -1 || cpufreq_calls != 1 || smp_calls != 0 ||
        downstream_calls != 0 || call_count != 1 || call_order[0] != 1)
        return 1;

    reset_case(T6032, -7, 0);
    if (payload_gate() != -1 || cpufreq_calls != 1 || smp_calls != 0 ||
        downstream_calls != 0 || call_count != 1 || call_order[0] != 1)
        return 2;

    reset_case(T6032, 0, 0);
    if (payload_gate() != 0 || cpufreq_calls != 1 || smp_calls != 1 ||
        downstream_calls != 2 || !valid_order(1, 2, 3) || call_order[3] != 4)
        return 3;

    reset_case(T6032, 0, -1);
    if (payload_gate() != -1 || cpufreq_calls != 1 || smp_calls != 1 ||
        downstream_calls != 0 || call_count != 2 || call_order[0] != 1 || call_order[1] != 2)
        return 4;

    reset_case(T6031, -1, 0);
    if (payload_gate() != 0 || cpufreq_calls != 1 || smp_calls != 1 ||
        downstream_calls != 2 || !valid_order(1, 2, 3) || call_order[3] != 4)
        return 5;

    reset_case(T6031, 0, 0);
    if (payload_gate() != 0 || cpufreq_calls != 1 || smp_calls != 1 ||
        downstream_calls != 2 || !valid_order(1, 2, 3) || call_order[3] != 4)
        return 6;

    reset_case(T6031, 0, -1);
    if (payload_gate() != -1 || cpufreq_calls != 1 || smp_calls != 1 ||
        downstream_calls != 0 || call_count != 2 || call_order[0] != 1 || call_order[1] != 2)
        return 7;

    reset_case(~0u, -1, 0);
    if (payload_gate() != 0 || cpufreq_calls != 1 || smp_calls != 1 ||
        downstream_calls != 2 || !valid_order(1, 2, 3) || call_order[3] != 4)
        return 8;

    reset_case(T6032, 1, 0);
    if (payload_gate() != 0 || cpufreq_calls != 1 || smp_calls != 1 ||
        downstream_calls != 2 || !valid_order(1, 2, 3) || call_order[3] != 4)
        return 9;

    return 0;
}

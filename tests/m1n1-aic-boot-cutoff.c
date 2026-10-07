/* Host-only AIC status and startup-prefix harness.
 * The runner prefixes this file with the existing aperture fixture (its main
 * is renamed) and inserts the reviewed m1n1_main prefix at the marker below.
 */

#include <setjmp.h>

/* INSERT_SOC_DEFINES */

u32 chip_id;

static unsigned startup_smp_calls;
static unsigned startup_action_calls;
static unsigned startup_mcc_calls;
static unsigned startup_panic_calls;
static bool startup_mcc_failure;
static bool startup_panic_armed;
static char startup_events[32];
static unsigned startup_event_count;
static char startup_panic_message[128];
static jmp_buf startup_panic_env;

static void startup_event(char event)
{
    if (startup_event_count < sizeof(startup_events) - 1)
        startup_events[startup_event_count++] = event;
    startup_events[startup_event_count] = 0;
}

static void startup_reset(void)
{
    startup_smp_calls = 0;
    startup_action_calls = 0;
    startup_mcc_calls = 0;
    startup_panic_calls = 0;
    startup_mcc_failure = false;
    startup_panic_armed = false;
    startup_event_count = 0;
    startup_events[0] = 0;
    startup_panic_message[0] = 0;
}

bool supports_gxf(void)
{
    return false;
}

void gxf_init(void)
{
    startup_event('G');
}

int mcc_init(void)
{
    startup_mcc_calls++;
    startup_event('M');
    return startup_mcc_failure ? -1 : 0;
}

void firmware_init(void) { startup_event('F'); }
void heapblock_init(void) { startup_event('H'); }
void mmu_init(void) { startup_event('U'); }
void wdt_disable(void) { startup_event('W'); }
void pmgr_init(void) { startup_event('P'); }
void cpufreq_fixup(void) { startup_event('C'); }
void sep_init(void) { startup_event('E'); }

int smp_init(void)
{
    startup_smp_calls++;
    startup_event('S');
    return 0;
}

void run_actions(void)
{
    startup_action_calls++;
    startup_event('A');
}

void panic(const char *format, ...)
{
    va_list args;
    startup_panic_calls++;
    va_start(args, format);
    vsnprintf(startup_panic_message, sizeof(startup_panic_message), format, args);
    va_end(args);
    if (startup_panic_armed)
        longjmp(startup_panic_env, 1);
    fprintf(stderr, "FAIL: unarmed panic: %s", startup_panic_message);
    exit(1);
}

/* INSERT_MAIN_STARTUP_PREFIX */

static int expect_aic_failure(const char *message)
{
    int status = aic_init();
    if (status >= 0 || aic)
        return fail(message);
    return 0;
}

static int test_status_contract(void)
{
    valid_fixture(1);
    if (aic_init() != 0 || !aic) return fail("valid AIC1 status changed");
    valid_fixture(2);
    if (aic_init() != 0 || !aic) return fail("valid AIC2 status changed");
    valid_fixture(3);
    if (aic_init() != 0 || !aic) return fail("valid AIC3 status changed");

    valid_fixture(2); fixture.path_ret = -1;
    if (expect_aic_failure("missing AIC node returned success")) return 1;
    valid_fixture(0);
    if (expect_aic_failure("unsupported AIC returned success")) return 1;
    valid_fixture(2); fixture.reg_size_present = false;
    if (expect_aic_failure("missing AIC reg returned success")) return 1;
    valid_fixture(2); fixture.reg_ret = -1;
    if (expect_aic_failure("failed AIC reg returned success")) return 1;
    valid_fixture(2); fixture.base = 0;
    if (expect_aic_failure("invalid AIC base returned success")) return 1;
    valid_fixture(1); fixture.cap_value = 1025;
    if (expect_aic_failure("AIC1 IRQ capacity returned success")) return 1;
    valid_fixture(1); fixture.reg_size = AIC_REG_SIZE - 4;
    if (expect_aic_failure("short AIC1 aperture returned success")) return 1;
    valid_fixture(2); fixture.ext_len = 1;
    if (expect_aic_failure("malformed external IRQ table returned success")) return 1;
    valid_fixture(3); fixture.cap_ret = -1;
    if (expect_aic_failure("missing AIC3 cap0 returned success")) return 1;
    valid_fixture(3); fixture.max_ret = -1;
    if (expect_aic_failure("missing AIC3 maxnumirq returned success")) return 1;
    valid_fixture(3); fixture.iack_prop_len = 4;
    if (expect_aic_failure("malformed AIC3 IACK returned success")) return 1;
    valid_fixture(3); fixture.cap_prop_len = 2;
    if (expect_aic_failure("malformed AIC3 cap0 returned success")) return 1;
    valid_fixture(3); fixture.cap_offset = -4;
    if (expect_aic_failure("negative AIC3 cap0 returned success")) return 1;
    valid_fixture(3); fixture.cap_offset = 0x50000;
    if (expect_aic_failure("out-of-range AIC3 cap0 returned success")) return 1;
    valid_fixture(2); fixture.strides_present = true; fixture.ext_stride = 2;
    fixture.set_stride = fixture.clr_stride = 16;
    fixture.ext_stride_len = fixture.set_stride_len = fixture.clr_stride_len = sizeof(u32);
    if (expect_aic_failure("invalid AIC2 stride returned success")) return 1;
    valid_fixture(2); set_caps(2, 64, 0, 32);
    if (expect_aic_failure("invalid AIC2 IRQ capacity returned success")) return 1;
    valid_fixture(2); fixture.config_present = true; fixture.config_base = 0x7ffc;
    fixture.config_prop_len = sizeof(u32);
    if (expect_aic_failure("out-of-range AIC2 config returned success")) return 1;
    valid_fixture(2); fixture.reg_size = 0;
    if (expect_aic_failure("zero AIC aperture returned success")) return 1;
    valid_fixture(2); fixture.base = UINT64_MAX - 3; fixture.reg_size = 8;
    if (expect_aic_failure("wrapping AIC aperture returned success")) return 1;
    valid_fixture(2); fixture.ext_len = 6;
    set_record(0, 0, 3, 2); set_record(1, 2, 65, 3);
    if (expect_aic_failure("invalid later external IRQ returned success")) return 1;

    valid_fixture(2);
    if (aic_init() != 0 || !aic) return fail("AIC repeated-init precondition failed");
    if (aic_init() != 0 || !aic) return fail("AIC repeated valid init failed");
    fixture.base = 0;
    if (expect_aic_failure("failed repeated init retained stale pointer")) return 1;
    return 0;
}

#ifndef BRINGUP
static int run_startup_once(u32 chip, int version, const char *label)
{
    startup_reset();
    chip_id = chip;
    valid_fixture(version);
    startup_panic_armed = true;
    if (setjmp(startup_panic_env) == 0)
        startup_prefix();
    startup_panic_armed = false;
    if (startup_panic_calls || startup_smp_calls != 1 || startup_action_calls != 1 || !aic)
        return fail(label);
    if (!strchr(startup_events, 'S') || !strchr(startup_events, 'A') ||
        strchr(startup_events, 'S') > strchr(startup_events, 'A'))
        return fail("startup SMP/action ordering changed");
    return 0;
}

static int run_startup_failure(u32 chip, int version, const char *label)
{
    startup_reset();
    chip_id = chip;
    valid_fixture(version);
    if (version == 1)
        fixture.reg_size = AIC_REG_SIZE - 4;
    else if (version == 2)
        fixture.base = 0;
    else
        fixture.cap_ret = -1;
    startup_panic_armed = true;
    if (setjmp(startup_panic_env) == 0)
        startup_prefix();
    startup_panic_armed = false;
    if (startup_panic_calls != 1 || strcmp(startup_panic_message,
                                           "AIC initialization failed!\n") ||
        aic || startup_smp_calls || startup_action_calls ||
        strcmp(startup_events, "FHMU"))
        return fail(label);
    return 0;
}
#endif

static int test_startup_contract(void)
{
#ifdef BRINGUP
    startup_reset();
    valid_fixture(2);
    startup_panic_armed = true;
    if (setjmp(startup_panic_env) == 0)
        startup_prefix();
    startup_panic_armed = false;
    if (startup_panic_calls || startup_smp_calls || startup_action_calls != 1 ||
        aic || fixture.reg_count || fixture.read_count || fixture.write_count)
        return fail("BRINGUP unexpectedly ran AIC");
    return 0;
#else
    if (run_startup_failure(T6032, 1, "T6032 AIC1-short failure reached SMP/actions")) return 1;
    if (run_startup_failure(T6031, 2, "T6031 AIC2-invalid-base failure reached SMP/actions")) return 1;
    if (run_startup_failure(AIC_TEST_LEGACY_CHIP, 3,
                            "legacy AIC3-missing-property failure reached SMP/actions")) return 1;

    if (run_startup_once(AIC_TEST_LEGACY_CHIP, 1, "legacy AIC1 startup path changed")) return 1;
    if (startup_mcc_calls != 1) return fail("legacy MCC path changed");
    if (run_startup_once(T6031, 2, "T6031 synthetic AIC2 startup path changed")) return 1;
    if (startup_mcc_calls != 1) return fail("T6031 MCC path changed");
    if (run_startup_once(T6032, 3, "T6032 synthetic AIC3 startup path changed")) return 1;
    if (startup_mcc_calls != 1) return fail("T6032 MCC path changed");
    if (run_startup_once(T6031, 3, "T6031 synthetic AIC3 startup path changed")) return 1;
    if (startup_mcc_calls != 1) return fail("T6031 MCC path changed");
    return 0;
#endif
}

int main(void)
{
    if (aperture_fixture_main() || test_status_contract() || test_startup_contract())
        return 1;
    puts("AIC status/startup cutoff harness: aperture, status, BRINGUP and caller paths passed");
    return 0;
}

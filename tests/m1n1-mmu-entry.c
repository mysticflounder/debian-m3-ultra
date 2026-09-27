#include <setjmp.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>

typedef uint64_t u64;
typedef uint32_t u32;
#define BIT(n) (1ULL << (n))
#define PAN 0xdead
#define SCTLR_EL1 0xbeef

/* INSERT_MMU_DEFINES */

struct cpu_features_fixture {
    bool mmu_sprr;
};
static struct cpu_features_fixture feature_fixture;
static struct cpu_features_fixture *cpu_features = &feature_fixture;
static int chip_id;
static u64 mock_sctlr;
static u64 written_sctlr;
static unsigned pagetable_calls, default_mapping_calls, configure_calls;
static unsigned sprr_calls, setup_calls, write_calls, msr_calls;
static bool fail_default_mappings;
static bool fail_write_sctlr;
static bool flag_seen_in_setup;
static unsigned panic_count;
static jmp_buf panic_jmp;
static bool panic_armed;

/* INSERT_MMU_STATE */

static void panic(const char *format, ...);
static u64 read_sctlr(void) { return mock_sctlr; }
static void write_sctlr(u64 value)
{
    if (fail_write_sctlr)
        panic("mock SCTLR write failure\n");
    written_sctlr = value;
    mock_sctlr = value;
    write_calls++;
}
static bool supports_pan(void) { return true; }
static u64 mrs(int reg) { (void)reg; return mock_sctlr; }
static void msr(int reg, u64 value) { (void)reg; (void)value; msr_calls++; }
static void mmu_init_pagetables(void) { pagetable_calls++; }
static void mmu_add_default_mappings(void)
{
    default_mapping_calls++;
    if (fail_default_mappings)
        panic("mock mapping failure\n");
}
static void mmu_configure(void) { configure_calls++; }
static void mmu_init_sprr(void) { sprr_calls++; }
static void mcc_t6032_begin_carveout_setup(void)
{
    setup_calls++;
    flag_seen_in_setup = t6032_mmu_initialized;
}
static void panic(const char *format, ...)
{
    va_list args;
    va_start(args, format);
    va_end(args);
    panic_count++;
    if (panic_armed)
        longjmp(panic_jmp, 1);
    abort();
}

/* INSERT_MMU_SOURCE */

#define CHECK(test) do { \
    if (!(test)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #test); return 1; } \
} while (0)

static void reset_fixture(void)
{
    chip_id = T6032;
    mock_sctlr = written_sctlr = 0;
    pagetable_calls = default_mapping_calls = configure_calls = 0;
    sprr_calls = setup_calls = write_calls = msr_calls = 0;
    fail_default_mappings = false;
    fail_write_sctlr = false;
    flag_seen_in_setup = false;
    panic_count = 0;
    panic_armed = false;
    feature_fixture.mmu_sprr = false;
    t6032_mmu_initialized = false;
}

static int call_mmu_init(bool expect_panic)
{
    panic_armed = true;
    if (setjmp(panic_jmp) == 0) {
        mmu_init();
        panic_armed = false;
        CHECK(!expect_panic);
    } else {
        panic_armed = false;
        CHECK(expect_panic);
    }
    return 0;
}

static int test_inherited_state(void)
{
    reset_fixture();
    mock_sctlr = SCTLR_M;
    CHECK(call_mmu_init(true) == 0 && panic_count == 1);
    CHECK(!pagetable_calls && !default_mapping_calls && !setup_calls && !write_calls);
    puts("MMU entry case: T6032 inherited M rejects before setup");
    return 0;
}

static int test_legacy_inherited_state(void)
{
    reset_fixture();
    chip_id = T6031;
    mock_sctlr = SCTLR_M;
    CHECK(call_mmu_init(false) == 0 && panic_count == 0);
    CHECK(!pagetable_calls && !default_mapping_calls && !setup_calls && !write_calls);
    puts("MMU entry case: legacy inherited M remains idempotent");
    return 0;
}

static int test_success_and_idempotence(void)
{
    reset_fixture();
    CHECK(call_mmu_init(false) == 0 && panic_count == 0);
    CHECK(t6032_mmu_initialized && mock_sctlr & SCTLR_M);
    CHECK(pagetable_calls == 1 && default_mapping_calls == 1 && setup_calls == 1);
    CHECK(write_calls == 1 && !flag_seen_in_setup);
    CHECK(call_mmu_init(false) == 0 && panic_count == 0);
    CHECK(pagetable_calls == 1 && setup_calls == 1 && write_calls == 1);
    CHECK(written_sctlr & SCTLR_M);
    puts("MMU entry case: disabled init publishes latch; repeated M-on is idempotent");
    return 0;
}

static int test_rebuild_clears_before_setup(void)
{
    CHECK(test_success_and_idempotence() == 0);
    mock_sctlr = 0;
    flag_seen_in_setup = true;
    CHECK(call_mmu_init(false) == 0 && panic_count == 0);
    CHECK(setup_calls == 2 && write_calls == 2 && !flag_seen_in_setup);
    CHECK(t6032_mmu_initialized);
    puts("MMU entry case: disabled rebuild clears latch before preflight");
    return 0;
}

static int test_failed_rebuild_does_not_publish(void)
{
    reset_fixture();
    fail_default_mappings = true;
    CHECK(call_mmu_init(true) == 0 && panic_count == 1);
    CHECK(!t6032_mmu_initialized && write_calls == 0);
    fail_default_mappings = false;
    mock_sctlr = SCTLR_M;
    CHECK(call_mmu_init(true) == 0 && panic_count == 2);
    CHECK(pagetable_calls == 1 && setup_calls == 1 && default_mapping_calls == 1 &&
          write_calls == 0);
    puts("MMU entry case: failed preflight leaves latch false and rejects inherited M");
    return 0;
}

static int test_temporary_disable_restore(void)
{
    reset_fixture();
    CHECK(call_mmu_init(false) == 0 && t6032_mmu_initialized);
    unsigned setup_before = setup_calls, writes_before = write_calls;
    mock_sctlr = 0;
    mock_sctlr = SCTLR_M;
    CHECK(call_mmu_init(false) == 0 && panic_count == 0);
    CHECK(t6032_mmu_initialized && setup_calls == setup_before &&
          write_calls == writes_before);
    puts("MMU entry case: simulated temporary disable/restore preserves validated latch");
    return 0;
}

static int test_failed_sctlr_write_does_not_publish(void)
{
    reset_fixture();
    CHECK(call_mmu_init(false) == 0 && t6032_mmu_initialized);
    mock_sctlr = 0;
    fail_write_sctlr = true;
    CHECK(call_mmu_init(true) == 0 && panic_count == 1);
    CHECK(!t6032_mmu_initialized && write_calls == 1);
    fail_write_sctlr = false;
    mock_sctlr = SCTLR_M;
    CHECK(call_mmu_init(true) == 0 && panic_count == 2);
    puts("MMU entry case: failed SCTLR write does not publish latch");
    return 0;
}

int main(void)
{
    CHECK(test_inherited_state() == 0);
    CHECK(test_legacy_inherited_state() == 0);
    CHECK(test_success_and_idempotence() == 0);
    CHECK(test_rebuild_clears_before_setup() == 0);
    CHECK(test_failed_rebuild_does_not_publish() == 0);
    CHECK(test_failed_sctlr_write_does_not_publish() == 0);
    CHECK(test_temporary_disable_restore() == 0);
    puts("m1n1 MMU entry: PASS (inherited-state, legacy, idempotence, rebuild, failed-preflight, failed-write, restore)");
    return 0;
}

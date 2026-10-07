/*
 * Source-extracted top-down reservation fixture.  The heapblock and
 * top_of_memory_alloc implementations are inserted verbatim by the runner;
 * backing storage is real host memory.  Each case is run in a fresh process
 * because the production guard-page state is deliberately static.
 */
#include <setjmp.h>
#include <stdarg.h>
#include <stdnoreturn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint8_t u8;
typedef uint64_t u64;

#define SZ_16K (1 << 14)
#define ALIGN_UP(x, a) (((x) + ((a) - 1)) & ~((a) - 1))
#define KERNEL_ALIGN (2 << 20)
#define MAX_DECOMPRESSED_SIZE (1U << 30)

struct mock_boot_args {
    u64 top_of_kernel_data;
    u64 phys_base;
    u64 mem_size;
};
struct mock_boot_args cur_boot_args;

static jmp_buf panic_env;
static bool panic_armed;
static int panic_seen;

_Noreturn static void fixture_fail(const char *expr, const char *file, int line)
{
    if (panic_armed) {
        panic_seen = 1;
        longjmp(panic_env, 1);
    }
    fprintf(stderr, "FIXTURE_ASSERT:%s:%d:%s\n", file, line, expr);
    exit(1);
}

#define assert(expr) ((expr) ? (void)0 : fixture_fail(#expr, __FILE__, __LINE__))

_Noreturn void panic(const char *format, ...)
{
    (void)format;
    panic_seen = 1;
    if (panic_armed)
        longjmp(panic_env, 1);
    va_list ap;
    va_start(ap, format);
    fputs("UNEXPECTED_PANIC:", stderr);
    vfprintf(stderr, format, ap);
    va_end(ap);
    exit(1);
}

/* INSERT_SOURCE_GLOBALS */

/* INSERT_SOURCE_PROTOTYPES */
/* INSERT_HEAP_FUNCTIONS */
/* INSERT_TOP_FUNCTION */
/* INSERT_PREPARE_FUNCTION */

#ifndef HAVE_TOP_RESERVE
void heapblock_reserve_top(void *limit) { (void)limit; }
#endif
#ifndef HAVE_PREPARE_FUNCTION
static bool prepare_decompression_buffer(void **dest, uint32_t *dest_len)
{
    (void)dest; (void)dest_len; return false;
}
#endif

static unsigned char *backing;
static size_t backing_size;

static void setup(u64 mem_size, u64 phys_base, size_t kernel_offset)
{
    backing_size = 8U << 20;
    backing = aligned_alloc(64, backing_size);
    assert(backing);
    memset(backing, 0xa5, backing_size);
    if (!phys_base)
        phys_base = (u64)(uintptr_t)backing;
    cur_boot_args.phys_base = phys_base;
    cur_boot_args.mem_size = mem_size;
    cur_boot_args.top_of_kernel_data = (u64)(uintptr_t)(backing + kernel_offset);
    heapblock_init();
}

static void expect_panic_top(size_t size)
{
    u64 old_mem = cur_boot_args.mem_size;
    void *old_cursor = heapblock_get_cursor();
    void *old_limit = heapblock_get_limit();
    panic_seen = 0;
    panic_armed = true;
    if (setjmp(panic_env) == 0) {
        (void)top_of_memory_alloc(size);
        panic_armed = false;
        fixture_fail("expected top-down panic", __FILE__, __LINE__);
    }
    panic_armed = false;
    assert(panic_seen);
    assert(cur_boot_args.mem_size == old_mem);
    assert(heapblock_get_cursor() == old_cursor);
    assert(heapblock_get_limit() == old_limit);
}

static void expect_panic_alloc(size_t size, size_t align)
{
    void *old_cursor = heapblock_get_cursor();
    void *old_limit = heapblock_get_limit();
    panic_seen = 0;
    panic_armed = true;
    if (setjmp(panic_env) == 0) {
        (void)heapblock_alloc_aligned(size, align);
        panic_armed = false;
        fixture_fail("expected heap allocator panic", __FILE__, __LINE__);
    }
    panic_armed = false;
    assert(panic_seen);
    assert(heapblock_get_cursor() == old_cursor);
    assert(heapblock_get_limit() == old_limit);
}

static void expect_panic_reserve(void *limit)
{
    void *old_cursor = heapblock_get_cursor();
    void *old_limit = heapblock_get_limit();
    panic_seen = 0;
    panic_armed = true;
    if (setjmp(panic_env) == 0) {
        heapblock_reserve_top(limit);
        panic_armed = false;
        fixture_fail("expected reserve_top panic", __FILE__, __LINE__);
    }
    panic_armed = false;
    assert(panic_seen);
    assert(heapblock_get_cursor() == old_cursor);
    assert(heapblock_get_limit() == old_limit);
}

static int case_basic(void)
{
    const u64 initial = 4ULL << 20;
    const size_t rounded = 0x14000;
    setup(initial, (u64)(uintptr_t)backing, 0x100);
    u64 base = cur_boot_args.phys_base;
    u64 first = top_of_memory_alloc(0x12345);
    assert(first == base + initial - rounded);
    assert(cur_boot_args.mem_size == initial - rounded - SZ_16K);
    assert((u64)(uintptr_t)heapblock_get_limit() == first - SZ_16K);
    u64 second = top_of_memory_alloc(0x20000);
    assert(second == first - 0x20000);
    assert(heapblock_get_limit() == (void *)(uintptr_t)(second - SZ_16K));
    free(backing);
    return 0;
}

static int case_zero(void)
{
    const u64 initial = 2ULL << 20;
    setup(initial, (u64)(uintptr_t)backing, 0x100);
    u64 first = top_of_memory_alloc(0);
    assert(first == cur_boot_args.phys_base + initial);
    assert(cur_boot_args.mem_size == initial - SZ_16K);
    assert((u64)(uintptr_t)heapblock_get_limit() == first - SZ_16K);
    u64 second = top_of_memory_alloc(0);
    assert(second == first);
    assert(cur_boot_args.mem_size == initial - SZ_16K);
    assert((u64)(uintptr_t)heapblock_get_limit() == first - SZ_16K);
    free(backing);
    return 0;
}

static int case_limits(void)
{
    const u64 initial = 4ULL << 20;
    setup(initial, (u64)(uintptr_t)backing, 0x100);
    u64 base = cur_boot_args.phys_base;
    void *cursor = heapblock_get_cursor();
    void *strict = (u8 *)cursor + 0x30000;
    heapblock_set_limit((u8 *)cursor + 0x30000);
    u64 top = top_of_memory_alloc(0x10000);
    assert((u64)(uintptr_t)heapblock_get_limit() == (u64)(uintptr_t)strict);
    heapblock_set_limit((u8 *)cursor + 0x70000);
    assert((u64)(uintptr_t)heapblock_get_limit() <= top);
    void *requested_wide = heapblock_get_limit();
    assert(requested_wide == (u8 *)cursor + 0x70000);
    heapblock_set_limit((u8 *)cursor - 1);
    assert(heapblock_get_limit() == (u8 *)cursor - 1);
    heapblock_set_limit(NULL);
    void *top_limit = (void *)(uintptr_t)(top - SZ_16K);
    assert(heapblock_get_limit() == top_limit);
    expect_panic_reserve(NULL);
    heapblock_reserve_top(top_limit);
    assert(heapblock_get_limit() == top_limit);
    expect_panic_reserve((u8 *)cursor - 1);
    expect_panic_reserve((u8 *)(uintptr_t)top + 0x1000);
    assert(base != 0);
    free(backing);
    return 0;
}

static int case_exact(void)
{
    setup(0x8100, (u64)(uintptr_t)backing, 0x100);
    void *cursor = heapblock_get_cursor();
    u64 top = top_of_memory_alloc(1);
    assert(top == (u64)(uintptr_t)cursor + SZ_16K);
    assert(heapblock_get_limit() == cursor);
    assert(heapblock_alloc_aligned(0, 64) == cursor);
    expect_panic_alloc(1, 64);
    free(backing);
    return 0;
}

static int case_allocation_exact(void)
{
    setup(4ULL << 20, 0, 0x100);
    void *cursor = heapblock_get_cursor();
    heapblock_reserve_top((u8 *)cursor + 0x100);
    assert(heapblock_alloc_aligned(0x100, 64) == cursor);
    assert(heapblock_get_cursor() == heapblock_get_limit());
    expect_panic_alloc(1, 64);
    free(backing);
    return 0;
}

static int case_top_strict(void)
{
    setup(1ULL << 20, 0, 0x100);
    void *cursor = heapblock_get_cursor();
    heapblock_set_limit((u8 *)cursor + 0x300000);
    u64 top = top_of_memory_alloc(0x20000);
    assert((u64)(uintptr_t)heapblock_get_limit() == top - SZ_16K);
    heapblock_set_limit(NULL);
    assert((u64)(uintptr_t)heapblock_get_limit() == top - SZ_16K);
    free(backing);
    return 0;
}

static int case_preinit(void)
{
    backing_size = 8U << 20;
    backing = aligned_alloc(64, backing_size);
    assert(backing);
    memset(backing, 0xa5, backing_size);
    cur_boot_args.phys_base = (u64)(uintptr_t)backing;
    cur_boot_args.mem_size = backing_size;
    cur_boot_args.top_of_kernel_data = (u64)(uintptr_t)(backing + 0x100);
    heapblock_reserve_top(backing + 0x40000);
    heapblock_init();
    assert((u64)(uintptr_t)heapblock_get_limit() == (u64)(uintptr_t)(backing + 0x40000));
    free(backing);
    return 0;
}

static int case_preinit_invalid(void)
{
    backing_size = 8U << 20;
    backing = aligned_alloc(64, backing_size);
    assert(backing);
    memset(backing, 0xa5, backing_size);
    cur_boot_args.phys_base = (u64)(uintptr_t)backing;
    cur_boot_args.mem_size = backing_size;
    cur_boot_args.top_of_kernel_data = (u64)(uintptr_t)(backing + 0x100);
    heapblock_set_limit(backing + 0x60000);
    expect_panic_reserve(NULL);
    heapblock_reserve_top(backing + 0x80);
    panic_seen = 0;
    panic_armed = true;
    if (setjmp(panic_env) == 0) {
        heapblock_init();
        panic_armed = false;
        fixture_fail("expected pre-init ceiling panic", __FILE__, __LINE__);
    }
    panic_armed = false;
    assert(panic_seen);
    free(backing);
    return 0;
}

static int case_invalid(void)
{
    setup(4ULL << 20, (u64)(uintptr_t)backing, 0x100);
    expect_panic_top(5ULL << 20);
    expect_panic_top(SIZE_MAX);
    expect_panic_alloc(1, 0);
    expect_panic_alloc(1, 3);
    u64 initial = cur_boot_args.mem_size;
    u64 base = cur_boot_args.phys_base;
    u64 first = top_of_memory_alloc(0);
    assert(first == base + initial);
    assert(cur_boot_args.mem_size == initial - SZ_16K);
    free(backing);
    return 0;
}

static int case_top_overflow(void)
{
    setup(0x2000, UINTPTR_MAX - 0x1000, 0x100);
    expect_panic_top(0);
    free(backing);
    return 0;
}

static int case_collision_atomic(void)
{
    setup(4ULL << 20, 0, 0x100);
    void *cursor = heapblock_get_cursor();
    (void)heapblock_alloc_aligned(0x3fd000, 64);
    u64 old_mem = cur_boot_args.mem_size;
    void *old_cursor = heapblock_get_cursor();
    void *old_limit = heapblock_get_limit();
    expect_panic_top(0);
    assert(cur_boot_args.mem_size == old_mem);
    assert(heapblock_get_cursor() == old_cursor);
    assert(heapblock_get_limit() == old_limit);
    cur_boot_args.mem_size = (u64)((u8 *)old_cursor - (u8 *)(uintptr_t)cur_boot_args.phys_base) + SZ_16K;
    u64 first = top_of_memory_alloc(0);
    assert(first == (u64)(uintptr_t)old_cursor + SZ_16K);

    /* A later reservation below the actual cursor must fail atomically. */
    u64 after_first_mem = cur_boot_args.mem_size;
    expect_panic_top(1);
    assert(cur_boot_args.mem_size == after_first_mem);
    u64 no_extra_guard = top_of_memory_alloc(0);
    assert(no_extra_guard == (u64)(uintptr_t)old_cursor + SZ_16K);
    assert(cur_boot_args.mem_size == after_first_mem);
    assert(heapblock_get_limit() == old_cursor);

    /* A later reservation that would raise heap_top must also be atomic. */
    u64 saved_top = (u64)(uintptr_t)heapblock_get_limit();
    old_mem = cur_boot_args.mem_size;
    old_cursor = heapblock_get_cursor();
    old_limit = heapblock_get_limit();
    cur_boot_args.mem_size = (saved_top - cur_boot_args.phys_base) + 0x20000;
    expect_panic_top(0);
    assert(cur_boot_args.mem_size == (saved_top - cur_boot_args.phys_base) + 0x20000);
    assert(heapblock_get_cursor() == old_cursor);
    assert(heapblock_get_limit() == old_limit);
    cur_boot_args.mem_size = saved_top - cur_boot_args.phys_base;
    u64 later = top_of_memory_alloc(0);
    assert(later == saved_top + SZ_16K);
    assert(cur_boot_args.mem_size == saved_top - cur_boot_args.phys_base);
    assert(heapblock_get_limit() == (void *)(uintptr_t)saved_top);
    assert(cursor != NULL);
    free(backing);
    return 0;
}

static int case_ret_overflow(void)
{
    setup(4ULL << 20, (u64)(uintptr_t)backing, 0x100);
    (void)top_of_memory_alloc(0);
    cur_boot_args.phys_base = UINTPTR_MAX - 0x1000;
    cur_boot_args.mem_size = 0x1000;
    expect_panic_top(0);
    free(backing);
    return 0;
}

static int case_heap_arithmetic(void)
{
    setup(4ULL << 20, (u64)(uintptr_t)backing, 0x100);
    cur_boot_args.top_of_kernel_data = UINTPTR_MAX - 0x1000;
    /* The real heap initializer performs the zero-byte aligned allocation;
     * this synthetic pointer is never dereferenced. */
    heapblock_init();
    expect_panic_alloc(SIZE_MAX, 64);
    free(backing);
    return 0;
}

static int case_heap_align_overflow(void)
{
    setup(4ULL << 20, (u64)(uintptr_t)backing, 0x100);
    cur_boot_args.top_of_kernel_data = UINTPTR_MAX - 0x1f;
    panic_seen = 0;
    panic_armed = true;
    if (setjmp(panic_env) == 0) {
        heapblock_init();
        panic_armed = false;
        fixture_fail("expected heap alignment panic", __FILE__, __LINE__);
    }
    panic_armed = false;
    assert(panic_seen);
    free(backing);
    return 0;
}

static int case_collision_control(void)
{
    setup(4ULL << 20, (u64)(uintptr_t)backing, 0x100);
    u64 top = top_of_memory_alloc(0x20000);
    (void)heapblock_alloc_aligned(0x400000, 64);
    if ((u64)(uintptr_t)heapblock_get_cursor() > top) {
        fprintf(stderr, "DESIGNATED_STALE_TOP_LIMIT_OVERLAP\n");
        return 1;
    }
    fprintf(stderr, "control did not cross top reservation\n");
    return 2;
}

static int case_integration(void)
{
    setup(4ULL << 20, (u64)(uintptr_t)backing, 0x100);
    (void)top_of_memory_alloc(0x20000);
    void *dest = NULL;
    uint32_t cap = 0;
    assert(prepare_decompression_buffer(&dest, &cap));
    u64 effective = (u64)(uintptr_t)heapblock_get_limit();
    assert(effective >= (u64)(uintptr_t)dest);
    assert(cap == effective - (u64)(uintptr_t)dest);
    free(backing);
    return 0;
}

int main(int argc, char **argv)
{
    assert(argc == 2);
    if (!strcmp(argv[1], "basic")) return case_basic();
    if (!strcmp(argv[1], "zero")) return case_zero();
    if (!strcmp(argv[1], "limits")) return case_limits();
    if (!strcmp(argv[1], "exact")) return case_exact();
    if (!strcmp(argv[1], "allocation-exact")) return case_allocation_exact();
    if (!strcmp(argv[1], "top-strict")) return case_top_strict();
    if (!strcmp(argv[1], "preinit")) return case_preinit();
    if (!strcmp(argv[1], "preinit-invalid")) return case_preinit_invalid();
    if (!strcmp(argv[1], "invalid")) return case_invalid();
    if (!strcmp(argv[1], "top-overflow")) return case_top_overflow();
    if (!strcmp(argv[1], "ret-overflow")) return case_ret_overflow();
    if (!strcmp(argv[1], "collision-atomic")) return case_collision_atomic();
    if (!strcmp(argv[1], "heap-arithmetic")) return case_heap_arithmetic();
    if (!strcmp(argv[1], "heap-align-overflow")) return case_heap_align_overflow();
    if (!strcmp(argv[1], "collision-control")) return case_collision_control();
    if (!strcmp(argv[1], "integration")) return case_integration();
    fprintf(stderr, "unknown case\n");
    return 2;
}

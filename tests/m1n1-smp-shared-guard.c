/* Host harness for the extracted 0016 SMP-shared mapping/lifecycle guards. */
#include <setjmp.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

typedef uint8_t u8;
typedef uint64_t u64;
#define BIT(n) (1ULL << (n))
#define ARRAY_SIZE(x) (sizeof(x) / sizeof((x)[0]))
#define UNUSED(x) ((void)(x))
#define PTE_MAIR_IDX(i) (((i) & 7) << 2)
#define T6032 1
static int chip_id;
static bool mmu_t6032_mapping_allowed(u64 from, u64 to, size_t size)
{ UNUSED(from); UNUSED(to); UNUSED(size); return true; }

#if defined(__APPLE__)
__asm__(
    ".section __DATA,__data\n.align 14\n"
    ".globl __smp_shared_start\n__smp_shared_start:\n"
    ".space 0x10000\n.globl __smp_shared_end\n__smp_shared_end:\n.text\n");
#else
__asm__(
    ".section .data\n.balign 0x4000\n"
    ".globl _smp_shared_start\n_smp_shared_start:\n"
    ".space 0x10000\n.globl _smp_shared_end\n_smp_shared_end:\n.text\n");
#endif

/* INSERT_MEMORY_DEFINES */

static bool mock_mmu_active;
static size_t mock_page_size = 4096;
static unsigned map_effects;
static unsigned remove_effects;
static unsigned cache_effects;
static unsigned barrier_effects;
static unsigned alloc_effects;
static unsigned panic_count;
static bool catch_panic;
static unsigned fail_map_call;
static u64 *mmu_pt_L0;
#define PAGE_SIZE 4096
#define ENTRIES_PER_L0_TABLE 512
static jmp_buf panic_env;

void mmu_add_mapping(u64 from, u64 to, size_t size, u8 attribute_index, u64 perms);
void mmu_rm_mapping(u64 from, size_t size);
void mmu_map_framebuffer(u64 addr, size_t size);

static int mmu_map(u64 from, u64 to, size_t size)
{
    (void)from; (void)to; (void)size;
    map_effects++;
    if (!to)
        remove_effects++;
    if (fail_map_call && map_effects == fail_map_call)
        return -1;
    return 0;
}
static size_t get_page_size(void) { return mock_page_size; }
static bool mmu_active(void) { return mock_mmu_active; }
static void *memalign(size_t alignment, size_t size)
{ (void)alignment; (void)size; alloc_effects++; return (void *)(uintptr_t)0x1000; }
static void memset64(void *ptr, uint64_t value, size_t size)
{ (void)ptr; (void)value; (void)size; }
static void dc_civac_range(void *addr, size_t size)
{ (void)addr; (void)size; cache_effects++; }
static void sysop(const char *op) { (void)op; barrier_effects++; }
static void panic(const char *message, ...)
{
    (void)message;
    panic_count++;
    if (catch_panic)
        longjmp(panic_env, 1);
    fprintf(stderr, "unexpected panic %u\\n", panic_count);
    abort();
}

/* INSERT_GUARD_SOURCE */

#define CHECK(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); \
        return 1; \
    } \
} while (0)

static bool expect_panic(void (*operation)(void))
{
    unsigned before_maps = map_effects;
    unsigned before_removes = remove_effects;
    unsigned before_cache = cache_effects;
    unsigned before_barriers = barrier_effects;
    catch_panic = true;
    if (setjmp(panic_env) == 0)
        operation();
    catch_panic = false;
    return panic_count == 1 && map_effects == before_maps &&
           remove_effects == before_removes && cache_effects == before_cache &&
           barrier_effects == before_barriers;
}

/* INSERT_TEST_ADAPTERS */

int main(void)
{
    /* The generated adapter supplies ready-state and function-call wrappers. */
    CHECK(test_guard_matrix() == 0);
    puts("SMP-shared guard harness passed: lifecycle, aliases, attrs, MMIO, framebuffer, start gate");
    return 0;
}

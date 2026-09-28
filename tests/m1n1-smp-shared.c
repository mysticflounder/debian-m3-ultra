/* Host harness for the extracted m1n1 SMP-shared MMU remap function. */
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

typedef uint8_t u8;
typedef uint64_t u64;
extern u8 _smp_shared_start[], _smp_shared_end[];
#define BIT(n) (1ULL << (n))

/* The aliases model the linker symbols, while keeping the fixture explicit. */
#if defined(__APPLE__)
__asm__(
    ".section __DATA,__data\n"
    ".align 14\n"
    ".globl __smp_shared_start\n"
    "__smp_shared_start:\n"
    ".space 0x10000\n"
    ".globl __smp_shared_end\n"
    "__smp_shared_end:\n"
    ".text\n");
#else
__asm__(
    ".section .data\n"
    ".balign 0x4000\n"
    ".globl _smp_shared_start\n"
    "_smp_shared_start:\n"
    ".space 0x10000\n"
    ".globl _smp_shared_end\n"
    "_smp_shared_end:\n"
    ".text\n");
#endif

/* INSERT_MEMORY_DEFINES */

struct mapping {
    u64 from;
    u64 to;
    size_t size;
    u8 attribute_index;
    u64 perms;
};

static struct mapping mappings[8];
static unsigned mapping_count;

/* This is the only hardware-facing seam: the extracted function calls it. */
static void record_mapping(u64 from, u64 to, size_t size, u8 attribute_index, u64 perms)
{
    if (mapping_count < sizeof(mappings) / sizeof(mappings[0]))
        mappings[mapping_count] = (struct mapping){from, to, size, attribute_index, perms};
    mapping_count++;
}

#define mmu_add_mapping record_mapping
/* INSERT_MMU_REMAP_FUNCTION */
#undef mmu_add_mapping

#define CHECK(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); \
        return 1; \
    } \
} while (0)

int main(void)
{
    const u64 base = (u64)(uintptr_t)_smp_shared_start;
    const size_t size = (size_t)(_smp_shared_end - _smp_shared_start);
    const u64 expected_from[] = {
        base,
        base | REGION_RWX_EL0,
        base | REGION_RW_EL0,
        base | REGION_RX_EL1,
    };

    CHECK(base % 0x1000 == 0 && base % 0x4000 == 0);
    CHECK(size == 0x10000 && size % 0x1000 == 0 && size % 0x4000 == 0);
    mmu_remap_smp_shared();
    CHECK(mapping_count == 4);
    for (unsigned i = 0; i < 4; i++) {
        CHECK(mappings[i].from == expected_from[i]);
        CHECK(mappings[i].to == base);
        CHECK(mappings[i].size == size);
        CHECK(mappings[i].attribute_index == MAIR_IDX_DEVICE_nGnRnE);
        CHECK(mappings[i].perms == (i == 0 ? PERM_RW : PERM_RW_EL0));
    }
    puts("SMP-shared mapping harness passed: 4 Device-nGnRnE mappings, 4K/16K aligned");
    return 0;
}

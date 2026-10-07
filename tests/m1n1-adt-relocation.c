/* Offline arithmetic tests: no pointer is dereferenced, no firmware executes. */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
#include "xnuboot.h"

struct adt_node_hdr {
    u32 property_count;
    u32 child_count;
};
_Static_assert(sizeof(struct adt_node_hdr) == 8, "ADT node header layout");

/* ADT_RELOCATION_SOURCE */

static unsigned cases;

static void expect(const char *name, struct boot_args ba, bool valid, u64 address)
{
    const u64 canary = UINT64_C(0xa5a5a5a5a5a5a5a5);
    u64 out = canary;
    bool result = adt_boot_address(&ba, &out);
    if (result != valid || out != (valid ? address : canary)) {
        fprintf(stderr, "FAIL: ADT relocation %s\n", name);
        exit(1);
    }
    cases++;
}

int main(int argc, char **argv)
{
    struct boot_args ba = {
        .virt_base = UINT64_C(0xfffffe0000000000),
        .phys_base = UINT64_C(0x800000000),
        .devtree = (void *)(uintptr_t)UINT64_C(0xfffffe0000010000),
        .devtree_size = 44,
    };
    /* Mutation controls select only their safe arithmetic failure case. */
    const char *selected = argc > 1 ? argv[1] : NULL;
    if (!selected) {
        expect("valid-high-virtual", ba, true, UINT64_C(0x800010000));
        ba.phys_base = UINT64_C(0x2800000000);
        expect("valid-two-die-high-physical", ba, true, UINT64_C(0x2800010000));
        ba.phys_base = 4;
        ba.virt_base = 4;
        ba.devtree = (void *)(uintptr_t)4;
        ba.devtree_size = 8;
        expect("minimum-node", ba, true, 4);
        ba.phys_base = UINT64_MAX - 11;
        expect("last-nonwrapping-aligned-span", ba, true, UINT64_MAX - 11);
        ba.phys_base = UINT64_C(0x800000000);
        ba.virt_base = 0;
        ba.devtree = NULL;
        ba.devtree_size = 8;
        expect("zero-virtual-not-zero-physical", ba, true, ba.phys_base);
    }

#define REJECT(label, setup)                                                                        \
    do {                                                                                           \
        if (!selected || strcmp(selected, label) == 0) {                                            \
            ba = (struct boot_args){.virt_base = 0x1000, .phys_base = 0x800000000,                   \
                                    .devtree = (void *)(uintptr_t)0x2000, .devtree_size = 44};      \
            setup;                                                                                \
            expect(label, ba, false, 0);                                                           \
        }                                                                                          \
    } while (0)

    REJECT("zero-size", ba.devtree_size = 0);
    REJECT("short-node", ba.devtree_size = 7);
    REJECT("subtraction-underflow", ba.devtree = (void *)(uintptr_t)0xffc);
    REJECT("virtual-span-overflow", ba.virt_base = UINT64_MAX - 0x1003;
           ba.devtree = (void *)(uintptr_t)(UINT64_MAX - 3));
    REJECT("physical-relocation-overflow", ba.phys_base = UINT64_MAX - 0xffb);
    REJECT("physical-span-overflow", ba.phys_base = UINT64_MAX - 0x101f);
    REJECT("null-physical", ba.phys_base = 0; ba.devtree = (void *)(uintptr_t)0x1000);
    REJECT("unaligned-physical", ba.phys_base++);
    REJECT("unaligned-offset", ba.devtree = (void *)(uintptr_t)0x2001);

    if (!cases) {
        fprintf(stderr, "FAIL: unknown ADT relocation test selector\n");
        return 1;
    }
    printf("PASS: %u ADT relocation arithmetic cases\n", cases);
    return 0;
}

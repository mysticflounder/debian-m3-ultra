/* Positive host fixture for the pinned m1n1 inline payload parser. */
#define _POSIX_C_SOURCE 200112L

#include <assert.h>
#include <ctype.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;

#define ALIGNED(x) __attribute__((aligned(x)))
#define PACKED __attribute__((packed))
#define BIT(x) (1UL << (x))
#define ACTLR_EL1 0
#define mrs(reg) ((u64)0)
#define msr(reg, value) ((void)(reg), (void)(value))
#define MAX_CPUS 32
#define T6032 0x6032

/* Keep the source's platform headers from pulling in ARM-only declarations. */
#define ASSERT_H
#define TYPES_H
#define __PAYLOAD_H__
#define XDT_H
#define __CHAINLOAD_H__
#define CPUFREQ_H
#define DISPLAY_H
#define HEAPBLOCK_H
#define KBOOT_H
#define MITIGATIONS_H
#define __SMP_H__
#define UTILS_H
#define XNUBOOT_H

struct kernel_header {
    u32 code[2];
    u64 text_offset;
    u64 image_size;
    u64 flags;
    u64 res2;
    u64 res3;
    u64 res4;
    u32 magic;
    u32 res5;
};

struct boot_args {
    u64 phys_base;
    u64 mem_size;
    u64 top_of_kernel_data;
};

struct boot_args cur_boot_args;
char *payload_start;
#define _payload_start payload_start

void *adt = (void *)(uintptr_t)1;
int chip_id;
int boot_cpu_idx;

static int mock_printf(const char *format, ...)
{
    va_list ap;
    int result;

    va_start(ap, format);
    result = vfprintf(stdout, format, ap);
    va_end(ap);
    return result;
}

#define printf mock_printf

static void *heap_storage;
static size_t heap_storage_size;
static uintptr_t heap_cursor;
static size_t heap_reserve_calls;

void *heapblock_get_cursor(void)
{
    return (void *)heap_cursor;
}

void *heapblock_get_limit(void)
{
    return (u8 *)heap_storage + heap_storage_size;
}

void *heapblock_alloc_aligned(size_t size, size_t align)
{
    uintptr_t block = (heap_cursor + align - 1) & ~(align - 1);

    assert(align && !(align & (align - 1)));
    assert(block >= (uintptr_t)heap_storage);
    assert(size <= heap_storage_size - (block - (uintptr_t)heap_storage));
    heap_cursor = block + size;
    if (size)
        heap_reserve_calls++;
    return (void *)block;
}

void *heapblock_alloc(size_t size)
{
    return heapblock_alloc_aligned(size, 1);
}

const void *adt_getprop(const void *ignored, int node, const char *name, u32 *len)
{
    static const char target[] = "j575d";

    (void)ignored;
    (void)node;
    if (strcmp(name, "target-type") != 0)
        return NULL;
    if (len)
        *len = sizeof(target);
    return target;
}

static void *retained_initrd;
static size_t retained_initrd_size;
static void *retained_fdt;
static void *retained_kernel;
static char retained_bootargs[1024];
static char retained_bootargs_name[128];
static unsigned int initrd_calls;
static unsigned int fdt_prepare_calls;
static unsigned int boot_calls;

void kboot_set_initrd(void *start, size_t size)
{
    retained_initrd = start;
    retained_initrd_size = size;
    initrd_calls++;
}

int kboot_set_chosen(const char *name, const char *value)
{
    snprintf(retained_bootargs_name, sizeof(retained_bootargs_name), "%s", name);
    snprintf(retained_bootargs, sizeof(retained_bootargs), "%s", value);
    return 0;
}

int kboot_prepare_dt(void *fdt)
{
    retained_fdt = fdt;
    fdt_prepare_calls++;
    return 0;
}

int kboot_boot(void *kernel)
{
    retained_kernel = kernel;
    boot_calls++;
    return 0;
}

int cpufreq_init(void)
{
    return 0;
}

void display_configure(const char *value)
{
    (void)value;
}

void mitigations_configure(const char *value)
{
    (void)value;
}

int smp_start_secondaries(void)
{
    return 0;
}

void mitigations_perform(void)
{
}

bool smp_is_alive(int cpu)
{
    (void)cpu;
    return false;
}

void smp_call4(int cpu, void *function, u64 arg0, u64 arg1, u64 arg2, u64 arg3)
{
    (void)cpu;
    (void)function;
    (void)arg0;
    (void)arg1;
    (void)arg2;
    (void)arg3;
}

void smp_call0(int cpu, void (*function)(void))
{
    (void)cpu;
    (void)function;
}

u64 smp_wait(int cpu)
{
    (void)cpu;
    return 0;
}

bool XzDecode(uint8_t *input, uint32_t *input_size,
              uint8_t *output, uint32_t *output_size)
{
    (void)input;
    (void)input_size;
    (void)output;
    (void)output_size;
    return false;
}

int chainload_load(const char *spec, char **vars, size_t var_count)
{
    (void)spec;
    (void)vars;
    (void)var_count;
    return -1;
}

static void require_file(const char *path, u8 **data, size_t *size)
{
    FILE *file = fopen(path, "rb");
    long length;

    assert(file);
    assert(fseek(file, 0, SEEK_END) == 0);
    length = ftell(file);
    assert(length >= 0);
    assert(fseek(file, 0, SEEK_SET) == 0);
    *size = (size_t)length;
    *data = malloc(*size ? *size : 1);
    assert(*data);
    assert(fread(*data, 1, *size, file) == *size);
    assert(fclose(file) == 0);
}

static size_t find_bytes(const u8 *data, size_t size, const u8 *needle, size_t needle_size)
{
    for (size_t offset = 0; offset + needle_size <= size; ++offset) {
        if (!memcmp(data + offset, needle, needle_size))
            return offset;
    }
    return SIZE_MAX;
}

/* The real source is inserted here by scripts/test-m1n1-inline-package.py. */
/* INSERT_PAYLOAD_INCLUDE */

#undef printf

int main(int argc, char **argv)
{
    static const u8 initramfs_magic[14] = {
        'm', '1', 'n', '1', '_', 'i', 'n', 'i', 't', 'r', 'a', 'm', 'f', 's'};
    static const u8 image_magic[4] = {'A', 'R', 'M', 0x64};
    static const u8 empty_magic[4] = {0, 0, 0, 0};
    u8 *package, *m1n1, *image, *dtb, *initrd;
    size_t package_size, m1n1_size, image_size, dtb_size, initrd_size;
    size_t gzip_offset, dtb_offset, wrapper_offset, initrd_offset, trailer_offset;
    size_t wrapper_relative;
    size_t trailer_relative;
    u32 wrapped_size;
    u8 *heap;
    const size_t heap_size = 64U * 1024U * 1024U;
    const char *bootargs;
    size_t decoded_image_size;
    size_t declared_image_size;

    assert(argc == 7);
    bootargs = argv[6];
    require_file(argv[1], &package, &package_size);
    require_file(argv[2], &m1n1, &m1n1_size);
    require_file(argv[3], &image, &image_size);
    require_file(argv[4], &dtb, &dtb_size);
    require_file(argv[5], &initrd, &initrd_size);
    assert(package_size > m1n1_size);
    assert(!memcmp(package, m1n1, m1n1_size));

    payload_start = (char *)package + m1n1_size;
    cur_boot_args.top_of_kernel_data = (u64)(uintptr_t)(package + package_size);
    cur_boot_args.phys_base = 0;
    cur_boot_args.mem_size = UINT64_MAX;
    heap = aligned_alloc(2U * 1024U * 1024U, heap_size);
    assert(heap);
    heap_storage = heap;
    heap_storage_size = heap_size;
    heap_cursor = (uintptr_t)heap;

    gzip_offset = find_bytes((u8 *)payload_start, package_size - m1n1_size,
                             (const u8 *)"\x1f\x8b", 2);
    assert(gzip_offset != SIZE_MAX);
    gzip_offset += m1n1_size;
    dtb_offset = SIZE_MAX;
    for (size_t candidate = gzip_offset; candidate + 4 <= package_size; ++candidate) {
        if (!memcmp(package + candidate, "\xd0\x0d\xfe\xed", 4) &&
            fdt_check_header(package + candidate) == 0 &&
            fdt_totalsize(package + candidate) <= package_size - candidate) {
            dtb_offset = candidate;
            break;
        }
    }
    assert(dtb_offset != SIZE_MAX);
    wrapper_relative = find_bytes(package + dtb_offset + dtb_size,
                                   package_size - dtb_offset - dtb_size,
                                   initramfs_magic, sizeof(initramfs_magic));
    assert(wrapper_relative != SIZE_MAX);
    wrapper_offset = dtb_offset + dtb_size + wrapper_relative;
    memcpy(&wrapped_size, package + wrapper_offset + sizeof(initramfs_magic), sizeof(wrapped_size));
    initrd_offset = wrapper_offset + sizeof(initramfs_magic) + sizeof(wrapped_size);
    assert(wrapped_size == initrd_size);
    assert(!memcmp(package + initrd_offset, initrd, initrd_size));
    trailer_relative = find_bytes(package + initrd_offset + initrd_size,
                                   package_size - initrd_offset - initrd_size,
                                   empty_magic, sizeof(empty_magic));
    assert(trailer_relative != SIZE_MAX);
    trailer_offset = initrd_offset + initrd_size + trailer_relative;
    assert(package_size - trailer_offset == 64);
    for (size_t i = trailer_offset; i < package_size; ++i)
        assert(package[i] == 0);

    assert(payload_run() == 0);
    assert(initrd_calls == 1);
    assert(retained_initrd == package + initrd_offset);
    assert(retained_initrd_size == initrd_size);
    assert(fdt_prepare_calls == 1);
    assert(retained_fdt == package + dtb_offset);
    assert(fdt_totalsize(package + dtb_offset) == dtb_size);
    assert(!memcmp(retained_fdt, dtb, dtb_size));
    assert(!strcmp(retained_bootargs_name, "bootargs"));
    assert(!strcmp(retained_bootargs, bootargs));
    assert(boot_calls == 1);
    assert(retained_kernel != NULL);

    decoded_image_size = image_size;
    assert((u8 *)retained_kernel >= heap);
    assert(!memcmp(retained_kernel, image, image_size));
    assert(((struct kernel_header *)image)->image_size >= image_size);
    declared_image_size = ((struct kernel_header *)image)->image_size;
    assert(heap_reserve_calls >= 2);
    assert(heap_cursor == (uintptr_t)retained_kernel + declared_image_size);
    assert(((struct kernel_header *)retained_kernel)->image_size == declared_image_size);
    assert(!memcmp(package + dtb_offset, dtb, dtb_size));
    assert(!memcmp(package + initrd_offset, initrd, initrd_size));

    printf("INLINE_PACKAGE_PASS\n");
    printf("m1n1_size=%zu\n", m1n1_size);
    printf("bootargs_end=%zu\n", gzip_offset);
    printf("gzip_offset=%zu\n", gzip_offset);
    printf("gzip_consumed=%zu\n", dtb_offset - gzip_offset);
    printf("dtb_offset=%zu\n", dtb_offset);
    printf("dtb_size=%zu\n", dtb_size);
    printf("initramfs_wrapper_offset=%zu\n", wrapper_offset);
    printf("initramfs_offset=%zu\n", initrd_offset);
    printf("initramfs_size=%zu\n", initrd_size);
    printf("initrd_set_pointer_offset=%zu\n", (size_t)((u8 *)retained_initrd - package));
    printf("initrd_set_size=%zu\n", retained_initrd_size);
    printf("trailer_offset=%zu\n", trailer_offset);
    printf("dtb_selected_offset=%zu\n", (size_t)((u8 *)retained_fdt - package));
    printf("chosen_name=%s\n", retained_bootargs_name);
    printf("chosen_bootargs=%s\n", retained_bootargs);
    printf("image_decoded_size=%zu\n", decoded_image_size);
    printf("image_declared_size=%zu\n", declared_image_size);
    printf("kernel_retained_span=%zu\n", declared_image_size);
    printf("kernel_retained_heap_offset=%zu\n", (size_t)((u8 *)retained_kernel - heap));
    printf("kernel_tail_reservation=%zu\n", declared_image_size - decoded_image_size);
    printf("initrd_set_calls=%u\n", initrd_calls);
    printf("dtb_prepare_calls=%u\n", fdt_prepare_calls);
    printf("kernel_boot_calls=%u\n", boot_calls);
    printf("stream_end=%zu\n", trailer_offset);

    free(heap);
    free(package);
    free(m1n1);
    free(image);
    free(dtb);
    free(initrd);
    return 0;
}

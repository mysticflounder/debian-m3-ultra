/*
 * Source-extracted host fixture for m1n1 payload decompression bounds.
 * The runner inserts the reviewed payload helpers/wrappers and real pinned
 * tinf/minilzma sources at the marked locations.  Heap, load_one_payload and
 * boot-args are deliberately host mocks; this is not native-loader proof.
 */
#include <assert.h>
#include <inttypes.h>
#include <limits.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;

#define KERNEL_ALIGN (2 << 20)
#define MAX_DECOMPRESSED_SIZE (1U << 30)
#define TINFCC

struct mock_boot_args {
    u64 phys_base;
    u64 mem_size;
};

struct mock_boot_args cur_boot_args;

static unsigned char *heap_storage;
static size_t heap_storage_size;
static uintptr_t heap_cursor;
static void *heap_limit;
static uintptr_t cursor_override;
static bool cursor_override_set;
static unsigned long zero_alloc_calls;
static unsigned long reserve_calls;
static unsigned long decoder_load_calls;
static void *last_loaded;
static size_t last_loaded_len;
static size_t payload_padding;

static void mock_heap_reset(size_t storage_size, size_t initial_offset)
{
    free(heap_storage);
    heap_storage = calloc(1, storage_size);
    assert(heap_storage);
    heap_storage_size = storage_size;
    memset(heap_storage, 0xa5, storage_size);
    assert(initial_offset < storage_size);
    heap_cursor = (uintptr_t)heap_storage + initial_offset;
    heap_limit = NULL;
    cursor_override = 0;
    cursor_override_set = false;
    zero_alloc_calls = 0;
    reserve_calls = 0;
    decoder_load_calls = 0;
    last_loaded = NULL;
    last_loaded_len = 0;
    payload_padding = 0;
}

static uintptr_t mock_aligned_cursor(void)
{
    return (heap_cursor + KERNEL_ALIGN - 1) & ~(KERNEL_ALIGN - 1);
}

void *heapblock_get_cursor(void)
{
    return (void *)(cursor_override_set ? cursor_override : heap_cursor);
}

void *heapblock_get_limit(void)
{
    return heap_limit;
}

void *heapblock_alloc_aligned(size_t size, size_t align)
{
    uintptr_t block;
    assert(align && !(align & (align - 1)));
    block = (heap_cursor + align - 1) & ~(align - 1);
    if (!size)
        zero_alloc_calls++;
    else
        reserve_calls++;
    /* Keep backing storage oversized: tests inspect bytes beyond the logical
     * limit instead of allowing a sanitizer-detected physical overflow. */
    assert(block >= (uintptr_t)heap_storage);
    assert(block - (uintptr_t)heap_storage <= heap_storage_size);
    assert(size <= heap_storage_size - (block - (uintptr_t)heap_storage));
    heap_cursor = block + size;
    return (void *)block;
}

static void reset_boot(u64 phys_base, u64 mem_size, void *limit)
{
    cur_boot_args.phys_base = phys_base;
    cur_boot_args.mem_size = mem_size;
    heap_limit = limit;
}

static void *load_one_payload(void *start, size_t size)
{
    decoder_load_calls++;
    last_loaded = start;
    last_loaded_len = size;
    return (u8 *)start + size + payload_padding;
}

/* INSERT_PAYLOAD_FUNCTIONS */

/* INSERT_DECODER_SOURCES */

static size_t changed_after(unsigned char *start, size_t begin, size_t end)
{
    size_t changed = 0;
    for (size_t i = begin; i < end; ++i)
        changed += start[i] != 0xa5;
    return changed;
}

static void assert_no_writes_after(unsigned char *dest, size_t cap, size_t output_len)
{
    assert(changed_after(dest, cap, output_len) == 0);
}

static void assert_writes_after(unsigned char *dest, size_t cap, size_t output_len)
{
    assert(changed_after(dest, cap, output_len) != 0);
}

static void test_helper_boundaries(const unsigned char *gzip, size_t gzip_len)
{
    (void)gzip;
    (void)gzip_len;
#ifdef HAVE_PREPARE_DECOMPRESSION_BUFFER
    void *dest = NULL;
    uint32_t cap = 0;
    uintptr_t base;

    mock_heap_reset(8U << 20, 17);
    base = (uintptr_t)heap_storage;
    reset_boot((u64)base, 3ULL << 30, NULL);
    assert(prepare_decompression_buffer(&dest, &cap));
    assert(cap == (1U << 30));
    assert(zero_alloc_calls == 1);

    mock_heap_reset(8U << 20, 17);
    base = (uintptr_t)heap_storage;
    reset_boot((u64)base, KERNEL_ALIGN + 64, NULL);
    assert(prepare_decompression_buffer(&dest, &cap));
    assert(cap == KERNEL_ALIGN + 64 - ((uintptr_t)dest - base));

    mock_heap_reset(8U << 20, 17);
    base = (uintptr_t)heap_storage;
    reset_boot((u64)base, 64, (void *)(mock_aligned_cursor() + 128));
    assert(prepare_decompression_buffer(&dest, &cap));
    assert(cap == 128);

    mock_heap_reset(8U << 20, 17);
    base = (uintptr_t)heap_storage;
    reset_boot((u64)base, 3ULL << 30, (void *)(mock_aligned_cursor() - 1));
    assert(!prepare_decompression_buffer(&dest, &cap));
    assert(zero_alloc_calls == 0);

    mock_heap_reset(8U << 20, 17);
    reset_boot((u64)heap_storage + 1, UINT64_MAX, NULL);
    assert(!prepare_decompression_buffer(&dest, &cap));
    assert(zero_alloc_calls == 0);

    mock_heap_reset(8U << 20, 17);
    base = (uintptr_t)heap_storage;
    reset_boot((u64)(mock_aligned_cursor() + 1), 64, NULL);
    assert(!prepare_decompression_buffer(&dest, &cap));
    assert(zero_alloc_calls == 0);

    mock_heap_reset(8U << 20, 17);
    reset_boot(0, 0, NULL);
    assert(!prepare_decompression_buffer(&dest, &cap));
    assert(zero_alloc_calls == 0);

    mock_heap_reset(8U << 20, 17);
    cursor_override = UINTPTR_MAX - (KERNEL_ALIGN - 2);
    cursor_override_set = true;
    reset_boot(0, UINT64_MAX, NULL);
    assert(!prepare_decompression_buffer(&dest, &cap));
    assert(zero_alloc_calls == 0);

    mock_heap_reset(8U << 20, 17);
    cursor_override = 0;
    cursor_override_set = true;
    reset_boot(0, UINT64_MAX, NULL);
    assert(!prepare_decompression_buffer(&dest, &cap));
    assert(zero_alloc_calls == 0);

    mock_heap_reset(8U << 20, 17);
    base = (uintptr_t)heap_storage;
    heap_limit = (void *)mock_aligned_cursor();
    reset_boot((u64)base, 1ULL << 30, heap_limit);
    assert(!prepare_decompression_buffer(&dest, &cap));
    assert(zero_alloc_calls == 0);

#endif
}

static void run_safe_wrapper(const unsigned char *input, size_t input_len,
                             size_t output_len, bool xz)
{
    unsigned char *dest;
    void *next;
    uintptr_t base;

    mock_heap_reset(8U << 20, 17);
    base = (uintptr_t)heap_storage;
    dest = (unsigned char *)mock_aligned_cursor();
    reset_boot((u64)base, (u64)((uintptr_t)dest - base) + output_len - 1, NULL);
    next = xz ? decompress_xz((void *)input, input_len) : decompress_gz((void *)input, input_len);
    assert(next == NULL);
    assert(zero_alloc_calls == 1);
    assert(decoder_load_calls == 0);
    assert_no_writes_after(dest, output_len - 1, output_len);

    /* The native inline-payload path supplies size zero while the complete
     * well-formed fixture remains in backing memory. Both real decoders must
     * discover and return the consumed encoded length. */
    mock_heap_reset(8U << 20, 17);
    base = (uintptr_t)heap_storage;
    dest = (unsigned char *)mock_aligned_cursor();
    reset_boot((u64)base, (u64)((uintptr_t)dest - base) + output_len + 4096, NULL);
    next = xz ? decompress_xz((void *)input, 0) : decompress_gz((void *)input, 0);
    assert(next == (void *)input + input_len);
    assert(decoder_load_calls == 1);
    assert(last_loaded == dest);
    assert(last_loaded_len == output_len);

    /* The same size-zero path must remain bounded when the output span is one
     * byte too short. */
    mock_heap_reset(8U << 20, 17);
    base = (uintptr_t)heap_storage;
    dest = (unsigned char *)mock_aligned_cursor();
    reset_boot((u64)base, (u64)((uintptr_t)dest - base) + output_len - 1, NULL);
    next = xz ? decompress_xz((void *)input, 0) : decompress_gz((void *)input, 0);
    assert(next == NULL);
    assert(zero_alloc_calls == 1);
    assert(decoder_load_calls == 0);
    assert_no_writes_after(dest, output_len - 1, output_len);

    /* The same one-byte-short case must hold when a non-null heap limit is
     * authoritative over a larger RAM fallback. */
    mock_heap_reset(8U << 20, 17);
    base = (uintptr_t)heap_storage;
    dest = (unsigned char *)mock_aligned_cursor();
    heap_limit = dest + output_len - 1;
    reset_boot((u64)base, 3ULL << 30, heap_limit);
    next = xz ? decompress_xz((void *)input, input_len) : decompress_gz((void *)input, input_len);
    assert(next == NULL);
    assert(zero_alloc_calls == 1);
    assert(decoder_load_calls == 0);
    assert_no_writes_after(dest, output_len - 1, output_len);

    mock_heap_reset(8U << 20, 17);
    base = (uintptr_t)heap_storage;
    dest = (unsigned char *)mock_aligned_cursor();
    reset_boot((u64)base, (u64)((uintptr_t)dest - base) + output_len + 4096, NULL);
    next = xz ? decompress_xz((void *)input, input_len) : decompress_gz((void *)input, input_len);
    assert(next != NULL);
    assert(decoder_load_calls == 1);
    assert(last_loaded_len == output_len);
    assert(reserve_calls == 1);
    assert(next == (void *)input + input_len);
    assert(last_loaded == dest);
    assert(memcmp(dest, xz ? "PAYLOAD-XZ-BOUNDARY" : "PAYLOAD-GZ-BOUNDARY", output_len) == 0);

    mock_heap_reset(8U << 20, 17);
    payload_padding = 7;
    base = (uintptr_t)heap_storage;
    dest = (unsigned char *)mock_aligned_cursor();
    heap_limit = dest + output_len + 7;
    reset_boot((u64)base, 3ULL << 30, heap_limit);
    next = xz ? decompress_xz((void *)input, input_len) : decompress_gz((void *)input, input_len);
    assert(next == (void *)input + input_len);
    assert(last_loaded == dest);
    assert(last_loaded_len == output_len);
    assert(heap_cursor == (uintptr_t)dest + output_len + 7);
    assert(reserve_calls == 2);
    payload_padding = 0;

    /* A non-null heap limit is authoritative over a larger RAM fallback. */
    mock_heap_reset(8U << 20, 17);
    base = (uintptr_t)heap_storage;
    dest = (unsigned char *)mock_aligned_cursor();
    heap_limit = dest + output_len;
    reset_boot((u64)base, 3ULL << 30, heap_limit);
    next = xz ? decompress_xz((void *)input, input_len) : decompress_gz((void *)input, input_len);
    assert(next == (void *)input + input_len);
    assert(last_loaded == dest);
    assert(heap_cursor == (uintptr_t)dest + output_len);

    /* Invalid physical span: each actual wrapper must reject before its
     * decoder and before the zero-byte heap reservation. */
    mock_heap_reset(8U << 20, 17);
    base = (uintptr_t)heap_storage;
    dest = (unsigned char *)mock_aligned_cursor();
    reset_boot((u64)(base + (8U << 20) + 1), UINT64_MAX, NULL);
    next = xz ? decompress_xz((void *)input, input_len) : decompress_gz((void *)input, input_len);
    assert(next == NULL);
    assert(zero_alloc_calls == 0);
    assert(decoder_load_calls == 0);
    assert_no_writes_after(dest, 0, output_len);
}

static int run_mutation(const unsigned char *input, size_t input_len,
                        size_t output_len, bool xz)
{
    uintptr_t base;
    unsigned char *dest;
    void *next;

    mock_heap_reset(8U << 20, 17);
    base = (uintptr_t)heap_storage;
    dest = (unsigned char *)mock_aligned_cursor();
    reset_boot((u64)base, (u64)((uintptr_t)dest - base) + output_len - 1, NULL);
    next = xz ? decompress_xz((void *)input, input_len) : decompress_gz((void *)input, input_len);
    if (!next || decoder_load_calls != 1)
        return 2;
    assert_writes_after(dest, output_len - 1, output_len);
    fprintf(stderr, "DESIGNATED_UNSAFE_WRITE_DETECTED\n");
    return 1;
}

int main(int argc, char **argv)
{
    static const unsigned char gzip[] = { /* INSERT_GZIP_BYTES */ };
    static const unsigned char xz[] = { /* INSERT_XZ_BYTES */ };
    const size_t output_len = sizeof("PAYLOAD-GZ-BOUNDARY") - 1;

    assert(sizeof(gzip) > 18 && sizeof(xz) > 32);
    if (argc > 1 && !strcmp(argv[1], "mutation-gzip"))
        return run_mutation(gzip, sizeof(gzip), output_len, false);
    if (argc > 1 && !strcmp(argv[1], "mutation-xz"))
        return run_mutation(xz, sizeof(xz), sizeof("PAYLOAD-XZ-BOUNDARY") - 1, true);

#ifdef BASE_SOURCE
    puts("BASE_SOURCE: invoke each codec with mutation-gzip/mutation-xz for designated exit1");
#else
    test_helper_boundaries(gzip, sizeof(gzip));
    run_safe_wrapper(gzip, sizeof(gzip), output_len, false);
    run_safe_wrapper(xz, sizeof(xz), sizeof("PAYLOAD-XZ-BOUNDARY") - 1, true);
    puts("PASS: bounded gzip/XZ; helper-boundary-cases=10 wrapper-cases=16 mutation-controls=4");
#endif
    free(heap_storage);
    return 0;
}

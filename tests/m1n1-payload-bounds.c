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
#define INLINE_STORAGE_SIZE (1U << 16)

struct mock_boot_args {
    u64 phys_base;
    u64 mem_size;
    u64 top_of_kernel_data;
};

struct mock_boot_args cur_boot_args;
char _payload_start[INLINE_STORAGE_SIZE];

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
    cur_boot_args.top_of_kernel_data = 0;
    heap_limit = limit;
}

static unsigned char *stage_inline(const unsigned char *input, size_t input_len,
                                   size_t tail_len)
{
    unsigned char *p = (unsigned char *)_payload_start + 0x100;
    assert(input_len + tail_len < INLINE_STORAGE_SIZE - 0x100);
    memcpy(p, input, input_len);
    memset(p + input_len, 0x5a, tail_len);
    cur_boot_args.top_of_kernel_data = (u64)(uintptr_t)(p + input_len + tail_len);
    return p;
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

#ifdef HAVE_TINF_PREFIX_APIS
/* Keep the direct decoder regression bound to the reviewed prefix API shape;
 * the declarations are repeated so the test also catches a missing header
 * prototype in a candidate source tree. */
int tinf_uncompress_prefix(void *dest, unsigned int *destLen,
                           const void *source, unsigned int *sourceLen);
int tinf_gzip_uncompress_prefix(void *dest, unsigned int *destLen,
                                const void *source, unsigned int *sourceLen);
#endif

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

#ifdef HAVE_TINF_PREFIX_APIS
static void test_prefix_decoder_apis(const unsigned char *gzip, size_t gzip_len)
{
    static const unsigned char expected[] = "PAYLOAD-GZ-BOUNDARY";
    unsigned char output[sizeof(expected)];
    unsigned char raw_with_tail[512];
    unsigned char gzip_with_tail[512];
    unsigned char bad_crc[512];
    unsigned char bad_isize[512];
    const size_t raw_offset = 10;
    const size_t raw_len = gzip_len - 18;
    const size_t tail_len = 32;
    unsigned int output_len;
    unsigned int source_len;

    assert(gzip_len + tail_len < sizeof(gzip_with_tail));
    assert(raw_len + tail_len < sizeof(raw_with_tail));
    memcpy(gzip_with_tail, gzip, gzip_len);
    memset(gzip_with_tail + gzip_len, 0x5a, tail_len);
    memcpy(raw_with_tail, gzip + raw_offset, raw_len);
    memset(raw_with_tail + raw_len, 0x5a, tail_len);

    /* Legacy zero-length source bounds remain unbounded and report the
     * decoder's actual consumption for both strict APIs. */
    output_len = sizeof(output);
    source_len = 0;
    assert(tinf_gzip_uncompress(output, &output_len, gzip, &source_len) == TINF_OK);
    assert(source_len == gzip_len && output_len == sizeof(expected) - 1);
    assert(memcmp(output, expected, sizeof(expected) - 1) == 0);

    output_len = sizeof(output);
    source_len = 0;
    assert(tinf_uncompress(output, &output_len, gzip + raw_offset, &source_len) == TINF_OK);
    assert(source_len == raw_len && output_len == sizeof(expected) - 1);
    assert(memcmp(output, expected, sizeof(expected) - 1) == 0);

    output_len = sizeof(output);
    source_len = (unsigned int)gzip_len;
    assert(tinf_gzip_uncompress(output, &output_len, gzip, &source_len) == TINF_OK);
    assert(source_len == gzip_len && output_len == sizeof(expected) - 1);
    assert(memcmp(output, expected, sizeof(expected) - 1) == 0);

    output_len = sizeof(output);
    source_len = (unsigned int)(gzip_len + tail_len);
    assert(tinf_gzip_uncompress(output, &output_len, gzip_with_tail, &source_len) != TINF_OK);

    output_len = sizeof(output);
    source_len = (unsigned int)(gzip_len + tail_len);
    assert(tinf_gzip_uncompress_prefix(output, &output_len, gzip_with_tail,
                                       &source_len) == TINF_OK);
    assert(source_len == gzip_len && output_len == sizeof(expected) - 1);
    assert(memcmp(output, expected, sizeof(expected) - 1) == 0);
    for (size_t i = 0; i < tail_len; ++i)
        assert(gzip_with_tail[gzip_len + i] == 0x5a);

    output_len = sizeof(output);
    source_len = (unsigned int)(gzip_len - 1);
    assert(tinf_gzip_uncompress_prefix(output, &output_len, gzip, &source_len) != TINF_OK);

    /* A zero output cap is rejected before either prefix decoder writes. */
    memset(output, 0xa5, sizeof(output));
    output_len = 0;
    source_len = (unsigned int)(gzip_len + tail_len);
    assert(tinf_gzip_uncompress_prefix(output, &output_len, gzip_with_tail,
                                       &source_len) != TINF_OK);
    for (size_t i = 0; i < sizeof(output); ++i)
        assert(output[i] == 0xa5);

    memset(output, 0xa5, sizeof(output));
    output_len = sizeof(output);
    source_len = 0;
    assert(tinf_gzip_uncompress_prefix(output, &output_len, gzip_with_tail,
                                       &source_len) != TINF_OK);
    for (size_t i = 0; i < sizeof(output); ++i)
        assert(output[i] == 0xa5);

    output_len = sizeof(output);
    source_len = (unsigned int)raw_len;
    assert(tinf_uncompress(output, &output_len, gzip + raw_offset, &source_len) == TINF_OK);
    assert(source_len == raw_len && output_len == sizeof(expected) - 1);
    assert(memcmp(output, expected, sizeof(expected) - 1) == 0);

    output_len = sizeof(output);
    source_len = (unsigned int)(raw_len + tail_len);
    assert(tinf_uncompress(output, &output_len, raw_with_tail, &source_len) != TINF_OK);

    output_len = sizeof(output);
    source_len = (unsigned int)(raw_len + tail_len);
    assert(tinf_uncompress_prefix(output, &output_len, raw_with_tail,
                                  &source_len) == TINF_OK);
    assert(source_len == raw_len && output_len == sizeof(expected) - 1);
    assert(memcmp(output, expected, sizeof(expected) - 1) == 0);
    for (size_t i = 0; i < tail_len; ++i)
        assert(raw_with_tail[raw_len + i] == 0x5a);

    output_len = sizeof(output);
    source_len = (unsigned int)(raw_len - 1);
    assert(tinf_uncompress_prefix(output, &output_len, gzip + raw_offset,
                                  &source_len) != TINF_OK);

    memset(output, 0xa5, sizeof(output));
    output_len = 0;
    source_len = (unsigned int)(raw_len + tail_len);
    assert(tinf_uncompress_prefix(output, &output_len, raw_with_tail,
                                  &source_len) != TINF_OK);
    for (size_t i = 0; i < sizeof(output); ++i)
        assert(output[i] == 0xa5);

    memset(output, 0xa5, sizeof(output));
    output_len = sizeof(output);
    source_len = 0;
    assert(tinf_uncompress_prefix(output, &output_len, raw_with_tail,
                                  &source_len) != TINF_OK);
    for (size_t i = 0; i < sizeof(output); ++i)
        assert(output[i] == 0xa5);

    /* Prefix mode must validate the footer at the actual stream end, not the
     * last bytes of the larger handoff span. */
    memcpy(bad_crc, gzip, gzip_len);
    bad_crc[gzip_len - 8] ^= 1;
    memset(bad_crc + gzip_len, 0x5a, tail_len);
    output_len = sizeof(output);
    source_len = (unsigned int)(gzip_len + tail_len);
    assert(tinf_gzip_uncompress_prefix(output, &output_len, bad_crc,
                                       &source_len) != TINF_OK);

    memcpy(bad_isize, gzip, gzip_len);
    bad_isize[gzip_len - 4] ^= 1;
    memset(bad_isize + gzip_len, 0x5a, tail_len);
    output_len = sizeof(output);
    source_len = (unsigned int)(gzip_len + tail_len);
    assert(tinf_gzip_uncompress_prefix(output, &output_len, bad_isize,
                                       &source_len) != TINF_OK);
}
#endif

static void test_input_helpers(void)
{
#ifdef HAVE_COMPRESSED_INPUT_HELPERS
    uint32_t source_len = 0;
    unsigned char *inline_source = (unsigned char *)_payload_start + 0x100;

    assert(prepare_compressed_source((void *)0x1000, 37, &source_len));
    assert(source_len == 37);
    assert(!prepare_compressed_source(NULL, 1, &source_len));
    assert(!prepare_compressed_source((void *)(uintptr_t)(UINTPTR_MAX - 1), 2,
                                      &source_len));
    if (SIZE_MAX > UINT32_MAX)
        assert(!prepare_compressed_source((void *)0x1000,
                                          (size_t)UINT32_MAX + 1, &source_len));

    cur_boot_args.top_of_kernel_data = (u64)(uintptr_t)(inline_source + 37);
    assert(prepare_compressed_source(inline_source, 0, &source_len));
    assert(source_len == 37);
    cur_boot_args.top_of_kernel_data = (u64)(uintptr_t)inline_source;
    assert(!prepare_compressed_source(inline_source, 0, &source_len));
    cur_boot_args.top_of_kernel_data = (u64)(uintptr_t)(inline_source - 1);
    assert(!prepare_compressed_source(inline_source, 0, &source_len));
    cur_boot_args.top_of_kernel_data = UINTPTR_MAX;
    assert(prepare_compressed_source(inline_source, 0, &source_len));
    assert(source_len == UINT32_MAX);
    assert(!prepare_compressed_source((void *)(uintptr_t)_payload_start - 1, 0,
                                      &source_len));

    assert(compressed_spans_disjoint((void *)0x1000, 0x10,
                                     (void *)0x1010, 0x10));
    assert(compressed_spans_disjoint((void *)0x1010, 0x10,
                                     (void *)0x1000, 0x10));
    assert(!compressed_spans_disjoint((void *)0x1000, 0x11,
                                      (void *)0x1010, 0x10));
    assert(!compressed_spans_disjoint((void *)0x1000, 0x10,
                                      (void *)0x1000, 0x10));
    assert(!compressed_spans_disjoint((void *)(uintptr_t)(UINTPTR_MAX - 1), 2,
                                      (void *)0x1000, 1));
    assert(!compressed_spans_disjoint(NULL, 1, (void *)0x1000, 1));
    assert(!compressed_spans_disjoint((void *)0x1000, 0, (void *)0x1010, 1));
#endif
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

#ifdef HAVE_TINF_PREFIX_APIS
static void run_prefix_inline_tail(const unsigned char *input, size_t input_len,
                                   size_t output_len, bool xz)
{
    uintptr_t base;
    unsigned char *dest;
    unsigned char *inline_input;
    void *next;

    /* The size-zero handoff boundary intentionally includes a nonempty
     * opaque following-payload suffix. Prefix decoders must return the stream
     * end. */
    mock_heap_reset(8U << 20, 17);
    base = (uintptr_t)heap_storage;
    dest = (unsigned char *)mock_aligned_cursor();
    reset_boot((u64)base, (u64)((uintptr_t)dest - base) + output_len + 4096, NULL);
    inline_input = stage_inline(input, input_len, 4096);
    next = xz ? decompress_xz(inline_input, 0) : decompress_gz(inline_input, 0);
    assert(next == (void *)inline_input + input_len);
    assert(decoder_load_calls == 1);
    assert(last_loaded == dest && last_loaded_len == output_len);
    assert(memcmp(dest, xz ? "PAYLOAD-XZ-BOUNDARY" : "PAYLOAD-GZ-BOUNDARY",
                  output_len) == 0);
    for (size_t i = 0; i < 4096; ++i)
        assert(inline_input[input_len + i] == 0x5a);

    /* A handoff one byte short of the encoded stream rejects before
     * finalization. The physical backing remains complete and oversized. */
    mock_heap_reset(8U << 20, 17);
    base = (uintptr_t)heap_storage;
    dest = (unsigned char *)mock_aligned_cursor();
    reset_boot((u64)base, (u64)((uintptr_t)dest - base) + output_len + 4096, NULL);
    inline_input = stage_inline(input, input_len, 4096);
    cur_boot_args.top_of_kernel_data = (u64)(uintptr_t)(inline_input + input_len - 1);
    next = xz ? decompress_xz(inline_input, 0) : decompress_gz(inline_input, 0);
    assert(next == NULL);
    assert(zero_alloc_calls == 1 && decoder_load_calls == 0 && reserve_calls == 0);
    for (size_t i = 0; i < 4096; ++i)
        assert(inline_input[input_len + i] == 0x5a);
}
#endif

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

    /* A declared two-byte span (gzip magic/XZ header prefix only) cannot
     * decode the complete backing fixture or reach finalization. */
    mock_heap_reset(8U << 20, 17);
    base = (uintptr_t)heap_storage;
    dest = (unsigned char *)mock_aligned_cursor();
    reset_boot((u64)base, (u64)((uintptr_t)dest - base) + output_len + 4096, NULL);
    next = xz ? decompress_xz((void *)input, 2) : decompress_gz((void *)input, 2);
    assert(next == NULL);
    assert(zero_alloc_calls == 1);
    assert(decoder_load_calls == 0);
    assert(reserve_calls == 0);
    assert_no_writes_after(dest, 0, output_len);

    /* The native inline-payload path supplies size zero while the complete
     * well-formed fixture remains in backing memory. Both real decoders must
     * discover and return the consumed encoded length. */
    mock_heap_reset(8U << 20, 17);
    base = (uintptr_t)heap_storage;
    dest = (unsigned char *)mock_aligned_cursor();
    reset_boot((u64)base, (u64)((uintptr_t)dest - base) + output_len + 4096, NULL);
    unsigned char *inline_input = stage_inline(input, input_len, 4096);
    cur_boot_args.top_of_kernel_data = (u64)(uintptr_t)(inline_input + input_len);
    next = xz ? decompress_xz(inline_input, 0) : decompress_gz(inline_input, 0);
    assert(next == (void *)inline_input + input_len);
    assert(decoder_load_calls == 1);
    assert(last_loaded == dest);
    assert(last_loaded_len == output_len);
    for (size_t i = 0; i < 4096; ++i)
        assert(inline_input[input_len + i] == 0x5a);

    /* The same size-zero path must remain bounded when the output span is one
     * byte too short. */
    mock_heap_reset(8U << 20, 17);
    base = (uintptr_t)heap_storage;
    dest = (unsigned char *)mock_aligned_cursor();
    reset_boot((u64)base, (u64)((uintptr_t)dest - base) + output_len - 1, NULL);
    inline_input = stage_inline(input, input_len, 4096);
    /* The handoff ends one byte before the encoded stream; the complete
     * stream and a nonempty opaque following-payload tail remain in backing
     * memory. */
    cur_boot_args.top_of_kernel_data = (u64)(uintptr_t)(inline_input + input_len - 1);
    next = xz ? decompress_xz(inline_input, 0) : decompress_gz(inline_input, 0);
    assert(next == NULL);
    assert(zero_alloc_calls == 1);
    assert(decoder_load_calls == 0);
    assert_no_writes_after(dest, output_len - 1, output_len);
    for (size_t i = 0; i < 4096; ++i)
        assert(inline_input[input_len + i] == 0x5a);

    /* XZ's stream decoder reports consumed bytes even when a known finite
     * source span includes a following payload. */
    if (xz) {
        mock_heap_reset(8U << 20, 17);
        base = (uintptr_t)heap_storage;
        dest = (unsigned char *)mock_aligned_cursor();
        reset_boot((u64)base, (u64)((uintptr_t)dest - base) + output_len + 4096, NULL);
        unsigned char *known_input = stage_inline(input, input_len, 32);
        next = decompress_xz(known_input, input_len + 32);
        assert(next == (void *)known_input + input_len);
        assert(decoder_load_calls == 1);
        assert(last_loaded == dest);
        assert(last_loaded_len == output_len);
        for (size_t i = 0; i < 32; ++i)
            assert(known_input[input_len + i] == 0x5a);
    }

#ifdef HAVE_TINF_PREFIX_APIS
    run_prefix_inline_tail(input, input_len, output_len, xz);
#endif

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

    /* A truncated real stream fails with sufficient destination backing. */
    mock_heap_reset(8U << 20, 17);
    base = (uintptr_t)heap_storage;
    dest = (unsigned char *)mock_aligned_cursor();
    reset_boot((u64)base, (u64)((uintptr_t)dest - base) + output_len + 4096, NULL);
    next = xz ? decompress_xz((void *)input, input_len - 1) :
                decompress_gz((void *)input, input_len - 1);
    assert(next == NULL);
    assert(zero_alloc_calls == 1);
    assert(decoder_load_calls == 0);
    assert(reserve_calls == 0);

    /* Invalid input and source/output overlap reject before decode and finalization. */
    mock_heap_reset(8U << 20, 17);
    base = (uintptr_t)heap_storage;
    dest = (unsigned char *)mock_aligned_cursor();
    reset_boot((u64)base, (u64)((uintptr_t)dest - base) + output_len + 4096, NULL);
    next = xz ? decompress_xz(NULL, input_len) : decompress_gz(NULL, input_len);
    assert(next == NULL);
    assert(zero_alloc_calls == 0);
    assert(decoder_load_calls == 0);

    mock_heap_reset(8U << 20, 17);
    base = (uintptr_t)heap_storage;
    dest = (unsigned char *)mock_aligned_cursor();
    memcpy(dest, input, input_len);
    reset_boot((u64)base, (u64)((uintptr_t)dest - base) + output_len + 4096, NULL);
    next = xz ? decompress_xz(dest, input_len) : decompress_gz(dest, input_len);
    assert(next == NULL);
    assert(zero_alloc_calls == 1);
    assert(decoder_load_calls == 0);
    assert(reserve_calls == 0);
    assert(memcmp(dest, input, input_len) == 0);

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

static int run_dropped_input_control(const unsigned char *input, size_t input_len,
                                     size_t output_len, bool xz)
{
    (void)input;
    (void)input_len;
    (void)output_len;
    (void)xz;
#ifdef DROPPED_INPUT_BOUND
    mock_heap_reset(8U << 20, 17);
    uintptr_t base = (uintptr_t)heap_storage;
    unsigned char *dest = (unsigned char *)mock_aligned_cursor();
    unsigned char *inline_input = stage_inline(input, input_len, 128);
    cur_boot_args.top_of_kernel_data = (u64)(uintptr_t)(inline_input + input_len);
    reset_boot((u64)base, (u64)((uintptr_t)dest - base) + output_len + 4096, NULL);
    void *next = xz ? decompress_xz(inline_input, 2) : decompress_gz(inline_input, 2);
    if (!next && changed_after(dest, 0, output_len) != 0) {
        fprintf(stderr, "DESIGNATED_UNSAFE_INPUT_BOUND\n");
        return 1;
    }
#endif
    return 2;
}

static int run_original_xz_known_tail(const unsigned char *input, size_t input_len,
                                      size_t output_len)
{
    (void)input;
    (void)input_len;
    (void)output_len;
#ifdef BASE_SOURCE
    mock_heap_reset(8U << 20, 17);
    uintptr_t base = (uintptr_t)heap_storage;
    unsigned char *dest = (unsigned char *)mock_aligned_cursor();
    unsigned char *inline_input = stage_inline(input, input_len, 32);
    reset_boot((u64)base, (u64)((uintptr_t)dest - base) + output_len + 4096, NULL);
    void *next = decompress_xz(inline_input, input_len + 32);
    if (next == inline_input + input_len + 32 && decoder_load_calls == 1 &&
        last_loaded == dest && last_loaded_len == output_len) {
        for (size_t i = 0; i < 32; ++i)
            assert(inline_input[input_len + i] == 0x5a);
        fprintf(stderr, "DESIGNATED_ORIGINAL_XZ_POINTER_SKIP\n");
        return 1;
    }
#endif
    return 2;
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
    if (argc > 1 && !strcmp(argv[1], "mutation-input-xz"))
        return run_dropped_input_control(xz, sizeof(xz), sizeof("PAYLOAD-XZ-BOUNDARY") - 1, true);
    if (argc > 1 && !strcmp(argv[1], "original-xz-known-tail"))
        return run_original_xz_known_tail(xz, sizeof(xz), sizeof("PAYLOAD-XZ-BOUNDARY") - 1);

#ifdef BASE_SOURCE
    puts("BASE_SOURCE: invoke each codec with mutation-gzip/mutation-xz for designated exit1");
#else
    test_input_helpers();
    test_helper_boundaries(gzip, sizeof(gzip));
#ifdef HAVE_TINF_PREFIX_APIS
    test_prefix_decoder_apis(gzip, sizeof(gzip));
#endif
    run_safe_wrapper(gzip, sizeof(gzip), output_len, false);
    run_safe_wrapper(xz, sizeof(xz), sizeof("PAYLOAD-XZ-BOUNDARY") - 1, true);
#ifdef HAVE_TINF_PREFIX_APIS
    puts("PASS: bounded gzip/XZ; input-helper-cases=16 helper-boundary-cases=10 prefix-api-cases=16 wrapper-scenarios=25 controls=6");
#else
    puts("PASS: bounded gzip/XZ; input-helper-cases=16 helper-boundary-cases=10 wrapper-scenarios=21 controls=6");
#endif
#endif
    free(heap_storage);
    return 0;
}

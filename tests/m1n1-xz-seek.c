/* Host regression for the minilzlib input-buffer seek/rewind fix.
 *
 * inputbuf.c is copied verbatim (or through a named mutation) by the Python
 * runner and included here so the fixture can inspect BUFFER_STATE.  The XZ
 * decoder itself is compiled from the reviewed source tree; no decoder mock
 * is used.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "inputbuf.c"
#include "minlzma.h"

/* These wrappers are appended to the generated host copy of rangedec.c. */
bool HostRcCanRead(void);
bool HostRcIsFailed(void);
bool HostRcInitialize(uint32_t *chunk_size);
void HostRcForceRange(uint32_t range, uint32_t code);

#ifndef TEST_HAS_BF_REWIND
#define TEST_HAS_BF_REWIND 0
#endif

static void fail(const char *where)
{
    fprintf(stderr, "FAIL: %s (offset=%" PRIu32 " soft=%" PRIu32 " size=%" PRIu32 ")\n",
            where, In.Offset, In.SoftLimit, In.Size);
    exit(2);
}

static void require_true(bool value, const char *where)
{
    if (!value)
        fail(where);
}

static void require_state(uint32_t offset, uint32_t soft, const char *where)
{
    if (In.Offset != offset || In.SoftLimit != soft)
        fail(where);
}

static bool rewind_input(uint32_t length)
{
#if TEST_HAS_BF_REWIND
    return BfRewind(length);
#else
    uint8_t *ignored = NULL;
    return BfSeek((uint32_t)(0U - length), &ignored);
#endif
}

static void test_forward_and_limits(void)
{
    uint8_t bytes[32] = {0};
    uint8_t *position = (uint8_t *)(uintptr_t)0x1234;

    BfInitialize(bytes, sizeof(bytes));
    require_true(BfSeek(0, &position), "forward zero");
    require_true(position == bytes, "forward zero pointer");
    require_state(0, sizeof(bytes), "forward zero state");
    require_true(BfSeek(8, &position), "forward ordinary");
    require_true(position == bytes, "forward ordinary pointer");
    require_state(8, sizeof(bytes), "forward ordinary state");
    position = (uint8_t *)(uintptr_t)0x1234;
    require_true(!BfSeek(25, &position), "forward overrun");
    require_true(position == NULL, "forward overrun pointer");
    require_state(8, sizeof(bytes), "forward overrun atomicity");

    require_true(BfSetSoftLimit(4), "soft limit set");
    require_state(8, 12, "soft limit boundary");
    position = (uint8_t *)(uintptr_t)0x1234;
    require_true(!BfSeek(5, &position), "soft limit overrun");
    require_true(position == NULL, "soft limit pointer");
    require_state(8, 12, "soft limit failure atomicity");
    require_true(!BfSetSoftLimit(25), "soft limit invalid");
    require_state(8, 12, "soft limit invalid atomicity");
    BfResetSoftLimit();
    require_state(8, sizeof(bytes), "soft limit reset");
    require_true(BfSeek(24, &position), "forward endpoint");
    require_state(32, sizeof(bytes), "forward endpoint state");
    position = (uint8_t *)(uintptr_t)0x1234;
    require_true(!BfSeek(1, &position), "forward past endpoint");
    require_true(position == NULL, "forward past endpoint pointer");
    require_state(32, sizeof(bytes), "forward past endpoint state");
}

static void test_rewind(void)
{
    uint8_t bytes[32] = {0};
    uint8_t *position = NULL;

    BfInitialize(bytes, sizeof(bytes));
    require_true(BfSeek(12, &position), "rewind setup");
    require_true(rewind_input(5), "rewind ordinary");
    require_state(7, sizeof(bytes), "rewind ordinary state");
    require_true(rewind_input(0), "rewind zero");
    require_state(7, sizeof(bytes), "rewind zero state");
    require_true(!rewind_input(8), "rewind underflow");
    require_state(7, sizeof(bytes), "rewind underflow atomicity");
}

static void test_uint32_endpoint(void)
{
    const size_t map_size = (size_t)UINT32_MAX + 4096U;
    uint8_t *mapping = mmap(NULL, map_size, PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    uint8_t *position = NULL;
    if (mapping == MAP_FAILED) {
        fprintf(stderr, "FAIL: mmap uint32 endpoint: %s\n", strerror(errno));
        exit(2);
    }
    BfInitialize(mapping, UINT32_MAX);
    require_true(BfSeek(UINT32_MAX - 1U, &position), "uint32 near endpoint");
    require_state(UINT32_MAX - 1U, UINT32_MAX, "uint32 near endpoint state");
    require_true(BfSeek(1, &position), "uint32 endpoint");
    require_state(UINT32_MAX, UINT32_MAX, "uint32 endpoint state");
    position = (uint8_t *)(uintptr_t)0x1234;
    require_true(!BfSeek(1, &position), "uint32 past endpoint");
    require_true(position == NULL, "uint32 past endpoint pointer");
    require_state(UINT32_MAX, UINT32_MAX, "uint32 past endpoint state");
    munmap(mapping, map_size);
}

static void test_read_align(void)
{
    uint8_t bytes[8] = {0, 0, 0, 0, 0x7f, 0x7f, 0, 0};
    uint8_t value = 0;

    BfInitialize(bytes, sizeof(bytes));
    require_true(BfRead(&value), "read first");
    require_true(value == 0, "read first value");
    require_true(BfAlign(), "align zero padding");
    require_state(4, sizeof(bytes), "align state");
    require_true(BfRead(&value), "read nonzero");
    require_true(value == 0x7f, "read nonzero value");
    require_true(!BfAlign(), "align invalid padding");
    require_state(6, sizeof(bytes), "align invalid state");

    BfInitialize(bytes, 1);
    value = 0x7f;
    require_true(BfRead(&value), "read boundary first");
    require_true(!BfRead(&value), "read boundary");
    require_true(value == 0, "read boundary value");
    require_state(1, 1, "read boundary state");
}

static void test_lzma2_size_only_65536(void)
{
    const size_t packet_size = 1U + 4U + 1U + 65536U + 1U;
    uint8_t *packet = calloc(packet_size, 1);
    uint32_t processed = 0;
    if (!packet)
        fail("allocate 65536-byte size-only packet");
    /* LZMA2 compressed control: raw size 65536 and compressed size 65536. */
    packet[0] = 0xe0;
    packet[1] = 0xff;
    packet[2] = 0xff;
    packet[3] = 0xff;
    packet[4] = 0xff;
    packet[5] = 0x5d;
    packet[packet_size - 1U] = 0;
    BfInitialize(packet, (uint32_t)packet_size);
    require_true(Lz2DecodeStream(&processed, true),
                 "65536-byte compressed size-only packet");
    require_true(processed == 65536U, "65536-byte size-only output");
    require_state((uint32_t)packet_size, (uint32_t)packet_size,
                  "65536-byte size-only consumption");
    /* This is metadata/seek coverage; it intentionally does not entropy-decode. */
    free(packet);
}

static void test_range_boundaries(void)
{
    uint8_t bytes[7] = {0, 0, 0, 0, 0, 0xa5, 0};
    uint32_t chunk, processed;

    BfInitialize(bytes, 6);
    require_true(BfSetSoftLimit(5), "range five-byte soft limit");
    chunk = 5;
    require_true(HostRcInitialize(&chunk), "range five-byte initialize");
    require_true(chunk == 0, "range remaining zero");
    require_state(5, 5, "range initialize endpoint");
    require_true(HostRcCanRead(), "range buffered endpoint readable");
    require_state(5, 5, "range endpoint read atomicity");
    processed = UINT32_MAX;
    require_true(RcIsComplete(&processed), "range endpoint complete");
    require_true(processed == 0, "range endpoint processed");
    require_state(5, 5, "range complete atomicity");

    BfInitialize(bytes, 6);
    require_true(BfSetSoftLimit(5), "range refill soft limit");
    chunk = 5;
    require_true(HostRcInitialize(&chunk), "range refill initialize");
    HostRcForceRange(1, 0);
    require_true(!HostRcCanRead() || BfTell() == 5,
                 "range refill precondition");
    RcNormalize();
    require_true(HostRcIsFailed(), "range refill sticky failure");
    require_true(!HostRcCanRead(), "range failed cannot read");
    processed = UINT32_MAX;
    require_true(!RcIsComplete(&processed), "range failed incomplete");
    require_state(5, 5, "range failed offset atomicity");
    require_true(bytes[5] == 0xa5, "range failed no footer read");

    BfInitialize(bytes, 4);
    require_true(BfSetSoftLimit(4), "range undersized soft limit");
    chunk = 4;
    require_true(!HostRcInitialize(&chunk), "range undersized initialize failure");
    require_state(0, 4, "range undersized atomicity");

    BfInitialize(bytes, 6);
    require_true(BfSetSoftLimit(5), "range truncated soft limit");
    chunk = 6;
    require_true(!HostRcInitialize(&chunk), "range truncated initialize failure");
    require_state(0, 5, "range truncated atomicity");
}

static void test_huge_forward_witness(void)
{
    uint8_t bytes[32] = {0};
    uint8_t *position = (uint8_t *)(uintptr_t)0x1234;
    BfInitialize(bytes, sizeof(bytes));
    require_true(BfSeek(8, &position), "huge forward setup");
    position = (uint8_t *)(uintptr_t)0x1234;
    if (BfSeek(UINT32_MAX - 3U, &position) || In.Offset != 8 || position != NULL) {
        fputs("DESIGNATED_BASELINE_WRAP\n", stderr);
        exit(1);
    }
    fail("huge forward did not produce witness");
}

static void test_dropped_forward_guard(void)
{
    uint8_t bytes[32] = {0};
    uint8_t *position = (uint8_t *)(uintptr_t)0x1234;
    BfInitialize(bytes, sizeof(bytes));
    require_true(BfSeek(8, &position), "dropped forward setup");
    position = (uint8_t *)(uintptr_t)0x1234;
    if (BfSeek(UINT32_MAX - 3U, &position) || In.Offset != 8 || position != NULL) {
        fputs("DESIGNATED_DROPPED_FORWARD_GUARD\n", stderr);
        exit(1);
    }
    fail("dropped forward guard did not produce witness");
}

static void test_dropped_rewind_guard(void)
{
#if TEST_HAS_BF_REWIND
    uint8_t bytes[32] = {0};
    uint8_t *position = NULL;
    BfInitialize(bytes, sizeof(bytes));
    require_true(BfSeek(4, &position), "dropped rewind setup");
    if (BfRewind(5) || In.Offset != 4) {
        fputs("DESIGNATED_DROPPED_REWIND_GUARD\n", stderr);
        exit(1);
    }
    fail("dropped rewind guard did not produce witness");
#else
    fail("dropped rewind guard requires BfRewind");
#endif
}

static uint8_t *read_file(const char *path, size_t *length)
{
    FILE *file = fopen(path, "rb");
    long size;
    uint8_t *data;
    if (!file)
        return NULL;
    if (fseek(file, 0, SEEK_END) != 0 || (size = ftell(file)) < 0 ||
        fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        return NULL;
    }
    data = malloc((size_t)size ? (size_t)size : 1U);
    if (!data || fread(data, 1, (size_t)size, file) != (size_t)size) {
        free(data);
        fclose(file);
        return NULL;
    }
    fclose(file);
    *length = (size_t)size;
    return data;
}

static uint32_t read_u32_file(const char *path)
{
    size_t length = 0;
    uint8_t *data = read_file(path, &length);
    char text[64];
    uint32_t value = 0;
    if (!data || length == 0 || length >= sizeof(text))
        fail("read consumed sidecar");
    memcpy(text, data, length);
    text[length] = '\0';
    if (sscanf(text, "%" SCNu32, &value) != 1)
        fail("parse consumed sidecar");
    free(data);
    return value;
}

static void decode_fixture(const char *directory, const char *name, bool valid,
                           bool tail, bool require_rewind)
{
    char input_path[4096], output_path[4096], consumed_path[4096];
    size_t input_size = 0, expected_size = 0;
    uint8_t *input, *expected, *output;
    uint32_t decoder_input_size, decoder_output_size;
    bool result;
    snprintf(input_path, sizeof(input_path), "%s/%s.xz", directory, name);
    snprintf(output_path, sizeof(output_path), "%s/%s.out", directory, name);
    input = read_file(input_path, &input_size);
    expected = valid ? read_file(output_path, &expected_size) : NULL;
    if (!input || (valid && !expected))
        fail("read XZ fixture");
    output = calloc(valid ? expected_size + 1U : 65536U, 1);
    if (!output)
        fail("allocate decode output");
    decoder_input_size = (uint32_t)input_size;
    decoder_output_size = valid ? (uint32_t)expected_size : 65536U;
    result = XzDecode(input, &decoder_input_size, output, &decoder_output_size);
    if (!valid) {
        if (result) {
            fputs("FAIL: malformed XZ unexpectedly decoded\n", stderr);
            exit(2);
        }
        if (require_rewind && In.Offset != 14)
            fail("empty XZ rewind state");
    } else {
        if (!result || decoder_output_size != expected_size ||
            memcmp(output, expected, expected_size) != 0) {
            fprintf(stderr, "decode mismatch %s: result=%d output_size=%" PRIu32
                    " expected_size=%zu consumed=%" PRIu32 "\n", name,
                    result, decoder_output_size, expected_size, decoder_input_size);
            fail(name);
        }
        if (tail) {
            snprintf(consumed_path, sizeof(consumed_path), "%s/%s.consumed",
                     directory, name);
            if (decoder_input_size != read_u32_file(consumed_path))
                fail("tail consumption");
        }
    }
    free(output);
    free(expected);
    free(input);
}

static void test_xz(const char *directory)
{
    decode_fixture(directory, "compressed-32768", true, false, false);
    decode_fixture(directory, "raw-random-31", true, false, false);
    decode_fixture(directory, "raw-random-65536", true, false, false);
    decode_fixture(directory, "empty", false, false, true);
    decode_fixture(directory, "tail", true, true, false);
    decode_fixture(directory, "truncated", false, false, false);
    decode_fixture(directory, "bad-footer", false, false, false);
}

static void test_caller_rewind_not_migrated(const char *directory)
{
    char input_path[4096];
    size_t input_size = 0;
    uint8_t *input = NULL, *output = NULL;
    uint32_t decoder_input_size, decoder_output_size = 65536;
    snprintf(input_path, sizeof(input_path), "%s/compressed-32768.xz", directory);
    input = read_file(input_path, &input_size);
    output = calloc(decoder_output_size, 1);
    if (!input || !output)
        fail("read empty XZ fixture");
    decoder_input_size = (uint32_t)input_size;
    if (!XzDecode(input, &decoder_input_size, output, &decoder_output_size) &&
        In.Offset == In.SoftLimit && In.Offset > 30) {
        fputs("DESIGNATED_CALLER_REWIND_NOT_MIGRATED\n", stderr);
        exit(1);
    }
    fail("caller rewind mutation did not produce wrong state");
}

int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr, "usage: %s MODE FIXTURE_DIR\n", argv[0]);
        return 2;
    }
    if (strcmp(argv[1], "patched") == 0) {
        test_forward_and_limits();
        test_rewind();
        test_uint32_endpoint();
        test_read_align();
        test_lzma2_size_only_65536();
        test_range_boundaries();
        test_xz(argv[2]);
        puts("PASS: minilzlib input seek/rewind and real XZ fixtures");
        return 0;
    }
    if (strcmp(argv[1], "baselinewrap") == 0) {
        test_huge_forward_witness();
    } else if (strcmp(argv[1], "droppedforwardguard") == 0) {
        test_dropped_forward_guard();
    } else if (strcmp(argv[1], "droppedrewindguard") == 0) {
        test_dropped_rewind_guard();
    } else if (strcmp(argv[1], "callerrewindnotmigrated") == 0) {
        test_caller_rewind_not_migrated(argv[2]);
    } else {
        fprintf(stderr, "unknown mode: %s\n", argv[1]);
        return 2;
    }
    return 2;
}

/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Behavioral checks for the AArch64 features advertised to a QEMU/HVF guest.
 *
 * Compile this file at baseline Armv8-A. Optional instructions are confined
 * to arm64-feature-tests.S and are reached only by alarm-bounded forked
 * children pinned to one guest CPU.
 */
#define _GNU_SOURCE

#include <errno.h>
#include <inttypes.h>
#include <sched.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/auxv.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <asm/hwcap.h>

#ifndef HWCAP_FP
#define HWCAP_FP (1UL << 0)
#endif
#ifndef HWCAP_ASIMD
#define HWCAP_ASIMD (1UL << 1)
#endif
#ifndef HWCAP_EVTSTRM
#define HWCAP_EVTSTRM (1UL << 2)
#endif
#ifndef HWCAP_AES
#define HWCAP_AES (1UL << 3)
#endif
#ifndef HWCAP_PMULL
#define HWCAP_PMULL (1UL << 4)
#endif
#ifndef HWCAP_SHA1
#define HWCAP_SHA1 (1UL << 5)
#endif
#ifndef HWCAP_SHA2
#define HWCAP_SHA2 (1UL << 6)
#endif
#ifndef HWCAP_CRC32
#define HWCAP_CRC32 (1UL << 7)
#endif
#ifndef HWCAP_ATOMICS
#define HWCAP_ATOMICS (1UL << 8)
#endif
#ifndef HWCAP_FPHP
#define HWCAP_FPHP (1UL << 9)
#endif
#ifndef HWCAP_ASIMDHP
#define HWCAP_ASIMDHP (1UL << 10)
#endif
#ifndef HWCAP_CPUID
#define HWCAP_CPUID (1UL << 11)
#endif
#ifndef HWCAP_ASIMDRDM
#define HWCAP_ASIMDRDM (1UL << 12)
#endif
#ifndef HWCAP_JSCVT
#define HWCAP_JSCVT (1UL << 13)
#endif
#ifndef HWCAP_FCMA
#define HWCAP_FCMA (1UL << 14)
#endif
#ifndef HWCAP_LRCPC
#define HWCAP_LRCPC (1UL << 15)
#endif
#ifndef HWCAP_DCPOP
#define HWCAP_DCPOP (1UL << 16)
#endif
#ifndef HWCAP_SHA3
#define HWCAP_SHA3 (1UL << 17)
#endif
#ifndef HWCAP_ASIMDDP
#define HWCAP_ASIMDDP (1UL << 20)
#endif
#ifndef HWCAP_SHA512
#define HWCAP_SHA512 (1UL << 21)
#endif
#ifndef HWCAP_ASIMDFHM
#define HWCAP_ASIMDFHM (1UL << 23)
#endif
#ifndef HWCAP_DIT
#define HWCAP_DIT (1UL << 24)
#endif
#ifndef HWCAP_USCAT
#define HWCAP_USCAT (1UL << 25)
#endif
#ifndef HWCAP_ILRCPC
#define HWCAP_ILRCPC (1UL << 26)
#endif
#ifndef HWCAP_FLAGM
#define HWCAP_FLAGM (1UL << 27)
#endif
#ifndef HWCAP_SB
#define HWCAP_SB (1UL << 29)
#endif
#ifndef HWCAP_PACA
#define HWCAP_PACA (1UL << 30)
#endif
#ifndef HWCAP_PACG
#define HWCAP_PACG (1UL << 31)
#endif

#ifndef HWCAP2_DCPODP
#define HWCAP2_DCPODP (1UL << 0)
#endif
#ifndef HWCAP2_FLAGM2
#define HWCAP2_FLAGM2 (1UL << 7)
#endif
#ifndef HWCAP2_FRINT
#define HWCAP2_FRINT (1UL << 8)
#endif
#ifndef HWCAP2_I8MM
#define HWCAP2_I8MM (1UL << 13)
#endif
#ifndef HWCAP2_BF16
#define HWCAP2_BF16 (1UL << 14)
#endif
#ifndef HWCAP2_BTI
#define HWCAP2_BTI (1UL << 17)
#endif
#ifndef HWCAP2_AFP
#define HWCAP2_AFP (1UL << 20)
#endif

#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define OBSERVED_SIZE 160

extern uint64_t feature_test_fp_add(uint64_t a, uint64_t b);
extern void feature_test_asimd_add(const uint32_t *a, const uint32_t *b,
				   uint32_t *out);
extern uint32_t feature_test_crc32c_u64(uint32_t crc, uint64_t value);
extern void feature_test_pmull_u64(uint64_t a, uint64_t b, uint64_t *out);
extern uint64_t feature_test_lse_ldaddal(uint64_t addend, uint64_t *value);
extern uint64_t feature_test_ldapr(const uint64_t *value);
extern uint64_t feature_test_ldapur(const uint64_t *value);
extern uint64_t feature_test_cfinv(void);
extern uint64_t feature_test_sb(void);
extern uint64_t feature_test_dit_toggle(void);
extern uint64_t feature_test_paca_roundtrip(uint64_t pointer, uint64_t modifier,
					    uint64_t *signed_pointer);
extern uint64_t feature_test_pacga(uint64_t value, uint64_t modifier);
extern void feature_test_dc_zva(void *address);
extern uint64_t feature_test_dc_cvap(void *address);
extern uint64_t feature_test_dc_cvadp(void *address);
extern uint64_t feature_test_evtstrm(void);
extern void feature_test_aes(const uint8_t *input, const uint8_t *round_key,
			     uint8_t *out);
extern uint32_t feature_test_sha1(uint32_t value);
extern void feature_test_sha2(const uint32_t *input, const uint32_t *schedule,
			      uint32_t *out);
extern uint32_t feature_test_fphp(uint32_t a_bits, uint32_t b_bits);
extern void feature_test_asimdhp(const uint16_t *a, const uint16_t *b,
				 uint16_t *out);
extern uint64_t feature_test_cpuid(void);
extern uint32_t feature_test_asimdrdm(uint32_t a, uint32_t b);
extern uint32_t feature_test_jscvt(uint64_t double_bits);
extern void feature_test_fcma(const uint32_t *a, const uint32_t *b,
			      uint32_t *out);
extern void feature_test_sha3(const uint64_t *a, const uint64_t *b,
			      const uint64_t *c, uint64_t *out);
extern void feature_test_asimddp(const uint8_t *a, const uint8_t *b,
				 uint32_t *out);
extern void feature_test_sha512(const uint64_t *input, const uint64_t *schedule,
				uint64_t *out);
extern void feature_test_asimdfhm(const uint16_t *a, const uint16_t *b,
				  uint32_t *out);
extern uint64_t feature_test_uscat(uint64_t addend, void *unaligned_address);
extern uint64_t feature_test_flagm2(void);
extern uint64_t feature_test_frint(uint64_t double_bits);
extern void feature_test_i8mm(const int8_t *a, const int8_t *b, int32_t *out);
extern void feature_test_bf16(const uint16_t *a, const uint16_t *b,
			      uint32_t *out);
extern uint64_t feature_test_bti(void);
extern uint64_t feature_test_afp(void);

enum test_kind {
	TEST_FP_ASIMD,
	TEST_CRC32,
	TEST_PMULL,
	TEST_LSE,
	TEST_LRCPC,
	TEST_ILRCPC,
	TEST_FLAGM,
	TEST_SB,
	TEST_DIT,
	TEST_PACA,
	TEST_PACG,
	TEST_DC_ZVA,
	TEST_DC_CVAP,
	TEST_DC_CVADP,
	TEST_EVTSTRM,
	TEST_AES,
	TEST_SHA1,
	TEST_SHA2,
	TEST_FPHP,
	TEST_ASIMDHP,
	TEST_CPUID,
	TEST_ASIMDRDM,
	TEST_JSCVT,
	TEST_FCMA,
	TEST_SHA3,
	TEST_ASIMDDP,
	TEST_SHA512,
	TEST_ASIMDFHM,
	TEST_USCAT,
	TEST_FLAGM2,
	TEST_FRINT,
	TEST_I8MM,
	TEST_BF16,
	TEST_BTI,
	TEST_AFP,
};

struct test_spec {
	const char *feature;
	const char *hwcap_source;
	const char *hwcap_bit;
	unsigned long mask;
	bool hwcap2;
	const char *test_level;
	enum test_kind kind;
};

static const struct test_spec tests[] = {
	{"fp_asimd", "AT_HWCAP", "HWCAP_FP|HWCAP_ASIMD",
	 HWCAP_FP | HWCAP_ASIMD, false, "semantic", TEST_FP_ASIMD},
	{"crc32", "AT_HWCAP", "HWCAP_CRC32",
	 HWCAP_CRC32, false, "semantic", TEST_CRC32},
	{"pmull", "AT_HWCAP", "HWCAP_PMULL",
	 HWCAP_PMULL, false, "semantic", TEST_PMULL},
	{"lse_atomic", "AT_HWCAP", "HWCAP_ATOMICS",
	 HWCAP_ATOMICS, false, "semantic", TEST_LSE},
	{"lrcpc_ldapr", "AT_HWCAP", "HWCAP_LRCPC",
	 HWCAP_LRCPC, false, "execution", TEST_LRCPC},
	{"ilrcpc_ldapur", "AT_HWCAP", "HWCAP_ILRCPC",
	 HWCAP_ILRCPC, false, "execution", TEST_ILRCPC},
	{"flagm_cfinv", "AT_HWCAP", "HWCAP_FLAGM",
	 HWCAP_FLAGM, false, "semantic", TEST_FLAGM},
	{"sb", "AT_HWCAP", "HWCAP_SB",
	 HWCAP_SB, false, "execution", TEST_SB},
	{"dit", "AT_HWCAP", "HWCAP_DIT",
	 HWCAP_DIT, false, "semantic", TEST_DIT},
	{"paca_roundtrip", "AT_HWCAP", "HWCAP_PACA",
	 HWCAP_PACA, false, "execution", TEST_PACA},
	{"pacg", "AT_HWCAP", "HWCAP_PACG",
	 HWCAP_PACG, false, "execution", TEST_PACG},
	{"dc_zva", "DCZID_EL0", "DZP==0",
	 0, false, "semantic", TEST_DC_ZVA},
	{"dc_cvap", "AT_HWCAP", "HWCAP_DCPOP",
	 HWCAP_DCPOP, false, "execution", TEST_DC_CVAP},
	{"dc_cvadp", "AT_HWCAP2", "HWCAP2_DCPODP",
	 HWCAP2_DCPODP, true, "execution", TEST_DC_CVADP},
	{"evtstrm_wfe", "AT_HWCAP", "HWCAP_EVTSTRM",
	 HWCAP_EVTSTRM, false, "execution", TEST_EVTSTRM},
	{"aes_round", "AT_HWCAP", "HWCAP_AES",
	 HWCAP_AES, false, "semantic", TEST_AES},
	{"sha1_h", "AT_HWCAP", "HWCAP_SHA1",
	 HWCAP_SHA1, false, "semantic", TEST_SHA1},
	{"sha256_su0", "AT_HWCAP", "HWCAP_SHA2",
	 HWCAP_SHA2, false, "semantic", TEST_SHA2},
	{"fphp_add", "AT_HWCAP", "HWCAP_FPHP",
	 HWCAP_FPHP, false, "semantic", TEST_FPHP},
	{"asimdhp_add", "AT_HWCAP", "HWCAP_ASIMDHP",
	 HWCAP_ASIMDHP, false, "semantic", TEST_ASIMDHP},
	{"cpuid_isar0", "AT_HWCAP", "HWCAP_CPUID",
	 HWCAP_CPUID, false, "semantic", TEST_CPUID},
	{"asimdrdm_sqrdmlah", "AT_HWCAP", "HWCAP_ASIMDRDM",
	 HWCAP_ASIMDRDM, false, "semantic", TEST_ASIMDRDM},
	{"jscvt_fjcvtzs", "AT_HWCAP", "HWCAP_JSCVT",
	 HWCAP_JSCVT, false, "semantic", TEST_JSCVT},
	{"fcma_fcadd", "AT_HWCAP", "HWCAP_FCMA",
	 HWCAP_FCMA, false, "semantic", TEST_FCMA},
	{"sha3_eor3", "AT_HWCAP", "HWCAP_SHA3",
	 HWCAP_SHA3, false, "semantic", TEST_SHA3},
	{"asimddp_udot", "AT_HWCAP", "HWCAP_ASIMDDP",
	 HWCAP_ASIMDDP, false, "semantic", TEST_ASIMDDP},
	{"sha512_su0", "AT_HWCAP", "HWCAP_SHA512",
	 HWCAP_SHA512, false, "semantic", TEST_SHA512},
	{"asimdfhm_fmlal", "AT_HWCAP", "HWCAP_ASIMDFHM",
	 HWCAP_ASIMDFHM, false, "semantic", TEST_ASIMDFHM},
	{"uscat_unaligned_atomic", "AT_HWCAP", "HWCAP_USCAT",
	 HWCAP_USCAT, false, "semantic", TEST_USCAT},
	{"flagm2_axflag", "AT_HWCAP2", "HWCAP2_FLAGM2",
	 HWCAP2_FLAGM2, true, "semantic", TEST_FLAGM2},
	{"frint32z", "AT_HWCAP2", "HWCAP2_FRINT",
	 HWCAP2_FRINT, true, "semantic", TEST_FRINT},
	{"i8mm_smmla", "AT_HWCAP2", "HWCAP2_I8MM",
	 HWCAP2_I8MM, true, "semantic", TEST_I8MM},
	{"bf16_bfdot", "AT_HWCAP2", "HWCAP2_BF16",
	 HWCAP2_BF16, true, "semantic", TEST_BF16},
	{"bti", "AT_HWCAP2", "HWCAP2_BTI",
	 HWCAP2_BTI, true, "execution", TEST_BTI},
	{"afp_fpcr", "AT_HWCAP2", "HWCAP2_AFP",
	 HWCAP2_AFP, true, "semantic", TEST_AFP},
};

struct child_result {
	int observed_cpu;
	int passed;
	char expected[OBSERVED_SIZE];
	char observed[OBSERVED_SIZE];
};

struct row_result {
	const char *classification;
	int observed_cpu;
	char expected[OBSERVED_SIZE];
	char observed[OBSERVED_SIZE];
};

static uint64_t dczid_el0;

static uint32_t crc32c_reference(uint32_t crc, uint64_t value)
{
	unsigned int byte;
	unsigned int bit;

	for (byte = 0; byte < 8; byte++) {
		crc ^= (uint8_t)(value >> (byte * 8));
		for (bit = 0; bit < 8; bit++)
			crc = (crc >> 1) ^ ((crc & 1) ? UINT32_C(0x82f63b78) : 0);
	}
	return crc;
}

static unsigned __int128 pmull_reference(uint64_t a, uint64_t b)
{
	unsigned __int128 result = 0;
	unsigned int bit;

	for (bit = 0; bit < 64; bit++) {
		if ((a >> bit) & 1)
			result ^= (unsigned __int128)b << bit;
	}
	return result;
}

static uint32_t ror32(uint32_t value, unsigned int amount)
{
	return (value >> amount) | (value << (32U - amount));
}

static uint64_t ror64(uint64_t value, unsigned int amount)
{
	return (value >> amount) | (value << (64U - amount));
}

static void result_text(struct child_result *result, bool passed,
			const char *expected, const char *observed)
{
	result->passed = passed;
	snprintf(result->expected, sizeof(result->expected), "%s", expected);
	snprintf(result->observed, sizeof(result->observed), "%s", observed);
}

static void run_fp_asimd(struct child_result *result)
{
	static const uint32_t a[4] = {1, 2, 3, 4};
	static const uint32_t b[4] = {5, 6, 7, 8};
	const uint32_t wanted[4] = {6, 8, 10, 12};
	uint32_t out[4] = {0, 0, 0, 0};
	uint64_t fp;
	bool ok;

	fp = feature_test_fp_add(UINT64_C(0x3ff8000000000000),
				 UINT64_C(0x4002000000000000));
	feature_test_asimd_add(a, b, out);
	ok = fp == UINT64_C(0x400e000000000000) &&
	     memcmp(out, wanted, sizeof(out)) == 0;
	snprintf(result->expected, sizeof(result->expected),
		 "fp_bits=4615626668101337088,asimd=6:8:10:12");
	snprintf(result->observed, sizeof(result->observed),
		 "fp_bits=%" PRIu64 ",asimd=%" PRIu32 ":%" PRIu32 ":%" PRIu32 ":%" PRIu32,
		 fp, out[0], out[1], out[2], out[3]);
	result->passed = ok;
}

static void run_crc32(struct child_result *result)
{
	const uint32_t initial = UINT32_C(0x13579bdf);
	const uint64_t value = UINT64_C(0x0123456789abcdef);
	uint32_t expected = crc32c_reference(initial, value);
	uint32_t observed = feature_test_crc32c_u64(initial, value);

	result->passed = observed == expected;
	snprintf(result->expected, sizeof(result->expected), "crc32c=%" PRIu32, expected);
	snprintf(result->observed, sizeof(result->observed), "crc32c=%" PRIu32, observed);
}

static void run_pmull(struct child_result *result)
{
	const uint64_t a = UINT64_C(0x0123456789abcdef);
	const uint64_t b = UINT64_C(0xfedcba9876543210);
	unsigned __int128 expected = pmull_reference(a, b);
	uint64_t observed[2] = {0, 0};

	feature_test_pmull_u64(a, b, observed);
	result->passed = observed[0] == (uint64_t)expected &&
			 observed[1] == (uint64_t)(expected >> 64);
	snprintf(result->expected, sizeof(result->expected),
		 "lo=%" PRIu64 ",hi=%" PRIu64,
		 (uint64_t)expected, (uint64_t)(expected >> 64));
	snprintf(result->observed, sizeof(result->observed),
		 "lo=%" PRIu64 ",hi=%" PRIu64, observed[0], observed[1]);
}

static void run_aes(struct child_result *result)
{
	static const uint8_t input[16] __attribute__((aligned(16))) = {
		0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
		0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff
	};
	static const uint8_t key[16] __attribute__((aligned(16))) = {
		0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
		0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f
	};
	static const uint8_t expected[16] = {
		0x5f, 0x72, 0x64, 0x15, 0x57, 0xf5, 0xbc, 0x92,
		0xf7, 0xbe, 0x3b, 0x29, 0x1d, 0xb9, 0xf9, 0x1a
	};
	uint8_t observed[16] __attribute__((aligned(16))) = {0};

	feature_test_aes(input, key, observed);
	result->passed = memcmp(observed, expected, sizeof(observed)) == 0;
	snprintf(result->expected, sizeof(result->expected),
		 "bytes=5f72641557f5bc92f7be3b291db9f91a");
	snprintf(result->observed, sizeof(result->observed),
		 "edge=%02x%02x%02x%02x",
		 (unsigned int)observed[0], (unsigned int)observed[1],
		 (unsigned int)observed[14], (unsigned int)observed[15]);
}

static void run_sha1(struct child_result *result)
{
	const uint32_t input = UINT32_C(0x01234567);
	const uint32_t expected = ror32(input, 2);
	uint32_t observed = feature_test_sha1(input);

	result->passed = observed == expected;
	snprintf(result->expected, sizeof(result->expected), "value=%" PRIu32,
		 expected);
	snprintf(result->observed, sizeof(result->observed), "value=%" PRIu32,
		 observed);
}

static void run_sha2(struct child_result *result)
{
	static const uint32_t input[4] __attribute__((aligned(16))) = {
		UINT32_C(0x01234567), UINT32_C(0x89abcdef),
		UINT32_C(0xfedcba98), UINT32_C(0x76543210)
	};
	static const uint32_t schedule[4] __attribute__((aligned(16))) = {
		UINT32_C(0x0f1e2d3c), UINT32_C(0x4b5a6978),
		UINT32_C(0x8796a5b4), UINT32_C(0xc3d2e1f0)
	};
	uint32_t source[4] = {input[1], input[2], input[3], schedule[0]};
	uint32_t expected[4];
	uint32_t observed[4] __attribute__((aligned(16))) = {0};
	unsigned int index;

	for (index = 0; index < ARRAY_SIZE(expected); index++)
		expected[index] = input[index] + (ror32(source[index], 7) ^
				  ror32(source[index], 18) ^ (source[index] >> 3));
	feature_test_sha2(input, schedule, observed);
	result->passed = memcmp(observed, expected, sizeof(observed)) == 0;
	snprintf(result->expected, sizeof(result->expected),
		 "lanes=%" PRIu32 ":%" PRIu32 ":%" PRIu32 ":%" PRIu32,
		 expected[0], expected[1], expected[2], expected[3]);
	snprintf(result->observed, sizeof(result->observed),
		 "lanes=%" PRIu32 ":%" PRIu32 ":%" PRIu32 ":%" PRIu32,
		 observed[0], observed[1], observed[2], observed[3]);
}

static void run_fphp(struct child_result *result)
{
	uint32_t observed = feature_test_fphp(UINT32_C(0x3e00), UINT32_C(0x4080));

	result->passed = observed == UINT32_C(0x4380);
	snprintf(result->expected, sizeof(result->expected), "half_bits=17280");
	snprintf(result->observed, sizeof(result->observed), "half_bits=%" PRIu32,
		 observed);
}

static void run_asimdhp(struct child_result *result)
{
	uint16_t a[8] __attribute__((aligned(16)));
	uint16_t b[8] __attribute__((aligned(16)));
	uint16_t observed[8] __attribute__((aligned(16))) = {0};
	unsigned int index;
	bool ok = true;

	for (index = 0; index < ARRAY_SIZE(a); index++) {
		a[index] = UINT16_C(0x3e00);
		b[index] = UINT16_C(0x4080);
	}
	feature_test_asimdhp(a, b, observed);
	for (index = 0; index < ARRAY_SIZE(observed); index++)
		ok = ok && observed[index] == UINT16_C(0x4380);
	result->passed = ok;
	snprintf(result->expected, sizeof(result->expected), "eight_half_lanes=17280");
	snprintf(result->observed, sizeof(result->observed),
		 "edge=%u:%u", (unsigned int)observed[0],
		 (unsigned int)observed[7]);
}

static void run_cpuid(struct child_result *result)
{
	const uint64_t expected = UINT64_C(0x0021100110212120);
	uint64_t observed = feature_test_cpuid();

	result->passed = observed == expected;
	snprintf(result->expected, sizeof(result->expected), "isar0=%" PRIu64,
		 expected);
	snprintf(result->observed, sizeof(result->observed), "isar0=%" PRIu64,
		 observed);
}

static void run_asimdrdm(struct child_result *result)
{
	uint32_t observed = feature_test_asimdrdm(UINT32_C(0x40000000),
						 UINT32_C(0x40000000));

	result->passed = observed == UINT32_C(0x20000000);
	snprintf(result->expected, sizeof(result->expected), "value=536870912");
	snprintf(result->observed, sizeof(result->observed), "value=%" PRIu32,
		 observed);
}

static void run_jscvt(struct child_result *result)
{
	uint32_t observed = feature_test_jscvt(UINT64_C(0x400e000000000000));

	result->passed = observed == 3;
	snprintf(result->expected, sizeof(result->expected), "integer=3");
	snprintf(result->observed, sizeof(result->observed), "integer=%" PRIu32,
		 observed);
}

static void run_fcma(struct child_result *result)
{
	static const uint32_t a[2] __attribute__((aligned(8))) = {
		UINT32_C(0x3f800000), UINT32_C(0x40000000)
	};
	static const uint32_t b[2] __attribute__((aligned(8))) = {
		UINT32_C(0x40400000), UINT32_C(0x40800000)
	};
	static const uint32_t expected[2] = {
		UINT32_C(0xc0400000), UINT32_C(0x40a00000)
	};
	uint32_t observed[2] __attribute__((aligned(8))) = {0};

	feature_test_fcma(a, b, observed);
	result->passed = memcmp(observed, expected, sizeof(observed)) == 0;
	snprintf(result->expected, sizeof(result->expected),
		 "bits=3225419776:1084227584");
	snprintf(result->observed, sizeof(result->observed),
		 "bits=%" PRIu32 ":%" PRIu32, observed[0], observed[1]);
}

static void run_sha3(struct child_result *result)
{
	static const uint64_t a[2] __attribute__((aligned(16))) = {
		UINT64_C(0x0123456789abcdef), UINT64_C(0xfedcba9876543210)
	};
	static const uint64_t b[2] __attribute__((aligned(16))) = {
		UINT64_C(0x0f0f0f0f0f0f0f0f), UINT64_C(0xf0f0f0f0f0f0f0f0)
	};
	static const uint64_t c[2] __attribute__((aligned(16))) = {
		UINT64_C(0xaaaaaaaaaaaaaaaa), UINT64_C(0x5555555555555555)
	};
	uint64_t expected[2] = {a[0] ^ b[0] ^ c[0], a[1] ^ b[1] ^ c[1]};
	uint64_t observed[2] __attribute__((aligned(16))) = {0};

	feature_test_sha3(a, b, c, observed);
	result->passed = memcmp(observed, expected, sizeof(observed)) == 0;
	snprintf(result->expected, sizeof(result->expected),
		 "lanes=%" PRIu64 ":%" PRIu64, expected[0], expected[1]);
	snprintf(result->observed, sizeof(result->observed),
		 "lanes=%" PRIu64 ":%" PRIu64, observed[0], observed[1]);
}

static void run_asimddp(struct child_result *result)
{
	uint8_t a[16] __attribute__((aligned(16)));
	uint8_t b[16] __attribute__((aligned(16)));
	uint32_t observed[4] __attribute__((aligned(16))) = {0};
	unsigned int index;

	memset(a, 1, sizeof(a));
	memset(b, 2, sizeof(b));
	feature_test_asimddp(a, b, observed);
	result->passed = true;
	for (index = 0; index < ARRAY_SIZE(observed); index++)
		result->passed = result->passed && observed[index] == 8;
	snprintf(result->expected, sizeof(result->expected), "lanes=8:8:8:8");
	snprintf(result->observed, sizeof(result->observed),
		 "lanes=%" PRIu32 ":%" PRIu32 ":%" PRIu32 ":%" PRIu32,
		 observed[0], observed[1], observed[2], observed[3]);
}

static void run_sha512(struct child_result *result)
{
	static const uint64_t input[2] __attribute__((aligned(16))) = {
		UINT64_C(0x0123456789abcdef), UINT64_C(0xfedcba9876543210)
	};
	static const uint64_t schedule[2] __attribute__((aligned(16))) = {
		UINT64_C(0x0f1e2d3c4b5a6978), UINT64_C(0x8796a5b4c3d2e1f0)
	};
	uint64_t expected[2];
	uint64_t observed[2] __attribute__((aligned(16))) = {0};
	uint64_t sigma;

	sigma = ror64(input[1], 1) ^ ror64(input[1], 8) ^ (input[1] >> 7);
	expected[0] = input[0] + sigma;
	sigma = ror64(schedule[0], 1) ^ ror64(schedule[0], 8) ^
		(schedule[0] >> 7);
	expected[1] = input[1] + sigma;
	feature_test_sha512(input, schedule, observed);
	result->passed = memcmp(observed, expected, sizeof(observed)) == 0;
	snprintf(result->expected, sizeof(result->expected),
		 "lanes=%" PRIu64 ":%" PRIu64, expected[0], expected[1]);
	snprintf(result->observed, sizeof(result->observed),
		 "lanes=%" PRIu64 ":%" PRIu64, observed[0], observed[1]);
}

static void run_asimdfhm(struct child_result *result)
{
	uint16_t a[4] __attribute__((aligned(8)));
	uint16_t b[4] __attribute__((aligned(8)));
	uint32_t observed[4] __attribute__((aligned(16))) = {0};
	unsigned int index;

	for (index = 0; index < ARRAY_SIZE(a); index++) {
		a[index] = UINT16_C(0x3e00);
		b[index] = UINT16_C(0x4000);
	}
	feature_test_asimdfhm(a, b, observed);
	result->passed = true;
	for (index = 0; index < ARRAY_SIZE(observed); index++)
		result->passed = result->passed && observed[index] == UINT32_C(0x40400000);
	snprintf(result->expected, sizeof(result->expected),
		 "four_fp32_lanes=1077936128");
	snprintf(result->observed, sizeof(result->observed),
		 "edge=%" PRIu32 ":%" PRIu32, observed[0], observed[3]);
}

static void run_uscat(struct child_result *result)
{
	unsigned char storage[32] __attribute__((aligned(16))) = {0};
	uint64_t initial = 37;
	uint64_t final = 0;
	uint64_t old;

	memcpy(storage + 1, &initial, sizeof(initial));
	old = feature_test_uscat(5, storage + 1);
	memcpy(&final, storage + 1, sizeof(final));
	result->passed = old == 37 && final == 42;
	snprintf(result->expected, sizeof(result->expected), "old=37,memory=42");
	snprintf(result->observed, sizeof(result->observed),
		 "old=%" PRIu64 ",memory=%" PRIu64, old, final);
}

static void run_flagm2(struct child_result *result)
{
	uint64_t observed = feature_test_flagm2();
	const uint64_t expected = UINT64_C(0x2000000040000000);

	result->passed = observed == expected;
	snprintf(result->expected, sizeof(result->expected), "packed=%" PRIu64,
		 expected);
	snprintf(result->observed, sizeof(result->observed), "packed=%" PRIu64,
		 observed);
}

static void run_frint(struct child_result *result)
{
	uint64_t observed = feature_test_frint(UINT64_C(0x400e000000000000));
	const uint64_t expected = UINT64_C(0x4008000000000000);

	result->passed = observed == expected;
	snprintf(result->expected, sizeof(result->expected), "double_bits=%" PRIu64,
		 expected);
	snprintf(result->observed, sizeof(result->observed), "double_bits=%" PRIu64,
		 observed);
}

static void run_i8mm(struct child_result *result)
{
	int8_t a[16] __attribute__((aligned(16)));
	int8_t b[16] __attribute__((aligned(16)));
	int32_t observed[4] __attribute__((aligned(16))) = {0};
	unsigned int index;

	memset(a, 1, sizeof(a));
	memset(b, 2, sizeof(b));
	feature_test_i8mm(a, b, observed);
	result->passed = true;
	for (index = 0; index < ARRAY_SIZE(observed); index++)
		result->passed = result->passed && observed[index] == 16;
	snprintf(result->expected, sizeof(result->expected), "lanes=16:16:16:16");
	snprintf(result->observed, sizeof(result->observed),
		 "lanes=%" PRId32 ":%" PRId32 ":%" PRId32 ":%" PRId32,
		 observed[0], observed[1], observed[2], observed[3]);
}

static void run_bf16(struct child_result *result)
{
	uint16_t a[8] __attribute__((aligned(16)));
	uint16_t b[8] __attribute__((aligned(16)));
	uint32_t observed[4] __attribute__((aligned(16))) = {0};
	unsigned int index;

	for (index = 0; index < ARRAY_SIZE(a); index++) {
		a[index] = UINT16_C(0x3f80);
		b[index] = UINT16_C(0x4000);
	}
	feature_test_bf16(a, b, observed);
	result->passed = true;
	for (index = 0; index < ARRAY_SIZE(observed); index++)
		result->passed = result->passed && observed[index] == UINT32_C(0x40800000);
	snprintf(result->expected, sizeof(result->expected),
		 "four_fp32_lanes=1082130432");
	snprintf(result->observed, sizeof(result->observed),
		 "edge=%" PRIu32 ":%" PRIu32, observed[0], observed[3]);
}

static void run_lse(struct child_result *result)
{
	uint64_t value = 37;
	uint64_t old = feature_test_lse_ldaddal(5, &value);

	result->passed = old == 37 && value == 42;
	snprintf(result->expected, sizeof(result->expected), "old=37,memory=42");
	snprintf(result->observed, sizeof(result->observed),
		 "old=%" PRIu64 ",memory=%" PRIu64, old, value);
}

static void run_load(struct child_result *result, bool ilrcpc)
{
	const uint64_t value = UINT64_C(0x1122334455667788);
	uint64_t observed = ilrcpc ? feature_test_ldapur(&value) :
				    feature_test_ldapr(&value);

	result->passed = observed == value;
	snprintf(result->expected, sizeof(result->expected), "value=%" PRIu64, value);
	snprintf(result->observed, sizeof(result->observed), "value=%" PRIu64, observed);
}

static void run_simple_one(struct child_result *result, uint64_t observed,
			   const char *text)
{
	result->passed = observed == 1;
	snprintf(result->expected, sizeof(result->expected), "%s", text);
	snprintf(result->observed, sizeof(result->observed),
		 "%s=%" PRIu64, text, observed);
}

static void run_paca(struct child_result *result)
{
	uint64_t local = UINT64_C(0xa5a5a5a55a5a5a5a);
	uint64_t pointer = (uintptr_t)&local;
	uint64_t signed_pointer = pointer;
	uint64_t authenticated;

	authenticated = feature_test_paca_roundtrip(pointer,
					     UINT64_C(0x3141592653589793),
					     &signed_pointer);
	result->passed = authenticated == 1;
	snprintf(result->expected, sizeof(result->expected),
		 "authenticated_original=1");
	snprintf(result->observed, sizeof(result->observed),
		 "authenticated_original=%" PRIu64, authenticated);
}

static void run_dc_zva(struct child_result *result)
{
	unsigned int block_size = 4U << (dczid_el0 & 0xf);
	unsigned int alignment = block_size < sizeof(void *) ? sizeof(void *) : block_size;
	unsigned char *buffer = NULL;
	unsigned int index;
	bool zero = true;
	bool guards = true;

	if (block_size > 4096 || posix_memalign((void **)&buffer, alignment,
						 block_size * 3U) != 0) {
		result_text(result, false, "allocated_aligned_block", "allocation_failed");
		return;
	}
	memset(buffer, 0xa5, block_size * 3U);
	feature_test_dc_zva(buffer + block_size);
	for (index = 0; index < block_size; index++) {
		if (buffer[block_size + index] != 0) {
			zero = false;
		}
		if (buffer[index] != 0xa5 || buffer[block_size * 2U + index] != 0xa5)
			guards = false;
	}
	result->passed = zero && guards;
	snprintf(result->expected, sizeof(result->expected),
		 "zeroed_bytes=%u,guards_unchanged=1", block_size);
	snprintf(result->observed, sizeof(result->observed),
		 "zeroed_bytes=%u,guards_unchanged=%d", zero ? block_size : 0,
		 guards);
	free(buffer);
}

static void run_test(enum test_kind kind, struct child_result *result)
{
	uint64_t cacheline[16] __attribute__((aligned(64))) = {0};

	switch (kind) {
	case TEST_FP_ASIMD:
		run_fp_asimd(result);
		break;
	case TEST_CRC32:
		run_crc32(result);
		break;
	case TEST_PMULL:
		run_pmull(result);
		break;
	case TEST_LSE:
		run_lse(result);
		break;
	case TEST_LRCPC:
		run_load(result, false);
		break;
	case TEST_ILRCPC:
		run_load(result, true);
		break;
	case TEST_FLAGM:
		run_simple_one(result, feature_test_cfinv(), "carry_toggled");
		break;
	case TEST_SB:
		run_simple_one(result, feature_test_sb(), "executed");
		break;
	case TEST_DIT:
		run_simple_one(result, feature_test_dit_toggle(), "toggle_readback_restored");
		break;
	case TEST_PACA:
		run_paca(result);
		break;
	case TEST_PACG:
		run_simple_one(result,
			       feature_test_pacga(UINT64_C(0x0123456789abcdef),
						  UINT64_C(0xfedcba9876543210)),
			       "executed");
		break;
	case TEST_DC_ZVA:
		run_dc_zva(result);
		break;
	case TEST_DC_CVAP:
		run_simple_one(result, feature_test_dc_cvap(cacheline), "executed");
		break;
	case TEST_DC_CVADP:
		run_simple_one(result, feature_test_dc_cvadp(cacheline), "executed");
		break;
	case TEST_EVTSTRM:
		run_simple_one(result, feature_test_evtstrm(), "wfe_returned");
		break;
	case TEST_AES:
		run_aes(result);
		break;
	case TEST_SHA1:
		run_sha1(result);
		break;
	case TEST_SHA2:
		run_sha2(result);
		break;
	case TEST_FPHP:
		run_fphp(result);
		break;
	case TEST_ASIMDHP:
		run_asimdhp(result);
		break;
	case TEST_CPUID:
		run_cpuid(result);
		break;
	case TEST_ASIMDRDM:
		run_asimdrdm(result);
		break;
	case TEST_JSCVT:
		run_jscvt(result);
		break;
	case TEST_FCMA:
		run_fcma(result);
		break;
	case TEST_SHA3:
		run_sha3(result);
		break;
	case TEST_ASIMDDP:
		run_asimddp(result);
		break;
	case TEST_SHA512:
		run_sha512(result);
		break;
	case TEST_ASIMDFHM:
		run_asimdfhm(result);
		break;
	case TEST_USCAT:
		run_uscat(result);
		break;
	case TEST_FLAGM2:
		run_flagm2(result);
		break;
	case TEST_FRINT:
		run_frint(result);
		break;
	case TEST_I8MM:
		run_i8mm(result);
		break;
	case TEST_BF16:
		run_bf16(result);
		break;
	case TEST_BTI:
		run_simple_one(result, feature_test_bti(), "executed");
		break;
	case TEST_AFP:
		run_simple_one(result, feature_test_afp(), "fpcr_ah_readback_restored");
		break;
	}
}

static bool write_full(int fd, const void *buffer, size_t size)
{
	const unsigned char *position = buffer;

	while (size != 0) {
		ssize_t written = write(fd, position, size);
		if (written < 0) {
			if (errno == EINTR)
				continue;
			return false;
		}
		position += written;
		size -= (size_t)written;
	}
	return true;
}

static ssize_t read_full(int fd, void *buffer, size_t size)
{
	unsigned char *position = buffer;
	size_t total = 0;

	while (total != size) {
		ssize_t count = read(fd, position + total, size - total);
		if (count == 0)
			break;
		if (count < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		total += (size_t)count;
	}
	return (ssize_t)total;
}

static bool is_advertised(const struct test_spec *test, unsigned long hwcap,
			  unsigned long hwcap2)
{
	if (test->kind == TEST_DC_ZVA)
		return (dczid_el0 & (1U << 4)) == 0;
	if (test->hwcap2)
		return (hwcap2 & test->mask) == test->mask;
	return (hwcap & test->mask) == test->mask;
}

static void execute_child(const struct test_spec *test, int cpu,
			  struct row_result *row)
{
	struct child_result result;
	int pipefd[2];
	pid_t child;
	pid_t waited;
	int status;
	ssize_t count;
	bool wait_failed = false;

	memset(&result, 0, sizeof(result));
	if (pipe(pipefd) != 0) {
		row->classification = "wrong_result";
		row->observed_cpu = -1;
		snprintf(row->expected, sizeof(row->expected), "test_completed");
		snprintf(row->observed, sizeof(row->observed), "pipe_failed");
		return;
	}
	child = fork();
	if (child == 0) {
		static const int contained_signals[] = {
			SIGALRM, SIGILL, SIGBUS, SIGSEGV, SIGFPE, SIGABRT
		};
		struct sigaction default_action;
		sigset_t fault_signals;
		size_t signal_index;

		close(pipefd[0]);
		memset(&default_action, 0, sizeof(default_action));
		default_action.sa_handler = SIG_DFL;
		sigemptyset(&default_action.sa_mask);
		sigemptyset(&fault_signals);
		for (signal_index = 0;
		     signal_index < ARRAY_SIZE(contained_signals); signal_index++) {
			sigaddset(&fault_signals, contained_signals[signal_index]);
			if (sigaction(contained_signals[signal_index],
				      &default_action, NULL) != 0)
				_exit(125);
		}
		if (sigprocmask(SIG_UNBLOCK, &fault_signals, NULL) != 0)
			_exit(125);
		alarm(3);
		result.observed_cpu = sched_getcpu();
		if (result.observed_cpu != cpu) {
			result.passed = false;
			snprintf(result.expected, sizeof(result.expected),
				 "observed_cpu=%d", cpu);
			snprintf(result.observed, sizeof(result.observed),
				 "observed_cpu=%d", result.observed_cpu);
		} else {
			run_test(test->kind, &result);
		}
		(void)write_full(pipefd[1], &result, sizeof(result));
		close(pipefd[1]);
		_exit(0);
	}
	close(pipefd[1]);
	if (child < 0) {
		close(pipefd[0]);
		row->classification = "wrong_result";
		row->observed_cpu = -1;
		snprintf(row->expected, sizeof(row->expected), "test_completed");
		snprintf(row->observed, sizeof(row->observed), "fork_failed");
		return;
	}
	do {
		waited = waitpid(child, &status, 0);
	} while (waited < 0 && errno == EINTR);
	if (waited < 0)
		wait_failed = true;
	count = read_full(pipefd[0], &result, sizeof(result));
	close(pipefd[0]);
	if (wait_failed) {
		row->classification = "wrong_result";
		row->observed_cpu = -1;
		snprintf(row->expected, sizeof(row->expected), "child_reaped");
		snprintf(row->observed, sizeof(row->observed), "waitpid_failed");
	} else if (WIFSIGNALED(status)) {
		int signal_number = WTERMSIG(status);
		if (signal_number == SIGILL) {
			row->classification = "SIGILL";
			snprintf(row->observed, sizeof(row->observed), "signal=SIGILL");
		} else if (signal_number == SIGALRM) {
			row->classification = "timeout";
			snprintf(row->observed, sizeof(row->observed), "alarm_seconds=3");
		} else {
			row->classification = "other_signal";
			snprintf(row->observed, sizeof(row->observed),
				 "signal=%d", signal_number);
		}
		snprintf(row->expected, sizeof(row->expected), "test_completed");
		row->observed_cpu = -1;
	} else if (!WIFEXITED(status) || WEXITSTATUS(status) != 0 ||
		   count != (ssize_t)sizeof(result)) {
		row->classification = "wrong_result";
		snprintf(row->expected, sizeof(row->expected), "test_completed");
		snprintf(row->observed, sizeof(row->observed), "child_protocol_failed");
		row->observed_cpu = -1;
	} else {
		row->classification = result.passed ? "pass" : "wrong_result";
		row->observed_cpu = result.observed_cpu;
		snprintf(row->expected, sizeof(row->expected), "%s", result.expected);
		snprintf(row->observed, sizeof(row->observed), "%s", result.observed);
	}
}

static void emit_json_string(const char *text)
{
	const unsigned char *position = (const unsigned char *)text;

	putchar('"');
	while (*position != '\0') {
		switch (*position) {
		case '"': fputs("\\\"", stdout); break;
		case '\\': fputs("\\\\", stdout); break;
		case '\b': fputs("\\b", stdout); break;
		case '\f': fputs("\\f", stdout); break;
		case '\n': fputs("\\n", stdout); break;
		case '\r': fputs("\\r", stdout); break;
		case '\t': fputs("\\t", stdout); break;
		default:
			if (*position < 0x20)
				printf("\\u%04x", (unsigned int)*position);
			else
				putchar(*position);
		}
		position++;
	}
	putchar('"');
}

static void emit_row(const struct test_spec *test, bool advertised, int cpu,
		     const struct row_result *row, bool *first)
{
	if (!*first)
		putchar(',');
	*first = false;
	printf("{\"feature\":");
	emit_json_string(test->feature);
	printf(",\"hwcap_source\":");
	emit_json_string(test->hwcap_source);
	printf(",\"hwcap_bit\":");
	emit_json_string(test->hwcap_bit);
	printf(",\"advertised\":%s,\"test_level\":", advertised ? "true" : "false");
	emit_json_string(test->test_level);
	printf(",\"expected\":");
	emit_json_string(row->expected);
	printf(",\"observed\":");
	emit_json_string(row->observed);
	printf(",\"classification\":");
	emit_json_string(row->classification);
	printf(",\"cpu\":%d,\"observed_cpu\":", cpu);
	if (row->observed_cpu < 0)
		printf("null}");
	else
		printf("%d}", row->observed_cpu);
}

int main(void)
{
	cpu_set_t original_affinity;
	cpu_set_t online_affinity;
	sigset_t original_signals;
	unsigned long hwcap = getauxval(AT_HWCAP);
	unsigned long hwcap2 = getauxval(AT_HWCAP2);
	long online_count = sysconf(_SC_NPROCESSORS_ONLN);
	int affinity_count;
	int cpu;
	bool first = true;
	bool all_passed = true;

	__asm__ volatile("mrs %0, dczid_el0" : "=r" (dczid_el0));
	if (sched_getaffinity(0, sizeof(original_affinity), &original_affinity) != 0 ||
	    sigprocmask(SIG_SETMASK, NULL, &original_signals) != 0) {
		fputs("feature behavior: cannot capture process state\n", stderr);
		return 2;
	}
	online_affinity = original_affinity;
	affinity_count = CPU_COUNT(&online_affinity);
	if (online_count < 1 || online_count != affinity_count) {
		fputs("feature behavior: online CPUs differ from allowed affinity\n", stderr);
		return 2;
	}

	puts("FEATURE_BEHAVIOR_JSON_BEGIN");
	printf("{\"schema_version\":1,\"online_cpu_count\":%ld,"
	       "\"hwcap\":\"%lu\",\"hwcap2\":\"%lu\",\"dczid_el0\":\"%" PRIu64 "\",\"tests\":[",
	       online_count, hwcap, hwcap2, dczid_el0);
	for (cpu = 0; cpu < CPU_SETSIZE; cpu++) {
		cpu_set_t one_cpu;
		size_t index;

		if (!CPU_ISSET(cpu, &online_affinity))
			continue;
		CPU_ZERO(&one_cpu);
		CPU_SET(cpu, &one_cpu);
		if (sched_setaffinity(0, sizeof(one_cpu), &one_cpu) != 0) {
			all_passed = false;
			for (index = 0; index < ARRAY_SIZE(tests); index++) {
				struct row_result row;

				memset(&row, 0, sizeof(row));
				row.classification = "wrong_result";
				row.observed_cpu = -1;
				snprintf(row.expected, sizeof(row.expected), "cpu_pinned");
				snprintf(row.observed, sizeof(row.observed), "affinity_failed");
				emit_row(&tests[index],
					 is_advertised(&tests[index], hwcap, hwcap2),
					 cpu, &row, &first);
			}
			continue;
		}
		for (index = 0; index < ARRAY_SIZE(tests); index++) {
			const struct test_spec *test = &tests[index];
			bool advertised = is_advertised(test, hwcap, hwcap2);
			struct row_result row;

			memset(&row, 0, sizeof(row));
			if (advertised) {
				execute_child(test, cpu, &row);
				if (strcmp(row.classification, "pass") != 0)
					all_passed = false;
			} else {
				row.classification = "not_advertised";
				row.observed_cpu = cpu;
				snprintf(row.expected, sizeof(row.expected), "not_executed");
				snprintf(row.observed, sizeof(row.observed), "not_executed");
			}
			emit_row(test, advertised, cpu, &row, &first);
		}
	}
	printf("]}\n");
	puts("FEATURE_BEHAVIOR_JSON_END");
	if (sched_setaffinity(0, sizeof(original_affinity), &original_affinity) != 0 ||
	    sigprocmask(SIG_SETMASK, &original_signals, NULL) != 0) {
		fputs("feature behavior: cannot restore process state\n", stderr);
		return 2;
	}
	return all_passed ? 0 : 1;
}

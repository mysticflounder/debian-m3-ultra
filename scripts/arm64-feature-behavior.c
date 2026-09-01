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
#ifndef HWCAP_PMULL
#define HWCAP_PMULL (1UL << 4)
#endif
#ifndef HWCAP_CRC32
#define HWCAP_CRC32 (1UL << 7)
#endif
#ifndef HWCAP_ATOMICS
#define HWCAP_ATOMICS (1UL << 8)
#endif
#ifndef HWCAP_LRCPC
#define HWCAP_LRCPC (1UL << 15)
#endif
#ifndef HWCAP_DCPOP
#define HWCAP_DCPOP (1UL << 16)
#endif
#ifndef HWCAP_DIT
#define HWCAP_DIT (1UL << 24)
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

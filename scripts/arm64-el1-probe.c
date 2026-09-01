// SPDX-License-Identifier: GPL-2.0
/*
 * Guest-only, read-only arm64 EL1 system-register probe.
 *
 * The module takes a CPU-hotplug read lock, synchronously samples every
 * online CPU with work_on_cpu(), and only then emits the collected values.
 * It retains no probe data after initialization.
 */

#include <linux/cpu.h>
#include <linux/errno.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/preempt.h>
#include <linux/slab.h>
#include <linux/smp.h>
#include <linux/workqueue.h>

#include <asm/sysreg.h>

#ifndef CONFIG_ARM64
#error "arm64-el1-probe is only supported on arm64"
#endif

/* Older arm64 headers predate these two feature-register definitions. */
#ifndef SYS_ID_AA64ZFR0_EL1
#define SYS_ID_AA64ZFR0_EL1	sys_reg(3, 0, 0, 4, 4)
#endif

#ifndef SYS_ID_AA64SMFR0_EL1
#define SYS_ID_AA64SMFR0_EL1	sys_reg(3, 0, 0, 4, 5)
#endif

#define PROBE_SCHEMA_VERSION	1U
#define ID_AA64PFR0_SVE_SHIFT	32
#define ID_AA64PFR1_SME_SHIFT	24
#define ID_AA64_FEATURE_MASK	0xfULL

enum probe_register {
	PROBE_MPIDR_EL1,
	PROBE_CLIDR_EL1,
	PROBE_CTR_EL0,
	PROBE_DCZID_EL0,
	PROBE_ID_AA64PFR0_EL1,
	PROBE_ID_AA64PFR1_EL1,
	PROBE_ID_AA64DFR0_EL1,
	PROBE_ID_AA64DFR1_EL1,
	PROBE_ID_AA64ISAR0_EL1,
	PROBE_ID_AA64ISAR1_EL1,
	PROBE_ID_AA64MMFR0_EL1,
	PROBE_ID_AA64MMFR1_EL1,
	PROBE_ID_AA64MMFR2_EL1,
	PROBE_ID_AA64ZFR0_EL1,
	PROBE_ID_AA64SMFR0_EL1,
	PROBE_REGISTER_COUNT,
};

struct register_sample {
	u64 value;
	bool was_read;
};

struct cpu_sample {
	unsigned int cpu;
	unsigned int observed_cpu;
	bool was_read;
	struct register_sample registers[PROBE_REGISTER_COUNT];
};

static const char *const register_names[PROBE_REGISTER_COUNT] = {
	[PROBE_MPIDR_EL1] = "MPIDR_EL1",
	[PROBE_CLIDR_EL1] = "CLIDR_EL1",
	[PROBE_CTR_EL0] = "CTR_EL0",
	[PROBE_DCZID_EL0] = "DCZID_EL0",
	[PROBE_ID_AA64PFR0_EL1] = "ID_AA64PFR0_EL1",
	[PROBE_ID_AA64PFR1_EL1] = "ID_AA64PFR1_EL1",
	[PROBE_ID_AA64DFR0_EL1] = "ID_AA64DFR0_EL1",
	[PROBE_ID_AA64DFR1_EL1] = "ID_AA64DFR1_EL1",
	[PROBE_ID_AA64ISAR0_EL1] = "ID_AA64ISAR0_EL1",
	[PROBE_ID_AA64ISAR1_EL1] = "ID_AA64ISAR1_EL1",
	[PROBE_ID_AA64MMFR0_EL1] = "ID_AA64MMFR0_EL1",
	[PROBE_ID_AA64MMFR1_EL1] = "ID_AA64MMFR1_EL1",
	[PROBE_ID_AA64MMFR2_EL1] = "ID_AA64MMFR2_EL1",
	[PROBE_ID_AA64ZFR0_EL1] = "ID_AA64ZFR0_EL1",
	[PROBE_ID_AA64SMFR0_EL1] = "ID_AA64SMFR0_EL1",
};

#define SAMPLE_SYSREG(sample, index, encoding) do { \
	(sample)->registers[(index)].value = read_sysreg_s(encoding); \
	(sample)->registers[(index)].was_read = true; \
} while (0)

static long collect_cpu_registers(void *argument)
{
	struct cpu_sample *sample = argument;
	u64 pfr0;
	u64 pfr1;

	preempt_disable();
	sample->observed_cpu = smp_processor_id();
	SAMPLE_SYSREG(sample, PROBE_MPIDR_EL1, SYS_MPIDR_EL1);
	SAMPLE_SYSREG(sample, PROBE_CLIDR_EL1, SYS_CLIDR_EL1);
	SAMPLE_SYSREG(sample, PROBE_CTR_EL0, SYS_CTR_EL0);
	SAMPLE_SYSREG(sample, PROBE_DCZID_EL0, SYS_DCZID_EL0);
	SAMPLE_SYSREG(sample, PROBE_ID_AA64PFR0_EL1,
		      SYS_ID_AA64PFR0_EL1);
	SAMPLE_SYSREG(sample, PROBE_ID_AA64PFR1_EL1,
		      SYS_ID_AA64PFR1_EL1);
	SAMPLE_SYSREG(sample, PROBE_ID_AA64DFR0_EL1,
		      SYS_ID_AA64DFR0_EL1);
	SAMPLE_SYSREG(sample, PROBE_ID_AA64DFR1_EL1,
		      SYS_ID_AA64DFR1_EL1);
	SAMPLE_SYSREG(sample, PROBE_ID_AA64ISAR0_EL1,
		      SYS_ID_AA64ISAR0_EL1);
	SAMPLE_SYSREG(sample, PROBE_ID_AA64ISAR1_EL1,
		      SYS_ID_AA64ISAR1_EL1);
	SAMPLE_SYSREG(sample, PROBE_ID_AA64MMFR0_EL1,
		      SYS_ID_AA64MMFR0_EL1);
	SAMPLE_SYSREG(sample, PROBE_ID_AA64MMFR1_EL1,
		      SYS_ID_AA64MMFR1_EL1);
	SAMPLE_SYSREG(sample, PROBE_ID_AA64MMFR2_EL1,
		      SYS_ID_AA64MMFR2_EL1);

	pfr0 = sample->registers[PROBE_ID_AA64PFR0_EL1].value;
	if (((pfr0 >> ID_AA64PFR0_SVE_SHIFT) & ID_AA64_FEATURE_MASK) != 0)
		SAMPLE_SYSREG(sample, PROBE_ID_AA64ZFR0_EL1,
			      SYS_ID_AA64ZFR0_EL1);

	pfr1 = sample->registers[PROBE_ID_AA64PFR1_EL1].value;
	if (((pfr1 >> ID_AA64PFR1_SME_SHIFT) & ID_AA64_FEATURE_MASK) != 0)
		SAMPLE_SYSREG(sample, PROBE_ID_AA64SMFR0_EL1,
			      SYS_ID_AA64SMFR0_EL1);

	sample->was_read = true;
	preempt_enable();
	return 0;
}

static void emit_samples(const struct cpu_sample *samples,
			 unsigned int cpu_count)
{
	bool all_read = true;
	unsigned int i;
	unsigned int reg;

	pr_info("EL1_PROBE_START schema_version=%u online_cpu_count=%u\n",
		PROBE_SCHEMA_VERSION, cpu_count);

	for (i = 0; i < cpu_count; ++i) {
		const struct cpu_sample *sample = &samples[i];

		pr_info("EL1_PROBE_CPU cpu=%u observed_cpu=%u status=%s\n",
			sample->cpu, sample->observed_cpu,
			sample->was_read ? "read" : "not_read");
		all_read = all_read && sample->was_read;
		for (reg = 0; reg < PROBE_REGISTER_COUNT; ++reg) {
			const struct register_sample *value =
				&sample->registers[reg];

			pr_info("EL1_PROBE_REG cpu=%u name=%s status=%s value=0x%016llx\n",
				sample->cpu, register_names[reg],
				value->was_read ? "read" : "not_read",
				(unsigned long long)value->value);
		}
	}

	pr_info("EL1_PROBE_END sampled_cpu_count=%u status=%s\n",
		cpu_count, all_read ? "ok" : "error");
}

static int __init arm64_el1_probe_init(void)
{
	struct cpu_sample *samples;
	unsigned int cpu_count = 0;
	unsigned int cpu;

	samples = kcalloc(nr_cpu_ids, sizeof(*samples), GFP_KERNEL);
	if (!samples)
		return -ENOMEM;

	cpus_read_lock();
	for_each_online_cpu(cpu) {
		struct cpu_sample *sample = &samples[cpu_count];

		sample->cpu = cpu;
		if (work_on_cpu(cpu, collect_cpu_registers, sample) != 0)
			sample->was_read = false;
		++cpu_count;
	}
	cpus_read_unlock();

	/* No output precedes completion of the synchronous per-CPU reads. */
	emit_samples(samples, cpu_count);
	kfree(samples);
	return 0;
}

static void __exit arm64_el1_probe_exit(void)
{
}

module_init(arm64_el1_probe_init);
module_exit(arm64_el1_probe_exit);

MODULE_DESCRIPTION("Guest-only arm64 EL1 system-register diagnostic probe");
MODULE_AUTHOR("debian-m3 contributors");
MODULE_LICENSE("GPL");

// SPDX-License-Identifier: GPL-2.0
/*
 * Guest-only regression probe for QEMU/HVF PMINTENCLR_EL1 semantics.
 *
 * This intentionally performs one system-register write inside a disposable
 * one-vCPU guest.  It runs only when the cycle interrupt and overflow bits are
 * initially clear.  On conforming implementations, writing the clear alias
 * leaves the interrupt-enable bit clear.  The affected QEMU irqchip-off path
 * instead sets the bit; that state is discarded with the guest immediately
 * after collection.
 */

#include <linux/bitops.h>
#include <linux/cpu.h>
#include <linux/init.h>
#include <linux/irqflags.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/preempt.h>
#include <linux/smp.h>
#include <linux/workqueue.h>

#include <asm/barrier.h>
#include <asm/sysreg.h>

#ifndef CONFIG_ARM64
#error "arm64-pmintenclr-probe is only supported on arm64"
#endif

#ifndef SYS_PMCR_EL0
#define SYS_PMCR_EL0		sys_reg(3, 3, 9, 12, 0)
#endif

#ifndef SYS_PMINTENCLR_EL1
#define SYS_PMINTENCLR_EL1	sys_reg(3, 0, 9, 14, 2)
#endif

#ifndef SYS_PMOVSCLR_EL0
#define SYS_PMOVSCLR_EL0	sys_reg(3, 3, 9, 12, 3)
#endif

#define PROBE_SCHEMA_VERSION	1U
#define PMUVER_SHIFT		8U
#define PMUVER_MASK		0xfULL
#define CYCLE_COUNTER_BIT	BIT_ULL(31)
#define PMCR_ENABLE_BIT		BIT_ULL(0)

static bool allow_hidden_pmu;
module_param(allow_hidden_pmu, bool, 0400);
MODULE_PARM_DESC(allow_hidden_pmu,
	"permit the intentional QEMU irqchip-off PMU access when PMUVer is zero");

enum probe_status {
	PROBE_NOT_RUN,
	PROBE_PASS,
	PROBE_FAIL,
	PROBE_SKIPPED_DIRTY_STATE,
	PROBE_SKIPPED_NO_OPT_IN,
	PROBE_SKIPPED_UNEXPECTED_PMUVER,
	PROBE_SKIPPED_DISABLE_FAILED,
};

struct probe_sample {
	unsigned int requested_cpu;
	unsigned int observed_cpu;
	u64 id_aa64dfr0;
	u64 pmcr;
	u64 pmcr_disabled;
	u64 pmcr_after;
	u64 pminten_before;
	u64 pminten_after;
	u64 pmovs_before;
	enum probe_status status;
};

static const char *probe_status_name(enum probe_status status)
{
	switch (status) {
	case PROBE_PASS:
		return "pass";
	case PROBE_FAIL:
		return "fail";
	case PROBE_SKIPPED_DIRTY_STATE:
		return "skipped_dirty_state";
	case PROBE_SKIPPED_NO_OPT_IN:
		return "skipped_no_opt_in";
	case PROBE_SKIPPED_UNEXPECTED_PMUVER:
		return "skipped_unexpected_pmuver";
	case PROBE_SKIPPED_DISABLE_FAILED:
		return "skipped_disable_failed";
	case PROBE_NOT_RUN:
	default:
		return "not_run";
	}
}

static const char *probe_restore_name(const struct probe_sample *sample)
{
	if (sample->status == PROBE_SKIPPED_NO_OPT_IN ||
	    sample->status == PROBE_SKIPPED_UNEXPECTED_PMUVER)
		return "unchanged";
	if (sample->status == PROBE_FAIL)
		return "no";
	return sample->pmcr_after == sample->pmcr ? "yes" : "no";
}

static long run_probe(void *argument)
{
	struct probe_sample *sample = argument;
	unsigned long irq_flags;

	preempt_disable();
	local_irq_save(irq_flags);
	sample->observed_cpu = smp_processor_id();
	sample->id_aa64dfr0 = read_sysreg_s(SYS_ID_AA64DFR0_EL1);
	if (((sample->id_aa64dfr0 >> PMUVER_SHIFT) & PMUVER_MASK) != 0) {
		sample->status = PROBE_SKIPPED_UNEXPECTED_PMUVER;
		goto out;
	}
	if (!allow_hidden_pmu) {
		sample->status = PROBE_SKIPPED_NO_OPT_IN;
		goto out;
	}

	/* QEMU's irqchip-off path intentionally handles these despite PMUVer=0. */
	sample->pmcr = read_sysreg_s(SYS_PMCR_EL0);
	write_sysreg_s(sample->pmcr & ~PMCR_ENABLE_BIT, SYS_PMCR_EL0);
	isb();
	sample->pmcr_disabled = read_sysreg_s(SYS_PMCR_EL0);
	if (sample->pmcr_disabled & PMCR_ENABLE_BIT) {
		sample->status = PROBE_SKIPPED_DISABLE_FAILED;
		goto restore_pmcr;
	}
	sample->pminten_before = read_sysreg_s(SYS_PMINTENCLR_EL1);
	sample->pmovs_before = read_sysreg_s(SYS_PMOVSCLR_EL0);

	/*
	 * A pending cycle overflow plus the buggy set operation could assert a
	 * PMU interrupt.  A pre-enabled cycle interrupt would also make the test
	 * destructive on a conforming implementation.  Refuse both cases.
	 */
	if ((sample->pminten_before | sample->pmovs_before) &
	    CYCLE_COUNTER_BIT) {
		sample->pminten_after = sample->pminten_before;
		sample->status = PROBE_SKIPPED_DIRTY_STATE;
		goto restore_pmcr;
	}

	write_sysreg_s(CYCLE_COUNTER_BIT, SYS_PMINTENCLR_EL1);
	isb();
	sample->pminten_after = read_sysreg_s(SYS_PMINTENCLR_EL1);
	sample->status = sample->pminten_after & CYCLE_COUNTER_BIT ?
		PROBE_FAIL : PROBE_PASS;

restore_pmcr:
	/* Keep global counting disabled on failure so the bad enable cannot fire. */
	if (sample->status != PROBE_FAIL) {
		write_sysreg_s(sample->pmcr, SYS_PMCR_EL0);
		isb();
	}
	sample->pmcr_after = read_sysreg_s(SYS_PMCR_EL0);
out:
	local_irq_restore(irq_flags);
	preempt_enable();
	return 0;
}

static int __init arm64_pmintenclr_probe_init(void)
{
	struct probe_sample sample = { 0 };
	unsigned int cpu;
	int result;

	pr_info("PMINTENCLR_PROBE_START schema_version=%u\n",
		PROBE_SCHEMA_VERSION);

	cpus_read_lock();
	cpu = cpumask_first(cpu_online_mask);
	if (cpu >= nr_cpu_ids) {
		cpus_read_unlock();
		pr_info("PMINTENCLR_PROBE_END status=no_online_cpu\n");
		return 0;
	}
	sample.requested_cpu = cpu;
	result = work_on_cpu(cpu, run_probe, &sample);
	cpus_read_unlock();

	if (result != 0) {
		pr_info("PMINTENCLR_PROBE_END status=work_on_cpu_error code=%d\n",
			result);
		return 0;
	}

	pr_info("PMINTENCLR_PROBE_STATE requested_cpu=%u observed_cpu=%u "
		"id_aa64dfr0=0x%016llx pmuver=%llu hidden_pmu_opt_in=%s "
		"pmcr=0x%016llx pmcr_disabled=0x%016llx pmcr_after=0x%016llx "
		"pminten_before=0x%016llx pmovs_before=0x%016llx\n",
		sample.requested_cpu, sample.observed_cpu,
		(unsigned long long)sample.id_aa64dfr0,
		(unsigned long long)((sample.id_aa64dfr0 >> PMUVER_SHIFT) &
				     PMUVER_MASK),
		allow_hidden_pmu ? "yes" : "no",
		(unsigned long long)sample.pmcr,
		(unsigned long long)sample.pmcr_disabled,
		(unsigned long long)sample.pmcr_after,
		(unsigned long long)sample.pminten_before,
		(unsigned long long)sample.pmovs_before);
	pr_info("PMINTENCLR_PROBE_RESULT target_bit=31 "
		"pminten_after=0x%016llx status=%s guest_state_restored=%s\n",
		(unsigned long long)sample.pminten_after,
		probe_status_name(sample.status),
		probe_restore_name(&sample));
	pr_info("PMINTENCLR_PROBE_END status=complete\n");
	return 0;
}

static void __exit arm64_pmintenclr_probe_exit(void)
{
}

module_init(arm64_pmintenclr_probe_init);
module_exit(arm64_pmintenclr_probe_exit);

MODULE_DESCRIPTION("Guest-only QEMU/HVF PMINTENCLR_EL1 regression probe");
MODULE_AUTHOR("debian-m3 contributors");
MODULE_LICENSE("GPL");

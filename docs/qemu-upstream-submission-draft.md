# QEMU upstream submission draft

Status: local draft; not sent.

This package separates the concrete HVF PMU bug fix from the broader M3 Ultra
`-cpu host` investigation. QEMU requires patches to be emailed to
`qemu-devel@nongnu.org`; a GitHub pull request is not the submission path.

## Routing

For the PMINTENCLR patch and the M3 Ultra design note:

- To: `qemu-devel@nongnu.org`
- Cc: Alexander Graf `<agraf@csgraf.de>`
- Cc: Peter Maydell `<peter.maydell@linaro.org>`
- Cc: `qemu-arm@nongnu.org`

These recipients are produced by QEMU's `scripts/get_maintainer.pl` for
`target/arm/hvf/hvf.c`. The single patch is small enough that it does not need
a cover letter. Do not add `qemu-stable` unless a maintainer considers this
compatibility-path defect severe enough for backporting.

## Submission 1: standalone correctness fix

Subject:

```text
[PATCH] target/arm/hvf: Fix PMINTENCLR_EL1 clear semantics
```

Patch:

```text
patches/qemu/0001-hvf-arm-fix-pmintenclr-semantics.patch
```

The commit message contains the one-vCPU before/after result and the
originating commit:

```text
Fixes: e6fd3192edb8 ("hvf: arm: Properly disable PMU")
```

Submission claims are deliberately limited:

- QEMU 11.1.1 changed PMINTENCLR cycle bit 31 from `0` to `0x80000000`
  after a write of bit 31 to the clear alias.
- The patched QEMU 11.1.50 build left the bit at `0` and restored the guest
  PMU state.
- The patch changes only the AArch64 HVF `kernel-irqchip=off` PMU
  compatibility handler.
- It does not add host PMU passthrough or make Linux perf events available.
- The external Debian kernel-module probe is reproduction evidence, not an
  upstream CI test. A QEMU-tree test would require a macOS/HVF-specific
  functional guest or a production-code refactor, neither of which belongs in
  this fix.

Before sending, run from the QEMU checkout:

```sh
scripts/checkpatch.pl \
  ../patches/qemu/0001-hvf-arm-fix-pmintenclr-semantics.patch

git send-email --dry-run --confirm=never \
  --to=qemu-devel@nongnu.org \
  --cc=agraf@csgraf.de \
  --cc=peter.maydell@linaro.org \
  --cc=qemu-arm@nongnu.org \
  ../patches/qemu/0001-hvf-arm-fix-pmintenclr-semantics.patch
```

An actual send requires working SMTP or sendmail configuration for
`adam@flounder.net` and an explicit final review of the rendered email.

## Submission 2: M3 Ultra host-CPU design note

Subject:

```text
[RFC] target/arm/hvf: M3 Ultra -cpu host feature-contract results
```

Draft body:

```text
Hello,

I am validating QEMU's AArch64 -cpu host contract under HVF for an arm64
Debian guest. The primary test host is a Mac Studio Mac15,14 with an Apple
M3 Ultra, running macOS 26.6.2 (25G83) and the 26.5 SDK. The baseline is
QEMU 11.1.1 with:

  -M virt -accel hvf -cpu host

The goal is a homogeneous guest CPU contract containing every
architecturally safe feature available through public Hypervisor.framework
interfaces. It is not Apple device emulation, physical P/E-core identity,
or bare-metal support.

I collected the HVF vCPU-configuration feature and cache registers and
compared them with both Linux's EL0 feature ABI and raw EL1 values from
instantiated guest vCPUs. The guest matrix covered 1, 8, 16, 24, and 32
vCPUs.

Results:

* Every tested vCPU count exposed a homogeneous register, HWCAP, and sysfs
  contract. QEMU's synthetic Apple MIDR was 0x610f0000 on every vCPU.
* Raw EL1 observation found 11 exact host/guest register matches. The sole
  comparable difference was ID_AA64DFR0_EL1: the HVF configuration API
  reported 0x10305006 and the instantiated guest reported 0x10305106. This
  corresponds to the existing minimal virtual PMU policy and is not being
  proposed as a host-feature patch.
* CTR_EL0, CLIDR_EL1, DCZID_EL0, and all CLIDR-described CCSIDR_EL1 values
  were already exact at runtime. At 32 vCPUs all 96 sampled cache rows were
  homogeneous, and every transient CSSELR_EL1 selection was restored.
* All 35 advertised-feature checks passed at one vCPU. The same checks
  passed on all 32 vCPUs (1,120 rows total): 26 semantic checks and nine
  execution-only checks.
* Guest hardware performance events were unavailable with both
  kernel-irqchip modes. I classify this as unavailable in the current HVF
  runtime, not as evidence for a QEMU host-PMU passthrough patch.

The current M3 Ultra data therefore does not demonstrate a host CPU-feature
loss that should be fixed by changing QEMU's guest CPU ABI. In particular,
the fact that QEMU's explicit host snapshot does not consume the public
cache-register API is not by itself a runtime gap: instantiated vCPUs already
expose those values exactly.

My proposed patch boundary is:

1. Keep an independently discovered PMINTENCLR_EL1 clear-semantics fix as a
   standalone compatibility-path bug fix.
2. Do not change cache or ID-register exposure unless a public HVF value and
   a guest-visible mismatch are both demonstrated.
3. Investigate newer PFR2, ISAR2, MMFR3, and MMFR4 API availability and
   repeat the complete inventory independently on M5 Max before proposing a
   CPU-model extension.
4. Treat physical MIDR and P/E-core identity as unavailable through the
   current public API; retain a safe homogeneous model.

I would appreciate guidance on four policy questions before preparing any
CPU-model patch:

* Is the homogeneous vCPU-configuration-derived contract the intended
  meaning of -cpu host under Apple HVF?
* Should newer ID-register queries be added only when the deployment target
  provides a pre-vCPU public API and all configured vCPUs can be shown to
  agree?
* Would an explicit QEMU validation/test of the cache contract be useful even
  though the instantiated vCPU values already match?
* Should this host model be documented as non-migratable, or should a future
  change use a versioned model with destination preflight checks?

The collectors, comparison tools, exact register tables, and reproduction
commands are documented here:

  https://github.com/mysticflounder/debian-m3-ultra

The M5 Max inventory is intentionally pending and will be reported
separately rather than inferred from the M3 Ultra result.

Regards,
Adam McKenna
```

## Final pre-send gates

- Confirm the public repository contains the referenced results document at
  the commit linked from the email.
- Rebase the QEMU patch on current upstream master if master has moved and
  rerun the build and matched probe.
- Run `scripts/checkpatch.pl` and the reverse-apply identity check against the
  exact patched commit.
- Render the complete patch email with `git send-email --dry-run` and inspect
  To, Cc, From, subject, body, sign-off, `Fixes`, and diff.
- Configure SMTP/sendmail for `adam@flounder.net`.
- Obtain Adam's explicit approval of both outbound messages before sending.

Official process reference:
<https://www.qemu.org/docs/master/devel/submitting-a-patch.html>

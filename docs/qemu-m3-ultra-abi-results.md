# M3 Ultra arm64 ABI selftests

The one-vCPU `ptrace` ABI smoke passed all 11 checks on 2026-09-06;
the matching `syscall-abi` smoke subsequently passed both baseline checks.
Broader ABI validation remains open. The completed HWCAP
matrix is recorded separately in [HWCAP results](qemu-m3-ultra-selftest-results.md).

## Ptrace smoke

The unmodified `ptrace.c` from `linux-asahi-7.1.10-1` passed 11 planned
checks, with zero skips and zero failures. It ran pinned to CPU 0 as
UID/GID 65534 with cleared supplementary groups and `no_new_privs`, under
a 30-second timeout plus two-second termination grace. The surrounding
one-vCPU, 2 GiB QEMU/HVF launch retained the 420-second deadline.

Seven checks cover the TLS register-set read/write and TPIDR/TPIDR2 handling;
four cover hardware-debug register-set reads and nonzero architecture fields.
The kernel reported debug architecture version 6 with four watchpoint slots
and six breakpoint slots. This does not test breakpoint/watchpoint delivery,
prove SME support, or establish complete architectural register preservation.
The test explicitly accommodates TPIDR2 reading as zero when SME is absent.

Evidence: `out/ptrace-abi.u8tW4N/manifest.json`, with `run/ptrace.tap`,
`run/summary.json`, and `run/serial.raw.log`. The privilege check recorded
`uid=65534(nobody) gid=65534(nogroup) groups=65534(nogroup)`. The guest
answered the fresh nonce, retained QEMU identity, and shut down cleanly.
Its overlay was removed; all protected input identities and hashes matched
before/after. No QEMU patch was needed, and the persistent VM was untouched.

This is the Asahi builder kernel `7.1.10+deb14-asahi`, not a validation of
the persistent VM's stock kernel or bare-metal M3 Ultra drivers.

The source and matching `kselftest.h` hashes are pinned before compilation:

- `ptrace.c`: `c20dc561b5858671a58a909555edf47265de2b6d197420ef01ded1114ed3f575`
- `kselftest.h`: `b01a128468643494316bb8f998c80a1aacd4e686c5f13446c16e09928cf9355c`

The test runs unprivileged because its upstream error path can call
`kill(-1, SIGKILL)` if `fork()` fails. Dropping privilege confines that
path to test-user processes inside the disposable guest. Strict TAP parsing
and the exact 11-check plan are required in addition to successful exit.

## Syscall ABI smoke

The unmodified matching `syscall-abi.c` and `syscall-abi-asm.S` passed:

```text
TAP version 13
1..2
ok 1 getpid() FPSIMD
ok 2 sched_yield() FPSIMD
# Totals: pass:2 fail:0 xfail:0 xpass:0 skip:0 error:0
```

Each check verifies preservation of general-purpose registers x9–x30 and
all 128-bit Q0–Q31 registers across the named syscall. The baseline does not
check syscall return values (x0), x1–x8, SP, NZCV, FPCR/FPSR, TPIDR2, or
SVE/SME register state. It is not a test of complete CPU-state passthrough.
Source references: `syscall-abi.c` lines 74–137 and 393–417, and
`syscall-abi-asm.S` lines 108–145 and 216–255 in the verified inventory below.

Evidence: `out/syscall-abi.Pb37TV/manifest.json`, with `run/syscall.tap`,
`run/summary.json`, and `run/serial.raw.log`. The guest used the same builder
kernel `7.1.10+deb14-asahi`, one vCPU, 2 GiB RAM, and CPU-0 affinity. It ran
as UID/GID 65534 with cleared groups and `no_new_privs`, under the same
30-second test deadline plus two-second termination grace and 420-second
QEMU deadline. There was no network or host-device attachment. The nonce,
QEMU identity, QMP socket identity, and clean shutdown checks passed;
protected input identities/hashes were unchanged and the overlay was removed.
No QEMU patch was needed; the persistent VM and host firmware were untouched.

The guest pins four source hashes before compiling the unchanged C and
assembly with their matching local headers:

- `syscall-abi.c`: `5b2bb4c98064b0263860cda635340c68a4169a2882698101629f94a79b1de5af`
- `syscall-abi-asm.S`: `9c7e954f4273960af9043380ef1087d286238810658d36209bfb5178adde6a93`
- `syscall-abi.h`: `3459f9a4735b082e1716aa19741750d24faaa37b56abf17450c9170524efe423`
- `kselftest.h`: `b01a128468643494316bb8f998c80a1aacd4e686c5f13446c16e09928cf9355c`

The program returns zero even on reported check failures, so process exit
alone cannot pass this gate. The host requires strict TAP integrity, both
named FPSIMD baselines, no failures/skips, and a reachable source-derived
plan. The plan is `2 * (1 + S + 3*M + 3*S*M)` for SVE/SME vector-length
counts `S,M` in 0–5 (at most 192 checks). This source emits no SKIP records;
the observed two-check plan exercised no optional SVE/SME cases. The guest
unsets `KSFT_TAP_LEVEL` so the required TAP header is not suppressed.

The first launch, `out/syscall-abi.ZHqvtu`, never ran the guest test: the
execution sandbox denied the QMP Unix-socket bind and process inspection.
After verifying both recorded processes absent, no image openers, and all
protected hashes/identities unchanged, its lock was archived as
`recovered-lock` within that run. Its logs and unused overlay remain there
for diagnosis. The audited harness was retried outside the sandbox without
weakening process-identity checks or changing the VM configuration.

All 38 syscall protocol/TAP fixtures pass, including mandatory baseline
names, dynamic/maximum plans, unreachable plans, skip/failure rejection,
truncation, CRLF, exact markers, and identity/nonce drift. The existing 22
ptrace and 15 shared TAP fixtures were also rerun successfully (75 total).

## Source inventory and harness validation

The exact `ptrace` and `syscall-abi` sources were reviewed from the builder's
`linux-asahi-7.1.10-1` tree. Treat
`tpidr2` separately because its recorded Makefile uses a static, freestanding
nolibc build. Do not assume these programs share HWCAP's output or skip rules.

The inventory exported nine allowlisted files (81,385 decoded bytes), with
each decoded size and SHA-256 verified: Makefile, `ptrace.c`, `syscall-abi.c`,
`syscall-abi-asm.S`, `syscall-abi.h`, `tpidr2.c`, `hwcap.c`, `kselftest.h`,
and `lib.mk`. Evidence is in `out/abi-inventory.N4B2ZL/manifest.json`;
verified files and `inventory.tsv` are in `scratch/abi-sources.BsBo9b/`.
The transport itself runs no ABI binaries; its synthetic protocol result
must not be counted as an ABI test pass.

The first inventory (`out/abi-inventory.mUqvW3`) exported eight valid files
but falsely failed its host CRLF marker check. That validator was corrected
and regression-tested, and the missing `syscall-abi.h` dependency was added
before the passing retry. No upstream test source was modified.

Fixture suites pass: 15 inventory cases, 22 ptrace protocol/TAP cases, and
15 shared strict-TAP cases (52 total). These cover CRLF, missing/duplicate
markers, filename traversal, incorrect hashes/sizes, exact plan enforcement,
failure records despite a successful process exit, and separate skip counts.

```sh
/bin/bash scripts/test-abi-inventory-fixtures.sh
/bin/bash scripts/test-ptrace-abi-fixtures.sh
/bin/bash scripts/test-kselftest-fixtures.sh
/bin/bash scripts/abi-inventory-vm.sh
/bin/bash scripts/extract-abi-inventory.sh out/abi-inventory.N4B2ZL/run/serial.raw.log
/bin/bash scripts/ptrace-abi-vm.sh
/bin/bash scripts/test-syscall-abi-fixtures.sh
/bin/bash scripts/syscall-abi-vm.sh
```

## Next steps

Extend the passed ptrace and syscall ABI tests to multi-vCPU coverage next.
The separate `tpidr2` static/freestanding build remains open and must be
reviewed independently; absent optional features must not count as support.

Further execution will remain bounded and confined to disposable
guest roots. The persistent VM, host firmware, boot policy, raw disks, and
host devices are outside this task. Broader ABI coverage remains open until
actual test evidence is recorded.

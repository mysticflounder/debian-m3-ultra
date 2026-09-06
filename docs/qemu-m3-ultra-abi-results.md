# M3 Ultra arm64 ABI selftests

The one-vCPU `ptrace` ABI smoke passed all 11 checks on 2026-09-06.
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
```

## Next steps

Build and run the matching `syscall-abi` test at one vCPU next, including its
local header and assembly companion. Source review found only the configured
`getpid` and `sched_yield` system calls in its assembly path; SVE/SME state
tests are feature-gated. Its dynamic TAP plan and unconditional zero return
still require strict output validation. It has not yet been compiled or run.
Multi-vCPU ABI coverage and the separate `tpidr2` build remain open.

Execution, once reviewed, will remain bounded and confined to disposable
guest roots. The persistent VM, host firmware, boot policy, raw disks, and
host devices are outside this task. Broader ABI coverage remains open until
actual test evidence is recorded.

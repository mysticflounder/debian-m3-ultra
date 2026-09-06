# M3 Ultra Linux CPU-feature selftests

The one-vCPU HWCAP smoke passed; broader validation remains in progress.
This gate begins with Linux's arm64 HWCAP selftest,
not the entire kernel selftest suite. It complements the project's existing
35-row instruction tests; it does not replace them.

## Contract

Use the HWCAP source and kselftest header from the builder's Linux source
tree on `out/build.ext4`, attached read-only and mounted `ro,noload` in a
disposable guest. Copy only those inputs to the writable disposable root and
compile there using the builder's compiler, UAPI headers, and matching
read-only `tools/include` directory. Preserve source
and executable hashes in serial evidence. No source-disk writes, host-device
access, network, firmware changes, or persistent-VM modifications are needed.

Run the executable once pinned to each guest CPU. Each invocation has a
30-second deadline; the complete VM launch has a 420-second deadline plus
termination grace. These are correctness deadlines, not performance scores.

The HWCAP test compares Linux's auxiliary-vector feature bits with
`/proc/cpuinfo`, then checks instruction/signal behavior where implemented.
Unsupported features and unimplemented signal probes can produce legitimate
SKIP records. Report these separately: skipped checks are not evidence that
a feature works, and passing absence checks are not feature-support claims.

Require a complete, sequential TAP plan, zero failures, and at least one
non-skipped check, as well as successful process exit. Exit status alone is
insufficient: the upstream v6.12 reference's `main` prints totals and returns
zero even if individual checks fail. The host also checks fresh-nonce guest
identity, QMP responsiveness, clean shutdown, input hashes, and overlay cleanup.

## Results

On 2026-09-05, the one-vCPU smoke passed all host gates with 228 planned
checks: **98 passed, 130 skipped, zero failures**. These are checks, not 98
supported CPU features. The test reported 12 HWCAP entries present; other
passing checks include agreement that a feature is absent and expected
instruction rejection. Skips remain explicitly unvalidated.

Evidence: `out/selftest-matrix.4yMQBU/manifest.json`, with `smp-1/cpu-0.tap`
and `smp-1/cpu-0.summary.json`. The guest answered the fresh nonce and
shut down cleanly; QEMU process identity was retained, the disposable overlay
was removed, and protected input identities and hashes matched before/after.
No QEMU patch was needed. This used builder kernel `7.1.10+deb14-asahi`,
not the persistent VM's stock Debian kernel.

The 8/16/24/32-vCPU matrix and broader arm64 ABI selftests remain unvalidated.
Next: run this same HWCAP test at those counts, then select the additional
arm64 ABI tests. Do not mark the full Linux-selftest roadmap item complete.

### Build integration and fixtures

Static safety review passed. The first one-vCPU attempt stopped during guest
compilation: the matching `hwcap.c` includes `linux/compiler.h`, which needs
the kernel tools include directory. No HWCAP tests executed, so this is a
build-integration failure, not a CPU/QEMU failure.
The no-VM suites pass 15 TAP fixtures and 47 serial-protocol/digest/composition
fixtures. These include the CPU 1 versus CPU 10 marker distinction and
separate pass/skip aggregation.

The tools include path was corrected without changing the upstream test.
The second attempt (`out/selftest-matrix.YqjbmN/smp-1/serial.raw.log`) then
reached the next include and failed to locate `kselftest.h`: the matching
source uses its basename, unlike the older reference's relative include.
The copied header's include path was then added, producing the passing third
attempt without modifying the upstream source. Neither failed attempt
executed CPU checks. All 62 fixtures pass.
This harness uses `/usr/bin/openssl dgst -sha256 -r` for the same
full-file SHA-256 contract; it checks command status and digest shape, and
protects the OpenSSL executable's identity and hash along with the inputs.
The original shasum and OpenSSL baselines agree on both complete disk images.

```sh
/bin/bash scripts/test-kselftest-fixtures.sh
/bin/bash scripts/test-selftest-fixtures.sh
SMP_LIST=1 /bin/bash scripts/selftest-vm.sh
```

Protected-image hashing occurs outside the guest launch deadline and includes
the 60 GiB builder source disk. Do not interpret that host-side elapsed time
as selftest execution time or CPU performance.

First attempt: `out/selftest-matrix.zZgzSD/smp-1/serial.raw.log`.
It selected `linux-asahi-7.1.10-1/tools/testing/selftests/arm64/abi/hwcap.c`
and ran the Debian GCC 16.2.0 compiler. Source SHA-256:

- `hwcap.c`: `a5ced13d508818a4374d11db9646afc96477ca9e2e83a822ed6106314cb356d0`
- `kselftest.h`: `b01a128468643494316bb8f998c80a1aacd4e686c5f13446c16e09928cf9355c`

## Reference

The preliminary source review used the
[Linux v6.12 HWCAP test](https://github.com/torvalds/linux/blob/adc218676eef25575469234709c2d87185ca223a/tools/testing/selftests/arm64/abi/hwcap.c)
and its matching `kselftest.h`. The executed source came instead from the
builder's matching source tree, with its own hashes recorded; no v6.12 result
count is assumed for that tree.

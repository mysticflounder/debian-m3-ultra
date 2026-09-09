# Current-fork M3 Ultra raw-register validation

## Scope

These are register-contract tests, not performance benchmarks. The unchanged
`arm64-el1-probe.c` kernel module samples every online guest CPU and restores
CSSELR after reading the cache descriptions. The guest uses the existing
builder kernel, `7.1.10+deb14-asahi`, with QEMU/HVF `-cpu host` and explicit
`kernel-irqchip=on`. This does not change the persistent VM's kernel.

The current-fork runner uses the checked lifecycle from `reboot-vm.sh`, with
the launch/shutdown sequence used by `abi-matrix-vm.sh`. Each test has a
disposable root overlay, read-only build/source drives, 2 GiB RAM, and a
420-second VM deadline. There is no networking, graphical display, firmware,
NVRAM, physical disk or host-device attachment. QMP is a private local socket.
The invoking host account is not root; loading the module requires guest root.

## Provenance — 2026-09-08

- QEMU binary: `out/qemu-fork-pmintenclr-build/qemu-system-aarch64`, version
  11.1.50, SHA256
  `ea37dd7dfff94f9702af1c37eb12016842b6b371a53a8dc50ccf7779deb1a60a`.
- Clean QEMU checkout recorded by the parent repository at gitlink
  `789e3d805f9ca84e64c40fe1b99129336ce911b8`.
- Fresh HVF configuration: `out/el1-fork-host.wLfqPk/host.json`, macOS
  26.6.2 (25G83), SDK 26.5. All 14 queries succeeded. The capture records the
  sandbox brand fallback `arm64`, not an independently verified chip name.
- `out/el1-fork-host.wLfqPk/provenance.json` records the parent revision,
  QEMU gitlink/worktree status and binary/host-capture hashes. These establish
  checkout and executable identity separately, not reproducible-build proof.
- Each run records the actual executable hash and full launch arguments,
  process identity, and before/after identities and SHA256 hashes for all
  protected inputs, including both backing images and the test sources.

## Results

The one-vCPU gate passed in `out/el1-fork.hYTSJR/manifest.json`:
15 register rows, three cache rows, all consistency checks true, clean guest
shutdown, all protected input hashes unchanged, and overlay/lock removed.

| Comparison surface | Result per CPU |
| --- | --- |
| PFR0/1, DFR1, ISAR0/1, MMFR0/1/2, CTR, CLIDR, DCZID | 11 exact host/EL1 matches |
| DFR0 | Host `0x10305006`, guest `0x10305106`: known minimal virtual PMU |
| ZFR0 / SMFR0 | Two explicit `not_read` records, not measured zero or behavioral passes |
| CCSIDR | L1 data `0x700fe03a`, L1 instruction `0x203fe01a`, L2 unified `0x70ffe07b`: all exact |
| MPIDR | Guest affinity, checked for uniqueness within each VM; not physical identity passthrough |

The 8/16/24/32-vCPU follow-up also passed in
`out/el1-fork.1MDU6Z/manifest.json`.

| vCPUs | Register records | Cache comparisons | Result |
| --- | ---: | ---: | --- |
| 1 | 15 | 3 | pass |
| 8 | 120 | 24 | pass |
| 16 | 240 | 48 | pass |
| 24 | 360 | 72 | pass |
| 32 | 480 | 96 | pass |
| Total | 1,215 | 243 | all five configurations passed |

Across all 81 CPU samples, the non-MPIDR register contracts and cache
descriptions are identical. The register total includes 162 explicit
`not_read` records; it is not a count of 1,215 successful register reads.
All five reports contain 11 exact comparable register matches, two absent
feature records, one known PMU difference and three exact cache descriptions.
Each report compares the homogeneous per-VM contract; the raw artifacts retain
every CPU's observations.

All 23 protected inputs had identical before/after identities and hashes in
every run. All five QMP logs confirmed guest shutdown. Final checks confirmed
all five overlays, serial/QMP FIFOs, QMP sockets, PID files and the shared
probe lock were removed. No QEMU source change or persistent-VM modification
was needed.

## Interpretation

The completed matrix closes the stock-versus-fork provenance gap for the
existing 1/8/16/24/32-vCPU raw-register contract. No new register-loss or
cache-description bug is demonstrated.
The DFR0 difference is the intentional kernel-irqchip PMU representation, not
access to host event counters.

Current source has no HVF synchronization/emulation path for CTR, CLIDR,
DCZID or CCSIDR. Successful current-fork reads therefore support native/HVF
servicing; this is a source-supported inference, not a direct trace of each
register access. No cache override patch is justified by these results.

This does not validate newer PFR2/ISAR2/MMFR3/MMFR4 exposure, SVE/SME
instructions or state, physical per-core identity, migration to another
machine, bare-metal boot, or M5 Max.

The next register-exposure work is a bounded investigation of the newer ID
registers and their supported HVF access paths. Direct tracing of cache
servicing is only needed if it would resolve a proposed change; these exact
runtime values do not justify an override or another performance benchmark.

## Reproduction and regression checks

Capture fresh host values into a new directory with `cpu-probe-host.sh`, then:

```bash
HOST_JSON=/absolute/path/under/out/host.json SMP_LIST=1 \
  /bin/bash scripts/el1-fork-vm.sh
# Only after the single-vCPU gate passes:
HOST_JSON=/absolute/path/under/out/host.json SMP_LIST='8 16 24 32' \
  /bin/bash scripts/el1-fork-vm.sh
```

The runner calls `el1-probe-compare.sh` and additionally requires all three
cache rows to be exact. Any failed count stops the sequence. Use the normal
host account in an environment that permits private QMP sockets and process
identity inspection; do not bypass these checks to run inside a restrictive
sandbox.

`/bin/bash scripts/test-el1-fork-fixtures.sh` passed 25 no-VM cases, including
malformed/missing/duplicate records, legitimate conditional `not_read` rows,
token boundaries, partial lines, count validation, comparator compatibility,
and execution of the actual launch-wrapper body against a stub. Another 416
existing ABI/lifecycle-related fixtures passed; logs are retained under
`scratch/reboot-lifecycle-fixtures.20260908193103/`.

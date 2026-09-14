# M5 Max macOS host inventory

Collection timestamp: `2026-09-14T01:36:20Z` (UTC)

## Host identity and operating system

- CPU: `Apple M5 Max`
- Mac model: `Mac17,6`
- Architecture: `arm64`
- macOS: `26.6.2`, build `25G83`
- Darwin kernel: `25.6.0`, arm64
- macOS SDK: `26.5`
- Compiler: Apple clang `21.0.0 (clang-2100.1.1.101)`
- Measured CPU counts: 18 active, physical, and logical; performance-level counts `6` and `12`

The CPU and model values are direct `sysctl` results. No M3 register values,
topology, or feature outcomes were substituted.

## ARM feature flags

`hw.optional.arm.txt` contains the complete filtered `hw.optional.arm*`
query output. It contains 69 binary feature flags: 64 enabled and 5 disabled.
The output also preserves non-binary values exposed in that namespace, including
`hw.optional.arm.caps`, `hw.optional.arm.sme_max_svl_b`, and `hw.optional.arm64`.

## Public HVF configuration view

`hvf-host-cpu.json` is the raw output from `scripts/hvf-host-cpu.c`. The
collector exited successfully with schema version 1, configuration creation
status `ok`, all 14 feature-register queries `ok`, and both cache-register
queries `ok`. It created only an `hv_vcpu_config_t`; it did not create a VM or
vCPU.

The reported feature registers include the M5 Max public HVF values for the
PFR, DFR, ISAR, MMFR, SME/SVE, `CTR_EL0`, `CLIDR_EL1`, and `DCZID_EL0` views.
The cache view includes the data/unified and instruction `CCSIDR_EL1` arrays.

## Reproducibility and failures

- `commands.txt` records the commands used.
- `source-hashes.txt` records SHA-256 hashes for the collector source and the
  repository guidance files; `source.sha256` is the collector-source hash.
- `collector.sha256` is the compiled collector hash.
- All final host inventory queries returned status 0; `query-failures.txt`
  records the final status.
- `xcrun --sdk macosx --show-sdk-version` emitted Xcode cache/file-system-event
  diagnostics on stderr but returned status 0; the SDK query succeeded.
- The collector compiler and runtime stderr files were empty, and the JSON
  schema validation returned `true`.

## Scope and exclusions

This bundle contains host inventory only. No sudo, dependency installation,
VM launch, boot-security change, firmware change, or NVRAM change was used.
Serial numbers, hardware UUIDs, network addresses, and credentials were not
queried or recorded.

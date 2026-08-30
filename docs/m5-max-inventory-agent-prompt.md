# Prompt for the M5 Max inventory agent

Copy the prompt below into the coding-agent session running locally on the M5
Max MacBook. Run it from a clone of this repository when possible so the
artifacts remain together under `scratch/`.

---

You are collecting the read-only, privacy-sanitized hardware evidence needed
to plan m1n1 and Linux support for an M5 Max MacBook. Do not implement the port
or change the machine. Your deliverable is a reproducible inventory and a
source gap report.

## Safety boundary

No system, firmware, device, or repository source state changes are authorized.
Writes confined to the artifact directory as described below are the only
exception. Do not:

- use `sudo` or request administrator credentials;
- write NVRAM, boot policy, APFS metadata, EFI partitions, firmware, recovery
  state, or device settings;
- reboot, enter DFU/recovery, load or chainload m1n1, enable DebugUSB, or run an
  installer;
- access `/dev/mem`, issue MMIO reads or writes, probe peripheral registers, or
  load a kernel extension/driver;
- extract firmware, SEP data, personalization records, keys, tickets, nonces,
  or complete `chosen` properties;
- upload the report, use a paste service, or send its contents over the
  network;
- print or save a broad unsanitized `ioreg -l`, `ioreg -a`, `sysctl -a`, or
  complete `system_profiler` dump;
- enable shell tracing such as `set -x`; or
- write unsanitized command output to a temporary file, compiler log, cache,
  transcript, or shell variable that will later be printed.

All report files, collector source/build products, module caches, and temporary
files must stay below `scratch/m5-max-inventory/` in the current repository.
Do not commit or push them. If the repository is absent, create the same
relative directory under the current project directory and report it as
`<PROJECT>/scratch/m5-max-inventory/`, not as a user-bearing absolute path.

## Privacy rules

Omit values for all unique or user-linked identifiers, including:

- serial numbers, MLB/logic-board serials, ECID, UDID, provisioning UDID;
- hardware/platform/user UUIDs and disk/APFS/container UUIDs;
- Wi-Fi, Bluetooth, Ethernet, USB, or PCI MAC addresses and serial numbers;
- usernames, home-directory paths, hostnames, account data, environment
  variables, recovery keys, security tokens, certificates, and hashes/nonces
  tied to secure boot.

Do not retain a hash of a sensitive identifier; omit it. The model-class
properties `target-type`, `chip-id`, and numeric `board-id` are required and
are not unique-device serials. Preserve those three.

Apply the same redaction policy to node names, IORegistry paths, aliases,
source paths, command arguments, errors, and metadata. Store repository source
locations as `<REPO>/relative/path:line`; never emit an absolute home path.

Never print an unsanitized command result into the agent transcript. Use this
ordered collector fallback without installing anything:

1. If Swift and its IOKit/CoreFoundation SDK are already available, use them
   only after redirecting compiler/module caches and temporary directories
   below the artifact directory.
2. Otherwise, if an existing `python3` with the standard-library `plistlib` is
   available, it may consume `ioreg -p IODeviceTree -a` in process memory.
3. Otherwise, use only narrowly targeted `ioreg` calls whose stdout is passed
   immediately through a strict whitelist sanitizer. If that cannot be made
   fail-closed, record `collector unavailable` and stop instead of weakening
   the privacy boundary.

In every case the complete plist/output must never be printed, logged, or
written to disk. Record unavailable tooling without substituting a download,
package installation, or broader command.

## Host and software inventory

Record the absolute system executable path, exact sanitized argument vector,
tool version where available, timeout, exit status, and sanitized result for:

- `sw_vers`;
- targeted `sysctl -n` keys: `kern.osversion`, `hw.machine`, `hw.model`,
  `hw.ncpu`, `hw.logicalcpu`, `hw.physicalcpu`, `hw.memsize`, and
  `hw.pagesize`; record unavailable keys without substituting guesses;
- whitelisted fields from `system_profiler SPHardwareDataType
  SPSoftwareDataType`: model name, model identifier, chip name, core counts,
  memory, system firmware version, OS loader version, macOS version, and build;
  explicitly discard serial number, hardware UUID, and provisioning UDID; and
- architecture and kernel release from `uname -m` and `uname -r`.

Verify the whitelisted model and chip fields before deeper collection. If they
do not identify the intended M5 Max target, stop after the sanitized host
inventory and report the mismatch.

Do not run `system_profiler` sections for storage, network, Bluetooth, or user
applications. PCI/USB topology must come from the sanitized IORegistry
collector described below, not raw profiler output.

## IODeviceTree collector

Create `collector.swift` (or an equivalently self-contained local script) that
walks the `IODeviceTree` plane and emits only allowed fields. Add a separate,
targeted IOService-plane lookup for generated properties such as translated
`IODeviceMemory`; do not assume they exist in the IODeviceTree plane. Mark a
translation unavailable when it cannot be mapped safely. For every emitted
property, preserve raw byte order and width separately from any decoded value:

```json
{
  "path": "/arm-io/example",
  "property": "reg",
  "raw_hex": "...",
  "decoded": [{"address": "0x...", "size": "0x..."}],
  "encoding": "cells|u32-le|u64-le|string-list|bytes|unknown",
  "source": "IODeviceTree",
  "status": "present|absent|unreadable|inferred|omitted_by_policy",
  "notes": ""
}
```

Do not silently choose an endianness. For `CFData`, retain `raw_hex`, state the
decoding rule, and keep the raw value authoritative. Record phandle references
as raw cells plus resolved paths when resolution is unambiguous. Mark a value
`inferred` only when the inference and its inputs are stated explicitly.

Bound collection before reading or formatting values: 64 KiB per known,
whitelisted property and 4 KiB per unknown-encoding property. Never truncate a
value silently. Record the declared byte length and `omitted_by_policy` for an
oversized value. If an essential `reg`, `ranges`, CPU topology, MCC layout, or
identity property exceeds the bound, mark that entire inventory class
incomplete rather than publishing a partial value.

Generate a broad node index containing only sanitized full path, node name,
`compatible`, `reg`, `ranges`, and `status`. Then collect the following
class-specific properties for every matching instance.

### Root and chosen identity

- Root: `name`, `model`, `compatible`, `target-type`, `#address-cells`,
  `#size-cells`, timebase/clock-frequency fields, aliases, and child names.
- `/chosen`: only `chip-id`, `board-id`, and the selected console path if it is
  present as a plain device-tree path. Do not enumerate or save any other
  `chosen` property name or value.

### CPU topology

For `/cpus` and every CPU/cache/cluster child, collect:

- full path, node name, `compatible`, `cpu-id`, `reg`, `state`, and `status`;
- `die-id`, `cluster-id`, core/cluster type fields, and enable method;
- `cpu-impl-reg`, cache sizes/line sizes/sets, and cache relationships;
- clock/timebase frequency fields;
- property names and values matching `voltage-states*`, `freq*`, `perf*`, or
  `opp*`, provided they pass the privacy filter; and
- the running CPU, total CPU-node count, unique CPU IDs, decoded affinity
  tuple, die/cluster/core counts, gaps, and duplicates.

Do not assume the T6032 bit layout. Derive candidate masks from the values,
label them as hypotheses, and report whether existing m1n1 decoders fit.

### SoC fabric and early console

For `/arm-io`, collect `compatible`, `reg`, `ranges`, address/size cells,
interrupt-parent, child names, and both raw and translated address windows.

For every UART, debug console, dockchannel, and DebugUSB-related node, collect
path, `compatible`, `reg`, `interrupts`, clock/frequency fields, status,
pinctrl references, DART/PHY references, and console selection. Do not enable
or communicate with any debug interface.

### CPU start and power management

For PMGR and CPU-start-related nodes, collect path, `compatible`, `reg`,
declared register sizes, power-domain/clock/reset cell counts, referenced
clocks/resets/power domains, and relevant child names. Preserve all
`cpu-impl-reg` values from CPU nodes. Do not infer or test a CPU-start offset by
accessing hardware.

### Memory controller

For every MCC/AMCC-related node, collect:

- path, `compatible`, raw `reg`, translated `IODeviceMemory` ranges, and each
  entry's index/address/declared size;
- `plane-count-per-amcc`, `dcs-count-per-amcc`, `amcc-count`,
  `amcc-aperture-count`, and similarly named count/layout properties;
- interrupts, clocks, power domains, DMA/memory-region references, child names,
  and the complete list of property names with all non-whitelisted values
  omitted.

Classify register entries by size and die/address range without reading them.
Compare the shape with existing m1n1 MCC parsers, but do not propose that a
compatible string alone proves register equivalence.

### CPU frequency and OPP data

Find every node whose path, name, compatible, or properties mention CPU
frequency, performance domains, p-states, DVFS, voltage states, or OPPs.
Collect compatible, reg/ranges, count fields, CPU/cluster references, frequency
and voltage tables, and raw encodings. It is acceptable—and important—to report
that no such ADT node exists.

### Interrupts and peripheral fabrics

For every AIC, PCIe controller/port, DART/IOMMU, SPMI controller, SMC,
watchdog, USB/DRD/DWC3, and I2C/SPI controller, collect:

- full path, compatible list, reg/ranges with declared sizes, status, and child
  count;
- interrupt/MSI-parent and interrupt-cell data;
- clocks, resets, power domains, PHYs, stream IDs, DART/IOMMU mappings, DMA
  ranges, bus ranges, lane/port counts, and controller-specific count fields;
- for PCIe, each port's topology and register indices without probing links;
- for SPMI, peripheral addresses and compatibles without reading peripherals.

Inventory all instances, including die-prefixed or unusually named nodes.

## Read-only source gap analysis

If a local m1n1 checkout already exists, record its exact revision and inspect
it without modifying it. If it does not exist, say so; do not clone or download
anything for this collection task. Compare the collected evidence with:

- `src/soc.h` target IDs and early UART selection;
- `src/smp.h` CPU limits and `src/smp.c` topology/start-offset cases;
- `src/cpufreq.c` cluster tables and switch coverage;
- `src/mcc.c` compatible dispatch, register-list offsets/counting, and bounds;
- `src/pcie.c` compatible dispatch and expected register indices;
- `src/chickens.c` CPU identity/MIDR handling;
- serial, SPMI, DART, USB/DebugUSB, and ISP paths; and
- `src/kboot.c` CPU-node bounds, payload compatible selection, and FDT
  mutations.

For each area, report `supported`, `missing`, `selected-but-unverified`, or
`not enough evidence`, with source path/line, ADT evidence, and the next
hardware-free question. Do not write patches.

If a local Linux/Asahi source checkout already exists, record its revision and
whether an exact board DTS exists. Do not compile or build m1n1, Linux, DTBs,
or any other project in this collection session; leave build/schema validation
for the porting session.

## Required artifacts

Create:

- `scratch/m5-max-inventory/collector.swift` or the equivalent collector;
- `manifest.json` with collection time, OS/build, model-class identity, tool
  versions, exact executable/argument vectors, timeouts, exit statuses,
  limitations, and source revisions;
- `adt-properties.jsonl` using the property schema above;
- `nodes.tsv` with path/name/compatible/status and address-window summary;
- `topology.md` with CPU/die/cluster/cache and fabric relationships;
- `m1n1-gap-report.md` with the source comparison;
- `redaction-report.txt` listing the checks performed and only counts of
  removed fields, never removed values; and
- `SHA256SUMS` covering the published artifacts but excluding sensitive
  temporary data (which must not exist).

Run a final scan for serial/ECID/UDID/UUID/MAC/token/key/nonce patterns,
hostnames, usernames, and home paths. Inspect every match manually. The report
is incomplete until each requested class is either inventoried or explicitly
listed as absent/unreadable with the command and error.

## Final response

Return only:

1. the artifact directory;
2. the exact M5 Max model/target-type/chip-id/board-id and CPU/die counts;
3. the five most important m1n1 gaps, clearly separating proven gaps from
   hypotheses;
4. missing evidence or command failures;
5. confirmation that no privileged, state-changing, firmware, recovery,
   debug-interface, or MMIO action occurred; and
6. confirmation that the redaction scan passed.

Do not paste the full JSONL or IORegistry data into the chat.

---

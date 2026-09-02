# QEMU/HVF `PMINTENCLR_EL1` regression

Status: reproduced on QEMU 11.1.1 and fixed in QEMU fork commit
`235ced0f63315cadafa1d82b21cf6843ef94e2d9` on the M3 Ultra host. The commit is
based on upstream master `ef1e8668b9f3ab6d6e7826806db1de5326f9df7d`
(QEMU 11.1.50).

## Scope

This is a focused correctness fix for QEMU's existing Arm HVF
`kernel-irqchip=off` PMU compatibility path. It is not CPU acceleration, host
PMU passthrough, or a change to the guest CPU feature model. The broader PMU
availability result remains `unavailable`: Linux cannot open the advertised
hardware perf events under the tested HVF configurations.

## Source diagnosis

The irqchip-off handler in `target/arm/hvf/hvf.c` handled a write to
`PMINTENCLR_EL1` with:

```c
env->cp15.c9_pminten |= val;
```

That implements write-one-to-set behavior for a write-one-to-clear register.
QEMU's generic Arm PMU implementation instead masks the value to implemented
counters, clears those bits, and updates the PMU interrupt line. The HVF path's
existing `pmu_op_start()` and `pmu_op_finish()` calls are retained because they
materialize time-derived counter state and maintain overflow scheduling.

The proposed patch is
`patches/qemu/0001-hvf-arm-fix-pmintenclr-semantics.patch`. It changes only
this handler:

```c
pmu_op_start(env);
env->cp15.c9_pminten &= ~(val & pmu_counter_mask(env));
pmu_update_irq(env);
pmu_op_finish(env);
```

QEMU's `scripts/checkpatch.pl` reports zero errors and zero warnings, and the
patch applies cleanly to the local QEMU 11.1.50 source snapshot.

## Regression probe and safety boundary

`scripts/arm64-pmintenclr-probe.c` performs the minimum discriminating test:

1. Require the intentional irqchip-off hidden-PMU opt-in and PMUVer 0.
2. Disable the virtual PMU globally and verify that it is disabled.
3. Require cycle-interrupt enable and overflow bit 31 both to start clear.
4. Write bit 31 to `PMINTENCLR_EL1` and read the clear alias back.
5. Restore the virtual PMU on pass; on failure, leave global counting disabled
   until the disposable guest terminates.

The runner fixes the configuration at one vCPU and
`hvf,kernel-irqchip=off`. It attaches no network, monitor, firmware, pflash,
host device, or physical disk. The kernel, initrd, rootfs backing file, build
disk, and source share are immutable inputs; all guest filesystem writes land
in a disposable qcow2 overlay that is removed after QEMU exits. The system
register access changes only guest vCPU state.

Run the released baseline with:

```sh
./scripts/pmintenclr-probe-vm.sh
```

Exit 0 means pass, exit 2 means the semantic defect was captured, and exit 3
means a safety precondition caused the test to skip. A development build can
be selected explicitly:

```sh
QEMU=/absolute/path/to/qemu-system-aarch64 \
QEMU_EXPECT_VERSION= \
./scripts/pmintenclr-probe-vm.sh
```

## Matched result

| Build | Evidence | Before | After | Result | State restored |
|---|---|---:|---:|---|---|
| QEMU 11.1.1 | `out/pmintenclr-probe.92g8zm/evidence.json` | `0x0` | `0x80000000` | fail | no; VM discarded |
| fork commit `235ced0f6331` | `out/pmintenclr-probe.fU5ssY/evidence.json` | `0x0` | `0x0` | pass | yes |

Both evidence manifests report PMUVer 0, clear initial overflow state,
unchanged protected content hashes and build-disk metadata, removed overlays,
and no network, firmware, or host devices. Post-run checks found no QEMU
process, image opener, or probe lock remaining.

## Upstream boundary

Submit this as a standalone HVF PMU correctness patch with the one-vCPU
before/after evidence. Do not combine it with CPU model work or claims about
host performance-counter availability. The next PMU investigation should use
the same reproduce-first rule for any other handler discrepancy.

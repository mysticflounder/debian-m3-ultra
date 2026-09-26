# M3 Ultra macOS 27 / SDK 27 results

## Result — 2026-09-25

On macOS 27.0 (26A428), an SDK 27-built QEMU exposes
`ID_AA64ISAR2_EL1 = 0x10` to the guest: RPRES is now advertised. All 28
matched reciprocal-estimate probe results agree with the host.
This is a QEMU/HVF virtual-machine result, not bare-metal Linux support or
a performance measurement. The persistent VM has not been switched to this
binary; the previously validated binary remains intact.

The new QEMU patch imports four public HVF feature values into QEMU's
internal CPU feature model. **The patch did not cause the guest-visible
RPRES change:** a same-SDK build with the import block excluded exposes the
same guest register values.

## Public API and compatibility

Configuration-only queries using SDK 27's named feature constants return:

| Register | Value | API status |
| --- | --- | --- |
| ISAR2 | `0x0000000000000010` | success |
| PFR2 | `0x0000000000000000` | success |
| MMFR3 | `0x0000000000000000` | success |
| MMFR4 | `0x0000000000000000` | success |

The existing 14 feature and two cache queries are unchanged from the earlier
capture. Evidence: `scratch/hvf-sdk27.gECbtj/new-registers.json` and
`legacy-registers.json`; the preceding OS-update capture is
`scratch/hvf-macos27.zF4wOx/hvf-host-cpu.json`.

A separate never-run vCPU diagnostic successfully read, set to the queried
value, and reread all four registers. ISAR2 was already `0x10` before the
setter. Both vCPU and VM destruction succeeded; no guest instructions were
executed. Evidence: `scratch/hvf-sdk27.gECbtj/roundtrip.txt`.
No register setter was added to QEMU.

The patch is confined to `target/arm/hvf/hvf.c`. It uses an SDK version
compile guard and a macOS 27 runtime availability check, preserving the
existing getter error policy and zero-initialized fallback. It adds no
hard-coded Apple feature values and changes no other accelerator or
architecture. SDK 26.5 compatibility compilation of this translation unit
was exercised separately; an older macOS runtime was not tested.

The final replay transcript is `scratch/sdk26-hvf-audit/transcript.txt`.
Replaying the saved command verbatim failed because its GLib 2.88 include
paths no longer existed. Substituting the installed GLib 2.90 include paths
and retaining SDK 26.5 succeeded (exit 0). This verifies SDK compatibility,
not an unchanged full build environment. The resulting object hash is
`3cb2ea12ad7555f731418ea167baf7833210c27a83cd3dc00f96be581abdccc0`.

`git diff --check` passes. QEMU checkpatch flags the SDK preprocessor guard
as an architecture-specific define and requires a Signed-off-by trailer
for submission. The guard is intentional; review that warning and obtain
the author's sign-off before sending upstream.

## Controlled guest comparison

All three runs used the existing disposable, network-free EL1 runner with
`NEW_IDS=1 SMP_LIST=1`, identical probe/parser inputs, and the same host
capture. All manifests report `all_pass=true`.

| Build | Evidence directory | Guest ISAR2 |
| --- | --- | --- |
| Previously validated SDK 26.5 binary | `out/el1-fork.1aT4k8` | `0` |
| SDK 27 with imports | `out/el1-fork.WF14k9` | `0x10` |
| SDK 27, import block excluded | `out/el1-fork.d0mqyi` | `0x10` |

PFR2/MMFR3/MMFR4 are zero in every run. The two SDK 27 captures are
byte-identical. This rules out the import block as a necessary cause of the
guest change; it does not isolate the precise SDK/runtime mechanism.
The calibrated trace shows no userspace ID-register trap and does not
distinguish a physical register read from an HVF-handled read.

The temporary exclusion was removed and the final patched binary rebuilt.
The SDK 27 build lives separately in `out/qemu-sdk27-build/`.

## RPRES behavior and safety

The final patched binary passed the disposable RPRES run in
`out/rpres-vm.YOIthm/`. Its `guest.json` matches
`scratch/rpres-test.rtGWxy/host-o2.json`: 28 exact matches, zero mismatches.
The host test suite passed 16 checks. The runner now accepts a `QEMU`
environment override while retaining the old default and its existing
executable validation, canonicalization, and protected-input hashing.

The RPRES run recorded 19 unchanged protected inputs, clean guest shutdown,
and removal of the disposable overlay. The independent artifact audit
confirmed these results. No firmware, NVRAM, boot-security configuration,
raw host disk, or persistent VM configuration was modified.

Binary SHA-256 provenance:

```text
old validated SDK 26.5:
ea37dd7dfff94f9702af1c37eb12016842b6b371a53a8dc50ccf7779deb1a60a
initial SDK 27 patched (qemu-system-aarch64-import-only):
90e5da5c4ec7f98c04d958804b7f2398bfe2390633d5d1201ff3d2fee796cebf
SDK 27 no-import control (qemu-system-aarch64-no-import):
56e066b981d4270632c1392024189c0d96a57d75d9d23964e5ebca1e64048f77
final SDK 27 patched (qemu-system-aarch64):
364e7a7389f315c6ca95e3b46f50bd3aa8488fbb5c5fb0fa94b4c6fe5adea59a
```

## Remaining work

- Before promoting this binary, rerun the SMP/PSCI, reboot and save/restore
  regression checks on the updated host/build; retain an easy rollback.
- Validate M5 Max independently; these results apply only to M3 Ultra.
- Prepare separate upstream submissions for the PMINTENCLR fix, PSCI fix
  and guarded feature import. See the [submission draft](qemu-upstream-submission-draft.md).
  Upstream acceptance does not block local use of the fork.

The earlier SDK 26.5 API-boundary reports remain valid historical evidence;
their missing-public-API conclusion does not apply to macOS 27 with SDK 27.

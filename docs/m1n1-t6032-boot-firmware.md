# J575d boot-firmware reference artifacts

2026-09-26. These are offline reference files from Apple's macOS 27.0 /
`26A428` restore archive, not a dump or identification of currently installed
firmware. Nothing was installed or executed on the target.

## Acquisition and identity

The [manifest locator](inventory/t6032-boot-artifact-locator-2026-09-26.json)
binds the archive and original BuildManifest by URL, size and SHA-256.
Only the exact `j575dap` / chip `0x6032` / board `0x44` identities are used:
indices 33 (erase), 93 (upgrade) and 153 (macOS Customer).

A subsequent bounded range retrieval downloaded the two exact members
under `Firmware/all_flash/`, receiving 2,665,853 bytes including ZIP metadata:

| Member basename | File bytes | SHA-256 |
| --- | ---: | --- |
| `iBoot.j575d.RELEASE.im4p` | 1,167,497 | `4b5bbde28524480e57b8633550d21fd99efc28cf2c44eff59ad6bd71c41e0a00` |
| `LLB.j575d.RELEASE.im4p` | 1,348,791 | `4bc8a03798f07612f43870ff972b67f82ba4008b17526f28fef9175950493846` |

HTTP 206 and exact Content-Range, ZIP size/CRC, and identity/path/digest
agreement were checked. SHA-384 computed over each complete IM4P file
equals the corresponding 48-byte plist Digest. This is an observed equality
for these artifacts, not Apple signature verification or a universal claim
about every Image4 digest's byte scope.

Both restore identities contain both components with matching digests;
identity 153 contains iBoot but no LLB component. That omission does not
establish which boot stages execute on this machine. The neighboring
`j575cap` / chip `0x6041` entries were excluded.

Local originals and acquisition receipt are under
`scratch/mcc-boot-reference/payloads/`. The acquisition script is
`scratch/fetch-j575d-boot-payloads.py`; its SHA-256 is
`ea0ae144412c9adcbca124ac671ee926f030932044be0b9325893258041961b4`.
It verifies the earlier range-reader hash and held BuildManifest before
fetching, caps each compressed/uncompressed member at 4 MiB and all network
range data at 16 MiB, and refuses an existing output directory.

## Container and decoded payloads

The [inspection record](inventory/t6032-boot-firmware-2026-09-26.json)
records container, compressed payload and decoded hashes separately.
Both complete DER IM4P containers have payload offset 40, a `bvx2` stream,
description `mBoot-20457.1.29`, a two-integer size trailer, and a PAYP
wrapper. The latter is structurally checked but not semantically interpreted.

| Component | IM4P type | Compressed payload bytes | Decoded bytes | Decoded SHA-256 |
| --- | --- | ---: | ---: | --- |
| iBoot | `ibot` | 1,167,417 | 3,200,112 | `bed91c680ce5471ed1210be017ef9a33542e47c83bb7721f03e0aac209ca1c9e` |
| LLB | `illb` | 1,348,251 | 3,127,656 | `80ebece82b6752d76f1e00b09a6386f87f98c77aa69c6541346825549344d582` |

[`inspect-boot-firmware.py`](../scripts/inspect-boot-firmware.py) defaults
to metadata-only output. Explicit `--output-dir` enables libcompression
decoding into a fixed 16-MiB buffer; returned size must match the container's
size field and remain below the cap. Inputs are capped at 4 MiB. Outputs
must be a new directory below this repository's `scratch/`; no firmware is
executed. Unsupported types, compression markers and container shapes fail.

Example metadata-only invocation:

```sh
uv run --no-project --offline --python 3.13 scripts/inspect-boot-firmware.py \
  scratch/mcc-boot-reference/payloads/iBoot.j575d.RELEASE.im4p
```

The corresponding [28 synthetic tests](../scripts/test-boot-firmware.py)
pass, covering parser rejection, mocked decode failure/size limits, default
read-only behavior, output containment and non-overwrite behavior. Actual
decoding of both acquired files also passed the size/hash checks. Synthetic
tests do not validate libcompression's internals or Apple hardware behavior.

## Bounded string leads for the next trace

The following are **decoded-file offsets**, not runtime addresses. The
bytes at these positions were checked directly after the string search.

| Lead | LLB file offset | iBoot file offset |
| --- | --- | --- |
| `iBootStage1 for j575d` / `iBootStage2 for j575d` | `0x280` | `0x280` |
| AMCC error diagnostic format | `0x2b8ee9` | `0x2c6190` |
| `unsupported T6032 chip_rev` | `0x2b9341` | `0x2c667b` |
| `cache-status` | `0x2f878d` | Not recorded in this table |
| `com.apple.System.tz0-size` | `0x2bced6` | Not recorded in this table |
| `inclusive-tz-range` | Not recorded in this table | `0x2c7517` |
| `tz0-size-override` | Not recorded in this table | `0x30b034` |

These are search anchors, not proof that a particular path executes or
that AMCC diagnostics implement the cache-enable operation under study.
The next step is to establish the image's address model and trace code
references to these anchors, then connect actual accesses and guards to the
MCC handoff ledger. No register address or permission is inferred from a
string's presence; unlisted strings are not claimed absent.

## Interpretation boundary

Container tags and embedded version text identify what these files say
they contain; they are not proof of installed firmware, executed paths,
MCC register semantics or early-boot permissions. Analysis must retain the
distinction between restore LLB, iBoot and the macOS kernel runtime.
The [MCC access ledger](m1n1-t6032-mcc-handoff-ledger.md) defines the accesses
whose boot-stage prerequisites still need evidence.

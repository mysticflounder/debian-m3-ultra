# J575d iBoot: protection-range records, not cache-enable writes

2026-09-27. Offline continuation of the
[AMCC write-address trace](m1n1-t6032-boot-write-addresses.md).
The representative stores in that trace select **lower/upper range limits**,
not the `cache-status` record. This narrows the cache investigation and
provides a separate lead for the TZ/carveout contract. No native execution,
register access, boot-policy, disk, firmware or VM changes were performed.

## Byte evidence

Same pinned 3,200,112-byte decoded J575d iBoot, SHA-256
`bed91c680ce5471ed1210be017ef9a33542e47c83bb7721f03e0aac209ca1c9e`.
Locations below are file offsets. Local evidence under `scratch/mcc-evidence/`:

| Artifact | SHA-256 |
| --- | --- |
| `verify-boot-range-records.py` | `794a5675628a69ce228db0372a6817ef5b9536c39da766965ede4bc79ebd269f` |
| `boot-range-records.json` | `ff239133408a30ef768013a572a0bafa3b0f1b81ea33715450aa97032b559f90` |

The verifier pins its earlier field-verifier dependency, checks the input and
zero-address byte-identical wrapper, and compares 417 words in 13 extracts.
It also checks 20 name entries and NUL-terminated strings, plus six signed
jump-table offsets. These are byte checks, not execution or semantic proofs.
The report retains exact ranges, extract hashes and raw table bytes.

## The selected records

Name helper `0x156554` maps tags 1–6 through 32-byte entries at `0x288b90`.
Helper `0x158680` returns the four pointer/bounds/type words of an entry.
String pointers are interpreted using the already established preferred
base `0x10071a94000`, not an observed runtime base.

The second record scan in `0x1a0e00` uses a six-entry signed jump table at
`0x1a1de4`; entries are relative to `0x1a1098`, not the table address:

| Tag | Name | Branch target | Selected pointer destination |
| --- | --- | --- | --- |
| 1 | `lower-limit` | `0x1a10a4` | `[x29-0x80]` at `0x1a10bc` |
| 2 | `upper-limit` | `0x1a1108` | `x20` at `0x1a1118` |
| 3 | `enable` | `0x1a10dc` | `[sp+0x88]` |
| 4 | `lock` | `0x1a10f0` | `[sp+0x28]` |
| 5 | `write-disable` | `0x1a10c4` | `[sp+0xa0]` |
| 6 | `dsid-force-enable` | `0x1a1120` | `x19` |

Each candidate is a 24-byte record; the branch paths reject duplicate
selected records. The lower/upper paths also reject a nonzero word at
record `+0x10`. The earlier representative store at `0x1a15cc` loads its
offset from `[x29-0x80]+8`; `0x1a15ec` loads it from `x20+8`.
They therefore write lower and upper limit offsets on those paths, not
the offset from the parent-level `0xc1` cache-status record.

Their payloads are not a fixed cache-enable value one. Under the `0x41`
input-flag gate at `0x1a1148–0x1a1158`, the code loads the input's words
at `+0x10/+0x14`, masks them with the lower/upper records' `+0xc` words,
checks ordering, and saves the results in `[sp+0x58]` and `[sp+0x50]`.
Without that gate those working values are initialized to zero.
The stores use those saved payloads. Input construction, units and runtime
selection are not established by this bounded trace.

## Group names and TZ0 constructor

Name helper `0x156534` indexes `0x2889d0` for tags `0x100–0x10d`.
The decoded names include `0x102 = ctrr-c`, `0x103 = tz0`,
`0x104 = tz1`, `0x105 = tz2`, and `0x106 = tz3`.
At `0x409b8`, a static caller supplies AMCC parent tag `0x1000`,
group tag `0x103` and flags `0xf`. This is a specific TZ0 call site,
not evidence that this path executed on the current boot.

The constructor writes group tag `0x103` at `0x3ba94`; its records include
lower offset `0x6d8` and upper offset `0x6dc`, each with mask `0x0fffffff`
(`0x3bab8–0x3badc`). This is stronger than a numeric search hit: the
group and kind names, record layout, lookup and offset-consuming store
paths are now connected. The group also stores 12 at `+8`; this note
does not infer an address unit solely from that constant.

These TZ0 offsets agree with the corresponding constants in the existing
[m1n1 carveout reader](m1n1-t6032-carveouts.md). They do not by themselves
prove inclusive upper-bound semantics, the physical-address reconstruction,
other TZ slots, identical controller/plane contents, or safe early reads.
No carveout implementation has been changed on that basis.

## Why the cache-status lead stops here

The first scan selects tag `0xc1` at `0x1a0f74–0x1a0f84` and retains its
pointer in `[x29-0x60]` for duplicate detection. The normal first-scan exit
branches to `0x1a0fc0`, not the error call at `0x1a0fbc`.
There is no explicit second persistent alias of that c1 pointer in the
bounded caller trace. The slot is cleared at `0x1a1008`, and `x20` is
cleared at `0x1a1014` before the second scan.

At `0x1a1124`, the same slot is repopulated with the tag-6 record's
**end bound** (`record+0x18`), not a cache register pointer. Later it is
reused as a scalar. Following only the stack offset would falsely connect
cache-status metadata to protection-range operations.

The next cache step must find another genuine transition consumer rather
than relabel these range writes. Earlier-stage LLB and other cache consumers
remain candidates; this is not an exhaustive absence claim about iBoot.
For TZ, the next useful checks are the remaining slots, endpoint conversion
and handoff/permission contract. Hardware write-alias scope, loader/DMA
containment and recovery remain unverified. Native dispatch stays off;
the separate initial-MMU MCC read path is not protected by that CPU gate.

#!/usr/bin/env python3
"""Compare captured acc-cores shift bytes with m1n1's legacy CPU masks.

Offline, exact-board evidence model only: never MMIO, firmware enablement or
a claim that Apple's runtime sequence is sufficient for early boot.
"""

import argparse
import hashlib
import json
import os
import pathlib
import stat

IDENTITY = {"target": "J575d", "chip_id": "0x6032"}
EXPECTED = {(die, cluster, core) for die in range(2)
            for cluster, count in enumerate((4, 6, 6)) for core in range(count)}


def model(pmgr, cpus):
    for report in (pmgr, cpus):
        if report.get("status") != "ok" or report.get("identity") != IDENTITY:
            raise ValueError("wrong identity or unsuccessful inventory")
    if pmgr.get("schema_version") != 2 or cpus.get("schema_version") != 1:
        raise ValueError("unsupported inventory schema")
    metadata = pmgr["cluster_metadata"]
    record = metadata["acc-cores"]
    raw = bytes.fromhex(record["raw_hex"])
    if record["length"] != 256 or len(raw) != 256:
        raise ValueError("expected 32 eight-byte acc-cores records")
    stride = metadata["die-stride"]
    stride_raw = bytes.fromhex(stride["raw_hex"])
    if (stride["length"] != 8 or len(stride_raw) != 8
            or int.from_bytes(stride_raw, "little") != 0x2000000000):
        raise ValueError("unexpected die stride")
    topology = {}
    ids = set()
    for cpu in cpus["topology"]["affinity"]:
        values = [cpu[field] for field in ("die", "cluster", "core", "cpu_id")]
        if any(type(value) is not int for value in values):
            raise ValueError("non-integer CPU affinity")
        die, cluster, core, cpu_id = values
        key = (die, cluster, core)
        if key in topology or cpu_id in ids or not 0 <= cpu_id < 32:
            raise ValueError("duplicate affinity or invalid CPU ID")
        topology[key] = cpu_id
        ids.add(cpu_id)
    if set(topology) != EXPECTED or ids != set(range(32)):
        raise ValueError("topology does not cover exact 32-CPU board")
    seen = set()
    shifts = {0: set(), 1: set()}
    rows = []
    legacy_users = {}
    for index in range(32):
        entry = raw[index * 8:index * 8 + 8]
        shift, core, physical_cluster = entry[5:8]
        die, cluster = physical_cluster >> 3, physical_cluster & 7
        key = (die, cluster, core)
        if key not in topology or key in seen:
            raise ValueError("unmatched or duplicate acc-cores physical ID")
        if shift >= 32 or shift in shifts[die]:
            raise ValueError("out-of-range or duplicate per-die shift")
        seen.add(key)
        shifts[die].add(shift)
        candidate = 1 << shift
        legacy = 1 << (4 * cluster + core)
        cpu_id = topology[key]
        legacy_users.setdefault((die, legacy), []).append(cpu_id)
        rows.append({"cpu_id": cpu_id, "die": die, "cluster": cluster, "core": core,
                     "record_index": index, "acc_cores_shift_byte": shift,
                     "candidate_group_plus_4_mask": hex(candidate),
                     "legacy_group_plus_4_mask": hex(legacy),
                     "candidate_cluster_mask": hex(1 << core),
                     "legacy_matches": legacy == candidate})
    if seen != EXPECTED or any(bits != set(range(16)) for bits in shifts.values()):
        raise ValueError("unexpected per-die mask coverage")
    return {
        "schema_version": 1, "status": "ok", "identity": IDENTITY,
        "acc_cores_sha256": hashlib.sha256(raw).hexdigest(),
        "cpu_count": len(rows), "rows": sorted(rows, key=lambda row: row["cpu_id"]),
        "legacy_mismatch_count": sum(not row["legacy_matches"] for row in rows),
        "legacy_alias_groups": [
            {"die": die, "mask": hex(mask), "cpu_ids": sorted(users)}
            for (die, mask), users in sorted(legacy_users.items()) if len(users) > 1],
        "interpretation": "acc-cores byte 5 shift model; runtime branch and early-boot contract unvalidated",
        "register_semantics_validated": False,
        "register_writes_performed": False, "cpu_release_validated": False,
    }


def load(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("inventory must be a regular file")
        raw = stream.read(1024 * 1024 + 1)
    if len(raw) > 1024 * 1024:
        raise ValueError("inventory size limit exceeded")
    return json.loads(raw)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pmgr", type=pathlib.Path)
    parser.add_argument("cpus", type=pathlib.Path)
    args = parser.parse_args()
    try:
        result = model(load(args.pmgr), load(args.cpus))
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        # Do not echo malformed input or private arbitrary fields.
        print(json.dumps({"schema_version": 1, "status": "error",
                          "error": "invalid_inventory"}))
        return 1
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

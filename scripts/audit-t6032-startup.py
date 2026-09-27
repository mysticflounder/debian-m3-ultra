#!/usr/bin/env python3
"""Allowlisted CPU-start metadata audit; never reads implementation registers."""

from __future__ import annotations

import importlib.util
import json
import math
import pathlib

SPEC = importlib.util.spec_from_file_location(
    "t6032_cpu_inventory", pathlib.Path(__file__).with_name("audit-t6032-cpus.py")
)
CPU = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CPU)
AuditError = CPU.AuditError


def audit_tree(root):
    topology = CPU.audit_tree(root)
    tree = CPU.MCC._unwrap_device_tree(root)
    cpus = CPU._find_one(CPU._children(tree), "cpus", "missing_cpus")
    records = []
    for node in CPU._children(cpus):
        decoded = CPU._decode_cpu(node)
        state = node.get("state")
        if state not in (b"running\0", b"waiting\0"):
            raise AuditError("invalid_cpu_state")
        impl = node.get("cpu-impl-reg")
        if not isinstance(impl, bytes) or len(impl) != 16:
            raise AuditError("invalid_cpu_impl_length")
        base = int.from_bytes(impl[:8], "little")
        size = int.from_bytes(impl[8:], "little")
        if not base or base & 7 or size < 0x108 or base + size >= 1 << 64:
            raise AuditError("invalid_cpu_impl_range")
        records.append({
            "cpu_id": decoded["cpu_id"],
            "die": decoded["die"],
            "cluster": decoded["cluster"],
            "core": decoded["core"],
            "reg": hex(CPU._u32_property(node, "reg")),
            "state": state[:-1].decode("ascii"),
            "cpu_impl_base": hex(base),
            "cpu_impl_size": hex(size),
        })
    by_base = sorted(records, key=lambda row: int(row["cpu_impl_base"], 16))
    for previous, current in zip(by_base, by_base[1:]):
        if (int(previous["cpu_impl_base"], 16) + int(previous["cpu_impl_size"], 16)
                > int(current["cpu_impl_base"], 16)):
            raise AuditError("overlapping_cpu_impl_ranges")
    running = [row["cpu_id"] for row in records if row["state"] == "running"]
    if len(running) != 1:
        raise AuditError("ambiguous_boot_cpu")
    return {
        "schema_version": 1,
        "status": "ok",
        "identity": topology["identity"],
        "source_path": "/cpus",
        "running_cpu_id": running[0],
        "cpu_count": len(records),
        "cpus": sorted(records, key=lambda row: row["cpu_id"]),
        "hardware_validated": False,
        "implementation_registers_read": False,
        "register_writes_performed": False,
        "mpidr_mapping_validated": False,
    }


def main():
    try:
        parser = CPU._parser()
        parser.description = __doc__
        args = parser.parse_args()
        if not math.isfinite(args.timeout) or not 0 < args.timeout <= 60:
            raise AuditError("invalid_timeout")
        report = audit_tree(CPU._load(CPU.MCC._read_input(args)))
    except (AuditError, CPU.MCC.AuditError) as exc:
        report = {"schema_version": 1, "status": "error", "error": {"code": exc.code}}
    except (OSError, UnicodeError):
        report = {"schema_version": 1, "status": "error", "error": {"code": "input_unavailable"}}
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["status"] == "ok" else 1


if __name__ == "__main__":
    raise SystemExit(main())

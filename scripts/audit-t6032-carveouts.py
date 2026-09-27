#!/usr/bin/env python3
"""Allowlisted T6032 carveout metadata; never reads hardware registers.

Input is an offline ioreg plist, stdin, or explicit --live metadata collection.
Only identity and region-id-2/4 are retained. LE64 address/size interpretation
is a candidate geometry model, not proof of physical addressing or TZ slots.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import math
import pathlib
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("mcc_metadata", ROOT / "scripts/audit-t6032-mcc.py")
MCC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MCC)
AuditError = MCC.AuditError
REGIONS = ("region-id-2", "region-id-4")


def decode_region(raw: Any) -> tuple[int, int]:
    if not isinstance(raw, bytes) or len(raw) != 16:
        raise AuditError("invalid_region_encoding")
    base, size = int.from_bytes(raw[:8], "little"), int.from_bytes(raw[8:], "little")
    if not base or not size or base % 4096 or size % 4096:
        raise AuditError("invalid_region_geometry")
    if base + size >= 1 << 64:
        raise AuditError("region_address_wrap")
    return base, size


def audit_tree(tree: Any) -> dict:
    if isinstance(tree, list):
        if len(tree) != 1:
            raise AuditError("unexpected_root")
        tree = tree[0]
    if not isinstance(tree, dict):
        raise AuditError("unexpected_root")
    MCC._validate_hierarchy(tree)
    dt = MCC._unwrap_device_tree(tree)
    identity = MCC._require_identity(dt)
    chosen, = [n for n in MCC._child_nodes(dt) if MCC._node_name(n) == "chosen"]
    maps = [n for n in MCC._child_nodes(chosen) if MCC._node_name(n) == "carveout-memory-map"]
    if len(maps) != 1:
        raise AuditError("missing_or_duplicate_carveout_map")
    regions = []
    pairs = []
    for name in REGIONS:
        if name not in maps[0]:
            raise AuditError("missing_required_region")
        base, size = decode_region(maps[0][name])
        pairs.append((base, base + size))
        regions.append({"name": name, "raw_hex": maps[0][name].hex(),
                        "byte_length": 16, "candidate_base": hex(base),
                        "candidate_size": hex(size), "candidate_end_exclusive": hex(base + size)})
    return {
        "schema_version": 1, "status": "ok", "identity": identity,
        "source_node": "/chosen/carveout-memory-map", "regions": regions,
        "candidate_encoding": "two little-endian u64 values interpreted as address,size",
        "candidate_regions_overlap": pairs[0][0] < pairs[1][1] and pairs[1][0] < pairs[0][1],
        "limitations": ["metadata only; interpretation requires consumer corroboration",
                        "does not identify TZ register offsets, slot numbers or per-die replication",
                        "not an MMIO snapshot, bootloader carveout validation or native boot test"],
        "hardware_registers_accessed": False, "native_execution_performed": False,
        "tz_layout_validated": False,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("plist", nargs="?", help="saved ioreg plist or - for stdin")
    group.add_argument("--live", action="store_true", help="read-only ioreg metadata, in memory")
    parser.add_argument("--timeout", type=float, default=10.0)
    args = parser.parse_args(argv)
    try:
        if not math.isfinite(args.timeout) or not 0 < args.timeout <= 60:
            raise AuditError("invalid_timeout")
        report = audit_tree(MCC._load_plist(MCC._read_input(args)))
        report["capture_mode"] = "live_ioreg_metadata" if args.live else "offline_plist"
    except AuditError as error:
        report = {"schema_version": 1, "status": "error", "error": {"code": error.code}}
    except (OSError, UnicodeError):
        report = {"schema_version": 1, "status": "error", "error": {"code": "input_unavailable"}}
    print(json.dumps(report, indent=2))
    return 0 if report["status"] == "ok" else 1


if __name__ == "__main__":
    raise SystemExit(main())

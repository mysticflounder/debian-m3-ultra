#!/usr/bin/env python3
"""Allowlisted T6032 DVFS metadata capture; no MMIO or register writes.

Raw table words are deliberately not labeled frequencies, voltages or states:
their binary consumer contract must be established separately. Live IODeviceTree
and restore templates are distinct evidence sources, not interchangeable inputs.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import pathlib
import sys


def load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, pathlib.Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PMGR = load("dvfs_pmgr", "audit-t6032-pmgr.py")
ADT = load("dvfs_adt", "inspect-firmware-mcc.py")
AuditError = PMGR.AuditError
SCALARS = ("first-acc-dvfm-map-state", "nominal-performance1", "boost-performance1",
           "mcx-fast-pcpu-frequency")
TABLES = tuple(f"voltage-states{number}{suffix}"
               for number in (2, 5, 13, 34, 37, 45) for suffix in ("", "-sram", "-extra"))
REQUIRED_TABLES = ("voltage-states2", "voltage-states5", "voltage-states13")
OTHER = ("perf-domains", "perf-regs")
MAX_PROPERTY_BYTES = 4096


def properties(node: dict) -> dict:
    selected = {}
    absent = []
    for name in (*SCALARS, *OTHER, *TABLES):
        if name not in node:
            if name in REQUIRED_TABLES or name in SCALARS or name in OTHER:
                raise AuditError("missing_required_dvfs_property")
            absent.append(name)
            continue
        raw = node[name]
        if not isinstance(raw, bytes) or not 0 < len(raw) <= MAX_PROPERTY_BYTES:
            raise AuditError("invalid_dvfs_property")
        if len(raw) % 4 or (name in SCALARS and len(raw) != 4):
            raise AuditError("invalid_dvfs_property_length")
        # The traced voltage-states%u[-sram] parser advances by eight bytes.
        # The separate -extra format is still untraced; retain only word bounds.
        if name in TABLES and not name.endswith("-extra") and len(raw) % 8:
            raise AuditError("invalid_dvfs_table_record_length")
        selected[name] = {"length": len(raw), "raw_hex": raw.hex()}
        if name in SCALARS:
            selected[name]["value_le_u32"] = int.from_bytes(raw, "little")
    return {"properties": selected, "absent_optional_properties": absent,
            "table_word_semantics_validated": False,
            "state_count_inferred": False, "safe_initial_states_established": False}


def report(identity: dict, node: dict, source: str) -> dict:
    return {"schema_version": 1, "status": "ok", "identity": identity,
            "source_kind": source, "source_path": "/arm-io/pmgr", **properties(node),
            "domain_number_note": "34/37/45 are selected property names, not a validated die-1 mapping",
            "hardware_validated": False, "register_writes_performed": False}


def audit_tree(tree, *, live: bool = False) -> dict:
    if isinstance(tree, list) and len(tree) == 1:
        tree = tree[0]
    if not isinstance(tree, dict):
        raise AuditError("unexpected_root")
    PMGR.HELPER._validate_hierarchy(tree)
    device_tree = PMGR.HELPER._unwrap_device_tree(tree)
    identity = PMGR.HELPER._require_identity(device_tree)
    pmgr = PMGR.child(PMGR.child(device_tree, "arm-io"), "pmgr")
    return report(identity, pmgr, "live IODeviceTree" if live else "supplied IODeviceTree plist")


def audit_adt(data: bytes) -> dict:
    nodes = ADT.selected_nodes(data, ("/", "/chosen", "/arm-io/pmgr"))
    root, chosen, pmgr = (nodes[p] for p in ("/", "/chosen", "/arm-io/pmgr"))
    ADT.require(ADT.cstring(root.get("target-type", b"")) == "J575d", "unsupported target")
    ADT.require(ADT.cstring(root.get("model", b"")) == "Mac15,14", "target/model mismatch")
    ADT.require(ADT.cstring(pmgr.get("compatible", b"")) == "pmgr1,t6031",
                "unsupported PMGR compatible")
    identity = {"target": "J575d", "model": "Mac15,14",
                "template_chip_id": hex(ADT.u32(chosen.get("chip-id", b"")))}
    return report(identity, pmgr, "restore firmware template, not live or iBoot-final ADT")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--live", action="store_true", help="read ioreg metadata in memory")
    group.add_argument("--plist", help="supplied IODeviceTree plist, or - for stdin")
    group.add_argument("--firmware", type=pathlib.Path, help="local J575d device-tree IM4P")
    parser.add_argument("--timeout", type=float, default=10.0)
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or not 0 < args.timeout <= 60:
        raise AuditError("invalid_timeout")
    if args.firmware:
        if not args.firmware.is_file():
            raise AuditError("firmware_not_regular_file")
        with args.firmware.open("rb") as stream:
            raw = stream.read(ADT.LIMIT + 1)
        data = ADT.decode_im4p(raw)
        result = audit_adt(data)
        result.update({"im4p_sha256": hashlib.sha256(raw).hexdigest(),
                       "adt_sha256": hashlib.sha256(data).hexdigest()})
    else:
        result = audit_tree(PMGR.HELPER._load_plist(PMGR.HELPER._read_input(args)), live=args.live)
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AuditError, ValueError, OSError):
        # Do not leak paths, property contents or parser exception payloads.
        print(json.dumps({"schema_version": 1, "status": "error",
                          "error": "dvfs_metadata_unavailable_or_invalid"}), file=sys.stderr)
        raise SystemExit(1)

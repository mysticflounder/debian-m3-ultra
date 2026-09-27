#!/usr/bin/env python3
"""Capture allowlisted T6032 PMGR metadata; never read or write MMIO."""

from __future__ import annotations

import importlib.util
import json
import math
import pathlib
from typing import Any


HELPER_PATH = pathlib.Path(__file__).with_name("audit-t6032-mcc.py")
SPEC = importlib.util.spec_from_file_location("pmgr_inventory_helpers", HELPER_PATH)
assert SPEC is not None and SPEC.loader is not None
HELPER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HELPER)
AuditError = HELPER.AuditError

FEATURES = (
    "amx-thrtl", "apsc-snooze", "cpu-apsc", "cpu-fixed-freq-pll-relock",
    "llc-thrtl", "ppt-thrtl",
)
# Shape constraints for the observed J575d six-cluster metadata, not MMIO semantics.
RAW_FIELDS = {"acc-clusters": 48, "cluster-ctl-offset": 4, "clusters": 12}


def child(parent: dict[str, Any], name: str) -> dict[str, Any]:
    matches = [node for node in HELPER._child_nodes(parent) if HELPER._node_name(node) == name]
    if len(matches) != 1:
        raise AuditError("missing_or_duplicate_pmgr_path")
    return matches[0]


def property_bytes(node: dict[str, Any], name: str, length: int) -> bytes:
    value = node.get(name)
    if not isinstance(value, bytes) or len(value) != length:
        raise AuditError("invalid_pmgr_property")
    return value


def audit_tree(tree: Any) -> dict[str, Any]:
    if isinstance(tree, list) and len(tree) == 1:
        tree = tree[0]
    if not isinstance(tree, dict):
        raise AuditError("unexpected_root")
    HELPER._validate_hierarchy(tree)
    device_tree = HELPER._unwrap_device_tree(tree)
    identity = HELPER._require_identity(device_tree)
    pmgr = child(child(device_tree, "arm-io"), "pmgr")
    features = {}
    for name in FEATURES:
        raw = property_bytes(pmgr, name, 4)
        features[name] = {"raw_hex": raw.hex(), "value_le_u32": int.from_bytes(raw, "little")}
    metadata = {}
    for name, length in RAW_FIELDS.items():
        raw = property_bytes(pmgr, name, length)
        metadata[name] = {"raw_hex": raw.hex(), "length": len(raw)}
    metadata["cluster-ctl-offset"]["value_le_u32"] = int.from_bytes(
        property_bytes(pmgr, "cluster-ctl-offset", 4), "little"
    )
    return {
        "schema_version": 1,
        "status": "ok",
        "identity": identity,
        "source_path": "/arm-io/pmgr",
        "features": features,
        "cluster_metadata": metadata,
        "register_semantics_validated": False,
        "register_writes_performed": False,
    }


def main(argv: list[str] | None = None) -> int:
    try:
        parser = HELPER._parser()
        parser.description = __doc__
        args = parser.parse_args(argv)
        if not math.isfinite(args.timeout) or not 0 < args.timeout <= 60:
            raise AuditError("invalid_timeout")
        report = audit_tree(HELPER._load_plist(HELPER._read_input(args)))
    except AuditError as exc:
        report = {"schema_version": 1, "status": "error", "error": {"code": exc.code}}
    except (OSError, UnicodeError):
        report = {"schema_version": 1, "status": "error", "error": {"code": "input_unavailable"}}
    print(json.dumps(report, sort_keys=True, separators=(",", ":")))
    return 0 if report["status"] == "ok" else 1


if __name__ == "__main__":
    raise SystemExit(main())

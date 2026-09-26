#!/usr/bin/env python3
"""Offline, geometry-only audit of the T6032/J575d CPU topology."""

from __future__ import annotations

import argparse
import importlib.util
import json
import math
import pathlib
import sys
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parent
MCC_PATH = ROOT / "audit-t6032-mcc.py"
SPEC = importlib.util.spec_from_file_location("t6032_mcc_helpers", MCC_PATH)
if SPEC is None or SPEC.loader is None:  # pragma: no cover - installation failure
    raise RuntimeError("MCC helper unavailable")
MCC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MCC)


SCHEMA_VERSION = 1
EXPECTED_TARGET = "J575d"
EXPECTED_CPU_COUNT = 32
EXPECTED_DIE_COUNT = 2
EXPECTED_CLUSTERS_PER_DIE = 3
EXPECTED_MAX_CPUS = 32
EXPECTED_SOURCE_REVISION = "4184923ffb2dff079b384d6a32cc02142aa14572"


class AuditError(Exception):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


def _node_name(node: dict[str, Any]) -> str | None:
    return MCC._scalar_text(node.get("IORegistryEntryName", node.get("name")))


def _children(node: dict[str, Any]) -> list[dict[str, Any]]:
    value = node.get("IORegistryEntryChildren", [])
    if not isinstance(value, list) or any(not isinstance(child, dict) for child in value):
        raise AuditError("malformed_hierarchy")
    return value


def _u32_property(node: dict[str, Any], name: str) -> int:
    value = node.get(name)
    if not isinstance(value, bytes) or len(value) != 4:
        raise AuditError("malformed_cpu_property")
    return int.from_bytes(value, "little")


def _text_list(value: Any) -> list[str]:
    try:
        return MCC._compatible_values(value)
    except MCC.AuditError as exc:
        raise AuditError("malformed_cpu_property") from exc


def _cpu_compatible(node: dict[str, Any], cluster_type: str) -> str:
    compatible = _text_list(node.get("compatible"))
    expected = "apple,sawtooth" if cluster_type == "E" else "apple,everest"
    if expected not in compatible:
        raise AuditError("cpu_compatible_mismatch")
    return expected


def _find_one(nodes: list[dict[str, Any]], name: str, missing: str) -> dict[str, Any]:
    matches = [node for node in nodes if _node_name(node) == name]
    if len(matches) != 1:
        raise AuditError(missing)
    return matches[0]


def _decode_cpu(node: dict[str, Any]) -> dict[str, Any]:
    cpu_id = _u32_property(node, "cpu-id")
    reg = _u32_property(node, "reg")
    if reg & ~0x7FFF:
        raise AuditError("invalid_cpu_reg")
    die = (reg >> 11) & 0xF
    cluster = (reg >> 8) & 0x7
    core = reg & 0xFF
    advertised_die = _u32_property(node, "die-id")
    advertised_cluster = _u32_property(node, "die-cluster-id")
    advertised_core = _u32_property(node, "cluster-core-id")
    if (advertised_die, advertised_cluster, advertised_core) != (die, cluster, core):
        raise AuditError("cpu_affinity_mismatch")
    type_value = MCC._scalar_text(node.get("cluster-type"))
    if type_value not in ("E", "P"):
        raise AuditError("invalid_cluster_type")
    compatible = _cpu_compatible(node, type_value)
    if cpu_id >= EXPECTED_CPU_COUNT:
        raise AuditError("cpu_id_out_of_range")
    return {
        "cpu_id": cpu_id,
        "die": die,
        "cluster": cluster,
        "core": core,
        "cluster_type": type_value,
        "compatible": compatible,
    }


def _validate_groups(cpus: list[dict[str, Any]]) -> list[dict[str, Any]]:
    groups: dict[tuple[int, int], list[dict[str, Any]]] = {}
    for cpu in cpus:
        groups.setdefault((cpu["die"], cpu["cluster"]), []).append(cpu)
    if len(groups) != EXPECTED_DIE_COUNT * EXPECTED_CLUSTERS_PER_DIE:
        raise AuditError("unexpected_cluster_count")
    summaries = []
    for die in range(EXPECTED_DIE_COUNT):
        per_die = [(key, members) for key, members in groups.items() if key[0] == die]
        if len(per_die) != EXPECTED_CLUSTERS_PER_DIE:
            raise AuditError("unexpected_cluster_count")
        if {cluster for (_, cluster), _ in per_die} != {0, 1, 2}:
            raise AuditError("unexpected_cluster_geometry")
        types_counts = sorted((members[0]["cluster_type"], len(members)) for _, members in per_die)
        if types_counts != [("E", 4), ("P", 6), ("P", 6)]:
            raise AuditError("unexpected_cluster_geometry")
        for (_, cluster), members in per_die:
            if any(member["cluster_type"] != members[0]["cluster_type"] for member in members):
                raise AuditError("mixed_cluster_type")
            expected_type = "E" if cluster == 0 else "P"
            if members[0]["cluster_type"] != expected_type:
                raise AuditError("unexpected_cluster_geometry")
            if any(member["cluster"] != cluster or member["die"] != die for member in members):
                raise AuditError("unexpected_cluster_geometry")
            cores = sorted(member["core"] for member in members)
            if cores != list(range(len(members))):
                raise AuditError("unexpected_core_geometry")
            summaries.append(
                {
                    "die": die,
                    "cluster": cluster,
                    "cluster_type": members[0]["cluster_type"],
                    "cpu_count": len(members),
                }
            )
    return sorted(summaries, key=lambda item: (item["die"], item["cluster"]))


def audit_tree(tree: Any) -> dict[str, Any]:
    if isinstance(tree, list):
        if len(tree) != 1 or not isinstance(tree[0], dict):
            raise AuditError("unexpected_root")
        root = tree[0]
    elif isinstance(tree, dict):
        root = tree
    else:
        raise AuditError("unexpected_root")
    try:
        MCC._validate_hierarchy(root)
        device_tree = MCC._unwrap_device_tree(root)
        identity = MCC._require_identity(device_tree)
    except MCC.AuditError as exc:
        raise AuditError(exc.code) from exc
    if identity != {"target": EXPECTED_TARGET, "chip_id": "0x6032"}:
        raise AuditError("unexpected_identity")

    cpus = _find_one(_children(device_tree), "cpus", "missing_cpus")
    max_cpus = _u32_property(cpus, "max_cpus")
    cluster_count = _u32_property(cpus, "cpu-cluster-count")
    if max_cpus != EXPECTED_MAX_CPUS:
        raise AuditError("unexpected_max_cpus")
    if cluster_count != EXPECTED_CLUSTERS_PER_DIE:
        raise AuditError("unexpected_cluster_count")
    cpu_nodes = _children(cpus)
    if len(cpu_nodes) != EXPECTED_CPU_COUNT:
        raise AuditError("unexpected_cpu_count")
    names = [_node_name(node) or "" for node in cpu_nodes]
    if set(names) != {f"cpu{index}" for index in range(EXPECTED_CPU_COUNT)}:
        raise AuditError("unexpected_cpu_node")
    decoded = [_decode_cpu(node) for node in cpu_nodes]
    ids = [cpu["cpu_id"] for cpu in decoded]
    if len(set(ids)) != len(ids):
        raise AuditError("duplicate_cpu_id")
    if sorted(ids) != list(range(EXPECTED_CPU_COUNT)):
        raise AuditError("non_dense_cpu_ids")
    if any(cpu["cpu_id"] != int(name[3:]) for cpu, name in zip(decoded, names)):
        raise AuditError("cpu_name_id_mismatch")
    affinities = [(cpu["die"], cpu["cluster"], cpu["core"]) for cpu in decoded]
    if len(set(affinities)) != len(affinities):
        raise AuditError("duplicate_cpu_affinity")
    if {cpu["die"] for cpu in decoded} != {0, 1}:
        raise AuditError("unexpected_die_count")
    groups = _validate_groups(decoded)
    return {
        "schema_version": SCHEMA_VERSION,
        "status": "ok",
        "identity": identity,
        "topology": {
            "cpu_count": EXPECTED_CPU_COUNT,
            "advertised_max_cpus": max_cpus,
            "die_count": EXPECTED_DIE_COUNT,
            "clusters_per_die": cluster_count,
            "group_shape": "4E+6P+6P per die",
            "groups": groups,
            "affinity_model": "ADT reg fields; not architectural MPIDR",
            "reg_encoding": "little-endian u32; core[7:0], cluster[10:8], die[14:11]",
            "affinity": sorted(decoded, key=lambda item: item["cpu_id"]),
            "decoder_source_revision": EXPECTED_SOURCE_REVISION,
        },
        "topology_validated": True,
        "cpu_release_validated": False,
        "hardware_validated": False,
        "register_writes_performed": False,
    }


def _load(data: bytes) -> Any:
    try:
        return MCC._load_plist(data)
    except MCC.AuditError as exc:
        raise AuditError(exc.code) from exc


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("plist", nargs="?", help="saved plist path, or - for stdin")
    group.add_argument("--live", action="store_true", help="read ioreg in memory")
    parser.add_argument("--timeout", type=float, default=10.0)
    return parser


def main(argv: list[str] | None = None) -> int:
    try:
        args = _parser().parse_args(argv)
        if not math.isfinite(args.timeout) or args.timeout <= 0 or args.timeout > 60:
            raise AuditError("invalid_timeout")
        # Reuse the MCC loader's fixed command, safe path handling, and live timeout.
        data = MCC._read_input(args)
        report = audit_tree(_load(data))
    except (AuditError, MCC.AuditError) as exc:
        report = {"schema_version": SCHEMA_VERSION, "status": "error", "error": {"code": exc.code}}
    except (OSError, UnicodeError):
        report = {"schema_version": SCHEMA_VERSION, "status": "error", "error": {"code": "input_unavailable"}}
    print(json.dumps(report, sort_keys=True, separators=(",", ":")))
    return 0 if report["status"] == "ok" else 1


if __name__ == "__main__":
    raise SystemExit(main())

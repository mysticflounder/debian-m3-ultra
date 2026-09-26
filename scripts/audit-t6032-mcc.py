#!/usr/bin/env python3
"""Offline, geometry-only audit of the T6032 MCC register list.

The input is an XML/binary plist produced by ioreg, or stdin.  ``--live`` is
an explicit opt-in that captures the IODeviceTree plist in memory using the
fixed ioreg command.  This tool never opens /dev/mem, performs MMIO, or emits
raw registry properties, addresses, paths, or identifiers beyond the two
allowlisted target identity fields.
"""

from __future__ import annotations

import argparse
import json
import math
import plistlib
import subprocess
import sys
from typing import Any
from xml.parsers.expat import ExpatError


SCHEMA_VERSION = 1
U64_LIMIT = 1 << 64
EXPECTED_TARGET = "J575d"
EXPECTED_CHIP_ID = 0x6032
EXPECTED_COMPATIBLE = "mcc,t6031"
EXPECTED_PLANES = 4
EXPECTED_DCS = 4
EXPECTED_ENTRY_COUNT = 20
EXPECTED_HEADER_SIZES = (0x20000, 0x149C, 0x4000, 0x4000)
EXPECTED_INSTANCE_SIZE = 0x2000000
INSTANCE_INDICES = tuple(range(4, 20))
M1N1_SOURCE_REVISION = "4184923ffb2dff079b384d6a32cc02142aa14572"
MAX_INPUT_BYTES = 32 * 1024 * 1024
MAX_TREE_DEPTH = 64
MAX_TREE_NODES = 100_000


class AuditError(Exception):
    """An expected, safe-to-report audit failure."""

    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _scalar_text(value: Any) -> str | None:
    if isinstance(value, str):
        return value
    if isinstance(value, bytes):
        try:
            return value.decode("ascii").rstrip("\x00")
        except UnicodeDecodeError:
            return None
    return None


def _decode_u64(value: Any) -> int:
    if _is_int(value) and 0 <= value < U64_LIMIT:
        return value
    if isinstance(value, bytes) and 0 < len(value) <= 8:
        return int.from_bytes(value, "little")
    text = _scalar_text(value)
    if text is not None:
        try:
            parsed = int(text, 0)
        except ValueError as exc:
            raise AuditError("invalid_numeric_property") from exc
        if 0 <= parsed < U64_LIMIT:
            return parsed
    raise AuditError("invalid_numeric_property")


def _node_name(node: dict[str, Any]) -> str | None:
    return _scalar_text(node.get("IORegistryEntryName", node.get("name")))


def _child_nodes(node: dict[str, Any]) -> list[dict[str, Any]]:
    children = node.get("IORegistryEntryChildren", [])
    if not isinstance(children, list) or any(not isinstance(child, dict) for child in children):
        raise AuditError("malformed_hierarchy")
    return children


def _validate_hierarchy(root: dict[str, Any]) -> None:
    count = 0

    def visit(node: dict[str, Any], depth: int) -> None:
        nonlocal count
        count += 1
        if count > MAX_TREE_NODES or depth > MAX_TREE_DEPTH:
            raise AuditError("hierarchy_limit")
        for child in _child_nodes(node):
            visit(child, depth + 1)

    visit(root, 0)


def _compatible_values(value: Any) -> list[str]:
    if isinstance(value, bytes):
        try:
            decoded = value.decode("ascii")
        except UnicodeDecodeError as exc:
            raise AuditError("malformed_compatible") from exc
        return [item for item in decoded.split("\x00") if item]
    if isinstance(value, list):
        values = [_scalar_text(item) for item in value]
        if any(item is None for item in values):
            raise AuditError("malformed_compatible")
        return [item for item in values if item is not None]
    item = _scalar_text(value)
    if item is None:
        raise AuditError("malformed_compatible")
    return [item]


def _unwrap_device_tree(root: dict[str, Any]) -> dict[str, Any]:
    if _node_name(root) != "Root":
        raise AuditError("unexpected_root")
    children = _child_nodes(root)
    device_tree = [child for child in children if _node_name(child) == "device-tree"]
    if len(device_tree) != 1:
        raise AuditError("missing_device_tree")
    return device_tree[0]


def _require_identity(device_tree: dict[str, Any]) -> dict[str, Any]:
    target = _scalar_text(device_tree.get("target-type"))
    chosen_nodes = [child for child in _child_nodes(device_tree) if _node_name(child) == "chosen"]
    if target is None or len(chosen_nodes) != 1:
        raise AuditError("missing_identity")
    if target != EXPECTED_TARGET:
        raise AuditError("target_mismatch")
    try:
        chip_id = _decode_u64(chosen_nodes[0]["chip-id"])
    except KeyError as exc:
        raise AuditError("missing_identity") from exc
    if chip_id != EXPECTED_CHIP_ID:
        raise AuditError("chip_mismatch")
    return {"target": EXPECTED_TARGET, "chip_id": f"0x{EXPECTED_CHIP_ID:04x}"}


def _decode_reg(value: Any) -> list[tuple[int, int]]:
    if not isinstance(value, bytes):
        raise AuditError("malformed_reg")
    if len(value) % 16:
        raise AuditError("truncated_reg")
    count = len(value) // 16
    if count != EXPECTED_ENTRY_COUNT:
        raise AuditError("unexpected_reg_count")
    pairs = []
    for offset in range(0, len(value), 16):
        address = int.from_bytes(value[offset : offset + 8], "little")
        size = int.from_bytes(value[offset + 8 : offset + 16], "little")
        pairs.append((address, size))
    return pairs


def _validate_ranges(pairs: list[tuple[int, int]], code: str) -> None:
    ordered = sorted(pairs)
    previous_end = 0
    for address, size in ordered:
        if size <= 0 or address < 0 or address >= U64_LIMIT:
            raise AuditError(code)
        if size > U64_LIMIT - address:
            raise AuditError(code)
        if address < previous_end:
            raise AuditError(code)
        previous_end = address + size


def _memory_pairs(value: Any) -> list[tuple[int, int]]:
    if not isinstance(value, list) or len(value) != EXPECTED_ENTRY_COUNT:
        raise AuditError("malformed_iodevicememory")
    pairs: list[tuple[int, int]] = []
    for entry in value:
        if isinstance(entry, list):
            if len(entry) != 1:
                raise AuditError("malformed_iodevicememory")
            entry = entry[0]
        if not isinstance(entry, dict):
            raise AuditError("malformed_iodevicememory")
        if "address" not in entry:
            raise AuditError("malformed_iodevicememory")
        length_key = "length" if "length" in entry else "size"
        if length_key not in entry:
            raise AuditError("malformed_iodevicememory")
        pairs.append((_decode_u64(entry["address"]), _decode_u64(entry[length_key])))
    return pairs


def _count_property(node: dict[str, Any], names: tuple[str, ...], code: str) -> int:
    present = [node[name] for name in names if name in node]
    if len(present) != 1:
        raise AuditError(code)
    try:
        value = _decode_u64(present[0])
    except AuditError as exc:
        raise AuditError(code) from exc
    if value <= 0:
        raise AuditError(code)
    return int(value)


def _find_mcc(device_tree: dict[str, Any]) -> dict[str, Any]:
    arm_io = [child for child in _child_nodes(device_tree) if _node_name(child) == "arm-io"]
    if len(arm_io) != 1:
        raise AuditError("missing_arm_io")
    matches = []
    for node in _child_nodes(arm_io[0]):
        if _node_name(node) != "mcc" or "compatible" not in node:
            continue
        compatibles = _compatible_values(node["compatible"])
        if EXPECTED_COMPATIBLE in compatibles:
            matches.append(node)
    if not matches:
        raise AuditError("missing_mcc")
    if len(matches) != 1:
        raise AuditError("duplicate_mcc")
    return matches[0]


def audit_tree(tree: Any) -> dict[str, Any]:
    """Audit a parsed plist and return only the sanitized report."""
    if isinstance(tree, list):
        if len(tree) != 1 or not isinstance(tree[0], dict):
            raise AuditError("unexpected_root")
        root = tree[0]
    elif isinstance(tree, dict):
        root = tree
    else:
        raise AuditError("unexpected_root")

    _validate_hierarchy(root)
    device_tree = _unwrap_device_tree(root)
    identity = _require_identity(device_tree)
    mcc = _find_mcc(device_tree)
    compatible = _compatible_values(mcc.get("compatible"))
    if compatible.count(EXPECTED_COMPATIBLE) != 1:
        raise AuditError("unexpected_compatible")
    planes = _count_property(
        mcc,
        ("plane-count-per-amcc", "planes-per-amcc", "planes"),
        "missing_plane_count",
    )
    dcs = _count_property(
        mcc,
        ("dcs-count-per-amcc", "dcs-per-amcc", "dcs"),
        "missing_dcs_count",
    )
    if planes != EXPECTED_PLANES or dcs != EXPECTED_DCS:
        raise AuditError("unexpected_geometry_counts")

    reg_pairs = _decode_reg(mcc.get("reg"))
    _validate_ranges(reg_pairs, "invalid_reg_ranges")
    translated_pairs = _memory_pairs(mcc.get("IODeviceMemory"))
    _validate_ranges(translated_pairs, "invalid_iodevicememory_ranges")
    if [size for _, size in translated_pairs] != [size for _, size in reg_pairs]:
        raise AuditError("reg_iodevicememory_size_mismatch")

    sizes = [size for _, size in reg_pairs]
    if tuple(sizes[:4]) != EXPECTED_HEADER_SIZES:
        raise AuditError("unexpected_header_geometry")
    if any(size != EXPECTED_INSTANCE_SIZE for size in sizes[4:]):
        raise AuditError("unexpected_instance_geometry")

    old_selected = list(range(3, 19))
    old_selected_size = sizes[3]
    old_bad_planes = [plane for plane in range(1, planes) if 0x1C00 + plane * 0x40000 + 4 > old_selected_size]

    return {
        "schema_version": SCHEMA_VERSION,
        "status": "ok",
        "identity": identity,
        "mcc": {
            "compatible": EXPECTED_COMPATIBLE,
            "planes_per_mcc": EXPECTED_PLANES,
            "dcs_per_mcc": EXPECTED_DCS,
            "reg_encoding": "little-endian u64 address,size pairs",
            "reg_entry_count": EXPECTED_ENTRY_COUNT,
            "header_sizes": [f"0x{size:x}" for size in EXPECTED_HEADER_SIZES],
            "header_size_source": "reg_and_IODeviceMemory",
            "instance_indices": list(INSTANCE_INDICES),
            "instance_size": f"0x{EXPECTED_INSTANCE_SIZE:x}",
            "geometry_check": "pass",
            "candidate_selection_basis": "geometry_only",
            "old_m1n1": {
                "source_revision": M1N1_SOURCE_REVISION,
                "offset": 3,
                "cache_write_width": "0x4",
                "cache_plane_offset_model": "0x1c00 + plane * 0x40000",
                "selected_indices": old_selected,
                "selected_count_after_cap": 16,
                "omitted_index": 19,
                "selected_entry_size": f"0x{old_selected_size:x}",
                "undersized_selected_index": 3,
                "cache_plane_offsets_exceed_size_for_planes": old_bad_planes,
            },
        },
        "hardware_validated": False,
        "register_writes_performed": False,
    }


def _load_plist(data: bytes) -> Any:
    if len(data) > MAX_INPUT_BYTES:
        raise AuditError("input_too_large")
    try:
        return plistlib.loads(data)
    except (plistlib.InvalidFileException, TypeError, ValueError, OverflowError,
            RecursionError, ExpatError) as exc:
        raise AuditError("malformed_plist") from exc


def _read_input(args: argparse.Namespace) -> bytes:
    if args.live:
        try:
            completed = subprocess.run(
                ["/usr/sbin/ioreg", "-a", "-l", "-p", "IODeviceTree"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=args.timeout,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise AuditError("live_unavailable") from exc
        if completed.returncode != 0 or not completed.stdout:
            raise AuditError("live_unavailable")
        return completed.stdout
    if args.plist in (None, "-"):
        return sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
    try:
        with open(args.plist, "rb") as stream:
            return stream.read(MAX_INPUT_BYTES + 1)
    except OSError as exc:
        raise AuditError("input_unavailable") from exc


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("plist", nargs="?", help="saved plist path, or - for stdin")
    group.add_argument("--live", action="store_true", help="read ioreg in memory")
    parser.add_argument("--timeout", type=float, default=10.0, help="live ioreg timeout in seconds")
    return parser


def main(argv: list[str] | None = None) -> int:
    try:
        args = _parser().parse_args(argv)
        if not math.isfinite(args.timeout) or args.timeout <= 0 or args.timeout > 60:
            raise AuditError("invalid_timeout")
        report = audit_tree(_load_plist(_read_input(args)))
    except AuditError as exc:
        report = {
            "schema_version": SCHEMA_VERSION,
            "status": "error",
            "error": {"code": exc.code},
        }
    except (OSError, UnicodeError):
        report = {
            "schema_version": SCHEMA_VERSION,
            "status": "error",
            "error": {"code": "input_unavailable"},
        }
    print(json.dumps(report, sort_keys=True, separators=(",", ":")))
    return 0 if report["status"] == "ok" else 1


if __name__ == "__main__":
    raise SystemExit(main())

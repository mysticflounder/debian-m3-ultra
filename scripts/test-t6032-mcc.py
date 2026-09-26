#!/usr/bin/env python3
"""Synthetic, hardware-free tests for audit-t6032-mcc.py."""

from __future__ import annotations

import importlib.util
import io
import json
import pathlib
import plistlib
import subprocess
import sys
import unittest
from unittest.mock import patch


ROOT = pathlib.Path(__file__).resolve().parents[1]
AUDIT_PATH = ROOT / "scripts" / "audit-t6032-mcc.py"
SPEC = importlib.util.spec_from_file_location("audit_t6032_mcc", AUDIT_PATH)
assert SPEC is not None and SPEC.loader is not None
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


def make_tree(
    *,
    target: str = "J575d",
    chip_id: int = 0x6032,
    sizes: list[int] | None = None,
    address_override: dict[int, int] | None = None,
    reg_endian: str = "little",
    mcc_count: int = 1,
) -> dict:
    if sizes is None:
        sizes = list(AUDIT.EXPECTED_HEADER_SIZES) + [AUDIT.EXPECTED_INSTANCE_SIZE] * 16
    addresses = [0x100000000 + index * 0x4000000 for index in range(len(sizes))]
    for index, address in (address_override or {}).items():
        addresses[index] = address
    reg = b"".join(
        address.to_bytes(8, reg_endian) + size.to_bytes(8, reg_endian)
        for address, size in zip(addresses, sizes)
    )
    memory = [[{"address": address, "length": size}] for address, size in zip(addresses, sizes)]

    def mcc_node() -> dict:
        return {
            "IORegistryEntryName": b"mcc\x00",
            "compatible": b"mcc,t6031\x00vendor,mcc\x00",
            "plane-count-per-amcc": (4).to_bytes(4, "little"),
            "dcs-count-per-amcc": (4).to_bytes(4, "little"),
            "reg": reg,
            "IODeviceMemory": memory,
            "private-sentinel": "DO_NOT_LEAK_THIS",
        }

    mcc_nodes = [mcc_node() for _ in range(mcc_count)]
    return {
        "IORegistryEntryName": "Root",
        "IORegistryEntryChildren": [
            {
                "IORegistryEntryName": "device-tree",
                "target-type": target.encode("ascii") + b"\x00",
                "IORegistryEntryChildren": [
                    {
                        "IORegistryEntryName": "chosen",
                        "chip-id": chip_id.to_bytes(4, "little"),
                        "private-chosen-sentinel": "DO_NOT_LEAK_THIS",
                    },
                    {"IORegistryEntryName": "arm-io", "IORegistryEntryChildren": mcc_nodes},
                ],
            }
        ],
        "root-sentinel": "DO_NOT_LEAK_THIS",
    }


def plist_bytes(tree: dict) -> bytes:
    return plistlib.dumps(tree, fmt=plistlib.FMT_XML)


def run_cli(data: bytes) -> tuple[int, dict, str]:
    completed = subprocess.run(
        [sys.executable, str(AUDIT_PATH), "-"],
        input=data,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    text = completed.stdout.decode("utf-8")
    return completed.returncode, json.loads(text), text


class T6032MccAuditTests(unittest.TestCase):
    def test_truncated_xml_has_sanitized_error(self) -> None:
        code, report, text = run_cli(plist_bytes(make_tree())[:-30])
        self.assertEqual(code, 1)
        self.assertEqual(report["error"]["code"], "malformed_plist")
        self.assertNotIn("DO_NOT_LEAK_THIS", text)

    def test_file_read_is_bounded_before_parsing(self) -> None:
        stream = io.BytesIO(b"x" * 100)
        args = AUDIT._parser().parse_args(["unused.plist"])
        with patch.object(AUDIT, "MAX_INPUT_BYTES", 8):
            with patch("builtins.open", return_value=stream):
                data = AUDIT._read_input(args)
                self.assertEqual(len(data), 9)
                with self.assertRaisesRegex(AUDIT.AuditError, "input_too_large"):
                    AUDIT._load_plist(data)

    def test_nonfinite_timeout_is_rejected_without_live_query(self) -> None:
        for value in ("nan", "inf"):
            with self.subTest(value=value), patch.object(AUDIT, "_read_input") as read_input:
                with patch("sys.stdout", new_callable=io.StringIO) as output:
                    self.assertEqual(AUDIT.main(["--live", "--timeout", value]), 1)
                read_input.assert_not_called()
                self.assertEqual(json.loads(output.getvalue())["error"]["code"], "invalid_timeout")

    def test_little_endian_decodes_twenty_entries(self) -> None:
        report = AUDIT.audit_tree(make_tree())
        self.assertEqual(report["status"], "ok")
        self.assertEqual(report["mcc"]["reg_entry_count"], 20)
        self.assertEqual(report["mcc"]["instance_indices"], list(range(4, 20)))
        self.assertEqual(report["mcc"]["header_sizes"], ["0x20000", "0x149c", "0x4000", "0x4000"])

    def test_identity_mismatch_is_rejected(self) -> None:
        for tree in (make_tree(target="J575c"), make_tree(chip_id=0x6031)):
            with self.subTest(tree=tree["IORegistryEntryChildren"][0]["target-type"], chip=tree["IORegistryEntryChildren"][0]["IORegistryEntryChildren"][0]["chip-id"]):
                with self.assertRaises(AUDIT.AuditError):
                    AUDIT.audit_tree(tree)

    def test_old_m1n1_bounds_bug_is_reported_geometry_only(self) -> None:
        report = AUDIT.audit_tree(make_tree())
        old = report["mcc"]["old_m1n1"]
        self.assertEqual(old["selected_indices"], list(range(3, 19)))
        self.assertEqual(old["omitted_index"], 19)
        self.assertEqual(old["undersized_selected_index"], 3)
        self.assertEqual(old["selected_entry_size"], "0x4000")
        self.assertEqual(old["cache_plane_offsets_exceed_size_for_planes"], [1, 2, 3])
        self.assertEqual(old["source_revision"], "4184923ffb2dff079b384d6a32cc02142aa14572")
        self.assertEqual(old["cache_write_width"], "0x4")
        self.assertFalse(report["hardware_validated"])
        self.assertFalse(report["register_writes_performed"])
        self.assertNotIn("100000000", json.dumps(report))

    def test_missing_and_duplicate_mcc_fail_closed(self) -> None:
        missing = make_tree()
        missing["IORegistryEntryChildren"][0]["IORegistryEntryChildren"][1]["IORegistryEntryChildren"] = []
        duplicate = make_tree(mcc_count=2)
        for tree, code in ((missing, "missing_mcc"), (duplicate, "duplicate_mcc")):
            with self.subTest(code=code):
                with self.assertRaisesRegex(AUDIT.AuditError, code):
                    AUDIT.audit_tree(tree)

    def test_unrelated_property_cannot_supply_mcc(self) -> None:
        fake = make_tree()
        device_tree = fake["IORegistryEntryChildren"][0]
        arm_io = device_tree["IORegistryEntryChildren"][1]
        fake_node = arm_io["IORegistryEntryChildren"][0]
        arm_io["IORegistryEntryChildren"] = []
        device_tree["unrelated-property"] = {"IORegistryEntryName": "mcc", **fake_node}
        with self.assertRaisesRegex(AUDIT.AuditError, "missing_mcc"):
            AUDIT.audit_tree(fake)

    def test_malformed_and_truncated_reg_are_safe_errors(self) -> None:
        tree = make_tree()
        mcc = tree["IORegistryEntryChildren"][0]["IORegistryEntryChildren"][1]["IORegistryEntryChildren"][0]
        mcc["reg"] = mcc["reg"][:-1]
        code, report, text = run_cli(plist_bytes(tree))
        self.assertEqual(code, 1)
        self.assertEqual(report, {"schema_version": 1, "status": "error", "error": {"code": "truncated_reg"}})
        self.assertNotIn("DO_NOT_LEAK_THIS", text)

    def test_unexpected_count_and_geometry_fail_closed(self) -> None:
        short = make_tree(sizes=list(AUDIT.EXPECTED_HEADER_SIZES) + [AUDIT.EXPECTED_INSTANCE_SIZE] * 15)
        with self.assertRaisesRegex(AUDIT.AuditError, "unexpected_reg_count"):
            AUDIT.audit_tree(short)
        wrong_sizes = list(AUDIT.EXPECTED_HEADER_SIZES) + [AUDIT.EXPECTED_INSTANCE_SIZE] * 15 + [0x1000]
        with self.assertRaisesRegex(AUDIT.AuditError, "unexpected_instance_geometry"):
            AUDIT.audit_tree(make_tree(sizes=wrong_sizes))

    def test_overlap_and_translation_mismatch_fail_closed(self) -> None:
        overlap = make_tree(address_override={1: 0x100000100})
        with self.assertRaisesRegex(AUDIT.AuditError, "invalid_reg_ranges"):
            AUDIT.audit_tree(overlap)
        mismatch = make_tree()
        mismatch["IORegistryEntryChildren"][0]["IORegistryEntryChildren"][1]["IORegistryEntryChildren"][0]["IODeviceMemory"][4][0]["length"] = 0x1000
        with self.assertRaisesRegex(AUDIT.AuditError, "reg_iodevicememory_size_mismatch"):
            AUDIT.audit_tree(mismatch)

    def test_u64_overflow_and_nonbytes_reg_fail_closed(self) -> None:
        overflow = make_tree(address_override={0: (1 << 64) - 1})
        with self.assertRaisesRegex(AUDIT.AuditError, "invalid_reg_ranges"):
            AUDIT.audit_tree(overflow)
        malformed = make_tree()
        malformed["IORegistryEntryChildren"][0]["IORegistryEntryChildren"][1]["IORegistryEntryChildren"][0]["reg"] = "not-data"
        with self.assertRaisesRegex(AUDIT.AuditError, "malformed_reg"):
            AUDIT.audit_tree(malformed)

    def test_cli_success_is_allowlisted_json(self) -> None:
        code, report, text = run_cli(plist_bytes(make_tree()))
        self.assertEqual(code, 0)
        self.assertEqual(report["identity"], {"target": "J575d", "chip_id": "0x6032"})
        self.assertNotIn("DO_NOT_LEAK_THIS", text)
        self.assertNotIn("100000000", text)

    def test_opposite_endian_reg_is_rejected(self) -> None:
        with self.assertRaisesRegex(AUDIT.AuditError, "invalid_reg_ranges"):
            AUDIT.audit_tree(make_tree(reg_endian="big"))

    def test_hierarchy_shape_and_depth_are_bounded(self) -> None:
        malformed = make_tree()
        malformed["IORegistryEntryChildren"][0]["IORegistryEntryChildren"] = "not-a-list"
        with self.assertRaisesRegex(AUDIT.AuditError, "malformed_hierarchy"):
            AUDIT.audit_tree(malformed)
        deep = {"IORegistryEntryName": "Root"}
        cursor = deep
        for index in range(AUDIT.MAX_TREE_DEPTH + 1):
            child = {"IORegistryEntryName": f"n{index}"}
            cursor["IORegistryEntryChildren"] = [child]
            cursor = child
        with self.assertRaisesRegex(AUDIT.AuditError, "hierarchy_limit"):
            AUDIT.audit_tree(deep)


if __name__ == "__main__":
    unittest.main()

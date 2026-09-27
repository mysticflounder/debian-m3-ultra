#!/usr/bin/env python3
"""Synthetic regression tests for audit-t6032-carveouts.py.

The fixtures are ordinary Python values only: this test never invokes ioreg,
reads MMIO, or depends on a host IORegistry capture.
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import pathlib
import plistlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "t6032_carveouts_under_test", ROOT / "scripts/audit-t6032-carveouts.py"
)
CARVEOUTS = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(CARVEOUTS)
MCC = CARVEOUTS.MCC


def node(name: str, children: list[dict] | None = None, **properties: object) -> dict:
    value = {"IORegistryEntryName": name, "IORegistryEntryChildren": children or []}
    value.update(properties)
    return value


def pair(base: int, size: int) -> bytes:
    return base.to_bytes(8, "little") + size.to_bytes(8, "little")


def fixture(
    *,
    target: object = "J575d",
    chip: object = 0x6032,
    chosen: list[dict] | None = None,
    mapping: dict | None = None,
) -> dict:
    if chosen is None:
        chosen = [
            node(
                "chosen",
                [node("carveout-memory-map", **(mapping if mapping is not None else {
                    "region-id-2": pair(0x100000, 0x2000),
                    "region-id-4": pair(0x200000, 0x4000),
                }))],
                **{"chip-id": chip},
            )
        ]
    device_tree = node("device-tree", chosen, **{"target-type": target})
    return node("Root", [device_tree])


def error_code(callable_obj, *args, **kwargs) -> str:
    with unittest.TestCase().assertRaises(MCC.AuditError) as raised:
        callable_obj(*args, **kwargs)
    return raised.exception.code


class CarveoutAuditTests(unittest.TestCase):
    def test_valid_le64_pairs_and_allowlist(self) -> None:
        secret = "must-not-appear"
        tree = fixture(mapping={
            "region-id-2": pair(0x123000, 0x3000),
            "region-id-4": pair(0x456000, 0x5000),
            "private-registry-field": secret,
        })
        tree["private-root-field"] = secret
        tree["IORegistryEntryChildren"][0]["private-dt-field"] = secret
        tree["IORegistryEntryChildren"][0]["IORegistryEntryClass"] = secret
        tree["IORegistryEntryChildren"][0]["IORegistryEntryChildren"][0]["private-chosen-field"] = secret
        report = CARVEOUTS.audit_tree(tree)
        encoded = json.dumps(report, sort_keys=True)
        self.assertEqual(report["status"], "ok")
        self.assertEqual(report["identity"], {"target": "J575d", "chip_id": "0x6032"})
        self.assertEqual([r["candidate_base"] for r in report["regions"]], ["0x123000", "0x456000"])
        self.assertEqual([r["candidate_size"] for r in report["regions"]], ["0x3000", "0x5000"])
        self.assertNotIn(secret, encoded)
        self.assertNotIn("private-registry-field", encoded)
        self.assertNotIn("IORegistryEntryClass", encoded)
        self.assertFalse(report["hardware_registers_accessed"])
        self.assertFalse(report["native_execution_performed"])

    def test_overlap_is_reported_not_rejected(self) -> None:
        report = CARVEOUTS.audit_tree(fixture(mapping={
            "region-id-2": pair(0x100000, 0x4000),
            "region-id-4": pair(0x102000, 0x4000),
        }))
        self.assertTrue(report["candidate_regions_overlap"])

    def test_saved_allowlisted_capture(self) -> None:
        report = json.loads((ROOT / "docs/inventory/t6032-carveouts-2026-09-26.json").read_text())
        for region in report["regions"]:
            base, size = CARVEOUTS.decode_region(bytes.fromhex(region["raw_hex"]))
            self.assertEqual(hex(base), region["candidate_base"])
            self.assertEqual(hex(size), region["candidate_size"])
            self.assertEqual(hex(base + size), region["candidate_end_exclusive"])
        self.assertFalse(report["tz_layout_validated"])

    def test_plist_roundtrip_and_root_shapes(self) -> None:
        expected = CARVEOUTS.audit_tree(fixture())
        for fmt in (plistlib.FMT_XML, plistlib.FMT_BINARY):
            parsed = MCC._load_plist(plistlib.dumps([fixture()], fmt=fmt))
            self.assertEqual(CARVEOUTS.audit_tree(parsed), expected)
        for malformed in ([], [fixture(), fixture()], [None], None, "Root"):
            self.assertEqual(error_code(CARVEOUTS.audit_tree, malformed), "unexpected_root")

    def test_missing_map_and_empty_map(self) -> None:
        chosen = node("chosen", **{"chip-id": 0x6032})
        self.assertEqual(error_code(CARVEOUTS.audit_tree, fixture(chosen=[chosen])),
                         "missing_or_duplicate_carveout_map")
        self.assertEqual(error_code(CARVEOUTS.audit_tree, fixture(mapping={})), "missing_required_region")

    def test_identity_and_structure_failures(self) -> None:
        self.assertEqual(error_code(CARVEOUTS.audit_tree, fixture(target="J516c")), "target_mismatch")
        self.assertEqual(error_code(CARVEOUTS.audit_tree, fixture(chip=0x6031)), "chip_mismatch")
        self.assertEqual(error_code(CARVEOUTS.audit_tree, fixture(chosen=[])), "missing_identity")
        duplicate = fixture()
        dt = duplicate["IORegistryEntryChildren"][0]
        dt["IORegistryEntryChildren"].append(dt["IORegistryEntryChildren"][0].copy())
        self.assertEqual(error_code(CARVEOUTS.audit_tree, duplicate), "missing_identity")
        duplicate_map = fixture()
        chosen = duplicate_map["IORegistryEntryChildren"][0]["IORegistryEntryChildren"][0]
        chosen["IORegistryEntryChildren"].append(chosen["IORegistryEntryChildren"][0].copy())
        self.assertEqual(error_code(CARVEOUTS.audit_tree, duplicate_map), "missing_or_duplicate_carveout_map")
        missing = fixture(mapping={"region-id-2": pair(0x100000, 0x2000)})
        self.assertEqual(error_code(CARVEOUTS.audit_tree, missing), "missing_required_region")

    def test_region_encoding_geometry_and_wrap_fail_closed(self) -> None:
        cases = [
            (b"", "invalid_region_encoding"),
            (b"x" * 15, "invalid_region_encoding"),
            (b"x" * 17, "invalid_region_encoding"),
            ([], "invalid_region_encoding"),
            (pair(0, 0x1000), "invalid_region_geometry"),
            (pair(0x1000, 0), "invalid_region_geometry"),
            (pair(0x1001, 0x1000), "invalid_region_geometry"),
            (pair(0x1000, 0x1001), "invalid_region_geometry"),
            (pair((1 << 64) - 0x1000, 0x2000), "region_address_wrap"),
            (pair((1 << 64) - 0x1000, 0x1000), "region_address_wrap"),
        ]
        for raw, expected in cases:
            with self.subTest(expected=expected, raw_type=type(raw).__name__):
                mapping = {"region-id-2": raw, "region-id-4": pair(0x200000, 0x1000)}
                self.assertEqual(error_code(CARVEOUTS.audit_tree, fixture(mapping=mapping)), expected)

    def test_hierarchy_and_plist_failures(self) -> None:
        malformed = {"IORegistryEntryName": "Root", "IORegistryEntryChildren": "not-a-list"}
        self.assertEqual(error_code(CARVEOUTS.audit_tree, malformed), "malformed_hierarchy")
        tail = node("tail")
        for index in range(MCC.MAX_TREE_DEPTH + 2):
            tail = node(f"depth-{index}", [tail])
        self.assertEqual(error_code(CARVEOUTS.audit_tree, tail), "hierarchy_limit")
        self.assertEqual(error_code(MCC._load_plist, b"not a plist"), "malformed_plist")

    def test_cli_errors_are_safe_and_timeout_is_validated_first(self) -> None:
        def run(argv: list[str], stdin: bytes = b"") -> tuple[int, dict, str]:
            class FakeStdin:
                buffer = io.BytesIO(stdin)

            old_stdin = __import__("sys").stdin
            output = io.StringIO()
            try:
                __import__("sys").stdin = FakeStdin()
                with contextlib.redirect_stdout(output):
                    code = CARVEOUTS.main(argv)
            finally:
                __import__("sys").stdin = old_stdin
            text = output.getvalue()
            return code, json.loads(text), text

        code, report, text = run(["/private/private-carveout-input-do-not-leak"])
        self.assertEqual(code, 1)
        self.assertEqual(report["error"], {"code": "input_unavailable"})
        self.assertNotIn("private-carveout-input-do-not-leak", text)
        code, report, _ = run(["-"], b"not a plist")
        self.assertEqual(code, 1)
        self.assertEqual(report["error"], {"code": "malformed_plist"})
        for timeout in ("0", "-1", "61", "nan", "inf"):
            with self.subTest(timeout=timeout):
                code, report, _ = run(["--timeout", timeout])
                self.assertEqual(code, 1)
                self.assertEqual(report["error"], {"code": "invalid_timeout"})


if __name__ == "__main__":
    result = unittest.main(verbosity=1, exit=False)
    if result.result.wasSuccessful():
        print(f"T6032 carveout tests passed: {result.result.testsRun} tests")
    raise SystemExit(0 if result.result.wasSuccessful() else 1)

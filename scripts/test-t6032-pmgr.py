#!/usr/bin/env python3
"""Hardware-free tests for the PMGR metadata allowlist and failure paths."""

import copy
import importlib.util
import json
import pathlib
import plistlib
import subprocess
import sys
import unittest

SCRIPT = pathlib.Path(__file__).with_name("audit-t6032-pmgr.py")
SPEC = importlib.util.spec_from_file_location("audit_pmgr", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


def fixture():
    pmgr = {"IORegistryEntryName": "pmgr", "private-sentinel": "DO_NOT_LEAK"}
    pmgr.update({name: (1).to_bytes(4, "little") for name in AUDIT.FEATURES})
    pmgr.update({name: bytes(length) for name, length in AUDIT.RAW_FIELDS.items()})
    pmgr["cluster-ctl-offset"] = (0x18000).to_bytes(4, "little")
    dt = {"IORegistryEntryName": "device-tree", "target-type": b"J575d\0",
          "IORegistryEntryChildren": [
              {"IORegistryEntryName": "chosen", "chip-id": (0x6032).to_bytes(4, "little")},
              {"IORegistryEntryName": "arm-io", "IORegistryEntryChildren": [pmgr]},
          ]}
    return {"IORegistryEntryName": "Root", "IORegistryEntryChildren": [dt]}, dt, pmgr


class Tests(unittest.TestCase):
    def test_capture_and_privacy(self):
        tree, _, _ = fixture()
        report = AUDIT.audit_tree(tree)
        self.assertEqual(report["schema_version"], 2)
        self.assertEqual(report["cluster_metadata"]["acc-cores"]["length"], 256)
        self.assertEqual(report["cluster_metadata"]["die-stride"]["length"], 8)
        self.assertEqual(report["cluster_metadata"]["cluster-ctl-offset"]["value_le_u32"], 0x18000)
        self.assertFalse(report["register_semantics_validated"])
        self.assertFalse(report["register_writes_performed"])
        self.assertNotIn("DO_NOT_LEAK", json.dumps(report))
        self.assertEqual(AUDIT.audit_tree([tree]), report)

    def test_target_and_chip(self):
        for key in ("target", "chip"):
            with self.subTest(key=key):
                tree, dt, _ = fixture()
                if key == "target":
                    dt["target-type"] = b"J516c\0"
                else:
                    dt["IORegistryEntryChildren"][0]["chip-id"] = (0x6031).to_bytes(4, "little")
                with self.assertRaises(AUDIT.AuditError):
                    AUDIT.audit_tree(tree)

    def test_missing_malformed_and_oversized_properties(self):
        for name in (*AUDIT.FEATURES, *AUDIT.RAW_FIELDS):
            for value in (None, "DO_NOT_LEAK", b"", bytes(513)):
                with self.subTest(name=name, kind=type(value).__name__):
                    tree, _, pmgr = fixture()
                    pmgr[name] = value
                    with self.assertRaises(AUDIT.AuditError):
                        AUDIT.audit_tree(tree)

    def test_missing_and_duplicate_node(self):
        for duplicate in (False, True):
            tree, dt, pmgr = fixture()
            dt["IORegistryEntryChildren"][1]["IORegistryEntryChildren"] = (
                [pmgr, copy.deepcopy(pmgr)] if duplicate else []
            )
            with self.assertRaises(AUDIT.AuditError):
                AUDIT.audit_tree(tree)

    def test_malformed_hierarchy(self):
        tree, dt, _ = fixture()
        dt["IORegistryEntryChildren"] = "DO_NOT_LEAK"
        with self.assertRaises(AUDIT.AuditError):
            AUDIT.audit_tree(tree)

    def test_cli_saved_plist(self):
        tree, _, _ = fixture()
        result = subprocess.run([sys.executable, str(SCRIPT), "-"], input=plistlib.dumps(tree),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "ok")
        self.assertNotIn(b"DO_NOT_LEAK", result.stdout)

    def test_cli_error_privacy(self):
        for args, raw in ((["-"], b"DO_NOT_LEAK"), (["--timeout", "nan", "-"], b"")):
            result = subprocess.run([sys.executable, str(SCRIPT), *args], input=raw,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(json.loads(result.stdout)["status"], "error")
            self.assertNotIn(b"DO_NOT_LEAK", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()

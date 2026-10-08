#!/usr/bin/env python3
"""Independent raw-capture audit of the disabled 822-record USB-mode DT."""

from __future__ import annotations

import copy
import importlib.util
import json
import pathlib
import subprocess
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def module(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot import {relative}")
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


BASE = module("frozen_fabric_dt_audit", "tests/test-j575d-phy-fabric-dt.py")
BUILDER = module("usb_common_dt_builder", "scripts/build-j575d-phy-usb-common-dt.py")
AUDIT_SHA = "9bf7cb7696a7adddd38513554916a809085422758c91a0a9d587a2fd7d132f55"


class USBCommonDTCandidateTests(BASE.FabricDTCandidateTests):
    """Retain the raw generic audit and add independent USB tuple checks."""

    @classmethod
    def setUpClass(cls):
        cls.fabric, cls.usb, cls.before, cls.capture, cls.decoded = BUILDER.load_inputs()
        if cls.fabric.sha(ROOT / "tests/test-j575d-phy-fabric-dt.py") != AUDIT_SHA:
            raise AssertionError("frozen raw-capture audit changed")
        result = subprocess.run([sys.executable, str(ROOT / "scripts/build-j575d-phy-usb-common-dt.py")],
                                cwd=ROOT, check=True, capture_output=True, text=True)
        cls.record = json.loads(result.stdout)
        cls.workspace = ROOT / cls.record["output"]
        cls.after = cls.usb.read_dtb(cls.workspace / "candidate.dtb")

    def audit(self, tree):
        trimmed = copy.deepcopy(tree)
        for port in self.decoded["ports"]:
            path = self.usb.symbol(tree, port["linux_label"])
            self.assertIn("apple,tunable-usb-common", tree[path], "USB property missing")
            expected = b"".join(self.expected_property(port, name) for name in (
                "tunable_AUS40CMN_SHM", "tunable_AUSPLL_CORE", "tunable_CIO4PLL_CORE"))
            self.assertEqual(len(expected), 144, "twelve source USB rows")
            self.assertEqual(tree[path]["apple,tunable-usb-common"], expected,
                             "USB raw bytes, core translation, masks, values or order changed")
            trimmed[path].pop("apple,tunable-usb-common")
        super().audit(trimmed)

    def test_usb_raw_groups_and_total_count(self):
        self.audit(self.after)
        total = 0
        for port in self.decoded["ports"]:
            path = self.usb.symbol(self.after, port["linux_label"])
            self.assertEqual(tuple(len(self.source_raw(port, name)) // 12 for name in (
                "tunable_AUS40CMN_SHM", "tunable_AUSPLL_CORE", "tunable_CIO4PLL_CORE")), (1, 7, 4))
            for name in ("apple,tunable-axi2af", "apple,tunable-fabric",
                         "apple,tunable-common-b", "apple,tunable-usb-common"):
                total += len(self.after[path][name]) // 12
        self.assertEqual(total, 822)
        self.assertEqual(self.record["usb_common_records"], 72)
        self.assertEqual(self.record["changed_properties"], 42)
        manifest = json.loads((self.workspace / "manifest.json").read_text())
        self.assertEqual(manifest["cio80_default_records_unconverted"], 30)
        self.assertEqual(manifest["usb2_records_unconverted"], 12)
        self.assertFalse(manifest["native_validated"])
        self.assertFalse(manifest["mmio_performed"])
        self.assertFalse(manifest["numeric_native_enum_identity_claimed"])

    def test_usb_fixture_mutations_are_rejected(self):
        path = self.port(1)[1]
        prop = "apple,tunable-usb-common"
        raw = self.after[path][prop]
        mutants = {
            "missing": None,
            "empty": b"",
            "partial row": raw[:-4],
            "group order": raw[12:] + raw[:12],
            "endian": b"".join(raw[i:i+4][::-1] for i in range(0, len(raw), 4)),
            "wrong mask": raw[:4] + b"\0" * 4 + raw[8:],
            "wrong value": raw[:8] + b"\0" * 4 + raw[12:],
            "wrong base": b"\0\0\0\3" + raw[4:],
        }
        for name, value in mutants.items():
            with self.subTest(name=name):
                mutant = copy.deepcopy(self.after)
                if value is None:
                    mutant[path].pop(prop)
                else:
                    mutant[path][prop] = value
                with self.assertRaises(AssertionError):
                    self.audit(mutant)

    def test_builder_rejects_out_of_core_and_unaligned_records(self):
        core = next(window for window in self.decoded["ports"][0]["linux_windows"]
                    if window["name"] == "core")
        for address in (core["base"] - 4, core["base"] + core["size"], core["base"] + 1):
            with self.subTest(address=address):
                decoded = copy.deepcopy(self.decoded)
                block = next(block for block in decoded["ports"][0]["blocks"]
                             if block["source_property"] == "tunable_AUS40CMN_SHM")
                block["records"][0]["physical_address"] = address
                with self.assertRaises(self.fabric.CandidateError):
                    BUILDER.plan(self.fabric, self.usb, self.before, decoded)

    def test_builder_rejects_partial_groups_and_existing_usb_property(self):
        for name in ("tunable_AUS40CMN_SHM", "tunable_AUSPLL_CORE", "tunable_CIO4PLL_CORE"):
            with self.subTest(group=name):
                decoded = copy.deepcopy(self.decoded)
                block = next(block for block in decoded["ports"][0]["blocks"]
                             if block["source_property"] == name)
                block["records"].pop()
                with self.assertRaises(BUILDER.CandidateError):
                    BUILDER.plan(self.fabric, self.usb, self.before, decoded)
        before = copy.deepcopy(self.before)
        path = self.usb.symbol(before, self.decoded["ports"][0]["linux_label"])
        before[path]["apple,tunable-usb-common"] = b"\0" * 12
        with self.assertRaises(BUILDER.CandidateError):
            BUILDER.plan(self.fabric, self.usb, before, self.decoded)

    def test_second_cli_is_byte_identical(self):
        result = subprocess.run([sys.executable, str(ROOT / "scripts/build-j575d-phy-usb-common-dt.py")],
                                cwd=ROOT, check=True, capture_output=True, text=True)
        record = json.loads(result.stdout)
        second = ROOT / record["output"] / "candidate.dtb"
        self.assertEqual((self.workspace / "candidate.dtb").read_bytes(), second.read_bytes())
        self.assertEqual(self.fabric.sha(second), record["dtb_sha256"])
        # New receipts only: the frozen Fabric suite's pinned log is untouched.
        (self.workspace / "cli-reproducibility.json").write_text(json.dumps({
            "first": str(self.workspace.relative_to(ROOT)), "second": record["output"],
            "sha256": record["dtb_sha256"]}, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)

#!/usr/bin/env python3
"""Offline tests for the six-port named USB2 event-resource candidate."""
from __future__ import annotations

import copy
import importlib.util
import json
import pathlib
import struct
import subprocess
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
BUILDER_PATH = ROOT / "scripts/build-j575d-phy-usb2-event-dt.py"


def module(path: pathlib.Path):
    spec = importlib.util.spec_from_file_location("j575d_usb2_event_builder", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(path)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


B = module(BUILDER_PATH)
EXPECTED_PHYSICAL = {
    0: (0x702800000, 0x4000), 1: (0xB02800000, 0x4000),
    2: (0xF02800000, 0x4000), 3: (0x1302800000, 0x4000),
    4: (0x2702800000, 0x4000), 5: (0x2B02800000, 0x4000),
}


class USB2EventDTTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.layout, cls.before, cls.captured, _ = B.load_inputs()
        cls.changes = B.plan(cls.layout, cls.before, cls.captured)
        cls.after = copy.deepcopy(cls.before)
        for path, props in cls.changes.items():
            cls.after[path].update(props)

    def test_six_named_banks_and_die1_translation(self):
        counts = B.validate(self.layout, self.before, self.after, self.captured)
        self.assertEqual(counts["event_nodes"], 6)
        self.assertEqual(counts["changed_properties_relative_common"], 12)
        self.assertEqual(counts["changed_properties_relative_original"], 42)
        for port, label in enumerate(B.PORT_LABELS):
            path = self.layout.symbol(self.after, label)
            self.assertEqual(self.layout.strings(self.before[path]["compatible"]),
                             ("apple,t6031-atcphy", "apple,t8122-atcphy"))
            self.assertEqual(len(self.before[path]["reg"]), 6 * 16)
            self.assertEqual(len(self.after[path]["reg"]), 7 * 16)
            self.assertEqual(self.layout.strings(self.after[path]["reg-names"])[-1], B.EVENT_NAME)
            self.assertEqual(self.layout.translated_regs(self.after, path)[-1], EXPECTED_PHYSICAL[port])
            self.assertEqual(self.after[path]["status"], b"disabled\0")
        inherited = self.layout.symbol(self.after, "atcphy2_die1")
        self.assertNotIn(B.EVENT_NAME, self.layout.strings(self.after[inherited]["reg-names"]))
        self.assertEqual(self.after[inherited]["status"], b"disabled\0")

    def test_wrong_bank_and_swapped_port_rejected(self):
        wrong = dict(self.captured)
        wrong[0] = (wrong[0][0] + 0x800000, wrong[0][1])
        with self.assertRaises(B.CandidateError):
            B.plan(self.layout, self.before, wrong)
        swapped = dict(self.captured)
        swapped[0], swapped[1] = swapped[1], swapped[0]
        with self.assertRaises(B.CandidateError):
            B.plan(self.layout, self.before, swapped)

    def test_changed_status_unknown_label_name_and_existing_event_rejected(self):
        disabled = copy.deepcopy(self.before)
        path = self.layout.symbol(disabled, B.PORT_LABELS[0])
        disabled[path]["status"] = b"okay\0"
        with self.assertRaises(B.CandidateError):
            B.plan(self.layout, disabled, self.captured)

        wrong_name = copy.deepcopy(self.before)
        path = self.layout.symbol(wrong_name, B.PORT_LABELS[0])
        wrong_name[path]["reg-names"] = b"core\0lpdptx\0axi2af\0usb2phy\0pipehandler\0wrong\0"
        with self.assertRaises(B.CandidateError):
            B.plan(self.layout, wrong_name, self.captured)

        existing = copy.deepcopy(self.before)
        path = self.layout.symbol(existing, B.PORT_LABELS[0])
        existing[path]["reg-names"] += B.EVENT_NAME.encode() + b"\0"
        with self.assertRaises(B.CandidateError):
            B.plan(self.layout, existing, self.captured)

        unknown = copy.deepcopy(self.before)
        unknown["/__symbols__"].pop(B.PORT_LABELS[0])
        with self.assertRaises(self.layout.BuildError):
            B.plan(self.layout, unknown, self.captured)

    def test_wrong_translated_output_and_inherited_edit_rejected(self):
        mutant = copy.deepcopy(self.after)
        path = self.layout.symbol(mutant, B.PORT_LABELS[0])
        words = list(struct.unpack(">28I", mutant[path]["reg"]))
        words[-4] += 0x800000
        mutant[path]["reg"] = struct.pack(">28I", *words)
        with self.assertRaises(B.CandidateError):
            B.validate(self.layout, self.before, mutant, self.captured)

        inherited = copy.deepcopy(self.after)
        path = self.layout.symbol(inherited, "atcphy2_die1")
        inherited[path]["status"] = b"okay\0"
        with self.assertRaises(B.CandidateError):
            B.validate(self.layout, self.before, inherited, self.captured)

    def test_cli_manifest_and_roundtrip(self):
        run = subprocess.run([sys.executable, str(BUILDER_PATH)], cwd=ROOT,
                             capture_output=True, text=True, check=True)
        record = json.loads(run.stdout)
        self.assertEqual(record["event_nodes"], 6)
        self.assertEqual(record["changed_properties_relative_common"], 12)
        work = ROOT / record["output"]
        manifest = json.loads((work / "manifest.json").read_text())
        self.assertTrue(manifest["reservations_preserved"])
        self.assertTrue(manifest["roundtrip_tree_identical"])
        self.assertEqual(manifest["event_reg_bytes"], 16)
        self.assertEqual(manifest["layout_script_sha256"], B.LAYOUT_SCRIPT_SHA)
        self.assertEqual(manifest["pcie_script_sha256"], B.PCIE_SCRIPT_SHA)
        self.assertEqual(manifest["changed_properties_relative_original"], 42)
        self.assertEqual(manifest["labels"], list(B.PORT_LABELS))
        self.assertEqual(manifest["event_name"], B.EVENT_NAME)


if __name__ == "__main__":
    unittest.main(verbosity=2)

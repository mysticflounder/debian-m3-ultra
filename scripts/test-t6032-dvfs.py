#!/usr/bin/env python3
"""Portable negative/allowlist tests for DVFS metadata, without host access."""
import importlib.util
import json
import pathlib
import plistlib
import subprocess
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


AUDIT = load("audit_dvfs", "audit-t6032-dvfs.py")
FIX = load("pmgr_fixtures", "test-t6032-pmgr.py")
ADT = load("adt_fixtures", "test-firmware-mcc.py")


def fields():
    result = {name: (4).to_bytes(4, "little") for name in AUDIT.SCALARS}
    result.update({name: bytes(8) for name in (*AUDIT.REQUIRED_TABLES, *AUDIT.OTHER)})
    result["perf-domains"] = b"".join(bytes((selector, 1, 1, domain)) + bytes(24)
                                      for domain, selector in AUDIT.CPU_TABLE_SELECTORS)
    return result


def fixture():
    tree, dt, pmgr = FIX.fixture()
    pmgr.update(fields())
    return tree, dt, pmgr


def firmware(*, target="J575d", model="Mac15,14", compatible="pmgr1,t6031", chip=0):
    pmgr = ADT.node("pmgr", [("compatible", ADT.string(compatible)), *fields().items(),
                              ("serial-number", ADT.string("PRIVATE-SENTINEL"))])
    tree = ADT.node("device-tree", [("target-type", ADT.string(target)),
                                     ("model", ADT.string(model))],
                    [ADT.node("chosen", [("chip-id", ADT.scalar(chip))]),
                     ADT.node("arm-io", children=[pmgr])])
    return ADT.encode(tree)


class Tests(unittest.TestCase):
    def test_capture_and_allowlist(self):
        tree, _, pmgr = fixture()
        pmgr["voltage-states5-sram"] = bytes(16)
        pmgr["voltage-states99"] = b"PRIVATE-SENTINEL"
        result = AUDIT.audit_tree(tree)
        self.assertEqual(result["properties"]["first-acc-dvfm-map-state"]["value_le_u32"], 4)
        self.assertIn("voltage-states5-sram", result["properties"])
        self.assertNotIn("voltage-states5-sram", result["absent_optional_properties"])
        self.assertIn("voltage-states34", result["absent_optional_properties"])
        for sentinel in ("PRIVATE-SENTINEL", "DO_NOT_LEAK", "serial-number", "voltage-states99"):
            self.assertNotIn(sentinel, json.dumps(result))
        self.assertFalse(result["hardware_validated"])
        self.assertFalse(result["register_writes_performed"])
        self.assertFalse(result["table_word_semantics_validated"])
        self.assertFalse(result["state_count_inferred"])
        self.assertFalse(result["safe_initial_states_established"])

    def test_source_labels(self):
        tree, _, _ = fixture()
        self.assertEqual(AUDIT.audit_tree([tree])["source_kind"], "supplied IODeviceTree plist")
        self.assertEqual(AUDIT.audit_tree(tree, live=True)["source_kind"], "live IODeviceTree")

    def test_die1_selector_candidates_are_not_domain_offsets(self):
        tree, _, pmgr = fixture()
        for name in ("voltage-states33", "voltage-states33-sram", "voltage-states33-extra",
                     "voltage-states37", "voltage-states45"):
            pmgr[name] = bytes(16)
        pmgr["voltage-states34"] = bytes(8)
        result = AUDIT.audit_tree(tree)
        candidates = result["die1_table_selector_candidates"]
        self.assertEqual([(r["base_selector"], r["die1_selector"]) for r in candidates],
                         [(1, 33), (5, 37), (13, 45)])
        self.assertEqual([r["die1_property"] for r in candidates],
                         ["voltage-states33", "voltage-states37", "voltage-states45"])
        self.assertTrue(all(r["present"] for r in candidates))
        self.assertIn("voltage-states33-sram", result["properties"])
        self.assertIn("voltage-states33-extra", result["properties"])
        self.assertFalse(result["die1_runtime_application_validated"])
        self.assertFalse(result["safe_initial_states_established"])

    def test_die1_tables_remain_optional(self):
        tree, _, pmgr = fixture()
        pmgr["voltage-states34"] = bytes(8)
        result = AUDIT.audit_tree(tree)
        self.assertFalse(any(r["present"] for r in result["die1_table_selector_candidates"]))
        self.assertIn("voltage-states33", result["absent_optional_properties"])
        self.assertIn("voltage-states34", result["properties"])

    def test_die1_table_cannot_replace_required_base(self):
        tree, _, pmgr = fixture()
        del pmgr["voltage-states1"]
        pmgr["voltage-states33"] = bytes(8)
        with self.assertRaises(AUDIT.AuditError):
            AUDIT.audit_tree(tree)

    def test_required_properties(self):
        for name in (*AUDIT.REQUIRED_TABLES, *AUDIT.SCALARS, *AUDIT.OTHER):
            with self.subTest(name=name):
                tree, _, pmgr = fixture()
                del pmgr[name]
                with self.assertRaises(AUDIT.AuditError):
                    AUDIT.audit_tree(tree)

    def test_ep_table_selector_is_not_domain_id(self):
        tree, _, pmgr = fixture()
        self.assertNotIn("voltage-states2", pmgr)
        report = AUDIT.audit_tree(tree)
        self.assertEqual(report["schema_version"], 2)
        self.assertIn("voltage-states1", report["properties"])
        self.assertIn("voltage-states2", report["absent_optional_properties"])
        self.assertEqual(report["cpu_table_selectors"][0], {
            "descriptor_index": 0, "domain_id_byte3": 2, "table_selector_byte0": 1,
            "conversion_mode_byte2": 1, "base_property": "voltage-states1"})
        del pmgr["voltage-states1"]
        pmgr["voltage-states2"] = bytes(8)
        with self.assertRaises(AUDIT.AuditError):
            AUDIT.audit_tree(tree)

    def test_cpu_descriptor_layout_is_fail_closed(self):
        original = fields()["perf-domains"]
        for bad in (original[:-4], original[28:], original + original[:28],
                    bytes((2, 1, 1, 2)) + original[4:],
                    bytes((1, 1, 0, 2)) + original[4:]):
            tree, _, pmgr = fixture()
            pmgr["perf-domains"] = bad
            with self.subTest(raw=bad.hex()), self.assertRaises(AUDIT.AuditError):
                AUDIT.audit_tree(tree)

    def test_cpu_descriptor_order_is_not_assumed(self):
        tree, _, pmgr = fixture()
        raw = pmgr["perf-domains"]
        pmgr["perf-domains"] = raw[56:] + raw[28:56] + raw[:28]
        selectors = AUDIT.audit_tree(tree)["cpu_table_selectors"]
        self.assertEqual([r["descriptor_index"] for r in selectors], [2, 1, 0])
        self.assertEqual([r["base_property"] for r in selectors],
                         ["voltage-states1", "voltage-states5", "voltage-states13"])

    def test_bad_property_values(self):
        for name in (*AUDIT.SCALARS, *AUDIT.TABLES, *AUDIT.OTHER):
            for value in (None, True, 1, "PRIVATE-SENTINEL", b"", b"abc", bytes(4100)):
                with self.subTest(name=name, kind=type(value).__name__):
                    tree, _, pmgr = fixture()
                    pmgr[name] = value
                    with self.assertRaises(AUDIT.AuditError):
                        AUDIT.audit_tree(tree)

    def test_exact_scalar_size(self):
        for name in AUDIT.SCALARS:
            tree, _, pmgr = fixture()
            pmgr[name] = bytes(8)
            with self.assertRaises(AUDIT.AuditError):
                AUDIT.audit_tree(tree)

    def test_voltage_record_alignment(self):
        for name in AUDIT.TABLES:
            if name.endswith("-extra"):
                continue
            for length in (4, 12):
                tree, _, pmgr = fixture()
                pmgr[name] = bytes(length)
                with self.subTest(name=name, length=length), self.assertRaises(AUDIT.AuditError):
                    AUDIT.audit_tree(tree)

    def test_table_boundary_without_interpretation(self):
        tree, _, pmgr = fixture()
        pmgr["voltage-states5-extra"] = bytes(76)
        pmgr["voltage-states37"] = bytes(4096)
        report = AUDIT.audit_tree(tree)
        self.assertEqual(report["properties"]["voltage-states5-extra"]["length"], 76)
        self.assertEqual(report["properties"]["voltage-states37"]["length"], 4096)

    def test_wrong_live_identity(self):
        tree, dt, _ = fixture()
        dt["IORegistryEntryChildren"][0]["chip-id"] = (0).to_bytes(4, "little")
        with self.assertRaises(AUDIT.AuditError):
            AUDIT.audit_tree(tree)

    def test_missing_duplicate_path(self):
        for duplicate in (False, True):
            tree, dt, pmgr = fixture()
            dt["IORegistryEntryChildren"][1]["IORegistryEntryChildren"] = [pmgr, pmgr.copy()] if duplicate else []
            with self.assertRaises(AUDIT.AuditError):
                AUDIT.audit_tree(tree)

    def test_template_placeholder_not_live_identity(self):
        report = AUDIT.audit_adt(firmware())
        self.assertEqual(report["identity"]["template_chip_id"], "0x0")
        self.assertNotIn("chip_id", report["identity"])
        self.assertIn("not live", report["source_kind"])
        self.assertNotIn("PRIVATE-SENTINEL", json.dumps(report))

    def test_wrong_template_identity(self):
        for options in ({"target": "J516c"}, {"model": "Mac15,9"}, {"compatible": "pmgr1,t6022"}):
            with self.subTest(options=options), self.assertRaises(ValueError):
                AUDIT.audit_adt(firmware(**options))

    def test_truncated_template(self):
        with self.assertRaises(ValueError):
            AUDIT.audit_adt(firmware()[:-1])

    def test_cli_no_live_opt_in(self):
        tree, _, _ = fixture()
        result = subprocess.run([sys.executable, str(ROOT / "audit-t6032-dvfs.py"), "--plist", "-"],
                                input=plistlib.dumps(tree), capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(json.loads(result.stdout)["source_kind"], "supplied IODeviceTree plist")

    def test_cli_error_is_sanitized(self):
        for args, data in ((["--plist", "-"], b"PRIVATE-SENTINEL"),
                           (["--plist", "-", "--timeout", "nan"], b""),
                           (["--plist", "-", "--timeout", "61"], b"")):
            result = subprocess.run([sys.executable, str(ROOT / "audit-t6032-dvfs.py"), *args],
                                    input=data, capture_output=True, check=False)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, b"")
            self.assertNotIn("PRIVATE-SENTINEL", result.stderr.decode())
            self.assertNotIn("Traceback", result.stderr.decode())
            self.assertEqual(json.loads(result.stderr)["status"], "error")


if __name__ == "__main__":
    unittest.main()

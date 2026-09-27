#!/usr/bin/env python3
"""Synthetic regression for allowlisted CPU-start metadata capture."""

import copy
import importlib.util
import json
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


AUDIT = load("startup_audit", "audit-t6032-startup.py")
FIXTURE = load("cpu_fixture", "test-t6032-cpus.py")


def fixture():
    root = FIXTURE.make_tree()
    cpus = root["IORegistryEntryChildren"][0]["IORegistryEntryChildren"][1]
    for index, node in enumerate(cpus["IORegistryEntryChildren"]):
        node["state"] = b"running\0" if index == 4 else b"waiting\0"
        node["cpu-impl-reg"] = (0x200000000 + index * 0x10000).to_bytes(8, "little") + (0x9010).to_bytes(8, "little")
    return root, cpus["IORegistryEntryChildren"]


class Tests(unittest.TestCase):
    def test_valid_and_allowlisted(self):
        root, _ = fixture()
        report = AUDIT.audit_tree(root)
        self.assertEqual(report["cpu_count"], 32)
        self.assertEqual(report["running_cpu_id"], 4)
        self.assertNotIn("DO_NOT_LEAK_THIS", json.dumps(report))
        for key in ("hardware_validated", "implementation_registers_read",
                    "register_writes_performed", "mpidr_mapping_validated"):
            self.assertIs(report[key], False)

    def test_order_independent(self):
        root, nodes = fixture()
        expected = AUDIT.audit_tree(root)
        nodes.reverse()
        self.assertEqual(AUDIT.audit_tree(root), expected)

    def test_invalid_states(self):
        for state in (None, b"running", b"running\0extra", b"unknown\0", "running"):
            root, nodes = fixture()
            nodes[4]["state"] = state
            with self.subTest(state=state), self.assertRaises(AUDIT.AuditError):
                AUDIT.audit_tree(root)

    def test_zero_or_multiple_running(self):
        for index, state in ((4, b"waiting\0"), (31, b"running\0")):
            root, nodes = fixture()
            nodes[index]["state"] = state
            with self.subTest(index=index), self.assertRaises(AUDIT.AuditError):
                AUDIT.audit_tree(root)

    def test_impl_lengths(self):
        for value in (None, b"", bytes(15), bytes(17), "invalid"):
            root, nodes = fixture()
            nodes[31]["cpu-impl-reg"] = value
            with self.subTest(value=value), self.assertRaises(AUDIT.AuditError):
                AUDIT.audit_tree(root)

    def test_impl_range_errors(self):
        for base, size in ((0, 0x9010), (0x200010001, 0x9010),
                           (0x300000000, 0x107), ((1 << 64) - 0x1000, 0x2000)):
            root, nodes = fixture()
            nodes[31]["cpu-impl-reg"] = base.to_bytes(8, "little") + size.to_bytes(8, "little")
            with self.subTest(base=base, size=size), self.assertRaises(AUDIT.AuditError):
                AUDIT.audit_tree(root)

    def test_overlap(self):
        root, nodes = fixture()
        nodes[31]["cpu-impl-reg"] = nodes[0]["cpu-impl-reg"]
        with self.assertRaisesRegex(AUDIT.AuditError, "overlapping"):
            AUDIT.audit_tree(root)

    def test_existing_topology_guards(self):
        root, nodes = fixture()
        nodes[31]["cpu-id"] = copy.copy(nodes[0]["cpu-id"])
        with self.assertRaises(AUDIT.AuditError):
            AUDIT.audit_tree(root)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Synthetic tests for audit-t6032-cpus.py."""

from __future__ import annotations

import importlib.util
import json
import pathlib
import plistlib
import subprocess
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
AUDIT_PATH = ROOT / "scripts" / "audit-t6032-cpus.py"
SPEC = importlib.util.spec_from_file_location("audit_t6032_cpus", AUDIT_PATH)
assert SPEC is not None and SPEC.loader is not None
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


def u32(value: int, endian: str = "little") -> bytes:
    return value.to_bytes(4, endian)


def make_tree(
    *,
    target: str = "J575d",
    chip_id: int = 0x6032,
    reg_endian: str = "little",
    cpu_count: int = 32,
) -> dict:
    cpu_nodes = []
    for cpu_id in range(cpu_count):
        die = cpu_id // 16
        local = cpu_id % 16
        if local < 4:
            cluster, core, cluster_type, compatible = 0, local, "E", "apple,sawtooth"
        elif local < 10:
            cluster, core, cluster_type, compatible = 1, local - 4, "P", "apple,everest"
        else:
            cluster, core, cluster_type, compatible = 2, local - 10, "P", "apple,everest"
        reg = (die << 11) | (cluster << 8) | core
        cpu_nodes.append(
            {
                "IORegistryEntryName": f"cpu{cpu_id}",
                "cpu-id": u32(cpu_id),
                "reg": u32(reg, reg_endian),
                "die-id": u32(die),
                "die-cluster-id": u32(cluster),
                "cluster-core-id": u32(core),
                "cluster-type": cluster_type.encode("ascii") + b"\x00",
                "compatible": compatible.encode("ascii") + b"\x00",
                "private-sentinel": "DO_NOT_LEAK_THIS",
            }
        )
    return {
        "IORegistryEntryName": "Root",
        "IORegistryEntryChildren": [
            {
                "IORegistryEntryName": "device-tree",
                "target-type": target.encode("ascii") + b"\x00",
                "IORegistryEntryChildren": [
                    {
                        "IORegistryEntryName": "chosen",
                        "chip-id": u32(chip_id),
                    },
                    {
                        "IORegistryEntryName": "cpus",
                        "max_cpus": u32(32),
                        "cpu-cluster-count": u32(3),
                        "IORegistryEntryChildren": cpu_nodes,
                    },
                ],
            }
        ],
    }


def run_cli(tree: dict) -> tuple[int, dict, str]:
    completed = subprocess.run(
        [sys.executable, str(AUDIT_PATH), "-"],
        input=plistlib.dumps(tree, fmt=plistlib.FMT_XML),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    text = completed.stdout.decode("utf-8")
    return completed.returncode, json.loads(text), text


def cpu_nodes(tree: dict) -> list[dict]:
    return tree["IORegistryEntryChildren"][0]["IORegistryEntryChildren"][1]["IORegistryEntryChildren"]


class T6032CpuAuditTests(unittest.TestCase):
    def test_valid_topology_and_boundaries(self) -> None:
        report = AUDIT.audit_tree(make_tree())
        topology = report["topology"]
        self.assertEqual(topology["cpu_count"], 32)
        observed_ids = {cpu["cpu_id"] for cpu in topology["affinity"]}
        self.assertEqual(observed_ids, set(range(32)))
        for boundary in (0, 23, 24, 31):
            self.assertIn(boundary, observed_ids)
        self.assertEqual(
            [(group["die"], group["cluster_type"], group["cpu_count"]) for group in topology["groups"]],
            [(0, "E", 4), (0, "P", 6), (0, "P", 6), (1, "E", 4), (1, "P", 6), (1, "P", 6)],
        )
        self.assertTrue(report["topology_validated"])
        self.assertFalse(report["cpu_release_validated"])
        self.assertFalse(report["hardware_validated"])
        self.assertFalse(report["register_writes_performed"])

    def test_shuffled_nodes_preserve_ids(self) -> None:
        tree = make_tree()
        nodes = cpu_nodes(tree)
        nodes[0], nodes[31] = nodes[31], nodes[0]
        report = AUDIT.audit_tree(tree)
        self.assertEqual([cpu["cpu_id"] for cpu in report["topology"]["affinity"]], list(range(32)))

    def test_identity_mismatch_and_missing_die_fail(self) -> None:
        for tree in (make_tree(target="J575c"), make_tree(chip_id=0x6031), make_tree(cpu_count=24)):
            with self.assertRaises(AUDIT.AuditError):
                AUDIT.audit_tree(tree)
        missing24 = make_tree()
        cpu_nodes(missing24)[:] = [node for node in cpu_nodes(missing24) if node["IORegistryEntryName"] != "cpu24"]
        with self.assertRaisesRegex(AUDIT.AuditError, "unexpected_cpu_count"):
            AUDIT.audit_tree(missing24)

    def test_duplicate_and_thirty_third_cpu_fail(self) -> None:
        duplicate = make_tree()
        cpu_nodes(duplicate)[1]["cpu-id"] = u32(0)
        with self.assertRaisesRegex(AUDIT.AuditError, "duplicate_cpu_id"):
            AUDIT.audit_tree(duplicate)
        duplicate_affinity = make_tree()
        node = cpu_nodes(duplicate_affinity)[1]
        node["reg"] = u32(0)
        node["die-id"] = u32(0)
        node["die-cluster-id"] = u32(0)
        node["cluster-core-id"] = u32(0)
        with self.assertRaisesRegex(AUDIT.AuditError, "duplicate_cpu_affinity"):
            AUDIT.audit_tree(duplicate_affinity)
        extra = make_tree(cpu_count=33)
        with self.assertRaisesRegex(AUDIT.AuditError, "unexpected_cpu_count"):
            AUDIT.audit_tree(extra)

    def test_type_and_compatibility_mismatch_fail(self) -> None:
        wrong_type = make_tree()
        cpu_nodes(wrong_type)[0]["cluster-type"] = b"P\x00"
        with self.assertRaisesRegex(AUDIT.AuditError, "cpu_compatible_mismatch"):
            AUDIT.audit_tree(wrong_type)
        wrong_compat = make_tree()
        cpu_nodes(wrong_compat)[4]["compatible"] = b"apple,sawtooth\x00"
        with self.assertRaisesRegex(AUDIT.AuditError, "cpu_compatible_mismatch"):
            AUDIT.audit_tree(wrong_compat)
        mixed = make_tree()
        cpu_nodes(mixed)[1]["cluster-type"] = b"P\x00"
        cpu_nodes(mixed)[1]["compatible"] = b"apple,everest\x00"
        with self.assertRaisesRegex(AUDIT.AuditError, "mixed_cluster_type"):
            AUDIT.audit_tree(mixed)

    def test_reserved_reg_bits_fail(self) -> None:
        reserved = make_tree()
        cpu_nodes(reserved)[1]["reg"] = u32(0x8000)
        with self.assertRaisesRegex(AUDIT.AuditError, "invalid_cpu_reg"):
            AUDIT.audit_tree(reserved)

    def test_opposite_endian_reg_is_rejected(self) -> None:
        with self.assertRaisesRegex(AUDIT.AuditError, "invalid_cpu_reg"):
            AUDIT.audit_tree(make_tree(reg_endian="big"))

    def test_malformed_missing_and_privacy_error(self) -> None:
        malformed = make_tree()
        cpu_nodes(malformed)[0]["reg"] = b"short"
        code, report, text = run_cli(malformed)
        self.assertEqual(code, 1)
        self.assertEqual(report["error"]["code"], "malformed_cpu_property")
        self.assertNotIn("DO_NOT_LEAK_THIS", text)
        missing = make_tree()
        del cpu_nodes(missing)[0]["die-id"]
        with self.assertRaisesRegex(AUDIT.AuditError, "malformed_cpu_property"):
            AUDIT.audit_tree(missing)

    def test_unrelated_cpu_property_is_not_traversed(self) -> None:
        tree = make_tree()
        device_tree = tree["IORegistryEntryChildren"][0]
        cpus = device_tree["IORegistryEntryChildren"][1]
        fake = cpus["IORegistryEntryChildren"][0]
        cpus["IORegistryEntryChildren"] = []
        device_tree["unrelated-property"] = {"cpu0": fake}
        with self.assertRaisesRegex(AUDIT.AuditError, "unexpected_cpu_count"):
            AUDIT.audit_tree(tree)

    def test_cli_output_is_allowlisted(self) -> None:
        code, report, text = run_cli(make_tree())
        self.assertEqual(code, 0)
        self.assertEqual(report["identity"], {"target": "J575d", "chip_id": "0x6032"})
        self.assertNotIn("DO_NOT_LEAK_THIS", text)
        self.assertNotIn('"reg":', text)

    def test_malformed_node_names_are_safe_errors(self) -> None:
        for name in ("cpu" + "1" * 5000, "cpu00", "cpu32", "private-sentinel"):
            tree = make_tree()
            cpu_nodes(tree)[0]["IORegistryEntryName"] = name
            code, report, _ = run_cli(tree)
            self.assertEqual(code, 1)
            self.assertEqual(report["error"]["code"], "unexpected_cpu_node")

    def test_nonfinite_timeout_is_safe_error(self) -> None:
        data = plistlib.dumps(make_tree(), fmt=plistlib.FMT_XML)
        for timeout in ("nan", "inf", "-inf"):
            completed = subprocess.run(
                [sys.executable, str(AUDIT_PATH), f"--timeout={timeout}", "-"],
                input=data,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(completed.returncode, 1)
            report = json.loads(completed.stdout)
            self.assertEqual(report["error"]["code"], "invalid_timeout")


if __name__ == "__main__":
    unittest.main()

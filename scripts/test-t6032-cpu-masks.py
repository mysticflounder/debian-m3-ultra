#!/usr/bin/env python3
"""Host-only tests of the exact-board acc-cores comparison model."""

import copy
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("masks", ROOT / "scripts/model-t6032-cpu-masks.py")
MASKS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MASKS)


def fixture():
    pmgr = json.loads((ROOT / "docs/inventory/t6032-pmgr-cores-2026-09-26.json").read_text())
    cpus = json.loads((ROOT / "docs/inventory/t6032-cpus-2026-09-26.json").read_text())
    return pmgr, cpus


def change_bytes(pmgr, offset, value):
    field = pmgr["cluster_metadata"]["acc-cores"]
    data = bytearray.fromhex(field["raw_hex"])
    data[offset] = value
    field["raw_hex"] = data.hex()


class Tests(unittest.TestCase):
    def test_mode1_crosscheck_all_cpus(self):
        _, cpus = fixture()
        pmgr = json.loads((ROOT / "docs/inventory/t6032-pmgr-mode-2026-09-26.json").read_text())
        result = MASKS.model(pmgr, cpus)
        self.assertTrue(result["mode1_crosscheck_performed"])
        self.assertEqual(result["legacy_mismatch_count"], 12)
        for row in result["rows"]:
            self.assertEqual(row["mode1_group_plus_4_mask"], row["candidate_group_plus_4_mask"])
            self.assertEqual(row["mode1_cluster_masks"][row["cluster"]], row["candidate_cluster_mask"])
            self.assertEqual(sum(int(mask, 16) != 0 for mask in row["mode1_cluster_masks"]), 1)

    def test_mode1_wrong_selector_table_or_crosscheck_fails(self):
        for mutation in ("mode", "raw-mode", "width", "offset", "overflow", "zero-shift"):
            _, cpus = fixture()
            pmgr = json.loads((ROOT / "docs/inventory/t6032-pmgr-mode-2026-09-26.json").read_text())
            if mutation == "mode":
                pmgr["features"]["acc-harvesting"]["value_le_u32"] = 2
            elif mutation == "raw-mode":
                pmgr["features"]["acc-harvesting"]["raw_hex"] = "02000000"
            else:
                value = bytearray.fromhex(pmgr["cluster_metadata"]["clusters"]["raw_hex"])
                value[8 if mutation == "width" else 10] = (
                    32 if mutation == "overflow" else 0 if mutation == "zero-shift" else 5)
                pmgr["cluster_metadata"]["clusters"]["raw_hex"] = value.hex()
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                MASKS.model(pmgr, cpus)

    def test_mode1_rejects_zero_multicore_and_out_of_range_inputs(self):
        for mask in (0, -1, 3, 1 << 32, True):
            with self.subTest(mask=mask), self.assertRaises(ValueError):
                MASKS.mode1_single_cpu(mask, [4, 6, 6], [0, 4, 10])

    def test_all_32_masks_and_legacy_discrepancy(self):
        result = MASKS.model(*fixture())
        self.assertEqual(result["cpu_count"], 32)
        self.assertEqual(result["legacy_mismatch_count"], 12)
        self.assertEqual(len(result["legacy_alias_groups"]), 4)
        self.assertFalse(result["mode1_crosscheck_performed"])
        for row in result["rows"]:
            expected_shift = (0, 4, 10)[row["cluster"]] + row["core"]
            self.assertEqual(row["candidate_group_plus_4_mask"], hex(1 << expected_shift))
            self.assertEqual(row["candidate_cluster_mask"], hex(1 << row["core"]))
        for flag in ("register_semantics_validated", "register_writes_performed", "cpu_release_validated"):
            self.assertIs(result[flag], False)

    def test_record_order_does_not_define_cpu_id(self):
        pmgr, cpus = fixture()
        baseline = MASKS.model(pmgr, cpus)
        field = pmgr["cluster_metadata"]["acc-cores"]
        raw = bytes.fromhex(field["raw_hex"])
        field["raw_hex"] = b"".join(raw[i:i + 8] for i in range(248, -1, -8)).hex()
        cpus["topology"]["affinity"].reverse()
        permuted = MASKS.model(pmgr, cpus)
        for a, b in zip(baseline["rows"], permuted["rows"]):
            self.assertEqual({k: v for k, v in a.items() if k != "record_index"},
                             {k: v for k, v in b.items() if k != "record_index"})

    def test_duplicate_out_of_range_or_missing_shift(self):
        for offset, value in ((13, 0), (5, 32), (5, 31)):
            pmgr, cpus = fixture()
            change_bytes(pmgr, offset, value)
            with self.subTest(offset=offset, value=value), self.assertRaises(ValueError):
                MASKS.model(pmgr, cpus)

    def test_invalid_physical_ids(self):
        for offset, value in ((14, 0), (6, 6), (7, 3), (7, 16)):
            pmgr, cpus = fixture()
            change_bytes(pmgr, offset, value)
            with self.subTest(offset=offset, value=value), self.assertRaises(ValueError):
                MASKS.model(pmgr, cpus)

    def test_invalid_topology(self):
        for mutation in ("missing", "duplicate", "bad-id", "boolean", "wrong-core"):
            pmgr, cpus = fixture()
            rows = cpus["topology"]["affinity"]
            if mutation == "missing":
                rows.pop()
            elif mutation == "duplicate":
                rows[1] = copy.deepcopy(rows[0])
            elif mutation == "bad-id":
                rows[0]["cpu_id"] = 32
            elif mutation == "boolean":
                rows[0]["core"] = False
            else:
                rows[0]["core"] = 7
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                MASKS.model(pmgr, cpus)

    def test_shape_identity_schema_and_stride(self):
        for mutation in ("target", "schema", "length", "stride", "hex", "status"):
            pmgr, cpus = fixture()
            if mutation == "target":
                pmgr["identity"]["chip_id"] = "0x6031"
            elif mutation == "schema":
                pmgr["schema_version"] = 1
            elif mutation == "length":
                pmgr["cluster_metadata"]["acc-cores"]["length"] = 255
            elif mutation == "stride":
                pmgr["cluster_metadata"]["die-stride"]["raw_hex"] = "00" * 8
            elif mutation == "hex":
                pmgr["cluster_metadata"]["acc-cores"]["raw_hex"] = "not hex"
            else:
                cpus["status"] = "error"
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                MASKS.model(pmgr, cpus)

    def test_opaque_fields_and_unrelated_data_not_interpreted_or_exposed(self):
        pmgr, cpus = fixture()
        pmgr["private"] = "DO_NOT_LEAK"
        for index in range(32):
            for offset in range(5):
                change_bytes(pmgr, index * 8 + offset, 255)
        result = MASKS.model(pmgr, cpus)
        self.assertEqual(result["legacy_mismatch_count"], 12)
        self.assertNotIn("DO_NOT_LEAK", json.dumps(result))

    def test_input_limits_and_cli_error_privacy(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "scratch") as directory:
            path = pathlib.Path(directory) / "input"
            for content in (b"DO_NOT_LEAK", b" " * (1024 * 1024 + 1)):
                path.write_bytes(content)
                result = subprocess.run([sys.executable, str(ROOT / "scripts/model-t6032-cpu-masks.py"),
                                         str(path), str(path)], capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(json.loads(result.stdout)["status"], "error")
                self.assertNotIn(b"DO_NOT_LEAK", result.stdout + result.stderr)
            fifo = pathlib.Path(directory) / "fifo"
            os.mkfifo(fifo)
            with self.assertRaisesRegex(ValueError, "regular file"):
                MASKS.load(fifo)


if __name__ == "__main__":
    unittest.main()

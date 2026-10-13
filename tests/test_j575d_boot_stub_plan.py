#!/usr/bin/env python3
"""Offline tests for the inert J575d boot-stub asset planner."""

from __future__ import annotations

import importlib.util
import copy
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "plan_j575d_boot_stub", ROOT / "scripts/plan-j575d-boot-stub.py"
)
assert SPEC and SPEC.loader
PLANNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PLANNER)


def fixture() -> tuple[dict, list[dict]]:
    identity = {
        "ApBoardID": "0x44",
        "ApChipID": "0x6032",
        "Info": {
            "DeviceClass": "j575dap",
            "Variant": "macOS Customer",
            "RestoreBehavior": "Erase",
            "BuildNumber": "26A428",
        },
        "Manifest": {
            "BaseSystem": {"Info": {"Path": "BaseSystem.dmg.aea"}},
            "OS": {"Info": {"Path": "huge/OS.img"}},
            "RestoreRamDisk": {"Info": {"Path": "huge/ramdisk"}},
            "Cryptex1": {"Info": {"Path": "huge/cryptex"}},
            "Payload": {"Info": {"Path": "Firmware/payload.im4p"}},
            "PayloadAlias": {"Info": {"Path": "Firmware/payload.im4p"}},
        },
    }
    manifest = {
        "ProductBuildVersion": "26A428",
        "ProductVersion": "27.0",
        "BuildIdentities": [identity],
    }
    paths = set(PLANNER.ROOT_FILES)
    paths.update({
        "BuildManifest.plist",
        "BaseSystem.dmg.aea",
        "Firmware/payload.im4p",
        "BootabilityBundle/Restore/Bootability/boot.bin",
        "Firmware/Manifests/restore/macOS Customer/apticket.im4m",
    })
    rows = [
        {"path": path, "bytes": 10 + i, "compressed_bytes": 5 + i,
         "crc32": f"{i:08x}", "is_dir": False}
        for i, path in enumerate(sorted(paths))
    ]
    return manifest, rows


class BootStubPlanTests(unittest.TestCase):
    def test_ambiguous_identity_rejected(self) -> None:
        manifest, rows = fixture()
        manifest["BuildIdentities"].append(copy.deepcopy(manifest["BuildIdentities"][0]))
        with self.assertRaisesRegex(ValueError, "exactly one"):
            PLANNER.make_plan(manifest, rows)

    def test_wrong_board_build_and_variant_rejected(self) -> None:
        for field, wrong in (("ApBoardID", "0x43"), ("Variant", "macOS Customer Software Update"),
                             ("BuildNumber", "26A434")):
            with self.subTest(field=field):
                manifest, rows = fixture()
                identity = manifest["BuildIdentities"][0]
                (identity if field == "ApBoardID" else identity["Info"])[field] = wrong
                with self.assertRaisesRegex(ValueError, "exactly one"):
                    PLANNER.make_plan(manifest, rows)

    def test_numeric_hardware_ids(self) -> None:
        manifest, rows = fixture()
        identity = manifest["BuildIdentities"][0]
        identity["ApBoardID"] = 0x44
        identity["ApChipID"] = 0x6032
        self.assertEqual(PLANNER.make_plan(manifest, rows)["selection"]["identity_index"], 0)

    def test_missing_manifest_input_rejected(self) -> None:
        manifest, rows = fixture()
        rows = [r for r in rows if r["path"] != "BuildManifest.plist"]
        with self.assertRaisesRegex(ValueError, "missing required ZIP file"):
            PLANNER.make_plan(manifest, rows)

    def test_bad_sizes_rejected(self) -> None:
        for value in (-1, True, "10"):
            with self.subTest(value=value):
                manifest, rows = fixture()
                rows[0]["bytes"] = value
                with self.assertRaisesRegex(ValueError, "bad bytes"):
                    PLANNER.make_plan(manifest, rows)

    def test_exact_selection_and_roles(self) -> None:
        manifest, rows = fixture()
        plan = PLANNER.make_plan(manifest, rows)
        self.assertEqual(plan["selection"]["identity_index"], 0)
        self.assertEqual(plan["selection"]["product_version"], "27.0")
        self.assertEqual(plan["base_system"]["path"], "BaseSystem.dmg.aea")
        paths = {item["path"] for item in plan["members"]}
        self.assertIn("Firmware/payload.im4p", paths)
        self.assertNotIn("huge/OS.img", paths)
        payload = next(x for x in plan["members"] if x["path"] == "Firmware/payload.im4p")
        self.assertEqual(payload["roles"], ["identity_payload"])
        self.assertTrue(plan["accounting"]["source_bytes_only"])
        self.assertFalse(plan["accounting"]["installed"])
        self.assertFalse(plan["accounting"]["boot_qualified"])

    def test_missing_required_prefix(self) -> None:
        manifest, rows = fixture()
        rows = [r for r in rows if not r["path"].startswith("Firmware/Manifests/")]
        with self.assertRaisesRegex(ValueError, "missing required ZIP prefix"):
            PLANNER.make_plan(manifest, rows)

    def test_duplicate_zip_member_rejected(self) -> None:
        manifest, rows = fixture()
        rows.append(dict(rows[0]))
        with self.assertRaisesRegex(ValueError, "duplicate ZIP member"):
            PLANNER.make_plan(manifest, rows)

    def test_traversal_rejected(self) -> None:
        manifest, rows = fixture()
        rows[0] = dict(rows[0], path="Firmware/../escape")
        with self.assertRaisesRegex(ValueError, "unsafe ZIP member path"):
            PLANNER.make_plan(manifest, rows)

    def test_skipped_large_os_does_not_claim_budget(self) -> None:
        manifest, rows = fixture()
        rows.append({"path": "huge/OS.img", "bytes": 10**15,
                     "compressed_bytes": 10**15, "crc32": "00000000", "is_dir": False})
        plan = PLANNER.make_plan(manifest, rows)
        self.assertNotIn("huge/OS.img", {x["path"] for x in plan["members"]})
        self.assertLess(plan["totals"]["source_bytes"], 10**15)
        self.assertIsNone(plan["accounting"]["peak_disk_bytes"])


if __name__ == "__main__":
    unittest.main()

"""Receipt validation and explicit incomplete-layout accounting tests."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch, Mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("measure_stub", ROOT / "scripts/measure-j575d-stub-inputs.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class MeasurementTests(unittest.TestCase):
    def test_missing_restore_path_keeps_layout_unqualified(self):
        identity = {"Manifest": {"BaseSystem": {"Info": {"Path": "base.aea"}},
                                 "KernelCache": {"Info": {"Path": "kernelcache.test"}}}}
        names = ["BuildManifest.plist", "SystemVersion.plist", "RestoreVersion.plist",
                 "PlatformSupport.plist", "usr/standalone/bootcaches.plist",
                 "base.aea", "kernelcache.test", MODULE.TRUSTCACHE,
                 MODULE.BOOTABILITY + "file", MODULE.RESTORE_MANIFESTS + "file"]
        files = {name: {"bytes": 10, "symlink_body": False} for name in names}
        plists = {"BuildManifest.plist": {"BuildIdentities": [identity]},
                  "SystemVersion.plist": {"ProductUserVisibleVersion": "27.0"},
                  "usr/standalone/bootcaches.plist": {"bless2": {"Version": 1}}}
        planner = Mock()
        planner.select_identity.return_value = (0, identity)
        with patch.object(MODULE, "_load_receipt", return_value=files), \
             patch.object(MODULE, "_planner", return_value=planner), \
             patch.object(MODULE, "_plist", side_effect=lambda _, name: plists[name]):
            result = MODULE.measure(ROOT / "unused-receipt", ROOT)
        self.assertFalse(result["layout_qualified"])
        self.assertIsNone(result["restore_bundle_path"])
        self.assertIsNone(result["fit_8gb"])
        self.assertFalse(result["boot_validated"])
        self.assertFalse(result["final_installed_requirements"])
        plists["usr/standalone/bootcaches.plist"]["bless2"]["RestoreBundlePath"] = "example/restore"
        with patch.object(MODULE, "_load_receipt", return_value=files), \
             patch.object(MODULE, "_planner", return_value=planner), \
             patch.object(MODULE, "_plist", side_effect=lambda _, name: plists[name]):
            result = MODULE.measure(ROOT / "unused-receipt", ROOT)
        self.assertTrue(result["structural_gate"]["restore_bundle_path_valid"])
        self.assertFalse(result["layout_qualified"])
        self.assertIsNone(result["fit_8gb"])

    def test_missing_tree_cannot_silently_reduce_budget(self):
        with self.assertRaisesRegex(ValueError, "required tree"):
            MODULE._tree({}, "Bootability/")

    def test_link_bodies_are_not_counted_as_regular_files(self):
        rows = {"T/file": {"bytes": 10, "symlink_body": False},
                "T/link": {"bytes": 4, "symlink_body": True}}
        result = MODULE._tree(rows, "T/")
        self.assertEqual(result["logical_bytes"], 10)
        self.assertEqual(result["symlink_body_bytes"], 4)

    def test_receipt_hash_size_and_duplicate_checks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            payload = root / "payload"
            payload.write_bytes(b"abc")
            receipt = root / "receipt.json"
            row = {"member": "payload", "local_path": "payload", "bytes": 3,
                   "sha256": hashlib.sha256(b"abc").hexdigest()}
            receipt.write_text(json.dumps({"members": [row]}))
            self.assertEqual(MODULE._load_receipt(receipt, root)["payload"]["bytes"], 3)
            for mutation, message in ((dict(row, bytes=4), "size mismatch"),
                                      (dict(row, sha256="0" * 64), "sha256 mismatch"),
                                      (dict(row, member="../payload"), "unsafe member")):
                with self.subTest(message=message):
                    receipt.write_text(json.dumps({"members": [mutation]}))
                    with self.assertRaisesRegex(ValueError, message):
                        MODULE._load_receipt(receipt, root)
            receipt.write_text(json.dumps({"members": [row, row]}))
            with self.assertRaisesRegex(ValueError, "duplicate"):
                MODULE._load_receipt(receipt, root)


if __name__ == "__main__":
    unittest.main()

"""Offline tests for the bounded J575d boot-stub staging candidate."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("stage_j575d", ROOT / "scripts/stage-j575d-boot-stub.py")
stage = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(stage)


def fixture(tmp_path: Path):
    members = {}
    def add(name: str, data: bytes, mode: int = 0o100644):
        path = tmp_path / "source" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        members[name] = {"member": name, "local_path": str(path.relative_to(tmp_path)),
                         "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                         "unix_mode": mode}

    identity = {
        "ApBoardID": "0x44", "ApChipID": "0x6032",
        "Info": {"DeviceClass": "j575dap", "Variant": "macOS Customer",
                 "RestoreBehavior": "Erase", "BuildNumber": "26A428"},
        "Manifest": {
            "BaseSystem": {"Info": {"Path": "base.dmg"}},
            "OS": {"Info": {"Path": "ignored"}},
            "Kernel": {"Info": {"Path": "kernelcache.test"}},
            "Payload": {"Info": {"Path": "payload.im4p"}},
        },
    }
    manifest = {"ProductBuildVersion": "26A428", "ProductVersion": "27.0",
                "BuildIdentities": [identity]}
    add("BuildManifest.plist", plistlib.dumps(manifest))
    add("SystemVersion.plist", plistlib.dumps({"ProductUserVisibleVersion": "27.0"}))
    add("RestoreVersion.plist", b"restore-version")
    add("PlatformSupport.plist", b"platform-support")
    add("usr/standalone/bootcaches.plist", b"bootcaches")
    add("base.dmg", b"base-system")
    add("kernelcache.test", b"kernel")
    add("payload.im4p", b"payload")
    add(stage.TRUSTCACHE_MEMBER, b"trustcache")
    add("Firmware/Manifests/restore/macOS Customer/apticket.j575dap.im4m", b"ticket")
    boot = stage.BOOTABILITY_PREFIX
    add(boot + "BootabilityBrain.framework/Versions/A/BootabilityBrain", b"brain")
    add(boot + "BootabilityBrain.framework/Versions/A/Resources", b"resources")
    add(boot + "BootabilityBrain.framework/Versions/Current", b"A", 0o120777)
    add(boot + "BootabilityBrain.framework/BootabilityBrain", b"Versions/A/BootabilityBrain", 0o120777)
    add(boot + "BootabilityBrain.framework/Resources", b"Versions/A/Resources", 0o120777)
    receipt = tmp_path / "receipt.json"
    receipt.write_text(json.dumps({"members": list(members.values())}), encoding="utf-8")
    framework = members[stage.FRAMEWORK_MEMBER]["sha256"]
    return receipt, framework


def local_planner():
    spec = importlib.util.spec_from_file_location("test_j575d_planner", ROOT / "scripts/plan-j575d-boot-stub.py")
    planner = importlib.util.module_from_spec(spec)
    assert spec.loader
    spec.loader.exec_module(planner)
    return planner


class StubStagingTests(unittest.TestCase):
    def run_fixture(self, test_body):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt, framework = fixture(root)
            with mock.patch.object(stage, "CANONICAL_PROJECT", root), \
                 mock.patch.object(stage, "CANONICAL_SCRATCH", root / "scratch/boot-stub-provisioning"), \
                 mock.patch.object(stage, "_planner", lambda _root: local_planner()), \
                 mock.patch.object(stage, "FRAMEWORK_SHA256", framework):
                test_body(root, receipt)

    def test_full_synthetic_fixture_and_path_remap(self):
        def body(root, receipt):
            out = stage.stage(receipt, root, "26A428")
            self.assertEqual(out.parent, root / "scratch/boot-stub-provisioning")
            self.assertTrue((out / f"Preboot/{stage.FAKE_UUID}/restore/BuildManifest.plist").is_file())
            self.assertEqual((out / f"Recovery/{stage.FAKE_UUID}/usr/standalone/firmware/arm64eBaseSystem.dmg").read_bytes(), b"base-system")
            self.assertTrue((out / f"Preboot/{stage.FAKE_UUID}/restore/Bootability/BootabilityBrain.framework/Versions/Current").is_symlink())
            self.assertFalse(any(p.is_file() and p.stat().st_mode & 0o111 for p in out.rglob("*")))
            report = json.loads((out / "stage-receipt.json").read_text())
            self.assertTrue(report["layout_experimental"])
            self.assertFalse(report["boot_qualified"])
            self.assertIsNone(report["fit_8gb"])
            self.assertEqual(report["source_receipt_sha256"], hashlib.sha256(receipt.read_bytes()).hexdigest())
            self.assertIn("unchanged AEA", report["recovery_representation"])
            for row in report["files"]:
                if row["kind"] == "symlink":
                    self.assertEqual(row["source_sha256"], row["sha256"])
            self.assertGreaterEqual(len(report["files"]), 13)
        self.run_fixture(body)

    def test_profile_is_explicit_before_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt, _ = fixture(root)
            with self.assertRaisesRegex(ValueError, "explicit experimental profile"):
                stage.stage(receipt, root, "26A434")
            self.assertFalse((root / "scratch").exists())

    def test_framework_pin_mismatch_before_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt, _ = fixture(root)
            with mock.patch.object(stage, "FRAMEWORK_SHA256", "0" * 64):
                with self.assertRaisesRegex(ValueError, "framework SHA-256"):
                    stage.stage(receipt, root, "26A428")
            self.assertFalse((root / "scratch").exists())

    def test_link_containment_rejected(self):
        def body(root, receipt):
            link = root / "source" / (stage.BOOTABILITY_PREFIX + "BootabilityBrain.framework/Resources")
            link.write_bytes(b"../../../../outside")
            rows = json.loads(receipt.read_text())
            for row in rows["members"]:
                if row["member"].endswith("BootabilityBrain.framework/Resources"):
                    row["bytes"] = len(b"../../../../outside")
                    row["sha256"] = hashlib.sha256(b"../../../../outside").hexdigest()
            receipt.write_text(json.dumps(rows))
            with self.assertRaises(ValueError):
                stage.stage(receipt, root, "26A428")
        self.run_fixture(body)

    def test_destination_ancestor_collision_rejected(self):
        with self.assertRaisesRegex(ValueError, "collision"):
            stage._check_collision({"a": "one", "a/b": "two"})

    def test_destination_prefix_collision_rejected(self):
        identity = {"Manifest": {"BaseSystem": {"Info": {"Path": "base"}}, "Payload": {"Info": {"Path": "x"}}}}
        files = {"Firmware/Manifests/restore/macOS Customer/x": {}}
        with self.assertRaisesRegex(ValueError, "destination collision"):
            stage._destinations(files, identity)

    def test_missing_restore_tree_rejected(self):
        def body(root, receipt):
            raw = json.loads(receipt.read_text())
            raw["members"] = [row for row in raw["members"] if not row["member"].startswith(stage.RESTORE_MANIFEST_PREFIX)]
            receipt.write_text(json.dumps(raw))
            with self.assertRaisesRegex(ValueError, "restore manifest tree"):
                stage.stage(receipt, root, "26A428")
        self.run_fixture(body)


if __name__ == "__main__":
    unittest.main()

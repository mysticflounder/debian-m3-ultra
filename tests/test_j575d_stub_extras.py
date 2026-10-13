from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "j575d_stub_extras", ROOT / "scripts/stage-j575d-stub-extras.py"
)
assert SPEC.loader is not None
EXTRAS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EXTRAS)

STAGE = ROOT / "scratch/boot-stub-provisioning/stage-ohgqmpjl"
REAL_ASSETS = (
    STAGE.is_dir()
    and (STAGE / "stage-receipt.json").is_file()
    and EXTRAS.INLINE_MANIFEST.is_file()
    and EXTRAS.INLINE_SOURCE.is_file()
    and all((ROOT / "scratch/boot-stub-provisioning" /
             f"asahi-installer-{EXTRAS.INSTALLER_REVISION}" / relative).is_file()
            for relative in EXTRAS.INSTALLER_FILES)
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class StubExtrasTests(unittest.TestCase):
    def test_inert_script_synthetic_body_is_fail_closed(self):
        body = EXTRAS.inert_script(b"#!/bin/sh\nprintf synthetic-marker\\n\n")
        self.assertTrue(body.startswith(b"#!/bin/sh\n# INERT OFFLINE TEMPLATE"))
        self.assertLess(body.index(b"exit 97"), body.index(b"synthetic-marker"))

    @unittest.skipUnless(REAL_ASSETS, "retained boot-stub assets unavailable")
    def test_assembles_inert_templates_exports_and_candidate(self):
        output = EXTRAS.assemble(STAGE)
        self.assertEqual(output.parent.resolve(), EXTRAS.SCRATCH.resolve())
        self.assertTrue(output.name.startswith("extras-"))

        receipt = json.loads((output / "extras-receipt.json").read_text())
        self.assertEqual(receipt["schema"], "j575d-stub-extras-v1")
        self.assertFalse(receipt["native_approved"])
        self.assertFalse(receipt["boot_qualified"])
        self.assertEqual(receipt["synthetic_identity"]["index"], 153)
        self.assertEqual(receipt["synthetic_identity"]["fake_uuid"], EXTRAS.FAKE_UUID)
        self.assertEqual(receipt["synthetic_identity"]["distro"], "Debian")
        self.assertEqual(receipt["source_stage_receipt_sha256"], EXTRAS.STAGE_RECEIPT_SHA256)
        self.assertEqual(receipt["source_asset_receipt_sha256"], EXTRAS.SOURCE_ASSET_RECEIPT_SHA256)

        paths = {row["path"] for row in receipt["files"]}
        self.assertIn("templates/.IAPhysicalMedia", paths)
        self.assertIn("templates/Finish Installation.app.inert/Contents/Info.plist", paths)
        self.assertIn("templates/Finish Installation.app.inert/Contents/Resources/en.lproj/InfoPlist.strings", paths)
        self.assertIn("templates/Finish Installation.app.inert/Contents/MacOS/step2_launcher.sh.inert", paths)
        self.assertIn("templates/Finish Installation.app.inert/Contents/Resources/step2.sh.inert", paths)
        self.assertIn("candidates/UNQUALIFIED-boot.bin", paths)
        for name in (
            "installer-data/BuildManifest.plist",
            "installer-data/RestoreVersion.plist",
            "installer-data/SystemVersion.plist",
            "installer-data/kernelcache.release.mac15j",
        ):
            self.assertIn(name, paths)

        for row in receipt["files"]:
            path = output / row["path"]
            self.assertTrue(path.is_file(), row["path"])
            self.assertFalse(path.is_symlink(), row["path"])
            self.assertEqual(path.stat().st_size, row["bytes"])
            self.assertEqual(sha256(path), row["sha256"])
            self.assertFalse(path.stat().st_mode & 0o111, row["path"])

        step = output / "templates/Finish Installation.app.inert/Contents/Resources/step2.sh.inert"
        body = step.read_text()
        self.assertTrue(body.startswith("#!/bin/sh\n# INERT OFFLINE TEMPLATE"))
        self.assertLess(body.index("exit 97"), body.index("bputil -d"))
        self.assertIn('DISTRO="Debian"', body)
        self.assertIn(f'VGID="{EXTRAS.FAKE_UUID}"', body)
        self.assertNotIn("##DISTRO##", body)
        self.assertNotIn("##VGID##", body)
        self.assertNotIn("##PREBOOT##", body)

        launcher = output / "templates/Finish Installation.app.inert/Contents/MacOS/step2_launcher.sh.inert"
        self.assertLess(launcher.read_text().index("exit 97"), launcher.read_text().index("Terminal"))

        candidate = output / "candidates/UNQUALIFIED-boot.bin"
        self.assertEqual(candidate.stat().st_size, 20648267)
        self.assertEqual(sha256(candidate), EXTRAS.INLINE_SHA256)
        self.assertEqual(candidate.read_bytes(), EXTRAS.INLINE_SOURCE.read_bytes())

        omitted = set(receipt["omitted"])
        self.assertIn("AdminUserRecoveryInfo.plist", omitted)
        self.assertIn("all_firmware.tar.gz", omitted)
        self.assertIn("deployable boot.bin", omitted)
        self.assertNotIn("stub_info.json", paths)

    @unittest.skipUnless(REAL_ASSETS, "retained boot-stub assets unavailable")
    def test_rejects_distro_shell_injection_before_output(self):
        before = {path.name for path in EXTRAS.SCRATCH.glob("extras-*")}
        with self.assertRaises(ValueError):
            EXTRAS.assemble(STAGE, "Debian;reboot")
        self.assertEqual(before, {path.name for path in EXTRAS.SCRATCH.glob("extras-*")})

    def test_rejects_unverified_stage_receipt(self):
        EXTRAS.SCRATCH.mkdir(parents=True, exist_ok=True)
        fixture = Path(tempfile.mkdtemp(prefix="fixture-", dir=EXTRAS.SCRATCH))
        try:
            (fixture / "stage-receipt.json").write_text(json.dumps({
                "schema": "j575d-boot-stub-stage-receipt-v1",
                "profile": EXTRAS.PROFILE,
                "fake_uuid": EXTRAS.FAKE_UUID,
                "identity_index": 153,
                "source_receipt_sha256": "0" * 64,
                "files": [],
            }))
            with self.assertRaises(ValueError):
                EXTRAS.assemble(fixture)
        finally:
            shutil.rmtree(fixture)

    def test_rejects_stage_outside_canonical_scratch(self):
        with tempfile.TemporaryDirectory() as outside:
            with self.assertRaises(ValueError):
                EXTRAS.assemble(Path(outside))

    def test_rejects_symlinked_canonical_scratch(self):
        EXTRAS.SCRATCH.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory() as outside, tempfile.TemporaryDirectory(
            prefix="extras-link-test-", dir=EXTRAS.SCRATCH
        ) as fixture:
            link = Path(fixture) / "scratch-link"
            link.symlink_to(outside, target_is_directory=True)
            original = EXTRAS.SCRATCH
            try:
                EXTRAS.SCRATCH = link
                with self.assertRaises(ValueError):
                    EXTRAS.canonical_scratch()
            finally:
                EXTRAS.SCRATCH = original


if __name__ == "__main__":
    unittest.main()

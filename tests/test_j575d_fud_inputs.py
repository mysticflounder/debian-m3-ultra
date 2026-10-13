#!/usr/bin/env python3
"""Stdlib tests for the inert identity-153 FUD staging helper."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import plistlib
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "stage_j575d_fud_inputs", ROOT / "scripts/stage-j575d-fud-inputs.py"
)
assert SPEC and SPEC.loader
stage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(stage)


def _row(root: Path, member: str, data: bytes) -> dict:
    source = root / "source" / member
    source.parent.mkdir(parents=True, exist_ok=True)
    source.write_bytes(data)
    return {
        "member": member,
        "local_path": str(source.relative_to(root)),
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "unix_mode": 0o100644,
    }


def fixture(root: Path) -> tuple[Path, dict[str, Path]]:
    selected = dict(stage.EXPECTED_FUD)
    identity = {
        "ApBoardID": "0x44",
        "ApChipID": "0x6032",
        "Info": {
            "DeviceClass": "j575dap",
            "Variant": "macOS Customer",
            "RestoreBehavior": "Erase",
        },
        "Manifest": {
            key: {
                "Info": {
                    "Path": path,
                    "IsFUDFirmware": True,
                    "IsLoadedByiBoot": False,
                    "IsLoadedByiBootStage1": False,
                }
            }
            for key, path in selected.items()
        },
    }
    manifest = {
        "ProductBuildVersion": "26A428",
        "BuildIdentities": [{} for _ in range(stage.IDENTITY_INDEX)] + [identity],
    }
    manifest_bytes = plistlib.dumps(manifest)
    manifest_row = _row(root, "BuildManifest.plist", manifest_bytes)
    paths: dict[str, Path] = {}
    rows = [manifest_row]
    for index, path in enumerate(selected.values()):
        data = (f"FUD-{index}-" + path).encode("ascii")
        rows.append(_row(root, path, data))
        paths[path] = root / "source" / path
    receipt = root / "receipt.json"
    receipt.write_text(json.dumps({
        "scope": "source member bytes only, not bootable layout or signature validation",
        "plan_sha256": "0" * 64,
        "range_bytes": sum(row["bytes"] for row in rows),
        "members": rows,
    }), encoding="utf-8")
    return receipt, paths


def rewrite_manifest_row(receipt: Path, source: Path, manifest: dict) -> None:
    data = plistlib.dumps(manifest)
    source.write_bytes(data)
    raw = json.loads(receipt.read_text(encoding="utf-8"))
    for row in raw["members"]:
        if row["member"] == "BuildManifest.plist":
            row["bytes"] = len(data)
            row["sha256"] = hashlib.sha256(data).hexdigest()
            break
    receipt.write_text(json.dumps(raw), encoding="utf-8")


class FudInputTests(unittest.TestCase):
    def test_cli_rejects_project_and_output_overrides(self) -> None:
        with mock.patch.object(sys, "argv", ["stage-j575d-fud-inputs.py", "--project-root", "/tmp"]):
            with self.assertRaises(SystemExit) as raised:
                stage.main()
        self.assertEqual(raised.exception.code, 2)

    def test_helper_allocates_fresh_canonical_scratch_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt, _ = fixture(root)
            output = stage.stage(receipt, root)
            self.assertEqual(output.parent, (root / "scratch/boot-stub-provisioning").resolve())
            self.assertTrue(output.name.startswith("fud-j575d-"))

    def test_identity_pinned_and_exact_layout(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt, paths = fixture(root)
            output = stage.stage(receipt, root, root / "scratch/boot-stub-provisioning/fud-out")
            report = json.loads((output / "fud-inputs-receipt.json").read_text())
            self.assertEqual(report["identity_index"], 153)
            self.assertEqual(report["identity"]["device_class"], "j575dap")
            self.assertFalse(report["firmware_package_complete"])
            self.assertFalse(report["native_approved"])
            self.assertEqual(len(report["files"]), 8)
            for key, source in stage.EXPECTED_FUD.items():
                file_path = output / "fud_firmware" / source
                alias_path = output / "fud_firmware" / "j575d" / f"{key}.im4p"
                self.assertEqual(file_path.read_bytes(), paths[source].read_bytes())
                self.assertTrue(alias_path.is_symlink())
                self.assertEqual(os_readlink(alias_path), f"../{source}")
                self.assertEqual(alias_path.resolve(), file_path.resolve())
            self.assertEqual(
                sorted(p.relative_to(output).as_posix() for p in output.rglob("*")
                       if p.name != "fud-inputs-receipt.json" and (p.is_file() or p.is_symlink())),
                sorted(row["path"] for row in report["files"]),
            )

    def test_manifest_pin_mismatch_is_rejected_before_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt, _ = fixture(root)
            manifest_path = root / "source/BuildManifest.plist"
            manifest = plistlib.loads(manifest_path.read_bytes())
            manifest["BuildIdentities"][stage.IDENTITY_INDEX]["ApChipID"] = "0x6031"
            rewrite_manifest_row(receipt, manifest_path, manifest)
            output = root / "scratch/boot-stub-provisioning/fud-out"
            with self.assertRaisesRegex(ValueError, "pin mismatch"):
                stage.stage(receipt, root, output)
            self.assertFalse(output.exists())

    def test_destination_collision_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "collision"):
            stage._check_destinations(["fud_firmware/a", "fud_firmware/a"])
        with self.assertRaisesRegex(ValueError, "collision"):
            stage._check_destinations(["fud_firmware", "fud_firmware/a"])

    def test_alias_must_remain_contained(self) -> None:
        self.assertEqual(
            stage._alias_target("fud_firmware/j575d/Ap,DCP2.im4p", "Firmware/dcp/x.im4p"),
            "../Firmware/dcp/x.im4p",
        )
        with self.assertRaisesRegex(ValueError, "escapes"):
            stage._alias_target("fud_firmware/x.im4p", "Firmware/dcp/x.im4p")

    def test_input_hash_failure_is_rejected_before_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt, paths = fixture(root)
            source = paths[next(iter(stage.EXPECTED_FUD.values()))]
            source.write_bytes(b"X" * source.stat().st_size)
            output = root / "scratch/boot-stub-provisioning/fud-out"
            with self.assertRaisesRegex(ValueError, "source bytes"):
                stage.stage(receipt, root, output)
            self.assertFalse(output.exists())


def os_readlink(path: Path) -> str:
    return path.readlink().as_posix()


if __name__ == "__main__":
    unittest.main()

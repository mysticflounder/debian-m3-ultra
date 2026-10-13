import ast
import importlib.util
import json
import tempfile
import types
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/prepare-j575d-installer-adapter.py"
SPEC = importlib.util.spec_from_file_location("j575d_installer_adapter", SCRIPT)
ADAPTER = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(ADAPTER)
REAL_ASSETS = ADAPTER.INSTALLER.is_dir() and ADAPTER.INLINE_SOURCE.is_file()


class InstallerAdapterTests(unittest.TestCase):
    def test_modern_root_uses_explicit_restore_without_plist_key(self):
        with tempfile.TemporaryDirectory() as directory:
            preboot = Path(directory)
            expected = (preboot / ADAPTER.SYNTHETIC_UUID / "restore").resolve()
            self.assertEqual(
                ADAPTER.resolve_restore_root(preboot, ADAPTER.SYNTHETIC_UUID, {}, ADAPTER.PROFILE),
                expected,
            )

    def test_legacy_root_preserves_plist_lookup(self):
        with tempfile.TemporaryDirectory() as directory:
            preboot = Path(directory)
            bootcaches = {"bless2": {"RestoreBundlePath": "legacy-restore"}}
            self.assertEqual(
                ADAPTER.resolve_restore_root(preboot, "real-vgid", bootcaches, "legacy"),
                (preboot / "real-vgid" / "legacy-restore").resolve(),
            )

    def test_modern_profile_rejects_unsafe_vgid(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                ADAPTER.resolve_restore_root(Path(directory), "../escape", {}, ADAPTER.PROFILE)

    def test_render_requires_explicit_preboot_volume_uuid(self):
        with self.assertRaises(TypeError):
            ADAPTER.render_candidate_files(ADAPTER.SYNTHETIC_UUID)

    @unittest.skipUnless(REAL_ASSETS, "pinned installer source unavailable")
    def test_patched_real_method_behaviour(self):
        source = (ADAPTER.INSTALLER / "src/stub.py").read_bytes()
        patched = ADAPTER.patch_stub_source(source)
        tree = ast.parse(patched.decode())
        method = next(node for node in ast.walk(tree)
                      if isinstance(node, ast.FunctionDef) and node.name == "restore_bundle_rel")
        namespace = {}
        exec(compile(ast.Module(body=[method], type_ignores=[]), "stub.py", "exec"), namespace)
        resolve = namespace["restore_bundle_rel"]
        self.assertEqual(patched.count(b"self.restore_bundle_rel()"), 3)
        valid = types.SimpleNamespace(
            restore_profile=ADAPTER.PROFILE,
            identity={"Info": {"BuildNumber": "26A428", "Variant": "macOS Customer",
                                "RestoreBehavior": "Erase", "DeviceClass": "j575dap"},
                      "ApBoardID": "0x44", "ApChipID": "0x6032"},
            bootcaches={},
        )
        self.assertEqual(resolve(valid), "restore")
        invalid = types.SimpleNamespace(
            restore_profile=ADAPTER.PROFILE,
            identity={"Info": {"BuildNumber": "26A428", "Variant": "macOS Customer",
                                "RestoreBehavior": "Erase", "DeviceClass": "j575cap"},
                      "ApBoardID": "0x02", "ApChipID": "0x6041"},
            bootcaches={},
        )
        with self.assertRaises(ValueError):
            resolve(invalid)
        legacy = types.SimpleNamespace(
            restore_profile="legacy",
            identity={},
            bootcaches={"bless2": {"RestoreBundlePath": "legacy-restore"}},
        )
        self.assertEqual(resolve(legacy), "legacy-restore")
        legacy_missing = types.SimpleNamespace(restore_profile="legacy", identity={}, bootcaches={})
        with self.assertRaises(KeyError):
            resolve(legacy_missing)

    def test_source_pin_constants_are_sha256(self):
        self.assertEqual(len(ADAPTER.SOURCE_PINS), 3)
        self.assertTrue(all(len(value) == 64 for value in ADAPTER.SOURCE_PINS.values()))

    def test_synthetic_stub_info_preserves_source_shape_without_admin(self):
        info = ADAPTER.source_derived_stub_info(
            {"BuildID": "FFFF", "ProductBuildVersion": "26A428",
             "ProductName": "macOS", "ProductVersion": "27.0",
             "ProductUserVisibleVersion": "27.0"},
            {"Info": {"BuildNumber": "26A428", "Variant": "macOS Customer",
                       "DeviceClass": "j575dap"},
             "ApBoardID": "0x44", "ApChipID": "0x6032"},
        )
        self.assertFalse(info["complete"])
        self.assertEqual(info["system_version"]["BuildID"], "FFFF")
        self.assertEqual(info["system_version"]["ProductUserVisibleVersion"], "27.0 (stub)")
        self.assertEqual(info["manifest_info"], {
            "build_number": "26A428", "variant": "macOS Customer",
            "device_class": "j575dap", "board_id": "0x44", "chip_id": "0x6032",
        })
        self.assertEqual(set(info["manifest_info"]), {
            "build_number", "variant", "device_class", "board_id", "chip_id"
        })
        self.assertNotIn("admin_users", info)

    @unittest.skipUnless(REAL_ASSETS, "inline candidate unavailable")
    def test_direct_inline_profile_has_no_efi_chainload(self):
        profile = ADAPTER.inline_profile()
        self.assertEqual(profile["kind"], "direct-inline-diagnostic")
        self.assertFalse(profile["efi_chainload"])
        self.assertEqual(profile["m1n1_variables"], [])

    @unittest.skipUnless(REAL_ASSETS, "pinned templates unavailable")
    def test_render_candidate_files_is_write_free_and_direct_inline(self):
        vgid = "6C48ECEE-50E5-49F0-ACEF-9BA7C36926F7"
        preboot = "44170F1B-611F-47BB-89A9-0E7FF8F48823"
        candidate = ADAPTER.render_candidate_files(vgid.lower(), preboot.lower())
        self.assertEqual(candidate["vgid"], vgid)
        self.assertEqual(candidate["preboot_vgid"], preboot)
        self.assertFalse(candidate["native_approved"])
        boot_path = "Finish Installation.app/Contents/Resources/boot.bin"
        self.assertEqual(candidate["pins"][boot_path], ADAPTER.INLINE_SHA256)
        self.assertEqual(candidate["files"][boot_path], ADAPTER.INLINE_SOURCE.read_bytes())
        self.assertIn("Finish Installation.app/Contents/Resources/step2.sh", candidate["files"])
        self.assertIn(b'VGID="' + vgid.encode() + b'"',
                      candidate["files"]["Finish Installation.app/Contents/Resources/step2.sh"])
        self.assertIn(b'PREBOOT="' + preboot.encode() + b'"',
                      candidate["files"]["Finish Installation.app/Contents/Resources/step2.sh"])


if __name__ == "__main__":
    unittest.main()

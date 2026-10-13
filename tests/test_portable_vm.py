#!/usr/bin/env python3
"""Fail-closed checks for the standalone portable VM launcher."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = ROOT / "scripts" / "portable-vm.sh"


class PortableVmTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="portable-vm-test-")
        self.out = Path(self.tmp.name) / "out"
        self.out.mkdir()
        self.image = self.out / "debian-portable.qcow2"
        self.image.write_bytes(b"mock qcow2")
        self.code = Path(self.tmp.name) / "edk2-aarch64-code.fd"
        self.template = Path(self.tmp.name) / "edk2-arm-vars.fd"
        self.code.write_bytes(b"code")
        self.template.write_bytes(b"template")
        self.qemu_img = Path(self.tmp.name) / "qemu-img"
        self.qemu_img.write_text(
            """#!/bin/sh
if [ "$1" = info ]; then
  if [ "${FAKE_FORMAT:-qcow2}" = raw ]; then
    printf '%s\\n' '{"format":"raw"}'
  elif [ "${FAKE_BACKING:-0}" = 1 ]; then
    printf '%s\\n' '{"format":"qcow2","backing-filename":"base.qcow2"}'
  else
    printf '%s\\n' '{"format":"qcow2","virtual-size":8589934592}'
  fi
  exit 0
fi
if [ "$1" = check ]; then exit 0; fi
exit 0
"""
        )
        self.qemu_img.chmod(0o755)
        self.qemu = Path(self.tmp.name) / "qemu-system-aarch64"
        self.args = Path(self.tmp.name) / "qemu.args"
        self.qemu.write_text(
            f"""#!/bin/sh
printf '%s\\n' "$@" > {self.args}
exit 0
"""
        )
        self.qemu.chmod(0o755)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_launcher(self, command: str, **extra: str) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "PORTABLE_VM_OUT": str(self.out),
                "PORTABLE_VM_QEMU_IMG": str(self.qemu_img),
                "PORTABLE_VM_QEMU": str(self.qemu),
                "PORTABLE_VM_CODE": str(self.code),
                "PORTABLE_VM_VARS_SOURCE": str(self.template),
                "PORTABLE_VM_BRIDGE": "0",
                "PORTABLE_VM_QMP": "0",
            }
        )
        env.update(extra)
        return subprocess.run(
            [str(LAUNCHER), command],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_info_prints_uefi_configuration_and_default_constraints(self) -> None:
        result = self.run_launcher("info", PORTABLE_VM_QMP="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("accel:   hvf", result.stdout)
        self.assertIn("cpu:     host", result.stdout)
        self.assertIn("vcpus:   4", result.stdout)
        self.assertIn("memory:  4G", result.stdout)
        self.assertIn("portable-vm-test", result.stdout)
        self.assertIn("portable-qmp.sock", result.stdout)

    def test_run_copies_private_vars_without_kernel_or_initrd(self) -> None:
        result = self.run_launcher("run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.out / "debian-portable-vars.fd").read_bytes(), b"template")
        args = self.args.read_text()
        self.assertIn("-accel\nhvf", args)
        self.assertIn("-cpu\nhost", args)
        self.assertIn("-smp\n4", args)
        self.assertIn("-m\n4G", args)
        self.assertIn("if=pflash,format=raw,readonly=on", args)
        self.assertIn("mac=52:54:00:12:35:61", args)
        self.assertNotIn("-kernel", args)
        self.assertNotIn("-initrd", args)

    def test_existing_vars_are_never_overwritten(self) -> None:
        vars_path = self.out / "debian-portable-vars.fd"
        vars_path.write_bytes(b"guest state")
        result = self.run_launcher("run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(vars_path.read_bytes(), b"guest state")

    def test_stale_lock_is_refused_and_not_removed(self) -> None:
        lock = self.out / ".portable-vm.lock"
        lock.mkdir()
        (lock / "pid").write_text("999999")
        result = self.run_launcher("run")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing stale locks", result.stderr)
        self.assertTrue(lock.is_dir())

    def test_raw_and_backed_images_are_rejected(self) -> None:
        raw = self.run_launcher("info", FAKE_FORMAT="raw")
        self.assertNotEqual(raw.returncode, 0)
        self.assertIn("not qcow2", raw.stderr)
        backed = self.run_launcher("info", FAKE_BACKING="1")
        self.assertNotEqual(backed.returncode, 0)
        self.assertIn("backing or external", backed.stderr)

    def test_symlink_image_is_rejected(self) -> None:
        self.image.unlink()
        target = self.out / "real-image"
        target.write_bytes(b"mock")
        self.image.symlink_to(target)
        result = self.run_launcher("info")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("regular, non-symlink", result.stderr)

    def test_static_uefi_and_headless_contract(self) -> None:
        source = LAUNCHER.read_text()
        self.assertIn("-nographic", source)
        self.assertIn("if=pflash,format=raw,readonly=on", source)
        self.assertIn("PORTABLE_VM_BRIDGE", source)
        self.assertIn("vmnet-bridged", source)
        self.assertNotIn("Image-$KVER", source)


if __name__ == "__main__":
    unittest.main()

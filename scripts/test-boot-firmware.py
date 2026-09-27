#!/usr/bin/env python3
"""Synthetic portable parser tests; never executes Apple firmware."""
from __future__ import annotations

import importlib.util
import ctypes
import contextlib
import io
import json
import pathlib
import tempfile
import types
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("boot_inspector", ROOT / "scripts/inspect-boot-firmware.py")
INSPECTOR = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(INSPECTOR)


def tlv(tag: int, data: bytes) -> bytes:
    n = len(data)
    length = bytes([n]) if n < 128 else n.to_bytes((n.bit_length() + 7) // 8, "big")
    if n >= 128:
        length = bytes([0x80 | len(length)]) + length
    return bytes([tag]) + length + data


def integer(n: int) -> bytes:
    data = n.to_bytes(max(1, (n.bit_length() + 7) // 8), "big")
    if data[0] & 0x80:
        data = b"\0" + data
    return tlv(2, data)


def fixture(*, kind: bytes = b"ibot", description: bytes = b"mBoot-test",
            payload: bytes = b"bvx2synthetic", size: int = 32,
            marker: int = 1, extra: bytes = b"", trailer: bool = True) -> bytes:
    fields = (tlv(0x16, b"IM4P") + tlv(0x16, kind) + tlv(0x16, description)
              + tlv(4, payload) + tlv(0x30, integer(marker) + integer(size)))
    if trailer:
        fields += tlv(0xa0, tlv(0x30, b""))
    return tlv(0x30, fields + extra)


class BootFirmwareTests(unittest.TestCase):
    def rejected(self, data: bytes) -> None:
        with self.assertRaises(ValueError):
            INSPECTOR.parse_container(data)

    def test_supported_types_and_offsets(self):
        for kind in (b"ibot", b"illb"):
            with self.subTest(kind=kind):
                data = fixture(kind=kind)
                info = INSPECTOR.parse_container(data)
                self.assertEqual(info["type"], kind.decode())
                self.assertEqual(info["description"], "mBoot-test")
                start, size = info["payload_offset"], info["payload_size"]
                self.assertEqual(data[start:start + size], b"bvx2synthetic")
                self.assertEqual(info["decoded_size"], 32)
                self.assertEqual(info["compression_marker"], 1)

    def test_optional_trailer_absent(self):
        self.assertEqual(INSPECTOR.parse_container(fixture(trailer=False))["type"], "ibot")

    def test_long_lengths(self):
        data = fixture(payload=b"bvx2" + b"x" * 256)
        self.assertEqual(INSPECTOR.parse_container(data)["payload_size"], 260)

    def test_empty_and_truncated(self):
        data = fixture()
        for stop in range(len(data)):
            with self.subTest(stop=stop):
                self.rejected(data[:stop])

    def test_extra_outer_bytes(self):
        self.rejected(fixture() + b"\0")

    def test_wrong_magic(self):
        self.rejected(fixture().replace(b"IM4P", b"IMG4", 1))

    def test_wrong_type(self):
        for kind in (b"krnl", b"dtre", b"ibot\0"):
            self.rejected(fixture(kind=kind))

    def test_bad_description(self):
        for value in (b"x\0y", b"x\ny", b"\xff", b"x" * 129):
            self.rejected(fixture(description=value))

    def test_non_lzfse_payload(self):
        for value in (b"", b"bvx", b"complzss", b"\0" * 20):
            self.rejected(fixture(payload=value))

    def test_invalid_sizes(self):
        for size in (0, INSPECTOR.DECODE_LIMIT, INSPECTOR.DECODE_LIMIT + 1):
            self.rejected(fixture(size=size))

    def test_unknown_compression_marker(self):
        self.rejected(fixture(marker=2))

    def test_extra_inner_field(self):
        self.rejected(fixture(extra=integer(2)))

    def test_indefinite_der(self):
        self.rejected(b"\x30\x80" + fixture()[2:] + b"\0\0")

    def test_nonminimal_der_length(self):
        data = fixture()
        self.assertLess(data[1], 128)
        self.rejected(b"\x30\x81" + data[1:])

    def test_negative_integer(self):
        data = fixture()
        self.rejected(data.replace(integer(32), b"\x02\x01\xff", 1))

    def test_nonminimal_integer(self):
        fields = (tlv(0x16, b"IM4P") + tlv(0x16, b"ibot")
                  + tlv(0x16, b"test") + tlv(4, b"bvx2synthetic")
                  + tlv(0x30, integer(1) + tlv(2, b"\0\x20")))
        self.rejected(tlv(0x30, fields))

    def test_container_limit(self):
        self.rejected(b"x" * (INSPECTOR.LIMIT + 1))

    def test_decode_success(self):
        data = fixture()
        info = INSPECTOR.parse_container(data)
        def decoder(output, capacity, source, size, workspace, algorithm):
            self.assertEqual(capacity, INSPECTOR.DECODE_LIMIT)
            self.assertEqual(algorithm, 0x801)
            self.assertEqual(size, info["payload_size"])
            ctypes.memmove(output, b"x" * 32, 32)
            return 32
        library = types.SimpleNamespace(compression_decode_buffer=decoder)
        with mock.patch.object(INSPECTOR, "_load_compression", return_value=library):
            self.assertEqual(INSPECTOR.decode_payload(data, info), b"x" * 32)

    def test_decode_rejects_failure_limit_and_mismatch(self):
        data = fixture()
        info = INSPECTOR.parse_container(data)
        for returned in (0, 31, INSPECTOR.DECODE_LIMIT):
            decoder = mock.Mock(return_value=returned)
            library = types.SimpleNamespace(compression_decode_buffer=decoder)
            with self.subTest(returned=returned), mock.patch.object(
                    INSPECTOR, "_load_compression", return_value=library):
                with self.assertRaises(ValueError):
                    INSPECTOR.decode_payload(data, info)

    def test_output_containment(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "scratch") as tmp:
            parent = pathlib.Path(tmp)
            child = parent / "new"
            self.assertEqual(INSPECTOR.validate_output_dir(child), child.resolve())
            for bad in (parent, ROOT, ROOT / "scratch", ROOT / "not-scratch-output"):
                with self.subTest(path=bad), self.assertRaises(ValueError):
                    INSPECTOR.validate_output_dir(bad)
            link = parent / "escape"
            link.symlink_to(ROOT, target_is_directory=True)
            with self.assertRaises(ValueError):
                INSPECTOR.validate_output_dir(link / "new")

    def test_scratch_root_symlink_rejected(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "scratch") as tmp:
            parent = pathlib.Path(tmp).resolve()
            repo, outside = parent / "repo", parent / "outside"
            repo.mkdir()
            outside.mkdir()
            scratch = repo / "scratch"
            scratch.symlink_to(outside, target_is_directory=True)
            with mock.patch.object(INSPECTOR, "REPO_ROOT", repo), mock.patch.object(
                    INSPECTOR, "SCRATCH_ROOT", scratch):
                with self.assertRaises(ValueError):
                    INSPECTOR.validate_output_dir(scratch / "new")

    def test_default_cli_does_not_decode_or_write(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "scratch") as tmp:
            path = pathlib.Path(tmp) / "fixture.im4p"
            path.write_bytes(fixture())
            output = io.StringIO()
            with mock.patch.object(INSPECTOR, "decode_payload") as decoder:
                with contextlib.redirect_stdout(output):
                    self.assertEqual(INSPECTOR.main([str(path)]), 0)
                decoder.assert_not_called()
            self.assertFalse(json.loads(output.getvalue())["decoded"])
            self.assertEqual(list(path.parent.iterdir()), [path])

    def test_cli_decode_failure_has_no_output_effect(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "scratch") as tmp:
            path = pathlib.Path(tmp) / "fixture.im4p"
            path.write_bytes(fixture())
            destination = path.parent / "decoded"
            with mock.patch.object(INSPECTOR, "decode_payload", side_effect=ValueError("bad")):
                with self.assertRaises(ValueError):
                    INSPECTOR.main([str(path), "--output-dir", str(destination)])
            self.assertFalse(destination.exists())

    def test_existing_output_rejected_before_decode(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "scratch") as tmp:
            path = pathlib.Path(tmp) / "fixture.im4p"
            path.write_bytes(fixture())
            with mock.patch.object(INSPECTOR, "decode_payload") as decoder:
                with self.assertRaises(ValueError):
                    INSPECTOR.main([str(path), "--output-dir", tmp])
                decoder.assert_not_called()

    def test_cli_writes_only_new_decode_and_receipt(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "scratch") as tmp:
            path = pathlib.Path(tmp) / "fixture.im4p"
            original = fixture()
            path.write_bytes(original)
            destination = path.parent / "decoded"
            with mock.patch.object(INSPECTOR, "decode_payload", return_value=b"x" * 32):
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(INSPECTOR.main(
                        [str(path), "--output-dir", str(destination)]), 0)
            self.assertEqual(path.read_bytes(), original)
            self.assertEqual(sorted(p.name for p in destination.iterdir()),
                             ["fixture.bin", "fixture.json"])
            self.assertEqual((destination / "fixture.bin").read_bytes(), b"x" * 32)
            report = json.loads((destination / "fixture.json").read_text())
            self.assertTrue(report["decoded"])
            self.assertFalse(report["installed_or_executed"])

    def test_cli_rejects_input_symlink(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "scratch") as tmp:
            path = pathlib.Path(tmp) / "fixture.im4p"
            path.write_bytes(fixture())
            link = path.parent / "link.im4p"
            link.symlink_to(path)
            with self.assertRaises(ValueError):
                INSPECTOR.main([str(link)])

    def test_wrong_size_trailer_shape(self):
        fields = (tlv(0x16, b"IM4P") + tlv(0x16, b"ibot")
                  + tlv(0x16, b"test") + tlv(4, b"bvx2synthetic"))
        for body in (integer(1), integer(1) + integer(32) + integer(0),
                     tlv(4, b"\x01") + integer(32)):
            self.rejected(tlv(0x30, fields + tlv(0x30, body)))

    def test_malformed_payp_wrapper(self):
        data = fixture(trailer=False)
        fields = data[2:]
        self.assertLess(data[1], 128)
        for trailer in (tlv(4, b"PAYP"), tlv(0x30, tlv(0x16, b"FAIL")),
                        tlv(0x30, b"") + b"\0"):
            self.rejected(tlv(0x30, fields + tlv(0xa0, trailer)))


if __name__ == "__main__":
    unittest.main()

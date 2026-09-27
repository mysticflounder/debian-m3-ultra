#!/usr/bin/env python3
"""Synthetic file-only regression tests; no Apple binary fixtures required."""

import contextlib
import importlib.util
import io
import os
import pathlib
import struct
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location(
    "inspection", pathlib.Path(__file__).with_name("inspect-local-kernelcache.py"))
inspection = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(inspection)


def der(tag, value):
    size = len(value)
    length = bytes([size]) if size < 128 else b"\x82" + size.to_bytes(2, "big")
    return bytes([tag]) + length + value


def im4p(compressed=b"bvx2fixture", kind=b"krnl"):
    return der(0x30, der(0x16, b"IM4P") + der(0x16, kind)
               + der(0x16, b"test") + der(4, compressed))


def header(kind, commands):
    return struct.pack("<8I", 0xfeedfacf, 0x100000c, 2, kind,
                       len(commands), sum(map(len, commands)), 0, 0) + b"".join(commands)


def fixture(duplicate=False, segment_offset=512, segment_size=16):
    name = b"com.apple.driver.Fixture\0"
    entry = struct.pack("<IIQQII", 0x80000035, 32 + len(name),
                        0xfffffe0000000100, 256, 32, 0) + name
    segment = struct.pack("<II16sQQQQIIII", 0x19, 72, b"__TEXT_EXEC",
                          0xfffffe0000000200, 16, segment_offset, segment_size,
                          5, 5, 0, 0)
    outer = header(12, [entry] * (2 if duplicate else 1))
    inner = header(11, [segment])
    return outer.ljust(256, b"\0") + inner.ljust(256, b"\0") + b"payload-original"


class InspectionTests(unittest.TestCase):
    def test_im4p_and_img4(self):
        for data in (im4p(), der(0x30, der(0x16, b"IMG4") + im4p()
                                + der(0xa0, b"opaque signature"))):
            offset, compressed = inspection.payload(data)
            self.assertEqual(compressed, b"bvx2fixture")
            self.assertEqual(data[offset:offset + len(compressed)], compressed)

    def test_long_der(self):
        self.assertEqual(inspection.payload(im4p(b"bvx2" + b"a" * 200))[1],
                         b"bvx2" + b"a" * 200)

    def test_bad_der_and_payloads(self):
        for data in (b"", b"\x30\x80", b"\x30\x85xxxxx", im4p()[:-1],
                     im4p() + b"x", im4p(kind=b"ibot"), im4p(b"encrypted"),
                     der(0x30, der(0x16, b"IMG4") + der(4, b"bad"))):
            with self.subTest(data=data), self.assertRaises(ValueError):
                inspection.payload(data)

    def test_view_preserves_offsets_and_data(self):
        original = fixture()
        result, details = inspection.view(original, "com.apple.driver.Fixture")
        self.assertEqual(len(result), len(original))
        self.assertEqual(result[:104], original[256:360])
        self.assertEqual(result[104:], original[104:])
        self.assertTrue(details["inspection_only_not_loadable"])

    def test_missing_duplicate_or_wrong_fileset(self):
        for data, name in ((fixture(), "missing"), (fixture(True), "com.apple.driver.Fixture"),
                           (header(11, []), "missing")):
            with self.subTest(name=name), self.assertRaises(ValueError):
                inspection.view(data, name)

    def test_segment_bounds(self):
        for offset, size in ((0, 16), (100, 16), (512, 17), (999999, 16)):
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                inspection.view(fixture(segment_offset=offset, segment_size=size),
                                "com.apple.driver.Fixture")

    def test_command_bounds(self):
        for data in (b"", header(12, [])[:31], header(12, [struct.pack("<II", 1, 0)]),
                     header(12, [struct.pack("<II", 1, 100)])):
            with self.subTest(data=data), self.assertRaises(ValueError):
                inspection.commands(data, 0)

    def test_decode_limits_and_magic(self):
        valid = header(12, [])
        for count, decoded in ((0, b""), (64, b""), (4, b"bad!"),
                               (4, b"\xcf\xfa\xed\xfe"), (len(valid), valid)):
            library = mock.Mock()
            library.compression_decode_buffer.return_value = count
            with mock.patch.object(inspection, "LIMIT", 64), \
                    mock.patch.object(inspection.ctypes, "CDLL", return_value=library), \
                    mock.patch.object(inspection.ctypes, "string_at", return_value=decoded):
                if decoded == valid:
                    self.assertFalse(inspection.decode(im4p())[1]["signature_verified"])
                else:
                    with self.assertRaises(ValueError):
                        inspection.decode(im4p())

    def test_cli_scope_exclusive_output_and_argument_guard(self):
        # Fixtures/output stay under project scratch, including simulated ROOT.
        with tempfile.TemporaryDirectory(dir=inspection.ROOT / "scratch") as directory:
            root = pathlib.Path(directory)
            (root / "scratch").mkdir()
            source = root / "input"
            source.write_bytes(fixture())
            output = root / "scratch" / "view"
            base = ["inspect", "view", str(source)]
            with mock.patch.object(inspection, "ROOT", root):
                with mock.patch("sys.argv", base + [str(output), "--entry", "com.apple.driver.Fixture"]), \
                        contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(inspection.main(), 0)
                for args in ([str(output), "--entry", "com.apple.driver.Fixture"],
                             [str(root / "outside"), "--entry", "com.apple.driver.Fixture"],
                             [str(root / "scratch" / "missing-entry")]):
                    with mock.patch("sys.argv", base + args), \
                            contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                        inspection.main()
                self.assertEqual(output.read_bytes()[512:], b"payload-original")
                self.assertFalse((root / "outside").exists())

    def test_cli_symlinks_cannot_escape_scratch(self):
        with tempfile.TemporaryDirectory(dir=inspection.ROOT / "scratch") as directory:
            root = pathlib.Path(directory)
            outside = root / "outside"
            outside.mkdir()
            scratch = root / "scratch"
            source = root / "input"
            source.write_bytes(fixture())
            scratch.symlink_to(outside, target_is_directory=True)
            with mock.patch.object(inspection, "ROOT", root):
                for nested in (False, True):
                    if nested:
                        scratch.unlink()
                        scratch.mkdir()
                        (scratch / "nested").symlink_to(outside, target_is_directory=True)
                    output = scratch / "nested" / "output" if nested else scratch / "output"
                    with mock.patch("sys.argv", ["inspect", "view", str(source), str(output),
                                                 "--entry", "com.apple.driver.Fixture"]), \
                            contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                        inspection.main()
                    self.assertEqual(list(outside.iterdir()), [])

    def test_cli_rejects_fifo_without_blocking(self):
        with tempfile.TemporaryDirectory(dir=inspection.ROOT / "scratch") as directory:
            root = pathlib.Path(directory)
            source = root / "fifo"
            os.mkfifo(source)
            output = root / "output"
            with mock.patch("sys.argv", ["inspect", "decode", str(source), str(output)]), \
                    contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                inspection.main()
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()

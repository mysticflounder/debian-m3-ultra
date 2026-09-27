#!/usr/bin/env python3
"""Synthetic bounded fixup-chain tests; no proprietary fixture required."""

import importlib.util
import pathlib
import struct
import unittest

SPEC = importlib.util.spec_from_file_location(
    "fixup", pathlib.Path(__file__).with_name("inspect-kernelcache-fixup.py"))
FIXUP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FIXUP)
BASE = 0x100000
BLOB = 0x2000
STARTS_SEGMENT = BLOB + 28 + 16


def fixture():
    data = bytearray(0x3000)
    commands = []
    for index, name in enumerate((b"__TEXT", b"__DATA", b"__LINKEDIT")):
        commands.append(struct.pack("<II16sQQQQIIII", 0x19, 72, name,
                                    BASE + index * 0x1000, 0x1000,
                                    index * 0x1000, 0x1000, 3, 3, 0, 0))
    blob = (struct.pack("<7I", 0, 28, 0, 0, 0, 0, 0)
            + struct.pack("<4I", 3, 0, 16, 0)
            + struct.pack("<IHHQIHH", 24, 0x1000, 8, 0x1000, 0, 1, 0x40))
    commands.append(struct.pack("<4I", 0x80000034, 16, BLOB, len(blob)))
    header = struct.pack("<8I", 0xfeedfacf, 0x100000c, 2, 12,
                         len(commands), sum(map(len, commands)), 0, 0)
    prefix = header + b"".join(commands)
    data[:len(prefix)] = prefix
    data[BLOB:BLOB + len(blob)] = blob
    struct.pack_into("<Q", data, 0x1040, (1 << 63) | (2 << 51) | 0x200)
    struct.pack_into("<Q", data, 0x1048, 0x240)
    return data


class Tests(unittest.TestCase):
    def test_both_chain_members(self):
        for offset, target, authenticated in ((0x1040, 0x200, True), (0x1048, 0x240, False)):
            result = FIXUP.resolve(fixture(), BASE + offset)
            self.assertEqual(result["target_vmaddr"], hex(BASE + target))
            self.assertEqual(result["page_chain_entries"], 2)
            self.assertTrue(result["chain_membership_validated"])
            self.assertEqual(result["authenticated_encoding"], authenticated)
            self.assertFalse(result["pac_authenticated"])

    def test_plausible_nonmember_rejected(self):
        data = fixture()
        struct.pack_into("<Q", data, 0x1060, 0x200)
        with self.assertRaisesRegex(ValueError, "not a chained pointer"):
            FIXUP.resolve(data, BASE + 0x1060)

    def test_entire_page_chain_checked_even_after_found(self):
        data = fixture()
        struct.pack_into("<Q", data, 0x1048, (0xfff << 51) | 0x240)
        with self.assertRaisesRegex(ValueError, "escapes"):
            FIXUP.resolve(data, BASE + 0x1040)

    def test_unsupported_format_level_or_page_kind(self):
        for kind in ("format", "level", "multi", "empty", "pagesize"):
            data = fixture()
            if kind == "format":
                struct.pack_into("<H", data, STARTS_SEGMENT + 6, 7)
            elif kind == "level":
                struct.pack_into("<Q", data, 0x1040, (1 << 30) | 0x200)
            elif kind == "pagesize":
                struct.pack_into("<H", data, STARTS_SEGMENT + 4, 0x2000)
            else:
                struct.pack_into("<H", data, STARTS_SEGMENT + 22,
                                 0x8000 if kind == "multi" else 0xffff)
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                FIXUP.resolve(data, BASE + 0x1040)

    def test_bad_starts_header_and_layout(self):
        for offset, fmt, value in ((BLOB, "I", 1), (BLOB + 16, "I", 1),
                                   (BLOB + 28, "I", 4), (STARTS_SEGMENT, "I", 23),
                                   (STARTS_SEGMENT + 8, "Q", 0x2000),
                                   (STARTS_SEGMENT + 20, "H", 100)):
            data = fixture()
            struct.pack_into("<" + fmt, data, offset, value)
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                FIXUP.resolve(data, BASE + 0x1040)

    def test_truncated_or_unmapped(self):
        for data, address in ((fixture()[:20], BASE), (fixture()[:-1], BASE + 0x1040),
                              (fixture(), BASE + 0x5000)):
            with self.assertRaises(ValueError):
                FIXUP.resolve(data, address)

    def test_target_must_be_file_backed(self):
        data = fixture()
        struct.pack_into("<Q", data, 0x1040, 0x5000)
        with self.assertRaisesRegex(ValueError, "file-backed"):
            FIXUP.resolve(data, BASE + 0x1040)


if __name__ == "__main__":
    unittest.main()

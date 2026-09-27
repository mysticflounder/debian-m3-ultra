#!/usr/bin/env python3
"""Portable synthetic tests; no firmware fixtures or hardware required."""
import importlib.util
import json
import pathlib
import struct
import unittest

ROOT = pathlib.Path(__file__).resolve().parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


DVFS = load("dvfs", "inspect-firmware-dvfs.py")
FIX = load("fixtures", "test-firmware-mcc.py")


def fixture(*, target="J575d", model="Mac15,14", compatible="pmgr1,t6031",
            cells=2, ranges=None, reg=None, stride=None, extras=False):
    pairs = [(0, 0)] * 60
    for index, base in ((6, 0x10e20000), (15, 0x11e20000), (26, 0x12e20000)):
        pairs[index] = base, 0x11e8
    reg = b"".join(struct.pack("<QQ", *pair) for pair in pairs) if reg is None else reg
    ranges = struct.pack("<QQQ", 0, 0x200000000, 0x400000000) if ranges is None else ranges
    stride = struct.pack("<Q", 0x2000000000) if stride is None else stride
    private = [("serial-number", FIX.string("DO-NOT-EMIT"))] if extras else []
    pmgr = FIX.node("pmgr", [("compatible", FIX.string(compatible)), ("reg", reg),
                              ("die-stride", stride), *private])
    arm = FIX.node("arm-io", [("#address-cells", FIX.scalar(cells)),
                              ("#size-cells", FIX.scalar(2)), ("ranges", ranges)], [pmgr])
    chosen = FIX.node("chosen", [("chip-id", FIX.scalar(0)), *private])
    root = FIX.node("device-tree", [("target-type", FIX.string(target)),
                                     ("model", FIX.string(model)),
                                     ("#address-cells", FIX.scalar(2)),
                                     ("#size-cells", FIX.scalar(2)), *private], [chosen, arm])
    return FIX.encode(root)


class FirmwareDvfsTests(unittest.TestCase):
    def reject(self, **kwargs):
        with self.assertRaises(ValueError):
            DVFS.inspect_adt(fixture(**kwargs))

    def test_translated_candidates(self):
        report = DVFS.inspect_adt(fixture())
        self.assertEqual([w["candidate_pstate_address"] for w in report["windows"]],
                         ["0x210e20020", "0x211e20020", "0x212e20020"])
        self.assertEqual([c["pstate_address"] for c in report["per_die_candidates"]],
                         ["0x210e20020", "0x211e20020", "0x212e20020",
                          "0x2210e20020", "0x2211e20020", "0x2212e20020"])
        self.assertFalse(report["hardware_validated"])
        self.assertFalse(report["installed_or_executed"])
        self.assertEqual(report["identity"]["template_chip_id"], "0x0")

    def test_identity(self):
        for options in ({"target": "J516c"}, {"model": "Mac15,9"}, {"compatible": "pmgr1,t6022"}):
            with self.subTest(options=options):
                self.reject(**options)

    def test_cell_count(self):
        for cells in (0, 1, 3):
            self.reject(cells=cells)

    def test_stride(self):
        self.reject(stride=b"\0" * 4)
        self.reject(stride=struct.pack("<Q", 0x1000000000))

    def test_reg_length(self):
        for reg in (b"", b"\0" * 959, b"\0" * 976):
            self.reject(reg=reg)

    def test_selected_window(self):
        data = fixture()
        nodes = DVFS.ADT.selected_nodes(data, ("/arm-io/pmgr",))
        reg = nodes["/arm-io/pmgr"]["reg"]
        for base, size in ((0x10e20001, 0x11e8), (0x10e20000, 0x20),
                           (0xfffffffffffffff8, 0x11e8), (0x11e20000, 0x11e8)):
            altered = bytearray(reg)
            struct.pack_into("<QQ", altered, 6 * 16, base, size)
            self.reject(reg=bytes(altered))

    def test_ranges_shape(self):
        for ranges in (b"", b"\0" * 23, b"\0" * (65 * 24)):
            self.reject(ranges=ranges)

    def test_no_containing_range(self):
        self.reject(ranges=struct.pack("<QQQ", 0, 0x200000000, 0x10e20020))

    def test_overlapping_ranges(self):
        entry = struct.pack("<QQQ", 0, 0x200000000, 0x400000000)
        self.reject(ranges=entry + entry)

    def test_unrelated_overlapping_ranges(self):
        ranges = b"".join(struct.pack("<QQQ", *entry) for entry in
                          ((0, 0x200000000, 0x400000000),
                           (0x580000000, 0x580000000, 0x80000000),
                           (0x5a0000000, 0x5a0000000, 0x20000000)))
        self.assertEqual(len(DVFS.inspect_adt(fixture(ranges=ranges))["windows"]), 3)

    def test_range_overflow(self):
        for values in ((0, 0xfffffffffffffff0, 0x100),
                       (0xfffffffffffffff0, 0, 0x100), (0, 0, 0)):
            self.reject(ranges=struct.pack("<QQQ", *values))

    def test_translated_alignment(self):
        self.reject(ranges=struct.pack("<QQQ", 0, 0x200000001, 0x400000000))

    def test_die_stride_overflow(self):
        self.reject(ranges=struct.pack("<QQQ", 0, 0xfffffff000000000, 0x400000000))

    def test_cross_die_overlap(self):
        ranges = b"".join(struct.pack("<QQQ", *entry) for entry in
                          ((0x10e20000, 0x210e20000, 0x11e8),
                           (0x11e20000, 0x2210e20000, 0x11e8),
                           (0x12e20000, 0x212e20000, 0x11e8)))
        self.reject(ranges=ranges)

    def test_nonzero_child_translation_and_boundaries(self):
        self.assertEqual(DVFS.translate(0x120, 0x20, [(0x100, 0x800, 0x40)]), (0, 0x820))
        with self.assertRaises(ValueError):
            DVFS.translate(0x120, 0x21, [(0x100, 0x800, 0x40)])

    def test_allowlist(self):
        self.assertNotIn("DO-NOT-EMIT", json.dumps(DVFS.inspect_adt(fixture(extras=True))))
        self.assertNotIn("serial-number", json.dumps(DVFS.inspect_adt(fixture(extras=True))))

    def test_truncated_tree(self):
        with self.assertRaises(ValueError):
            DVFS.inspect_adt(fixture()[:-8])

    def test_parser_selection(self):
        for paths in ((), ("/", "/"), ("/absent",)):
            with self.assertRaises(ValueError):
                DVFS.ADT.selected_nodes(fixture(), paths)


if __name__ == "__main__":
    unittest.main()

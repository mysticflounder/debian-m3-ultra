#!/usr/bin/env python3
"""Synthetic, portable tests for the offline firmware MCC ADT inspector."""

from __future__ import annotations

import importlib.util
import json
import pathlib
import struct
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("inspect_firmware_mcc", ROOT / "scripts/inspect-firmware-mcc.py")
INSPECTOR = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(INSPECTOR)


HEADER_SIZES = (0x20000, 0x149C, 0x4000, 0x4000)
BANK_SIZE = 0x2000000


def prop(name: str, value: bytes) -> tuple[str, bytes]:
    return name, value


def node(name: str, properties: list[tuple[str, bytes]] | None = None,
         children: list[dict] | None = None) -> dict:
    entries = [prop("name", name.encode("ascii") + b"\0")]
    entries.extend(properties or [])
    return {"properties": entries, "children": children or []}


def encode(tree: dict) -> bytes:
    properties = tree["properties"]
    children = tree["children"]
    out = bytearray(struct.pack("<II", len(properties), len(children)))
    for name, value in properties:
        encoded_name = name.encode("ascii")
        if len(encoded_name) >= 32:
            raise ValueError("synthetic property name too long")
        out += encoded_name + b"\0" * (32 - len(encoded_name))
        out += struct.pack("<I", len(value))
        out += value
        out += b"\0" * ((-len(value)) % 4)
    for child in children:
        out += encode(child)
    return bytes(out)


def scalar(value: int) -> bytes:
    return struct.pack("<I", value)


def string(value: str) -> bytes:
    return value.encode("ascii") + b"\0"


def reg_pairs(header_count: int, bank_count: int) -> bytes:
    pairs = []
    base = 0x10000000
    for index in range(header_count + bank_count):
        size = HEADER_SIZES[index] if index < header_count else BANK_SIZE
        pairs.append((base, size))
        base += size + 0x1000
    return b"".join(struct.pack("<QQ", base, size) for base, size in pairs)


def fixture(target: str = "J575d", model: str = "Mac15,14",
            *, compatible: str = "mcc,t6031", planes: int = 4, dcs: int = 4,
            reg: bytes | None = None, extra_mcc: list[tuple[str, bytes]] | None = None,
            extra_root: list[tuple[str, bytes]] | None = None) -> bytes:
    header_count, bank_count = (3, 8) if target == "J516c" else (4, 16)
    mcc_properties = [
        prop("compatible", string(compatible)),
        prop("plane-count-per-amcc", scalar(planes)),
        prop("dcs-count-per-amcc", scalar(dcs)),
        prop("reg", reg if reg is not None else reg_pairs(header_count, bank_count)),
    ]
    mcc_properties.extend(extra_mcc or [])
    arm_io = node("arm-io", children=[node("mcc", mcc_properties)])
    chosen = node("chosen", [prop("chip-id", scalar(0))])
    root = node("device-tree", [prop("target-type", string(target)), prop("model", string(model)),
                                *(extra_root or [])],
                [chosen, arm_io])
    return encode(root)


def assert_rejected(test: unittest.TestCase, data: bytes) -> None:
    with test.assertRaises((ValueError, UnicodeDecodeError)):
        INSPECTOR.inspect_adt(data)


class FirmwareMccTests(unittest.TestCase):
    def test_valid_max_shape(self) -> None:
        report = INSPECTOR.inspect_adt(fixture("J516c", "Mac15,9"))
        self.assertEqual(report["identity"]["target"], "J516c")
        self.assertEqual(report["identity"]["model"], "Mac15,9")
        self.assertEqual(report["mcc"]["reg_entry_count"], 11)
        self.assertEqual(report["mcc"]["header_count"], 3)
        self.assertEqual(report["mcc"]["instance_count"], 8)

    def test_valid_ultra_shape(self) -> None:
        report = INSPECTOR.inspect_adt(fixture())
        self.assertEqual(report["identity"]["target"], "J575d")
        self.assertEqual(report["identity"]["model"], "Mac15,14")
        self.assertEqual(report["mcc"]["reg_entry_count"], 20)
        self.assertEqual(report["mcc"]["header_count"], 4)
        self.assertEqual(report["mcc"]["instance_count"], 16)

    def test_truncated_node_property_and_value(self) -> None:
        valid = fixture()
        for data in (valid[:7], valid[:-1], valid[:40] + valid[44:]):
            with self.subTest(length=len(data)):
                assert_rejected(self, data)

    def test_malformed_property_length(self) -> None:
        data = bytearray(fixture())
        # The first property value length starts at 8+32.
        struct.pack_into("<I", data, 40, 0x100000)
        assert_rejected(self, bytes(data))

    def test_count_and_duplicate_property(self) -> None:
        data = fixture()
        # An excessive property count must fail before
        # attempting to interpret child bytes as properties.
        malformed_count = bytearray(data)
        struct.pack_into("<I", malformed_count, 0, 4097)
        assert_rejected(self, bytes(malformed_count))

        duplicate = fixture(extra_mcc=[prop("compatible", string("private"))])
        assert_rejected(self, duplicate)

    def test_depth_limit(self) -> None:
        child = node("leaf")
        for index in range(70):
            child = node(f"n{index}", children=[child])
        root = node("device-tree", [prop("target-type", string("J575d")), prop("model", string("Mac15,14"))],
                    [child])
        assert_rejected(self, encode(root))

    def test_unsupported_board_and_model(self) -> None:
        assert_rejected(self, fixture("J999x", "Mac99,9"))
        assert_rejected(self, fixture("J575d", "Mac15,9"))

    def test_wrong_compatibility_and_geometry(self) -> None:
        assert_rejected(self, fixture(compatible="mcc,t6032"))
        assert_rejected(self, fixture(planes=2))
        assert_rejected(self, fixture(dcs=8))

    def test_wrong_register_count(self) -> None:
        valid = reg_pairs(4, 16)
        assert_rejected(self, fixture(reg=valid[:-16]))
        assert_rejected(self, fixture(reg=valid + b"\0" * 16))

    def test_overlap_alignment_and_wrap(self) -> None:
        valid = list(struct.iter_unpack("<QQ", reg_pairs(4, 16)))
        overlap = list(valid)
        overlap[1] = (overlap[0][0], overlap[1][1])
        assert_rejected(self, fixture(reg=b"".join(struct.pack("<QQ", *pair) for pair in overlap)))

        unaligned = list(valid)
        unaligned[0] = (unaligned[0][0] + 2, unaligned[0][1])
        assert_rejected(self, fixture(reg=b"".join(struct.pack("<QQ", *pair) for pair in unaligned)))

        wraps = list(valid)
        wraps[0] = ((1 << 64) - 0x1000, HEADER_SIZES[0])
        assert_rejected(self, fixture(reg=b"".join(struct.pack("<QQ", *pair) for pair in wraps)))

    def test_private_properties_are_not_emitted(self) -> None:
        report = INSPECTOR.inspect_adt(
            fixture(extra_mcc=[prop("private-field", b"do-not-emit\0")],
                    extra_root=[prop("secret-root-field", b"do-not-emit\0")]))
        serialized = json.dumps(report, sort_keys=True)
        self.assertNotIn("private-field", serialized)
        self.assertNotIn("secret-root-field", serialized)
        self.assertNotIn("do-not-emit", serialized)
        self.assertNotIn('"reg"', serialized)


    def test_missing_and_duplicate_selected_nodes(self) -> None:
        root_props = [prop("target-type", string("J575d")), prop("model", string("Mac15,14"))]
        assert_rejected(self, encode(node("device-tree", root_props)))
        duplicate = node("device-tree", root_props,
                         [node("chosen", [prop("chip-id", scalar(0))]),
                          node("chosen", [prop("chip-id", scalar(0))])])
        assert_rejected(self, encode(duplicate))

    def test_exact_scalar_and_string_lengths(self) -> None:
        for data in (b"", b"\x04", scalar(4) + b"\0"):
            with self.assertRaises(ValueError):
                INSPECTOR.u32(data)
        for data in (b"", b"mcc,t6031", b"mcc\0t6031\0"):
            with self.assertRaises(ValueError):
                INSPECTOR.cstring(data)

    def test_wrong_sizes_and_endianness(self) -> None:
        entries = list(struct.iter_unpack("<QQ", reg_pairs(4, 16)))
        for index in (0, 3, 4, 19):
            broken = list(entries)
            base, size = broken[index]
            broken[index] = base, size - 4
            assert_rejected(self, fixture(reg=b"".join(struct.pack("<QQ", *e) for e in broken)))
        assert_rejected(self, fixture(reg=b"".join(struct.pack(">QQ", *e) for e in entries)))

    def test_trailing_data_and_node_name(self) -> None:
        assert_rejected(self, fixture() + b"\x01")
        self.assertEqual(INSPECTOR.inspect_adt(fixture() + b"\0\0"),
                         INSPECTOR.inspect_adt(fixture()))
        assert_rejected(self, encode(node("bad/name")))
        assert_rejected(self, fixture().replace(b"device-tree\0", b"other--root\0", 1))
        bad_padding = bytearray(fixture())
        bad_padding[8 + len("name") + 1] = 0x41
        assert_rejected(self, bytes(bad_padding))

    def test_invalid_im4p_rejected_before_decompression(self) -> None:
        for raw in (b"", b"\x30\x00", b"not an IM4P"):
            with self.assertRaises(ValueError):
                INSPECTOR.decode_im4p(raw)


if __name__ == "__main__":
    unittest.main(verbosity=2)

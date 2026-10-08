#!/usr/bin/env python3
"""Offline regression tests for the retained J575d T6032 PHY decoder.

These tests exercise the decoder's pure normalization functions against the
retained capture, native table, and compiled candidate DTB.  They never emit
Linux DT properties, launch code, access hardware, or alter frozen inputs.
"""

from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import pathlib
import struct
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
DECODER_PATH = ROOT / "scripts/decode-j575d-phy-calibration.py"
spec = importlib.util.spec_from_file_location("j575d_phy_decoder", DECODER_PATH)
if spec is None or spec.loader is None:
    raise RuntimeError(f"cannot import {DECODER_PATH}")
DECODER = importlib.util.module_from_spec(spec)
spec.loader.exec_module(DECODER)

EXPECTED_DTB_SHA = "832bdc15bcc9c0d5204a62e5d18b72574890b4df8e48b41dd2da5cf1f4c3d265"
FROZEN_CANDIDATE = ROOT / DECODER.DTB
RESOURCE_NAMES = ("core", "lpdptx", "axi2af", "usb2phy", "pipehandler")
FIXED_SELECTORS = {
    "tunable_ATC0AXI2AF": 41,
    "tunable_ATC_FABRIC": 40,
    "tunable_LN0_RX_CFG_TX_OF_RXCLK": 20,
    "tunable_LN1_RX_CFG_TX_OF_RXCLK": 29,
    "tunable_AUS40CMN_SHM": 5,
    "tunable_AUSPLL_CORE": 8,
    "tunable_CIO4PLL_CORE": 10,
    "tunable_UC_REGS_CIO_DFLT": 3,
    "tunable_LN0_RX_TOP_CIO_DFLT": 16,
    "tunable_LN1_RX_TOP_CIO_DFLT": 25,
    "tunable_LN0_RX_EQ_CIO_DFLT": 18,
    "tunable_LN1_RX_EQ_CIO_DFLT": 27,
}
BLOCK_NAMES = tuple(FIXED_SELECTORS)
USB2_BLOCKS = ("tunable_USB2PHY_DEV", "tunable_USB2PHY_HOST")
EXPECTED_PAYLOADS = set(BLOCK_NAMES) | set(USB2_BLOCKS)


def packed_words(*values: int) -> bytes:
    return struct.pack(f"<{len(values)}I", *values)


def update_blob(properties: dict, name: str, raw: bytes) -> None:
    properties[name] = {
        "hex": raw.hex(),
        "byte_length": len(raw),
        "sha256": hashlib.sha256(raw).hexdigest(),
    }


def raw_records(raw: bytes) -> list[tuple[int, int, int]]:
    return list(struct.iter_unpack("<III", raw))


class PhyDecoderTests(unittest.TestCase):
    capture: dict
    table: dict
    usb: object
    tree: object
    decoded: dict
    candidate: pathlib.Path

    @classmethod
    def setUpClass(cls) -> None:
        cls.candidate = FROZEN_CANDIDATE
        if not cls.candidate.is_file() or DECODER.sha(cls.candidate) != EXPECTED_DTB_SHA:
            raise AssertionError(f"frozen candidate DTB missing or changed: {cls.candidate}")
        cls.capture = json.loads((ROOT / DECODER.CAPTURE).read_text(encoding="utf-8"))
        cls.table = json.loads((ROOT / DECODER.TABLE).read_text(encoding="utf-8"))
        cls.usb = DECODER.load_usb()
        cls.tree = cls.usb.read_dtb(cls.candidate)
        cls.decoded = DECODER.normalize(copy.deepcopy(cls.capture), copy.deepcopy(cls.table),
                                        cls.usb, cls.tree)

    def normalize(self, capture=None, table=None):
        return DECODER.normalize(
            copy.deepcopy(self.capture if capture is None else capture),
            copy.deepcopy(self.table if table is None else table), self.usb, self.tree)

    def test_actual_receipts_and_deterministic_decoded_sha(self) -> None:
        for relative, expected in DECODER.INPUTS.items():
            if relative == DECODER.DTB:
                continue
            path = ROOT / relative
            self.assertTrue(path.is_file(), relative)
            self.assertEqual(DECODER.sha(path), expected, relative)
        self.assertEqual(DECODER.sha(self.candidate), EXPECTED_DTB_SHA)
        first = (json.dumps(self.decoded, indent=2, sort_keys=True) + "\n").encode()
        second = (json.dumps(self.normalize(), indent=2, sort_keys=True) + "\n").encode()
        self.assertEqual(hashlib.sha256(first).hexdigest(), "1c4f6142872e40bc58b77288379fb3822b080414f59a11a024c2a2624b5fb782")
        self.assertEqual(hashlib.sha256(first).digest(), hashlib.sha256(second).digest())

    def test_all_six_native_columns_join_and_all_fields_are_preserved(self) -> None:
        native = [(int(row["address"], 16), int(row["length"], 16))
                  for row in self.table["rows"]]
        self.assertEqual(len(native), 336)
        self.assertEqual(self.decoded["source_register_join_count"], 252)
        self.assertEqual(len(self.decoded["ports"]), 6)
        for entry, port in zip(self.capture["atc_phy"], self.decoded["ports"]):
            port_number = port["port"]
            self.assertEqual(port["source_capture_entry_index"],
                             self.capture["atc_phy"].index(entry))
            # The retained reg is 42 little-endian (address, size) pairs.
            banks = list(struct.iter_unpack("<QQ", DECODER.blob(entry["properties"], "reg")))
            self.assertEqual(len(banks), 42)
            for selector in range(42):
                self.assertEqual(banks[selector], native[selector * 8 + port_number - 1])
            for block in port["blocks"]:
                name = block["source_property"]
                self.assertEqual(block["selector"], FIXED_SELECTORS[name])
                self.assertEqual(block["source_capture_property_index"],
                                 list(entry["properties"]).index(name))
                expected_base, expected_size = banks[FIXED_SELECTORS[name]]
                self.assertEqual((block["bank_base"], block["bank_size"]),
                                 (expected_base, expected_size))
                raw = DECODER.blob(entry["properties"], block["source_property"])
                self.assertEqual(len(raw) % 12, 0, name)
                triples = list(struct.iter_unpack("<III", raw))
                self.assertEqual(len(block["records"]), len(triples), name)
                for index, (got, (word, mask, value)) in enumerate(zip(block["records"], triples)):
                    offset = word & 0x07FFFFFF
                    if offset & 0x04000000:
                        offset -= 0x08000000
                    self.assertGreaterEqual(offset, 0, name)
                    want = {"index": index, "source_word0": word,
                            "bank_offset": offset,
                            "physical_address": block["bank_base"] + offset,
                            "mask": mask, "value": value}
                    self.assertEqual(
                        {key: got[key] for key in ("index", "source_word0", "bank_offset",
                                                   "physical_address", "mask", "value")},
                        want,
                    )
                    resource, containment_offset = DECODER.classify(
                        want["physical_address"], port["linux_windows"])
                    self.assertEqual(got["linux_containing_resource"], resource)
                    self.assertEqual(got["linux_containment_offset"], containment_offset)
                self.assertEqual(block["source_sha256"], hashlib.sha256(raw).hexdigest())

    def test_counts_per_port_differences_and_resource_containment(self) -> None:
        self.assertEqual(sum(len(block["records"]) for port in self.decoded["ports"]
                             for block in port["blocks"]), 852)
        self.assertEqual(len(self.decoded["ports"]) * len(BLOCK_NAMES), 72)
        self.assertEqual(self.decoded["resource_record_counts"],
                         {"axi2af": 312, "core": 150, "unassigned": 390})
        self.assertEqual([port["native_column"] for port in self.decoded["ports"]], list(range(6)))
        self.assertEqual(len({port["source_node"] for port in self.decoded["ports"]}), 6)
        for port in self.decoded["ports"]:
            blocks = {block["source_property"]: block for block in port["blocks"]}
            self.assertEqual(set(blocks), set(BLOCK_NAMES))
            self.assertEqual({record["linux_containing_resource"] for record in blocks["tunable_ATC_FABRIC"]["records"]},
                             {None})
            self.assertEqual({record["linux_containing_resource"] for record in blocks["tunable_ATC0AXI2AF"]["records"]},
                             {"axi2af"})
            for name in BLOCK_NAMES:
                if name not in ("tunable_ATC_FABRIC", "tunable_ATC0AXI2AF"):
                    self.assertEqual({record["linux_containing_resource"] for record in blocks[name]["records"]},
                                     {"core"})
        for name in ("tunable_ATC_FABRIC", "tunable_AUS40CMN_SHM",
                     "tunable_AUSPLL_CORE", "tunable_CIO4PLL_CORE"):
            hashes = {block["source_sha256"] for port in self.decoded["ports"]
                      for block in port["blocks"] if block["source_property"] == name}
            self.assertGreater(len(hashes), 1, name)

    def test_no_usb2_conversion_or_linux_dt_emission(self) -> None:
        self.assertFalse(self.decoded["linux_properties_emitted"])
        self.assertFalse(self.decoded["native_validated"])
        self.assertEqual(tuple(DECODER.USB2_PROPERTIES), USB2_BLOCKS)
        self.assertNotIn("dts", self.decoded)
        self.assertNotIn("overlay", self.decoded)
        for entry in self.capture["atc_phy"]:
            self.assertEqual({name for name in entry["properties"] if name.startswith("tunable_")},
                             EXPECTED_PAYLOADS)
        for port in self.decoded["ports"]:
            self.assertEqual(tuple(port["unconverted_properties"]), tuple(DECODER.USB2_PROPERTIES))
            receipts = {item["property"]: item for item in port["unconverted_source_receipts"]}
            self.assertEqual(set(receipts), set(USB2_BLOCKS))
            source = self.capture["atc_phy"][port["port"] - 1]["properties"]
            for name in USB2_BLOCKS:
                raw = DECODER.blob(source, name)
                self.assertEqual(receipts[name]["byte_length"], len(raw))
                self.assertEqual(receipts[name]["sha256"], hashlib.sha256(raw).hexdigest())
            self.assertNotIn("tunable_USB2PHY_DEV", {b["source_property"] for b in port["blocks"]})
            self.assertNotIn("tunable_USB2PHY_HOST", {b["source_property"] for b in port["blocks"]})

    def test_capture_ordinals_are_provenance_not_native_application_order(self) -> None:
        capture = copy.deepcopy(self.capture)
        capture["atc_phy"][0], capture["atc_phy"][5] = (
            capture["atc_phy"][5], capture["atc_phy"][0])
        decoded = self.normalize(capture=capture)
        self.assertEqual([port["port"] for port in decoded["ports"]], list(range(1, 7)))
        by_port = {port["port"]: port for port in decoded["ports"]}
        self.assertEqual(by_port[1]["source_capture_entry_index"], 5)
        self.assertEqual(by_port[6]["source_capture_entry_index"], 0)
        self.assertEqual([block["source_property"] for block in by_port[1]["blocks"]], list(BLOCK_NAMES))
        self.assertIn("canonicalized by number", decoded["ordering"])
        self.assertIn("are not native application order", decoded["ordering"])
        for port in decoded["ports"]:
            source = capture["atc_phy"][port["source_capture_entry_index"]]["properties"]
            for block in port["blocks"]:
                self.assertEqual(block["source_capture_property_index"],
                                 list(source).index(block["source_property"]))

    def test_decode_arithmetic_and_validation_boundaries(self) -> None:
        def record(word: int, mask: int = 0, value: int = 0) -> bytes:
            return packed_words(word, mask, value)

        wide_offset = 0x02000000
        decoded = DECODER.decode_records(record((4 << 27) | wide_offset), 0x100000000,
                                          wide_offset + 4)
        self.assertEqual(decoded[0]["bank_offset"], wide_offset)
        self.assertGreater(decoded[0]["bank_offset"], 0xFFFFFF)
        self.assertNotEqual(decoded[0]["bank_offset"] & 0xFFFFFF, decoded[0]["bank_offset"])
        self.assertEqual(decoded[0]["physical_address"], 0x100000000 + wide_offset)
        self.assertEqual(DECODER.decode_records(record((4 << 27) | 0x20), 0x1000, 0x24)[0]["bank_offset"], 0x20)
        for raw, base, size in (
            (record((4 << 27) | 2), 0, 8),
            (record((4 << 27) | 0x24), 0, 0x24),
            (record((4 << 27) | 0x04000000), 0, 0x100),
            (record((4 << 27) | 0x07FFFFFF), 0, 0x100),
            (record(3 << 27), 0, 0x100),
            (record(5 << 27), 0, 0x100),
            (b"\0" * 11, 0, 0x100),
            (b"\0" * 13, 0, 0x100),
        ):
            with self.assertRaises(DECODER.DecodeError):
                DECODER.decode_records(raw, base, size)

    def test_blob_length_and_checksum_guards(self) -> None:
        properties = copy.deepcopy(self.capture["atc_phy"][0]["properties"])
        raw = DECODER.blob(properties, "tunable_AUS40CMN_SHM")
        properties["tunable_AUS40CMN_SHM"]["byte_length"] += 4
        with self.assertRaises(DECODER.DecodeError):
            DECODER.blob(properties, "tunable_AUS40CMN_SHM")
        properties = copy.deepcopy(self.capture["atc_phy"][0]["properties"])
        properties["tunable_AUS40CMN_SHM"]["sha256"] = "0" * 64
        with self.assertRaises(DECODER.DecodeError):
            DECODER.blob(properties, "tunable_AUS40CMN_SHM")
        self.assertEqual(len(raw), 12)

    def test_table_and_capture_shape_mutations_are_rejected(self) -> None:
        table = copy.deepcopy(self.table)
        table["count"] = 335
        with self.assertRaises(DECODER.DecodeError):
            self.normalize(table=table)
        table = copy.deepcopy(self.table)
        table["rows"][0]["raw_hex"] = "00" * 16
        with self.assertRaises(DECODER.DecodeError):
            self.normalize(table=table)
        table = copy.deepcopy(self.table)
        table["rows"][0], table["rows"][1] = table["rows"][1], table["rows"][0]
        with self.assertRaises(DECODER.DecodeError):
            self.normalize(table=table)

        capture = copy.deepcopy(self.capture)
        capture["atc_phy"][0]["properties"]["compatible"] = '<"atc-phy,t8122">'
        with self.assertRaises(DECODER.DecodeError):
            self.normalize(capture=capture)
        capture = copy.deepcopy(self.capture)
        capture["atc_phy"].pop()
        with self.assertRaises(DECODER.DecodeError):
            self.normalize(capture=capture)
        capture = copy.deepcopy(self.capture)
        capture["atc_phy"][0]["properties"]["tunable_UNKNOWN"] = copy.deepcopy(
            capture["atc_phy"][0]["properties"]["tunable_USB2PHY_DEV"])
        with self.assertRaises(DECODER.DecodeError):
            self.normalize(capture=capture)
        capture = copy.deepcopy(self.capture)
        update_blob(capture["atc_phy"][1]["properties"], "port-number", packed_words(1))
        with self.assertRaises(DECODER.DecodeError):
            self.normalize(capture=capture)

    def test_column_and_per_record_containment_mutations_are_rejected(self) -> None:
        native = [(int(row["address"], 16), int(row["length"], 16))
                  for row in self.table["rows"]]
        capture = copy.deepcopy(self.capture)
        entry = capture["atc_phy"][4]
        replacement = b"".join(struct.pack("<QQ", *native[selector * 8])
                                for selector in range(42))
        update_blob(entry["properties"], "reg", replacement)
        with self.assertRaises(DECODER.DecodeError):
            self.normalize(capture=capture)

        for name in USB2_BLOCKS:
            capture = copy.deepcopy(self.capture)
            properties = capture["atc_phy"][0]["properties"]
            raw = bytearray(DECODER.blob(properties, name))
            raw[0] ^= 0x01
            properties[name]["hex"] = bytes(raw).hex()
            with self.assertRaises(DECODER.DecodeError):
                self.normalize(capture=capture)

        capture = copy.deepcopy(self.capture)
        raw = bytearray(DECODER.blob(capture["atc_phy"][0]["properties"],
                                     "tunable_ATC0AXI2AF"))
        for offset in range(0, len(raw), 4):
            raw[offset:offset + 4] = raw[offset:offset + 4][::-1]
        update_blob(capture["atc_phy"][0]["properties"], "tunable_ATC0AXI2AF", bytes(raw))
        with self.assertRaises(DECODER.DecodeError):
            self.normalize(capture=capture)

    def test_classify_ambiguity_boundaries_and_safe_selector_controls(self) -> None:
        windows = [{"name": "a", "base": 0x100, "size": 8},
                   {"name": "b", "base": 0x104, "size": 8}]
        with self.assertRaises(DECODER.DecodeError):
            DECODER.classify(0x104, windows)
        self.assertEqual(DECODER.classify(0x108, windows), ("b", 4))
        self.assertEqual(DECODER.classify(0x110, windows), (None, None))

        original = DECODER.SELECTORS["tunable_ATC0AXI2AF"]
        DECODER.SELECTORS["tunable_ATC0AXI2AF"] = DECODER.SELECTORS["tunable_ATC_FABRIC"]
        try:
            with self.assertRaises(DECODER.DecodeError):
                self.normalize()
        finally:
            DECODER.SELECTORS["tunable_ATC0AXI2AF"] = original

        original = DECODER.SELECTORS["tunable_ATC_FABRIC"]
        DECODER.SELECTORS["tunable_ATC_FABRIC"] = DECODER.SELECTORS["tunable_AUS40CMN_SHM"]
        try:
            with self.assertRaises(DECODER.DecodeError):
                self.normalize()
        finally:
            DECODER.SELECTORS["tunable_ATC_FABRIC"] = original


if __name__ == "__main__":
    unittest.main(verbosity=2)

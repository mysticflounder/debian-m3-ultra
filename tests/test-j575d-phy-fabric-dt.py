#!/usr/bin/env python3
"""Independent offline audit of the compiled J575d generic Fabric DT candidate."""

from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import pathlib
import struct
import subprocess
import sys
import unittest
from typing import Callable

ROOT = pathlib.Path(__file__).resolve().parents[1]

# The DT audit is deliberately independent of the builder's ``plan`` and
# ``validate`` functions.  It consumes the raw little-endian capture and the
# compiled DTB, then compares manually unpacked big-endian DT properties.
DT_BUILDER_PATH = ROOT / "scripts/build-j575d-phy-fabric-dt.py"
DT_BUILDER_SPEC = importlib.util.spec_from_file_location(
    "j575d_phy_fabric_dt_builder", DT_BUILDER_PATH
)
if DT_BUILDER_SPEC is None or DT_BUILDER_SPEC.loader is None:
    raise RuntimeError(f"cannot import {DT_BUILDER_PATH}")
DT_BUILDER = importlib.util.module_from_spec(DT_BUILDER_SPEC)
DT_BUILDER_SPEC.loader.exec_module(DT_BUILDER)
DT_SCRATCH = ROOT / "scratch" / "j575d-phy-fabric-dt-tests-2026-10-08"
DT_DEFAULT_WORKSPACE: pathlib.Path | None = None


def dt_words(value: bytes) -> tuple[int, ...]:
    if len(value) % 4:
        raise AssertionError("non-cell property")
    return struct.unpack(f">{len(value) // 4}I", value)


def dt_strings(value: bytes) -> tuple[str, ...]:
    if not value.endswith(b"\0"):
        raise AssertionError("unterminated string property")
    return tuple(part.decode() for part in value[:-1].split(b"\0"))


def dt_pack_triples(raw: bytes, base: int, size: int, target_base: int | None = None,
                    target_size: int | None = None) -> bytes:
    if len(raw) < 12 or len(raw) % 12:
        raise AssertionError("capture triple length")
    output = bytearray()
    for word, mask, value in struct.iter_unpack("<III", raw):
        if word >> 27 != 4:
            raise AssertionError("capture class")
        offset = word & 0x07FFFFFF
        if offset & 0x04000000:
            offset -= 0x08000000
        if offset < 0 or offset % 4 or offset + 4 > size:
            raise AssertionError("capture offset bounds")
        physical = base + offset
        output_offset = physical - (base if target_base is None else target_base)
        limit = size if target_size is None else target_size
        if output_offset < 0 or output_offset % 4 or output_offset + 4 > limit:
            raise AssertionError("target offset bounds")
        output.extend(struct.pack(">III", output_offset, mask, value))
    return bytes(output)


class FabricDTCandidateTests(unittest.TestCase):
    """Raw-capture to compiled-DTB audit; no builder validation is trusted."""

    workspace: pathlib.Path
    usb: object
    before: dict[str, dict[str, bytes]]
    after: dict[str, dict[str, bytes]]
    capture: dict
    decoded: dict

    @classmethod
    def setUpClass(cls) -> None:
        decoder = DT_BUILDER.load_decoder()
        cls.usb, cls.before, cls.capture, cls.decoded = DT_BUILDER.receipts(decoder)
        workspace = DT_DEFAULT_WORKSPACE
        if workspace is None:
            candidates = sorted(ROOT.glob("scratch/j575d-phy-fabric-dt.*/candidate.dtb"),
                                key=lambda p: p.stat().st_mtime)
            if not candidates:
                raise AssertionError("compiled Fabric candidate.dtb not found")
            workspace = candidates[-1].parent
        cls.workspace = workspace
        cls.after = cls.usb.read_dtb(workspace / "candidate.dtb")
        DT_SCRATCH.mkdir(parents=True, exist_ok=True)

    def port(self, number: int) -> tuple[dict, str, dict[str, bytes]]:
        port = self.decoded["ports"][number - 1]
        path = self.usb.symbol(self.after, port["linux_label"])
        return port, path, self.after[path]

    def source_raw(self, port: dict, name: str) -> bytes:
        entry = self.capture["atc_phy"][port["source_capture_entry_index"]]
        item = entry["properties"][name]
        raw = bytes.fromhex(item["hex"])
        self.assertEqual(len(raw), item["byte_length"], name)
        self.assertEqual(hashlib.sha256(raw).hexdigest(), item["sha256"], name)
        return raw

    def expected_property(self, port: dict, name: str) -> bytes:
        block = next(item for item in port["blocks"] if item["source_property"] == name)
        banks = list(struct.iter_unpack(
            "<QQ", self.source_raw(port, "reg")
        ))
        if name == "tunable_ATC0AXI2AF":
            target_base, target_size = next((item["base"], item["size"])
                              for item in port["linux_windows"] if item["name"] == "axi2af")
        elif name == "tunable_ATC_FABRIC":
            target_base, target_size = banks[block["selector"]]
        else:
            target_base, target_size = next((item["base"], item["size"])
                              for item in port["linux_windows"] if item["name"] == "core")
        source_base, source_size = banks[block["selector"]]
        return dt_pack_triples(self.source_raw(port, name), source_base, source_size,
                               target_base, target_size)

    def audit(self, tree: dict[str, dict[str, bytes]]) -> None:
        self.assertEqual(set(tree), set(self.before), "node set changed")
        labels = {port["linux_label"] for port in self.decoded["ports"]}
        phy_paths = {self.usb.symbol(tree, label) for label in labels}
        allowed = {"reg", "reg-names", "apple,tunable-axi2af",
                   "apple,tunable-fabric", "apple,tunable-common-b", "status"}
        for path, old_props in self.before.items():
            new_props = tree[path]
            if path not in phy_paths:
                self.assertEqual(new_props, old_props, f"unexpected change {path}")
                continue
            changed = {name for name in set(old_props) | set(new_props)
                       if old_props.get(name) != new_props.get(name)}
            self.assertEqual(changed, allowed, f"PHY delta {path}")
            self.assertEqual(dt_strings(new_props["compatible"]),
                             ("apple,t6031-atcphy", "apple,t8122-atcphy"))
            self.assertEqual(dt_strings(new_props["reg-names"]),
                             ("core", "lpdptx", "axi2af", "usb2phy", "pipehandler", "fabric"))
            self.assertEqual(new_props["status"], b"disabled\0")
            self.assertEqual(len(new_props["reg"]), 6 * 16)
            self.assertEqual(new_props["reg"][:80], old_props["reg"])
            self.assertEqual(tuple(struct.iter_unpack(">QQ", new_props["reg"][:80])),
                             tuple(struct.iter_unpack(">QQ", old_props["reg"])))
            self.assertEqual(set(name for name in new_props if name.startswith("apple,tunable-")),
                             {"apple,tunable-axi2af", "apple,tunable-fabric", "apple,tunable-common-b"})

        physical_fabric_bases = set()
        for number in range(1, 7):
            port = self.decoded["ports"][number - 1]
            path = self.usb.symbol(tree, port["linux_label"])
            props = tree[path]
            blocks = {item["source_property"]: item for item in port["blocks"]}
            old_regs = tuple(struct.iter_unpack(">QQ", self.before[path]["reg"]))
            got_regs = tuple(struct.iter_unpack(">QQ", props["reg"]))
            fabric_child, fabric_size = got_regs[5]
            physical = self.usb.translated_regs(tree, path)
            self.assertEqual(tuple(physical[:5]),
                             tuple((window["base"], window["size"])
                                   for window in port["linux_windows"]), path)
            self.assertEqual(physical[5][1], 0x4000, path)
            self.assertEqual(physical[5][0], blocks["tunable_ATC_FABRIC"]["bank_base"], path)
            physical_fabric_bases.add(physical[5][0])
            self.assertEqual(fabric_size, 0x4000, path)
            self.assertEqual(props["apple,tunable-axi2af"],
                             self.expected_property(port, "tunable_ATC0AXI2AF"))
            self.assertEqual(props["apple,tunable-fabric"],
                             self.expected_property(port, "tunable_ATC_FABRIC"))
            common = (self.expected_property(port, "tunable_LN0_RX_CFG_TX_OF_RXCLK") +
                      self.expected_property(port, "tunable_LN1_RX_CFG_TX_OF_RXCLK"))
            self.assertEqual(props["apple,tunable-common-b"], common)
            for name in ("apple,tunable-axi2af", "apple,tunable-fabric", "apple,tunable-common-b"):
                self.assertGreater(len(props[name]), 0, name)
                self.assertEqual(len(props[name]) % 12, 0, name)
        self.assertEqual(len(physical_fabric_bases), 6, "Fabric selector-40 bases not unique")

        for number in range(6):
            self.assertEqual(tree[self.usb.symbol(tree, f"hpm{number}")]["status"], b"disabled\0")

    def test_compiled_candidate_manual_raw_audit(self) -> None:
        self.audit(self.after)
        self.assertEqual(sum(len(self.after[self.usb.symbol(self.after, p["linux_label"])] [name]) // 12
                             for p in self.decoded["ports"] for name in (
                                 "apple,tunable-axi2af", "apple,tunable-fabric",
                                 "apple,tunable-common-b")), 750)

    def reject(self, name: str, mutate: Callable[[dict[str, dict[str, bytes]], int], None]) -> None:
        mutant = copy.deepcopy(self.after)
        mutate(mutant, 1)
        try:
            self.audit(mutant)
        except (AssertionError, self.usb.BuildError):
            return
        self.fail(f"mutation accepted: {name}")

    def test_fixture_mutations_are_rejected(self) -> None:
        def triple(tree, number, prop="apple,tunable-axi2af", index=0, *, offset=None,
                   mask=None, value=None):
            port, path, _ = self.port(number)
            raw = bytearray(tree[path][prop])
            old = struct.unpack_from(">III", raw, index * 12)
            struct.pack_into(">III", raw, index * 12,
                             old[0] if offset is None else offset,
                             old[1] if mask is None else mask,
                             old[2] if value is None else value)
            tree[path][prop] = bytes(raw)

        self.reject("offset", lambda t, n: triple(t, n, offset=3))
        self.reject("bounds", lambda t, n: triple(t, n, offset=0x8000))
        self.reject("endian", lambda t, n: t[self.port(n)[1]].__setitem__(
            "apple,tunable-axi2af", t[self.port(n)[1]]["apple,tunable-axi2af"][::-1]))
        self.reject("wrong Fabric bank", lambda t, n: t[self.port(n)[1]].__setitem__(
            "reg", t[self.port(n)[1]]["reg"][:80] + struct.pack(">QQ", 0x12340000, 0x4000)))
        self.reject("mask", lambda t, n: triple(t, n, mask=0))
        self.reject("value", lambda t, n: triple(t, n, value=0))

        def reorder(tree, number):
            path = self.port(number)[1]
            raw = tree[path]["apple,tunable-common-b"]
            tree[path]["apple,tunable-common-b"] = raw[12:] + raw[:12]
        self.reject("order", reorder)
        self.reject("source", lambda t, n: t[self.port(n)[1]].__setitem__(
            "apple,tunable-common-b", t[self.port(n)[1]]["apple,tunable-fabric"]))
        self.reject("compatible", lambda t, n: t[self.port(n)[1]].__setitem__(
            "compatible", b"apple,t8122-atcphy\0"))
        self.reject("window name", lambda t, n: t[self.port(n)[1]].__setitem__(
            "reg-names", b"core\0lpdptx\0axi2af\0usb2phy\0pipehandler\0wrong\0"))
        self.reject("changed node", lambda t, n: t.__setitem__("/fixture-mutant", {}))
        self.reject("status", lambda t, n: t[self.port(n)[1]].__setitem__("status", b"okay\0"))
        self.reject("extra control", lambda t, n: t[self.port(n)[1]].__setitem__(
            "apple,tunable-common-a", b"\0" * 12))

    def test_ace3_and_phy_statuses_stay_disabled(self) -> None:
        for number in range(6):
            self.assertEqual(self.after[self.usb.symbol(self.after, f"hpm{number}")]["status"],
                             b"disabled\0")
        for port in self.decoded["ports"]:
            self.assertEqual(self.after[self.usb.symbol(self.after, port["linux_label"])]["status"],
                             b"disabled\0")

    def test_second_cli_is_byte_identical(self) -> None:
        first = self.workspace / "candidate.dtb"
        result = subprocess.run([sys.executable, str(DT_BUILDER_PATH)], cwd=ROOT,
                                check=True, capture_output=True, text=True)
        record = json.loads(result.stdout)
        second = ROOT / record["output"] / "candidate.dtb"
        self.assertEqual(first.read_bytes(), second.read_bytes())
        self.assertEqual(hashlib.sha256(first.read_bytes()).hexdigest(), record["dtb_sha256"])
        log = DT_SCRATCH / "dt-cli-reproducibility.log"
        log.write_text(f"first={first}\nsecond={second}\nsha256={record['dtb_sha256']}\n")




if __name__ == "__main__":
    unittest.main(verbosity=2)

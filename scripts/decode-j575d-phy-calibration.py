#!/usr/bin/env python3
"""Normalize retained J575d PHY payloads; never emit a DT or access hardware.

This is a fixed-evidence offline decoder, not a general Apple tunable loader.
Named blocks remain separate: their Linux property placement is not proven.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import pathlib
import struct
import sys
import tempfile
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parents[1]
INPUTS = {
    "scratch/j575d-usb-live-2026-10-08/derived/collector.json":
        "4a16a0950b00f265bef58374f8ec4ef4263db253db993b62c231d313545fd46c",
    "scratch/j575d-phy-native-map-2026-10-08/sRegisters.json":
        "d7352d12d1c19d7777482aeea5591aab2137f306c86cffc98f14ef479621da16",
    "scratch/j575d-phy-kc-metadata-2026-10-08/AppleT6032TypeCPhy.macho":
        "34766e9ca25405f64a08e25a47a71378ab2dd7df6b221d85f94c3aefbafdcc2e",
    "scratch/j575d-phy-native-map-2026-10-08/tunable-selector-map.md":
        "6f22639fdd9a5b2d23be49bbea24a5d764dac20cc873053479c65ef22e2bd523",
    "scratch/j575d-ace3-candidate.dif94rf2/candidate.dtb":
        "832bdc15bcc9c0d5204a62e5d18b72574890b4df8e48b41dd2da5cf1f4c3d265",
    "scripts/build-j575d-usb-layout.py":
        "5617d5bf3ddf7c0c0fce7e8aa2a17a0a8dd264c4bc73b3f258b624c26efcbc2d",
    "scripts/build-j575d-pcie-dt.py":
        "574e2cf4a5cac153180b4a137cc1d8c6fc1048f147cc51620abc8634338a8f63",
    "scratch/j575d-usb-drivers.6s0L0J/source/drivers/phy/apple/atc.c":
        "1b9517fd9b79e1c5fb0be4cd56d8c1443b78d08a138e56c09ca7321505f51eae",
}
CAPTURE, TABLE, VIEW, SELECTOR_RECEIPT, DTB, USB_SCRIPT, PCIE_SCRIPT, DRIVER = INPUTS
LABELS = ("atcphy0", "atcphy1", "atcphy2", "atcphy3", "atcphy0_die1", "atcphy1_die1")
RESOURCE_NAMES = ("core", "lpdptx", "axi2af", "usb2phy", "pipehandler")
USB2_PROPERTIES = ("tunable_USB2PHY_DEV", "tunable_USB2PHY_HOST")
# Instruction-level provider lookup / applyTunables selector witnesses, not M1 offsets.
SELECTORS = {
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


class DecodeError(ValueError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise DecodeError(message)


def sha(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def blob(properties: dict[str, Any], name: str) -> bytes:
    item = properties[name]
    raw = bytes.fromhex(item["hex"])
    require(len(raw) == item["byte_length"], f"{name}: byte length mismatch")
    require(hashlib.sha256(raw).hexdigest() == item["sha256"], f"{name}: byte hash mismatch")
    return raw


def decode_records(raw: bytes, base: int, size: int) -> list[dict[str, Any]]:
    """Decode only the observed class-4, nonnegative, aligned J575d records.

    Native arithmetic: lsl(w0,5), then sbfx(x0,5,27), i.e. sign-extend
    word0[26:0]. High-byte 0x20 is not a Linux resource index. Other native
    record classes and negative offsets are outside this decoder's scope.
    """
    require(len(raw) >= 12 and len(raw) % 12 == 0, "incomplete 12-byte records")
    require(base >= 0 and size >= 4, "invalid source bank")
    records = []
    for index, (word, mask, value) in enumerate(struct.iter_unpack("<III", raw)):
        require(word >> 27 == 4, "record class is outside observed J575d scope")
        offset = word & 0x07FFFFFF
        if offset & 0x04000000:
            offset -= 0x08000000
        require(offset >= 0, "negative offset is outside observed J575d scope")
        require(offset % 4 == 0 and offset + 4 <= size, "source bank offset out of bounds/alignment")
        records.append({"index": index, "source_word0": word, "bank_offset": offset,
                        "physical_address": base + offset, "mask": mask, "value": value})
    return records


def load_usb() -> Any:
    for name in (USB_SCRIPT, PCIE_SCRIPT):
        require(sha(ROOT / name) == INPUTS[name], f"changed helper {name}")
    spec = importlib.util.spec_from_file_location("j575d_phy_usb_layout", ROOT / USB_SCRIPT)
    require(spec is not None and spec.loader is not None, "missing USB helper")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def linux_windows(usb: Any, tree: Any, label: str) -> list[dict[str, Any]]:
    path = usb.symbol(tree, label)
    names = usb.strings(tree[path]["reg-names"])
    require(names == RESOURCE_NAMES, f"unexpected resource names {label}")
    regs = usb.translated_regs(tree, path)
    require(len(regs) == len(names), f"unexpected resource count {label}")
    return [{"name": name, "base": base, "size": size}
            for name, (base, size) in zip(names, regs)]


def classify(address: int, windows: list[dict[str, Any]]) -> tuple[str | None, int | None]:
    matches = [window for window in windows
               if window["base"] <= address and address + 4 <= window["base"] + window["size"]]
    require(len(matches) <= 1, "ambiguous Linux resource containment")
    if not matches:
        return None, None
    return matches[0]["name"], address - matches[0]["base"]


def normalize(capture: dict[str, Any], table: dict[str, Any], usb: Any, tree: Any) -> dict[str, Any]:
    require(capture["host_identity"]["chip"] == "J575dAP", "wrong board capture")
    rows = table["rows"]
    require(len(rows) == 336 and table["count"] == 336 and table["entry_size"] == 16,
            "expected 42 by 8 native register cells")
    native = []
    for index, row in enumerate(rows):
        require(row["index"] == index, "native register table row order mismatch")
        pair = int(row["address"], 16), int(row["length"], 16)
        require(struct.pack("<QQ", *pair).hex() == row["raw_hex"], "native register table byte mismatch")
        native.append(pair)
    ports = []
    seen: set[int] = set()
    source_join_count = 0
    counters: dict[str, int] = {}
    for source_entry_index, entry in enumerate(capture["atc_phy"]):
        properties = entry["properties"]
        require(properties["compatible"] == '<"atc-phy,t6032">', "wrong native PHY generation")
        names = {name for name in properties if name.startswith("tunable_")}
        require(names == set(SELECTORS) | set(USB2_PROPERTIES), "unexpected named payload set")
        # Verify these retained bytes too, without claiming their consumer contract.
        unconverted = [{"property": name, "byte_length": len(blob(properties, name)),
                        "sha256": properties[name]["sha256"]} for name in USB2_PROPERTIES]
        number = blob(properties, "port-number")
        require(len(number) == 4, "invalid captured port number")
        port = struct.unpack("<I", number)[0]
        require(port in range(1, 7) and port not in seen, "duplicate/out-of-scope port")
        seen.add(port)
        reg = blob(properties, "reg")
        require(len(reg) == 42 * 16, "expected 42 captured register tuples")
        banks = list(struct.iter_unpack("<QQ", reg))
        columns = [column for column in range(8)
                   if all(banks[selector] == native[selector * 8 + column] for selector in range(42))]
        require(len(columns) == 1, "native/capture column mismatch or ambiguity")
        column = columns[0]
        require(column == port - 1, "port/native column mismatch")
        source_join_count += 42
        label = LABELS[port - 1]
        windows = linux_windows(usb, tree, label)
        property_order = list(properties)
        blocks = []
        for name, selector in SELECTORS.items():
            raw = blob(properties, name)
            base, size = banks[selector]
            records = decode_records(raw, base, size)
            for record in records:
                resource, offset = classify(record["physical_address"], windows)
                record["linux_containing_resource"] = resource
                record["linux_containment_offset"] = offset
                key = resource or "unassigned"
                counters[key] = counters.get(key, 0) + 1
                # This pin does not have any window covering the fabric bank.
                expected = None if name == "tunable_ATC_FABRIC" else (
                    "axi2af" if name == "tunable_ATC0AXI2AF" else "core")
                require(resource == expected, f"unexpected compiled Linux containment {name}")
            blocks.append({"source_property": name, "selector": selector,
                           "source_capture_property_index": property_order.index(name),
                           "source_sha256": hashlib.sha256(raw).hexdigest(),
                           "bank_base": base, "bank_size": size, "records": records})
        ports.append({"port": port, "source_capture_entry_index": source_entry_index,
                      "native_column": column, "source_node": entry["node"],
                      "linux_label": label, "linux_windows": windows, "blocks": blocks,
                      "unconverted_properties": list(USB2_PROPERTIES),
                      "unconverted_source_receipts": unconverted})
    require(seen == set(range(1, 7)), "missing captured port")
    return {"schema_version": 1, "board": "J575dAP", "generation": "T6032",
            "ports": sorted(ports, key=lambda item: item["port"]),
            "source_register_join_count": source_join_count, "resource_record_counts": counters,
            "linux_properties_emitted": False, "native_validated": False,
            "ordering": "Ports are canonicalized by number; named blocks are inspection groups, not an execution schedule. Record byte order is preserved. Capture JSON entry/property ordinals are retained, but are not native application order.",
            "limits": ["Linux common-a/common-b and lane grouping not assigned",
                       "Linux resource fields describe physical containment only, not calibration placement",
                       "ATC_FABRIC is outside all five current Linux resource windows",
                       "USB2 host/device payloads need their own native consumer contract",
                       "Only captured class-4, aligned, nonnegative records decoded",
                       "Static register placement does not prove runtime mappings or writes"]}


def main() -> int:
    require(not sys.argv[1:], "usage: decode-j575d-phy-calibration.py")
    receipts = []
    for name, expected in INPUTS.items():
        require(sha(ROOT / name) == expected, f"input receipt changed: {name}")
        receipts.append({"path": name, "sha256": expected})
    usb = load_usb()
    decoded = normalize(json.loads((ROOT / CAPTURE).read_text()),
                        json.loads((ROOT / TABLE).read_text()), usb, usb.read_dtb(ROOT / DTB))
    require(decoded["source_register_join_count"] == 252 and
            decoded["resource_record_counts"] == {"axi2af": 312, "core": 150, "unassigned": 390},
            "fixed-capture result changed")
    work = pathlib.Path(tempfile.mkdtemp(prefix="j575d-phy-decoded.", dir=ROOT / "scratch"))
    output = work / "decoded.json"
    output.write_text(json.dumps(decoded, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    manifest = {"inputs": receipts, "decoder_sha256": sha(pathlib.Path(__file__)),
                "output": str(output.relative_to(ROOT)), "output_sha256": sha(output),
                "ports": 6, "named_blocks": 72, "records": 852,
                "linux_properties_emitted": False, "native_validated": False, "mmio": False}
    (work / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({"work": str(work.relative_to(ROOT)), "records": 852,
                      "source_register_join_count": 252, "resource_record_counts": decoded["resource_record_counts"],
                      "output_sha256": sha(output), "linux_properties_emitted": False}))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (DecodeError, OSError, KeyError, ValueError, struct.error) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)

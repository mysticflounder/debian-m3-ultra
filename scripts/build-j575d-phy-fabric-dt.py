#!/usr/bin/env python3
"""Build an inert J575d generic-calibration DT candidate from fixed receipts.

Only AXI2AF -> Fabric -> LN0 RX-clock -> LN1 RX-clock is assigned. This is
not a boot profile: PHY nodes are disabled and mode-specific inputs stay out.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parents[1]
DECODER = ROOT / "scripts/decode-j575d-phy-calibration.py"
DECODER_SHA = "39d8af4f8a33a6bfb780edb4dbf50c741bb971ef41d49fb737e220959f9f3950"
DECODED_SHA = "1c4f6142872e40bc58b77288379fb3822b080414f59a11a024c2a2624b5fb782"
PATCH = ROOT / "patches/linux/j575d-602042bf/0004-apple-atcphy-m3-fabric-calibration.patch"
PATCH_SHA = "30a6398b2c7bf568b7b02db75e40fb2f8f1bcbf1d935353fb0a54acb9649f038"
GENERIC = ("tunable_ATC0AXI2AF", "tunable_ATC_FABRIC",
           "tunable_LN0_RX_CFG_TX_OF_RXCLK", "tunable_LN1_RX_CFG_TX_OF_RXCLK")
ASSIGNED = ("apple,tunable-axi2af", "apple,tunable-fabric", "apple,tunable-common-b")
LEGACY_NAMES = ("core", "lpdptx", "axi2af", "usb2phy", "pipehandler")
COMPATIBLE = ("apple,t6031-atcphy", "apple,t8122-atcphy")


class CandidateError(ValueError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise CandidateError(message)


def sha(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def cells(raw: bytes) -> tuple[int, ...]:
    require(len(raw) % 4 == 0, "incomplete DT cells")
    return struct.unpack(f">{len(raw) // 4}I", raw)


def strings(raw: bytes) -> tuple[str, ...]:
    require(raw.endswith(b"\0"), "unterminated string property")
    return tuple(value.decode("utf-8") for value in raw[:-1].split(b"\0"))


def reservations(path: pathlib.Path) -> tuple[tuple[int, ...], tuple[tuple[int, int], ...]]:
    data = path.read_bytes()
    header = struct.unpack_from(">10I", data)
    require(header[0] == 0xD00DFEED and header[1] == len(data), "DTB header")
    position = header[4]
    entries = []
    while position + 16 <= len(data):
        address, length = struct.unpack_from(">QQ", data, position)
        position += 16
        if address == length == 0:
            return header[5:8], tuple(entries)
        entries.append((address, length))
    raise CandidateError("unterminated reservation map")


def load_decoder() -> Any:
    require(sha(DECODER) == DECODER_SHA, "decoder changed")
    require(sha(PATCH) == PATCH_SHA, "Fabric driver patch changed")
    spec = importlib.util.spec_from_file_location("j575d_phy_decoder", DECODER)
    require(spec is not None and spec.loader is not None, "decoder import")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    for relative, expected in module.INPUTS.items():
        require(sha(ROOT / relative) == expected, f"input changed: {relative}")
    return module


def receipts(decoder: Any) -> tuple[Any, dict, dict, dict]:
    usb = decoder.load_usb()
    before = usb.read_dtb(ROOT / decoder.DTB)
    capture = json.loads((ROOT / decoder.CAPTURE).read_text())
    table = json.loads((ROOT / decoder.TABLE).read_text())
    decoded = decoder.normalize(capture, table, usb, before)
    encoded = (json.dumps(decoded, indent=2, sort_keys=True) + "\n").encode()
    require(hashlib.sha256(encoded).hexdigest() == DECODED_SHA, "decoded receipt changed")
    return usb, before, capture, decoded


def tuples(blocks: list[dict], base: int, size: int) -> bytes:
    result = bytearray()
    for block in blocks:
        for record in block["records"]:
            offset = record["physical_address"] - base
            require(0 <= offset <= size - 4 and offset % 4 == 0,
                    f"record outside assigned window: {block['source_property']}")
            result.extend(struct.pack(">III", offset, record["mask"], record["value"]))
    require(bool(result), "empty calibration group")
    return bytes(result)


def plan(usb: Any, before: dict, decoded: dict) -> dict[str, dict[str, bytes]]:
    result = {}
    require(len(decoded["ports"]) == 6, "expected six ports")
    for port in decoded["ports"]:
        path = usb.symbol(before, port["linux_label"])
        properties = before[path]
        require(strings(properties["compatible"]) == COMPATIBLE, "compatible pair")
        require(strings(properties["reg-names"]) == LEGACY_NAMES, "legacy window names")
        require(len(properties["reg"]) == 5 * 16, "legacy resource count/cell layout")
        require(all(name not in properties for name in ASSIGNED), "existing tunable overwritten")
        parent = path.rsplit("/", 1)[0]
        require(cells(before[parent]["#address-cells"]) == (2,) and
                cells(before[parent]["#size-cells"]) == (2,), "parent resource cells")
        windows = {window["name"]: window for window in port["linux_windows"]}
        blocks = {block["source_property"]: block for block in port["blocks"]}
        core, axi, fabric = windows["core"], windows["axi2af"], blocks[GENERIC[1]]
        child_core, core_length = struct.unpack_from(">QQ", properties["reg"])
        require(core_length == core["size"], "core size mismatch")
        delta = core["base"] - child_core
        child_fabric = fabric["bank_base"] - delta
        require(0 <= child_fabric < 1 << 64 and fabric["bank_size"] == 0x4000,
                "Fabric child range")
        result[path] = {
            "reg": properties["reg"] + struct.pack(">QQ", child_fabric, fabric["bank_size"]),
            "reg-names": properties["reg-names"] + b"fabric\0",
            "apple,tunable-axi2af": tuples([blocks[GENERIC[0]]], axi["base"], axi["size"]),
            "apple,tunable-fabric": tuples([fabric], fabric["bank_base"], fabric["bank_size"]),
            "apple,tunable-common-b": tuples([blocks[GENERIC[2]], blocks[GENERIC[3]]],
                                             core["base"], core["size"]),
            "status": b"disabled\0",
        }
    require(len(result) == 6, "duplicate PHY paths")
    return result


def validate(usb: Any, before: dict, after: dict, decoded: dict) -> dict[str, int]:
    expected = plan(usb, before, decoded)
    require(set(before) == set(after), "DT node set changed")
    changed = 0
    for path, properties in before.items():
        wanted = {**properties, **expected.get(path, {})}
        require(after[path] == wanted, f"unexpected property delta: {path}")
        changed += sum(properties.get(name) != value for name, value in wanted.items())
    for port in decoded["ports"]:
        path = usb.symbol(after, port["linux_label"])
        blocks = {block["source_property"]: block for block in port["blocks"]}
        physical = usb.translated_regs(after, path)
        legacy = [(window["base"], window["size"]) for window in port["linux_windows"]]
        require(physical == legacy + [(blocks[GENERIC[1]]["bank_base"], 0x4000)],
                "Fabric resource translation or legacy windows changed")
        require(after[path]["status"] == b"disabled\0", "PHY candidate enabled")
        for node in (f"hpm{port['port'] - 1}",):
            require(after[usb.symbol(after, node)].get("status") == b"disabled\0",
                    "ACE3 endpoint enabled")
    counts = {name: sum(len(properties[name]) // 12 for properties in expected.values())
              for name in ASSIGNED}
    require(counts == {"apple,tunable-axi2af": 312, "apple,tunable-fabric": 390,
                      "apple,tunable-common-b": 48}, "generic tuple counts")
    return {"ports": 6, "generic_records": sum(counts.values()),
            "axi2af_records": 312, "fabric_records": 390, "rx_clock_records": 48,
            "changed_properties": changed}


def main() -> int:
    require(len(sys.argv) == 1, "this fixed-evidence builder takes no arguments")
    decoder = load_decoder()
    usb, before, _, decoded = receipts(decoder)
    changes = plan(usb, before, decoded)
    fdtput = shutil.which("fdtput")
    dtc = shutil.which("dtc")
    require(bool(fdtput) and bool(dtc), "fdtput/dtc unavailable")
    work = pathlib.Path(tempfile.mkdtemp(prefix="j575d-phy-fabric-dt.", dir=ROOT / "scratch"))
    candidate = work / "candidate.dtb"
    shutil.copyfile(ROOT / decoder.DTB, candidate)
    commands = []
    for path, properties in changes.items():
        for name, raw in properties.items():
            numeric = name == "reg" or name in ASSIGNED
            values = [f"{value:x}" for value in cells(raw)] if numeric else list(strings(raw))
            command = [fdtput, "-t", "x" if numeric else "s", str(candidate), path, name, *values]
            run = subprocess.run(command, text=True, capture_output=True)
            require(run.returncode == 0, f"fdtput failed for {path}/{name}: {run.stderr[:300]}")
            commands.append(command)
    after = usb.read_dtb(candidate)
    counts = validate(usb, before, after, decoded)
    require(reservations(candidate) == reservations(ROOT / decoder.DTB),
            "DTB version, boot CPU or reservations changed")
    command = [dtc, "-I", "dtb", "-O", "dts", "-o", str(work / "candidate.dts"), str(candidate)]
    run = subprocess.run(command, text=True, capture_output=True)
    (work / "dtc.stderr").write_text(run.stderr)
    require(run.returncode == 0, "candidate decompile failed")
    commands.append(command)
    roundtrip = work / "roundtrip.dtb"
    command = [dtc, "-I", "dts", "-O", "dtb", "-o", str(roundtrip), str(work / "candidate.dts")]
    run = subprocess.run(command, text=True, capture_output=True)
    (work / "roundtrip.stderr").write_text(run.stderr)
    require(run.returncode == 0, "candidate roundtrip compile failed")
    commands.append(command)
    require(usb.read_dtb(roundtrip) == after and
            reservations(roundtrip) == reservations(candidate), "DTC roundtrip changed candidate")
    manifest = {
        "scope": "inert generic-calibration integration candidate, not boot approved",
        "inputs": {**decoder.INPUTS, str(DECODER.relative_to(ROOT)): DECODER_SHA,
                   str(PATCH.relative_to(ROOT)): PATCH_SHA},
        "script_sha256": sha(pathlib.Path(__file__)),
        "decoded_sha256": DECODED_SHA,
        "candidate_sha256": sha(candidate),
        "roundtrip_sha256": sha(roundtrip),
        "roundtrip_tree_identical": True,
        "reservations_and_boot_cpu_preserved": True,
        "counts": counts,
        "order": {"apple,tunable-axi2af": [GENERIC[0]], "apple,tunable-fabric": [GENERIC[1]],
                  "apple,tunable-common-b": list(GENERIC[2:])},
        "mode_specific_records_unconverted": 102,
        "usb2_records_unconverted": 12,
        "native_validated": False,
        "mmio_performed": False,
        "phy_nodes_disabled": True,
        "commands": commands,
    }
    (work / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"output": str(work.relative_to(ROOT)), "dtb_sha256": sha(candidate),
                      **counts, "native_validated": False}, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (CandidateError, OSError, KeyError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
